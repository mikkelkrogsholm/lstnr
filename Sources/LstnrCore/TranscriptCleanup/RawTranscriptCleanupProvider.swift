import Foundation

public struct RawTranscriptCleanupProvider: TranscriptCleanupProvider {
    public let id = "raw"
    public let displayName = "Raw Transcript"
    public let supportedModes: Set<TranscriptCleanupMode> = [.raw]

    public init() {}

    public func cleanup(_ request: TranscriptCleanupRequest) async throws -> TranscriptCleanupResult {
        guard supportedModes.contains(request.mode) else {
            throw TranscriptCleanupProviderError.unsupportedMode(providerID: id, mode: request.mode)
        }

        return TranscriptCleanupResult(
            rawText: request.rawText,
            cleanedText: request.rawText,
            mode: request.mode,
            providerID: id
        )
    }
}
