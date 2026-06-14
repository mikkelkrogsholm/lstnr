import Foundation

/// Aggregate dictation statistics computed from history items.
public struct DictationStats: Equatable, Sendable {
    public let totalDictations: Int
    public let wordsToday: Int
    public let wordsThisWeek: Int
    public let wordsTotal: Int
    public let spokenSecondsTotal: Double
    public let estimatedSavedSeconds: Double
    public let averageTranscriptionSecondsByBackend: [String: Double]

    /// Assumed typing speed used to estimate time saved by speaking instead.
    public static let typingWordsPerMinute: Double = 40

    /// Assumed speaking speed used when an item has no recorded audio duration.
    public static let speakingWordsPerMinute: Double = 150

    public static func compute(
        items: [DictationHistoryItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DictationStats {
        var wordsToday = 0
        var wordsThisWeek = 0
        var wordsTotal = 0
        var spokenSecondsTotal = 0.0
        var estimatedSavedSeconds = 0.0
        var transcriptionSecondsByBackend: [String: (total: Double, count: Int)] = [:]

        for item in items {
            let transcript = item.cleanedTranscript ?? item.rawTranscript
            let words = wordCount(of: transcript)
            wordsTotal += words

            if calendar.isDate(item.createdAt, inSameDayAs: now) {
                wordsToday += words
            }
            if calendar.isDate(item.createdAt, equalTo: now, toGranularity: .weekOfYear) {
                wordsThisWeek += words
            }

            let spokenSeconds = item.audioDurationSeconds
                ?? Double(words) / speakingWordsPerMinute * 60
            spokenSecondsTotal += spokenSeconds

            let typingSeconds = Double(words) / typingWordsPerMinute * 60
            estimatedSavedSeconds += max(0, typingSeconds - spokenSeconds)

            let existing = transcriptionSecondsByBackend[item.backend] ?? (0, 0)
            transcriptionSecondsByBackend[item.backend] = (
                existing.total + item.elapsedTranscriptionSeconds,
                existing.count + 1
            )
        }

        return DictationStats(
            totalDictations: items.count,
            wordsToday: wordsToday,
            wordsThisWeek: wordsThisWeek,
            wordsTotal: wordsTotal,
            spokenSecondsTotal: spokenSecondsTotal,
            estimatedSavedSeconds: estimatedSavedSeconds,
            averageTranscriptionSecondsByBackend: transcriptionSecondsByBackend.mapValues {
                $0.total / Double($0.count)
            }
        )
    }

    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
