import Foundation
import XCTest
@testable import LstnrCore

final class DictationStatsTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        return calendar
    }()

    // Friday 2026-06-12 12:00 local time.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: 12, hour: 12))!
    }

    func testEmptyHistoryYieldsZeroStats() {
        let stats = DictationStats.compute(items: [], now: now, calendar: calendar)

        XCTAssertEqual(stats.totalDictations, 0)
        XCTAssertEqual(stats.wordsTotal, 0)
        XCTAssertEqual(stats.wordsToday, 0)
        XCTAssertEqual(stats.wordsThisWeek, 0)
        XCTAssertEqual(stats.spokenSecondsTotal, 0)
        XCTAssertEqual(stats.estimatedSavedSeconds, 0)
        XCTAssertTrue(stats.averageTranscriptionSecondsByBackend.isEmpty)
    }

    func testWordsAreBucketedByDayAndWeek() {
        let items = [
            item(text: "en to tre", daysAgo: 0),            // today: 3 words
            item(text: "fire fem", daysAgo: 2),              // this week (Wednesday): 2 words
            item(text: "seks syv otte ni", daysAgo: 30),     // long ago: 4 words
        ]

        let stats = DictationStats.compute(items: items, now: now, calendar: calendar)

        XCTAssertEqual(stats.totalDictations, 3)
        XCTAssertEqual(stats.wordsToday, 3)
        XCTAssertEqual(stats.wordsThisWeek, 5)
        XCTAssertEqual(stats.wordsTotal, 9)
    }

    func testCleanedTranscriptIsPreferredForWordCount() {
        let items = [
            item(text: "raw raw raw raw", cleanedText: "kun tre ord", daysAgo: 0)
        ]

        let stats = DictationStats.compute(items: items, now: now, calendar: calendar)

        XCTAssertEqual(stats.wordsTotal, 3)
    }

    func testSavedTimeUsesTypingBaselineMinusSpokenTime() {
        // 40 words spoken in 30 seconds. Typing at 40 WPM would take 60s → saved 30s.
        let text = Array(repeating: "ord", count: 40).joined(separator: " ")
        let items = [item(text: text, daysAgo: 0, audioDurationSeconds: 30)]

        let stats = DictationStats.compute(items: items, now: now, calendar: calendar)

        XCTAssertEqual(stats.spokenSecondsTotal, 30, accuracy: 0.001)
        XCTAssertEqual(stats.estimatedSavedSeconds, 30, accuracy: 0.001)
    }

    func testMissingAudioDurationFallsBackToSpeakingRate() {
        // 150 words without duration → assumed 60s spoken, typing 225s → saved 165s.
        let text = Array(repeating: "ord", count: 150).joined(separator: " ")
        let items = [item(text: text, daysAgo: 0, audioDurationSeconds: nil)]

        let stats = DictationStats.compute(items: items, now: now, calendar: calendar)

        XCTAssertEqual(stats.spokenSecondsTotal, 60, accuracy: 0.001)
        XCTAssertEqual(stats.estimatedSavedSeconds, 165, accuracy: 0.001)
    }

    func testAverageTranscriptionSecondsGroupsByBackend() {
        let items = [
            item(text: "a", daysAgo: 0, backend: "scribe", elapsed: 1.0),
            item(text: "b", daysAgo: 0, backend: "scribe", elapsed: 3.0),
            item(text: "c", daysAgo: 0, backend: "groq", elapsed: 0.5),
        ]

        let stats = DictationStats.compute(items: items, now: now, calendar: calendar)

        XCTAssertEqual(stats.averageTranscriptionSecondsByBackend["scribe"]!, 2.0, accuracy: 0.001)
        XCTAssertEqual(stats.averageTranscriptionSecondsByBackend["groq"]!, 0.5, accuracy: 0.001)
    }

    func testWordCountIgnoresExtraWhitespace() {
        XCTAssertEqual(DictationStats.wordCount(of: "  et   to\n\ttre  "), 3)
        XCTAssertEqual(DictationStats.wordCount(of: ""), 0)
        XCTAssertEqual(DictationStats.wordCount(of: "   "), 0)
    }

    private func item(
        text: String,
        cleanedText: String? = nil,
        daysAgo: Int,
        audioDurationSeconds: Double? = 1,
        backend: String = "test",
        elapsed: Double = 0.5
    ) -> DictationHistoryItem {
        DictationHistoryItem(
            rawTranscript: text,
            cleanedTranscript: cleanedText,
            backend: backend,
            audioDurationSeconds: audioDurationSeconds,
            elapsedTranscriptionSeconds: elapsed,
            insertionStatus: .inserted,
            createdAt: calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        )
    }
}
