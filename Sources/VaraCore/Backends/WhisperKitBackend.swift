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
        // NOTE: the compressed "large-v3-v20240930_626MB" variant ships without
        // TextDecoderContextPrefill and hangs at transcribe time on the ANE here,
        // so it is intentionally NOT offered. See isModelDownloaded notes.
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

    /// Pays WhisperKit's one-time CoreML/ANE specialization (~175s on first run)
    /// OFF the real-dictation path by running a short silent buffer through the
    /// engine, then caching the warm pipe in-process. Idempotent (a no-op once
    /// warm). The Task can be abandoned (cancelled on reconfigure), but an ANE
    /// compile already in flight is uncancellable and runs to completion — it is
    /// simply not awaited; a still-queued prewarm aborts at the gate's
    /// `checkCancellation` without doing redundant work.
    ///
    /// WHY: loading the pipe is cheap; the cost is in the FIRST `pipe.transcribe`
    /// (the ANE compile), so we must actually run one prediction here. Called from
    /// AppState after a model download completes, never on the dictation path.
    public func prewarm() async throws {
        let log = diagnosticLog
        try await engine.prewarm { message in
            await log?(message)
        }
    }

    /// Base directory for the cached CoreML models. WhisperKit nests the model
    /// repo/name beneath this, so everything lives under the app's own folder
    /// instead of polluting `~/Documents`.
    public static var downloadBaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("vara/models/whisperkit", isDirectory: true)
    }

    /// Whisper expects 2-letter ISO codes ("da", "en"); a nil/empty hint lets the
    /// model auto-detect. WhisperKit is multilingual, so auto-detect is safe here.
    static func mapLanguage(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return String(code.prefix(2)).lowercased()
    }

    /// The compiled CoreML models every WhisperKit variant ships and needs to
    /// run. `TextDecoderContextPrefill` is deliberately NOT here: it is an
    /// optional prefill optimization that some variants ship and others (e.g.
    /// `large-v3-v20240930_626MB`) do not.
    private static let requiredModelArtifacts = [
        "AudioEncoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    /// Whether the CoreML model is fully cached on disk (so selecting it needs no
    /// download). WhisperKit stores variants prefixed under the repo path (e.g.
    /// `openai_whisper-<variant>`), so we match the variant suffix. We require the
    /// core compiled models AND `config.json`, each non-empty — a partial/aborted
    /// download can leave the folder present but with an empty `.mlmodelc` or a
    /// missing config, which would later hang at transcribe time. (Note: this
    /// detects *incomplete* downloads, not a complete-but-broken variant.)
    public static func isModelDownloaded(_ model: String) -> Bool {
        let fm = FileManager.default
        let repoDir = downloadBaseURL
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(atPath: repoDir.path),
              let match = entries.first(where: { $0 == model || $0.hasSuffix("-\(model)") }) else {
            return false
        }
        let modelDir = repoDir.appendingPathComponent(match, isDirectory: true)

        for artifact in requiredModelArtifacts {
            let dir = modelDir.appendingPathComponent(artifact)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  let inner = try? fm.contentsOfDirectory(atPath: dir.path), !inner.isEmpty else {
                return false
            }
        }
        return fm.fileExists(atPath: modelDir.appendingPathComponent("config.json").path)
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
    /// Whether at least one prediction (prewarm or a real dictation) has already
    /// run this session, so the ANE specialization is paid. Guarded by `lock`
    /// (NOT the gate) so `prewarm()` can fast-return without serializing.
    private var didPredict = false

    /// Serializes ENTRY to `pipe.transcribe`. WHY: the non-Sendable `WhisperKit`
    /// pipe stays put (the engine is deliberately not an actor — see the type
    /// comment); a prewarm and a real dictation must never call `transcribe` on
    /// the same pipe concurrently. A single-permit FIFO gate means a dictation
    /// that starts mid-prewarm simply queues behind the in-flight compile, then
    /// reuses the now-warm pipe — correct transcript, no recompile, no race.
    private let gate = TranscribeGate()

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
        // One transcribe at a time. `release()` in `defer` runs on every exit —
        // return, throw, or cancellation — so the gate is never left held. A task
        // cancelled while queued in the gate is still resumed FIFO by a later
        // release(); it then aborts here at `checkCancellation` BEFORE the
        // (uncancellable) ANE inference and hands the permit straight to the next
        // waiter via `defer`, so a cancelled prewarm never runs redundant work.
        await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()
        let options = DecodingOptions(language: language)
        let results = try await pipe.transcribe(audioPath: audioPath, decodeOptions: options)
        lock.withLock { didPredict = true }
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, results.first?.language ?? language)
    }

    /// Triggers + caches the one-time ANE specialization without a real dictation.
    /// Fast-returns if already warm this session; otherwise runs ~0.3s of silence
    /// through `transcribe` (THROUGH the same gate, so it can't race a dictation).
    func prewarm(log: @Sendable (String) async -> Void) async throws {
        if lock.withLock({ pipe != nil && didPredict }) { return }
        try Task.checkCancellation()

        // 0.3s of 16 kHz mono PCM16 silence = 9600 zero samples * 2 bytes.
        let silence = Data(count: Int(0.3 * 16_000) * 2)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vara-whisperkit-prewarm-\(UUID().uuidString).wav")
        try WhisperKitBackend.writePCM16WAV(data: silence, sampleRate: 16_000, to: tmpURL)
        // Registered before any cancellation check below, so the temp file is
        // removed on every exit (success, throw, or CancellationError unwind).
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        await log("WhisperKit prewarm: specializing CoreML/ANE (one-time)…")
        _ = try await transcribe(audioPath: tmpURL.path, language: nil, log: log)
        await log("WhisperKit prewarm complete.")
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
                .appendingPathComponent("vara-whisperkit-\(UUID().uuidString).wav")
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

/// A single-permit FIFO async semaphore, built in the same `@unchecked Sendable`
/// + `NSLock` idiom the codebase already trusts for cross-task coordination
/// (cf. `ResumeOnceLatch` / `CancellableTaskBox`). The lock guards only the
/// permit flag and the waiter queue and is NEVER held across an `await` (the
/// only `await` is the continuation itself; resume is synchronous). One permit
/// => only one holder runs at a time; FIFO dequeue => no starvation.
private final class TranscribeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire the permit, suspending FIFO behind any current holder/waiters.
    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if available {
                available = false
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Release the permit: hand it to the next waiter (FIFO), else mark free.
    func release() {
        lock.lock()
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            available = true
            lock.unlock()
        }
    }
}
