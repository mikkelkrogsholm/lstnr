@preconcurrency import AppKit
import ArgumentParser
import Foundation
import LstnrCore

@main
struct Lstnr: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lstnr",
        abstract: "Local dictation tool with pluggable ASR backends.",
        subcommands: [Transcribe.self, Dictate.self],
        defaultSubcommand: Transcribe.self
    )
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio file using the selected backend."
    )

    @Argument(help: "Path to audio file (wav, mp3, m4a, flac, etc.)")
    var file: String

    @Option(name: .shortAndLong, help: "Backend: scribe (realtime, default), scribe-batch")
    var backend: String = "scribe"

    @Option(name: .shortAndLong, help: "Language code (ISO 639-1, e.g. da, en). Omit for auto-detect.")
    var language: String?

    @Flag(name: .long, help: "Remove filler words (Scribe batch only).")
    var noVerbatim: Bool = false

    @Flag(name: .long, help: "Tag non-speech audio events like (laughter). (Batch only.)")
    var tagEvents: Bool = false

    @Flag(name: .long, help: "Enable speaker diarization. (Batch only.)")
    var diarize: Bool = false

    func run() async throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(fileURL.path)")
        }

        let asr = try makeBackend()
        let langLabel = language.map { "lang=\($0)" } ?? "lang=auto"
        FileHandle.standardError.write(Data("→ \(asr.name) • \(fileURL.lastPathComponent) • \(langLabel)\n".utf8))

        let result = try await asr.transcribe(audio: fileURL, language: language)
        print(result.text)
        printFooter(result: result)
    }

    private func makeBackend() throws -> any ASRBackend {
        let apiKey = try EnvLoader.resolve("ELEVENLABS_API_KEY")
        switch backend {
        case "scribe", "scribe-realtime", "realtime":
            return ScribeRealtimeBackend(apiKey: apiKey)
        case "scribe-batch", "batch":
            return ScribeV2Backend(
                apiKey: apiKey,
                noVerbatim: noVerbatim,
                tagAudioEvents: tagEvents,
                diarize: diarize
            )
        default:
            throw ValidationError("Unknown backend: \(backend). Available: scribe, scribe-batch")
        }
    }
}

struct Dictate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictate",
        abstract: "Hold Right Option to record; release to transcribe. Ctrl+C to quit."
    )

    @Option(name: .shortAndLong, help: "Language code (ISO 639-1, e.g. da, en). Omit for auto-detect.")
    var language: String?

    @MainActor
    func run() async throws {
        let apiKey = try EnvLoader.resolve("ELEVENLABS_API_KEY")
        let backend = ScribeRealtimeBackend(apiKey: apiKey)

        // Gate: Accessibility permission is required for CGEventTap.
        guard GlobalHotkey.hasAccessibility(prompt: true) else {
            throw HotkeyError.accessibilityNotGranted
        }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let session = DictationSession(backend: backend, language: language)

        let hotkey = GlobalHotkey(
            key: .rightOption,
            onDown: { Task { @MainActor in session.start() } },
            onUp: { Task { @MainActor in session.stop() } }
        )
        try hotkey.install()

        FileHandle.standardError.write(Data(
            "Hold ⌥ Right Option to dictate. Ctrl+C to quit.\n".utf8
        ))
        NSApp.run()
    }
}

@MainActor
final class DictationSession {
    private let backend: ScribeRealtimeBackend
    private let language: String?
    private var recorder: AudioRecorder?
    private var task: Task<Void, Never>?

    init(backend: ScribeRealtimeBackend, language: String?) {
        self.backend = backend
        self.language = language
    }

    func start() {
        guard task == nil else { return }
        let recorder: AudioRecorder
        let stream: AsyncStream<Data>
        do {
            recorder = try AudioRecorder()
            stream = try recorder.start()
        } catch {
            FileHandle.standardError.write(Data("❌ \(error)\n".utf8))
            return
        }
        self.recorder = recorder
        FileHandle.standardError.write(Data("🎤 Recording…\n".utf8))

        let backend = self.backend
        let language = self.language
        task = Task { [weak self] in
            do {
                let result = try await backend.transcribe(pcmChunks: stream, language: language)
                print(result.text)
                let dur = result.audioDurationSeconds.map { String(format: "%.1fs", $0) } ?? "?"
                let elapsed = String(format: "%.2fs", result.elapsedSeconds)
                FileHandle.standardError.write(Data(
                    "── \(result.detectedLanguage ?? "?") • \(dur) audio • \(elapsed) elapsed ──\n".utf8
                ))
            } catch {
                FileHandle.standardError.write(Data("❌ \(error)\n".utf8))
            }
            await MainActor.run {
                self?.recorder = nil
                self?.task = nil
            }
        }
    }

    func stop() {
        recorder?.stop()
    }
}

private func printFooter(result: TranscriptionResult) {
    let lang = result.detectedLanguage ?? "?"
    let dur = result.audioDurationSeconds.map { String(format: "%.1fs audio", $0) } ?? "?"
    let elapsed = String(format: "%.2fs elapsed", result.elapsedSeconds)
    FileHandle.standardError.write(Data("── \(lang) • \(dur) • \(elapsed) ──\n".utf8))
}
