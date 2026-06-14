import Foundation

public struct TranscriptCleanupRequest: Equatable, Sendable {
    public let rawText: String
    public let mode: TranscriptCleanupMode

    public init(rawText: String, mode: TranscriptCleanupMode) {
        self.rawText = rawText
        self.mode = mode
    }
}

public struct TranscriptCleanupResult: Equatable, Sendable {
    public let rawText: String
    public let cleanedText: String
    public let mode: TranscriptCleanupMode
    public let providerID: String

    public init(
        rawText: String,
        cleanedText: String,
        mode: TranscriptCleanupMode,
        providerID: String
    ) {
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.mode = mode
        self.providerID = providerID
    }
}

public enum TranscriptCleanupProviderError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedMode(providerID: String, mode: TranscriptCleanupMode)

    public var description: String {
        switch self {
        case .unsupportedMode(let providerID, let mode):
            return "Transcript cleanup provider '\(providerID)' does not support mode '\(mode.rawValue)'"
        }
    }
}

public protocol TranscriptCleanupProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportedModes: Set<TranscriptCleanupMode> { get }

    func cleanup(_ request: TranscriptCleanupRequest) async throws -> TranscriptCleanupResult
}
