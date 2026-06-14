import Foundation

public actor DictationHistoryStore {
    public typealias Clock = @Sendable () -> Date

    private let fileURL: URL
    private let maxRecentCount: Int
    private let clock: Clock
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        fileURL: URL,
        maxRecentCount: Int = 100,
        clock: @escaping Clock = Date.init
    ) {
        self.fileURL = fileURL
        self.maxRecentCount = max(1, maxRecentCount)
        self.clock = clock

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    @discardableResult
    public func add(
        rawTranscript: String,
        cleanedTranscript: String? = nil,
        backend: String,
        modeName: String? = nil,
        targetAppName: String? = nil,
        detectedLanguage: String? = nil,
        requestedLanguage: String? = nil,
        audioDurationSeconds: Double? = nil,
        elapsedTranscriptionSeconds: Double,
        insertionStatus: DictationInsertionStatus
    ) throws -> DictationHistoryItem? {
        guard rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        let item = DictationHistoryItem(
            rawTranscript: rawTranscript,
            cleanedTranscript: cleanedTranscript?.nilIfBlank,
            backend: backend,
            modeName: modeName?.nilIfBlank,
            targetAppName: targetAppName?.nilIfBlank,
            detectedLanguage: detectedLanguage?.nilIfBlank,
            requestedLanguage: requestedLanguage?.nilIfBlank,
            audioDurationSeconds: audioDurationSeconds,
            elapsedTranscriptionSeconds: elapsedTranscriptionSeconds,
            insertionStatus: insertionStatus,
            createdAt: clock()
        )
        var items = try loadItems()
        items.append(item)
        try saveItems(items)
        return item
    }

    public func listRecent() throws -> [DictationHistoryItem] {
        Array(try loadItems().newestFirst().prefix(maxRecentCount))
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        let items = try loadItems()
        let remainingItems = items.filter { $0.id != id }
        guard remainingItems.count != items.count else {
            return false
        }
        try saveItems(remainingItems)
        return true
    }

    public func clear() throws {
        try saveItems([])
    }

    private func loadItems() throws -> [DictationHistoryItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        guard data.isEmpty == false else {
            return []
        }

        do {
            return try decoder.decode([DictationHistoryItem].self, from: data)
        } catch DecodingError.dataCorrupted,
                DecodingError.keyNotFound,
                DecodingError.typeMismatch,
                DecodingError.valueNotFound {
            return []
        }
    }

    private func saveItems(_ items: [DictationHistoryItem]) throws {
        let recentItems = Array(items.newestFirst().prefix(maxRecentCount))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(recentItems)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension Array where Element == DictationHistoryItem {
    func newestFirst() -> [DictationHistoryItem] {
        sorted { left, right in
            if left.createdAt == right.createdAt {
                return left.id.uuidString > right.id.uuidString
            }
            return left.createdAt > right.createdAt
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
