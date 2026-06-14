import Foundation
import XCTest
@testable import VaraCore

final class DictationHistoryItemDecodingTests: XCTestCase {
    /// History written by older builds has no modeName/targetAppName keys and
    /// must keep decoding.
    func testDecodesLegacyItemWithoutModeAndTargetApp() throws {
        let legacyJSON = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "rawTranscript": "gammel diktering",
            "backend": "scribe-realtime",
            "elapsedTranscriptionSeconds": 1.5,
            "insertionStatus": "inserted",
            "createdAt": "2026-04-16T10:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let item = try decoder.decode(DictationHistoryItem.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(item.rawTranscript, "gammel diktering")
        XCTAssertNil(item.modeName)
        XCTAssertNil(item.targetAppName)
        XCTAssertNil(item.cleanedTranscript)
    }

    func testRoundTripsWithModeAndTargetApp() throws {
        let item = DictationHistoryItem(
            rawTranscript: "rå",
            cleanedTranscript: "renset",
            backend: "groq",
            modeName: "Ren tekst",
            targetAppName: "Mail",
            elapsedTranscriptionSeconds: 0.8,
            insertionStatus: .inserted,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            DictationHistoryItem.self,
            from: encoder.encode(item)
        )

        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.targetAppName, "Mail")
    }
}
