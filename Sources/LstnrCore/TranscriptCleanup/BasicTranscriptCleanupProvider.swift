import Foundation

public struct BasicTranscriptCleanupProvider: TranscriptCleanupProvider {
    public let id = "basic-clean"
    public let displayName = "Basic Clean"
    public let supportedModes: Set<TranscriptCleanupMode> = [.clean]

    public init() {}

    public func cleanup(_ request: TranscriptCleanupRequest) async throws -> TranscriptCleanupResult {
        guard supportedModes.contains(request.mode) else {
            throw TranscriptCleanupProviderError.unsupportedMode(providerID: id, mode: request.mode)
        }

        return TranscriptCleanupResult(
            rawText: request.rawText,
            cleanedText: Self.cleanText(request.rawText),
            mode: request.mode,
            providerID: id
        )
    }

    public static func cleanText(_ rawText: String) -> String {
        var text = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        text = text.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: " *\\n *",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\s+([,.;:!?])",
            with: "$1",
            options: .regularExpression
        )

        return text
    }
}
