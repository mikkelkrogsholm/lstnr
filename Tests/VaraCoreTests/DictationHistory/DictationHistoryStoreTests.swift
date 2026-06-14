import Foundation
import XCTest
@testable import VaraCore

final class DictationHistoryStoreTests: XCTestCase {
    func testAddPersistsEveryNonEmptyDictationField() async throws {
        let fileURL = try makeHistoryFileURL()
        let clock = DictationHistoryTestClock([
            Date(timeIntervalSince1970: 1_000),
            Date(timeIntervalSince1970: 2_000),
        ])
        let store = DictationHistoryStore(fileURL: fileURL, clock: clock.now)

        let olderItem = try await store.add(
            rawTranscript: "raw one",
            cleanedTranscript: "clean one",
            backend: "scribe-v2",
            detectedLanguage: "en",
            requestedLanguage: "da",
            audioDurationSeconds: 3.25,
            elapsedTranscriptionSeconds: 0.42,
            insertionStatus: .inserted
        )
        let newerItem = try await store.add(
            rawTranscript: "raw two",
            backend: "scribe-realtime",
            detectedLanguage: nil,
            requestedLanguage: nil,
            audioDurationSeconds: nil,
            elapsedTranscriptionSeconds: 0.25,
            insertionStatus: .notInserted
        )

        let reloadedStore = DictationHistoryStore(fileURL: fileURL, clock: clock.now)
        let items = try await reloadedStore.listRecent()
        let olderItemID = try XCTUnwrap(olderItem?.id)
        let newerItemID = try XCTUnwrap(newerItem?.id)

        XCTAssertEqual(items.map(\.id), [newerItemID, olderItemID])
        XCTAssertEqual(items[1].rawTranscript, "raw one")
        XCTAssertEqual(items[1].cleanedTranscript, "clean one")
        XCTAssertEqual(items[1].backend, "scribe-v2")
        XCTAssertEqual(items[1].detectedLanguage, "en")
        XCTAssertEqual(items[1].requestedLanguage, "da")
        XCTAssertEqual(items[1].audioDurationSeconds, 3.25)
        XCTAssertEqual(items[1].elapsedTranscriptionSeconds, 0.42)
        XCTAssertEqual(items[1].insertionStatus, .inserted)
        XCTAssertEqual(items[1].createdAt, Date(timeIntervalSince1970: 1_000))
    }

    func testAddSkipsWhitespaceOnlyTranscript() async throws {
        let fileURL = try makeHistoryFileURL()
        let store = DictationHistoryStore(
            fileURL: fileURL,
            clock: { Date(timeIntervalSince1970: 1_000) }
        )

        let item = try await store.add(
            rawTranscript: " \n\t ",
            backend: "scribe-v2",
            elapsedTranscriptionSeconds: 0.1,
            insertionStatus: .notInserted
        )

        let items = try await store.listRecent()

        XCTAssertNil(item)
        XCTAssertEqual(items, [])
    }

    func testListRecentReturnsEmptyWhenFileIsMissingOrCorrupt() async throws {
        let fileURL = try makeHistoryFileURL()
        let store = DictationHistoryStore(fileURL: fileURL)

        let missingFileItems = try await store.listRecent()
        XCTAssertEqual(missingFileItems, [])

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)

        let corruptFileItems = try await store.listRecent()
        XCTAssertEqual(corruptFileItems, [])
    }

    func testMaxRecentCountIsConfigurable() async throws {
        let fileURL = try makeHistoryFileURL()
        let clock = DictationHistoryTestClock([
            Date(timeIntervalSince1970: 1_000),
            Date(timeIntervalSince1970: 2_000),
            Date(timeIntervalSince1970: 3_000),
        ])
        let store = DictationHistoryStore(fileURL: fileURL, maxRecentCount: 2, clock: clock.now)

        try await store.add(
            rawTranscript: "first",
            backend: "test",
            elapsedTranscriptionSeconds: 0.1,
            insertionStatus: .inserted
        )
        let second = try await store.add(
            rawTranscript: "second",
            backend: "test",
            elapsedTranscriptionSeconds: 0.2,
            insertionStatus: .inserted
        )
        let third = try await store.add(
            rawTranscript: "third",
            backend: "test",
            elapsedTranscriptionSeconds: 0.3,
            insertionStatus: .inserted
        )

        let items = try await store.listRecent()
        let secondItemID = try XCTUnwrap(second?.id)
        let thirdItemID = try XCTUnwrap(third?.id)

        XCTAssertEqual(items.map(\.id), [thirdItemID, secondItemID])
        XCTAssertEqual(items.map(\.rawTranscript), ["third", "second"])
    }

    func testDeleteAndClearUpdatePersistedHistory() async throws {
        let fileURL = try makeHistoryFileURL()
        let clock = DictationHistoryTestClock([
            Date(timeIntervalSince1970: 1_000),
            Date(timeIntervalSince1970: 2_000),
        ])
        let store = DictationHistoryStore(fileURL: fileURL, clock: clock.now)
        let first = try await store.add(
            rawTranscript: "first",
            backend: "test",
            elapsedTranscriptionSeconds: 0.1,
            insertionStatus: .inserted
        )
        let second = try await store.add(
            rawTranscript: "second",
            backend: "test",
            elapsedTranscriptionSeconds: 0.2,
            insertionStatus: .inserted
        )

        let deleted = try await store.delete(id: try XCTUnwrap(first?.id))
        let deletedAgain = try await store.delete(id: try XCTUnwrap(first?.id))
        let itemsAfterDelete = try await store.listRecent()
        let secondItemID = try XCTUnwrap(second?.id)

        XCTAssertTrue(deleted)
        XCTAssertFalse(deletedAgain)
        XCTAssertEqual(itemsAfterDelete.map(\.id), [secondItemID])

        try await store.clear()

        let reloadedStore = DictationHistoryStore(fileURL: fileURL)
        let itemsAfterClear = try await reloadedStore.listRecent()
        XCTAssertEqual(itemsAfterClear, [])
    }
}

private func makeHistoryFileURL(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("VaraCoreTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL.appendingPathComponent("dictation-history.json")
}

private final class DictationHistoryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        guard dates.isEmpty == false else {
            return Date(timeIntervalSince1970: 0)
        }
        return dates.removeFirst()
    }
}
