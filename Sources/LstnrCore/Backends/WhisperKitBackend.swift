import Foundation
import WhisperKit

/// On-device speech-to-text via WhisperKit (Core ML + Apple Neural Engine).
///
/// Unlike `LocalHviskeBackend` — which shells out to a user-installed Python and
/// PyTorch — this runs entirely in-process: WhisperKit loads an `.mlmodelc` and
/// runs it on the ANE/GPU. The CoreML model is downloaded from HuggingFace
/// (`argmaxinc/whisperkit-coreml`) the first time the engine is used and cached
/// under Application Support, so the first dictation after selecting WhisperKit
/// pays a one-time download + model-specialization cost; later runs are instant.
///
/// The non-`Sendable` `WhisperKit` pipeline is fully encapsulated inside
/// `WhisperKitEngine` (an actor): the model never crosses an isolation boundary,
/// only the resulting text does.
public struct WhisperKitBackend: SpeechToTextBackend {
    /// Default model: the large-v3 turbo CoreML variant — Argmax's macOS
    /// recommendation for speed + multilingual accuracy (covers Danish). Other
    /// HuggingFace `argmaxinc/whisperkit-coreml` variants can be passed to `init`.
    public static let defaultModel = "large-v3-v20240930_turbo"

    /// CoreML model variants offered in Settings, newest/best first. These are
    /// names from the `argmaxinc/whisperkit-coreml` HuggingFace repo; the App
    /// layer maps them to localized labels. The full Turbo is fastest, the
    /// compressed Turbo is the best balance for Danish accuracy, and `small` is a
    /// lightweight fallback for weaker machines or tighter disk budgets.
    public static let availableModelIDs: [String] = [
        "large-v3-v20240930_turbo",
        "large-v3-v20240930_626MB",
        "small",
    ]

    public let id = "local-whisperkit"
    public let displayName: String
    public let capabilities = SpeechToTextBackendCapabilities(
        supportsFileTranscription: true,
        supportsStreamingTranscription: false,
        supportsLanguageHints: true,
        supportsTimestamps: true,
        runsLocally: true,
        // Steady-state truth: transcription is fully local. Only the one-time
        // first-run model download touches the network (handled by WhisperKit).
        requiresNetwork: false,
        requiredCredentialKeys: [],
        supportedSampleRates: [16_000]
    )

    private let model: String
    private let engine: WhisperKitEngine
    private let diagnosticLog: (@Sendable (String) async -> Void)?

    public init(
        model: String = WhisperKitBackend.defaultModel,
        diagnosticLog: (@Sendable (String) async -> Void)? = nil
    ) {
        self.model = model
        self.displayName = "Local WhisperKit (\(model))"
        self.diagnosticLog = diagnosticLog
        self.engine = WhisperKitEngine(model: model, downloadBase: Self.downloadBaseURL)
    }

    public func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult {
        let startedAt = Date()
        let audio = try await materializeAudioFile(from: request.audio)
        defer { audio.cleanup() }

        let language = Self.mapLanguage(request.languageCode)
        await diagnosticLog?(
            "WhisperKit starting. model=\(model), language=\(language ?? "auto"), downloadBase=\(Self.downloadBaseURL.path)"
        )

        let log = diagnosticLog
        let outcome = try await engine.transcribe(
            audioPath: audio.url.path,
            language: language
        ) { message in
            await log?(message)
        }

        await diagnosticLog?(
            "WhisperKit completed. textLength=\(outcome.text.count), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s"
        )

        return TranscriptionResult(
            text: outcome.text,
            detectedLanguage: outcome.detectedLanguage,
            languageConfidence: nil,
            audioDurationSeconds: audio.durationSeconds,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            backend: displayName,
            rawJSON: nil
        )
    }

    /// Base directory for the cached CoreML models. WhisperKit nests the model
    /// repo/name beneath this, so everything lives under the app's own folder
    /// instead of polluting `~/Documents`.
    public static var downloadBaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("lstnr/models/whisperkit", isDirectory: true)
    }

    /// Whisper expects 2-letter ISO codes ("da", "en"); a nil/empty hint lets the
    /// model auto-detect. WhisperKit is multilingual, so auto-detect is safe here.
    static func mapLanguage(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return String(code.prefix(2)).lowercased()
    }

    /// Whether the CoreML model is already cached on disk (so selecting it needs
    /// no download). WhisperKit stores variants prefixed under the repo path
    /// (e.g. `openai_whisper-<variant>`), so we match the variant suffix and
    /// require at least one compiled `.mlmodelc` to call it ready.
    public static func isModelDownloaded(_ model: String) -> Bool {
        let repoDir = downloadBaseURL
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: repoDir.path) else {
            return false
        }
        guard let match = entries.first(where: { $0 == model || $0.hasSuffix("-\(model)") }) else {
            return false
        }
        let modelDir = repoDir.appendingPathComponent(match, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    /// Downloads a CoreML model from HuggingFace, streaming download progress as a
    /// fraction in 0...1. The stream finishes when the download completes and
    /// throws if it fails; cancelling the consuming task cancels the download.
    public static func downloadModel(_ model: String) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try? FileManager.default.createDirectory(at: downloadBaseURL, withIntermediateDirectories: true)
                    _ = try await WhisperKit.download(
                        variant: model,
                        downloadBase: downloadBaseURL,
                        progressCallback: { progress in
                            continuation.yield(progress.fractionCompleted)
                        }
                    )
                    continuation.yield(1.0)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Owns the loaded `WhisperKit` pipeline. The model is loaded lazily on first use
/// and cached for the lifetime of the backend, so repeated dictations reuse it.
///
/// This is a plain (non-isolated) class rather than an actor on purpose: `WhisperKit`
/// is non-Sendable and its `transcribe`/`init` are `nonisolated async`, so an actor
/// would have to "send" the pipeline across its isolation boundary to call them
/// (a data-race diagnostic). With no isolation domain there is nothing to send;
/// thread-safety for the cached pointer comes from `NSLock` instead. The lock is
/// only held around the pointer read/write (never across an `await`); a rare race
/// of two first-time callers would at worst load the model twice, never corrupt it.
private final class WhisperKitEngine: @unchecked Sendable {
    private let model: String
    private let downloadBase: URL
    private let lock = NSLock()
    private var pipe: WhisperKit?

    init(model: String, downloadBase: URL) {
        self.model = model
        self.downloadBase = downloadBase
    }

    func transcribe(
        audioPath: String,
        language: String?,
        log: @Sendable (String) async -> Void
    ) async throws -> (text: String, detectedLanguage: String?) {
        let pipe = try await loadedPipe(log: log)
        let options = DecodingOptions(language: language)
        let results = try await pipe.transcribe(audioPath: audioPath, decodeOptions: options)
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, results.first?.language ?? language)
    }

    private func loadedPipe(log: @Sendable (String) async -> Void) async throws -> WhisperKit {
        if let cached = lock.withLock({ pipe }) { return cached }
        try? FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        await log("WhisperKit loading model '\(model)' — first run downloads + specializes the CoreML model…")
        let config = WhisperKitConfig(
            model: model,
            downloadBase: downloadBase,
            verbose: false
        )
        let created = try await WhisperKit(config)
        lock.withLock { pipe = created }
        await log("WhisperKit model ready.")
        return created
    }
}

private extension WhisperKitBackend {
    struct MaterializedAudio {
        let url: URL
        let durationSeconds: Double
        let isTemporary: Bool

        func cleanup() {
            if isTemporary { try? FileManager.default.removeItem(at: url) }
        }
    }

    func materializeAudioFile(from audio: SpeechToTextAudio) async throws -> MaterializedAudio {
        switch audio {
        case .file(let url):
            // WhisperKit's AudioProcessor decodes/resamples on its own, so the
            // user's file is passed through untouched (and never deleted).
            return MaterializedAudio(url: url, durationSeconds: 0, isTemporary: false)
        case .pcm16Stream(let stream, let sampleRate):
            guard sampleRate == 16_000 else {
                throw SpeechToTextBackendError.unsupportedAudio(
                    backendID: id,
                    reason: "WhisperKit expects PCM s16le mono at 16000 Hz; received \(sampleRate) Hz."
                )
            }
            var pcm = Data()
            for await chunk in stream {
                pcm.append(chunk)
            }
            guard !pcm.isEmpty else {
                throw SpeechToTextBackendError.unsupportedAudio(backendID: id, reason: "recorded audio is empty")
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("lstnr-whisperkit-\(UUID().uuidString).wav")
            try Self.writePCM16WAV(data: pcm, sampleRate: sampleRate, to: url)
            return MaterializedAudio(
                url: url,
                durationSeconds: Double(pcm.count / 2) / Double(sampleRate),
                isTemporary: true
            )
        }
    }

    static func writePCM16WAV(data: Data, sampleRate: Int, to url: URL) throws {
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let bitsPerSample = UInt16(16)
        let dataSize = UInt32(data.count)
        let riffSize = UInt32(36 + data.count)

        var wav = Data()
        wav.appendASCII("RIFF")
        wav.appendLittleEndian(riffSize)
        wav.appendASCII("WAVE")
        wav.appendASCII("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.appendASCII("data")
        wav.appendLittleEndian(dataSize)
        wav.append(data)
        try wav.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
