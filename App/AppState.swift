import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import VaraCore
import Observation

@MainActor
@Observable
final class AppState {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var lastTranscript: String = ""
    var lastError: String?
    var statusMessage: String = String(localized: "Starting …", comment: "Status message at launch")
    var historyItems: [DictationHistoryItem] = []
    var settings: VaraAppSettings
    var microphoneName: String
    var microphonePermissionStatus: String
    var debugLogEntries: [AppDebugLogEntry] = []

    /// Whether the local Ollama endpoint answered its last reachability probe.
    /// `nil` means not probed yet. Drives `isModeReady(.ollama)` and is exposed
    /// so the UI can show the "ready / Completely private" badge honestly rather
    /// than unconditionally. Refreshed on launch, on settings change, and on a
    /// periodic timer.
    var ollamaReachable: Bool?

    var debugLogFilePath: String {
        Self.debugLogFileURL().path
    }

    let hudState = RecordingHUDState()

    // `backend` is set when configuring the speech backend (AppState+Backends).
    var backend: (any SpeechToTextBackend)?
    // Built in AppState+Backends, used by the dictation flow (AppState+Dictation).
    var dictationSession: DictationSession?
    /// The in-flight transcription/forging Task launched by
    /// `endDictationInteraction()`. Stored so `cancelDictation()` can `.cancel()`
    /// it — though cancellation alone can't stop an uncancellable inference or the
    /// in-actor paste, so the generation token below is the authoritative drop.
    var forgingTask: Task<Void, Never>?
    /// Monotonically increasing token bumped at the start of every interaction and
    /// on every cancel. This is the ONLY reliable way to guarantee a late result
    /// from an abandoned forge can never paste text or append history after the
    /// user cancelled — Task.cancel() can't interrupt CoreML inference or a
    /// synchronous paste.
    var dictationGeneration: Int = 0
    /// The generation the currently in-flight forge belongs to, captured when its
    /// Task launches. The paste/apply path compares `dictationGeneration` against
    /// this: if they differ, the interaction that produced this result was
    /// superseded (cancelled or replaced) and its output must be dropped.
    var activeForgeGeneration: Int = 0
    /// Per-session WhisperKit warm-state machine (reset every launch since
    /// AppState is constructed once). Drives the HUD one-time-prep fallback and
    /// the Settings warming/failed rows. Only ever mutated on the MainActor.
    var whisperKitWarmState: WhisperKitWarmState = .notNeeded
    /// The in-flight background prewarm Task, stored so a reconfigure (model
    /// change / settings change) can cancel and restart it. Not `private` so the
    /// AppState+Backends extension (separate file) can manage it.
    var whisperKitPrewarmTask: Task<Void, Never>?
    // Installed/torn down in AppState+Hotkey and AppState+Backends.
    var hotkey: GlobalHotkey?
    /// PID of the app currently reported as holding secure keyboard input (which
    /// blocks the dictation hotkey system-wide). Tracked in AppState+Hotkey to
    /// avoid re-reporting the same holder and to clear the warning when released.
    var lastReportedSecureInputPID: pid_t?
    let credentialStore = VaraKeychainCredentialStore()
    let settingsStore = VaraSettingsStore()
    var historyStore: DictationHistoryStore
    let pendingHistory = PendingDictationHistoryStore()
    let hudController: RecordingHUDWindowController
    private var credentialsObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    /// Mode picked with 1–9 during the current dictation; cleared afterwards.
    var activeModeOverride: DictationMode?

    /// Mode chosen by a per-app rule for the current dictation.
    var activeAppRuleMode: DictationMode?
    /// App that was frontmost when the current dictation started — where the
    /// text will land. Used for history grouping and per-app mode rules.
    var dictationTargetAppName: String?

    /// The mode the next/ongoing dictation runs through:
    /// digit override > per-app rule > selected default.
    var activeMode: DictationMode {
        activeModeOverride ?? activeAppRuleMode ?? settings.selectedMode
    }

    /// Whether a mode can actually run: raw always can; LLM modes need a
    /// configured provider with its key in place.
    func isModeReady(_ mode: DictationMode) -> Bool {
        guard mode.behavior != .insertRaw else { return true }
        guard let selection = mode.llm ?? settings.defaultLLM else { return false }
        switch selection.provider {
        case .openAI:
            return hasLLMKey(.openAI)
        case .groq:
            return hasLLMKey(.groq)
        case .anthropic:
            return hasLLMKey(.anthropic)
        case .gemini:
            return hasLLMKey(.gemini)
        case .ollama:
            // Only "ready" if a probe has actually reached the local endpoint.
            // Before the first probe (nil) we optimistically allow it so the
            // badge isn't briefly wrong on a working setup; once probed, the
            // cached truth wins.
            return ollamaReachable ?? true
        case .claudeCLI, .codexCLI, .geminiCLI:
            // Ready when the CLI binary is installed; auth is assumed (a
            // logged-out run exits non-zero and the cleanup falls back to raw).
            guard let tool = selection.provider.cliTool else { return false }
            return CLIChatClient.detectInstalledTools().contains(tool)
        case .custom(let endpointID):
            return settings.customEndpoints.contains { $0.id == endpointID }
        }
    }

    private func hasLLMKey(_ provider: VaraCredentialProvider) -> Bool {
        if let key = try? credentialStore.credential(for: provider), !key.isEmpty {
            return true
        }
        if let key = try? EnvLoader.resolveForApp(provider.environmentVariableName), !key.isEmpty {
            return true
        }
        return false
    }

    /// Keeps App Nap from throttling the process — a napped app services its
    /// CGEventTap too slowly and macOS disables the tap, killing the hotkey
    /// whenever Vara is in the background.
    private var appNapActivity: NSObjectProtocol?

    /// Periodically re-probes the local Ollama endpoint so `ollamaReachable`
    /// reflects a server that was started or stopped after launch.
    private var ollamaProbeTimer: Timer?

    init() {
        // One-time data migration from the old "lstnr" identity. MUST run before
        // settings load and before any App Support access (history/debug.log), so
        // it is the very first statement here. Idempotent and never throws.
        VaraMigration.runIfNeeded()

        hudController = RecordingHUDWindowController(state: hudState, placement: .insertionPoint)
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Global dictation hotkey must stay responsive"
        )
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        microphoneName = AppState.defaultMicrophoneName()
        microphonePermissionStatus = Self.microphoneAuthorizationStatusTitle()
        historyStore = DictationHistoryStore(
            fileURL: Self.defaultHistoryFileURL(),
            maxRecentCount: loadedSettings.historyLimit
        )
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: .varaCredentialsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadConfiguration() }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .varaSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadConfiguration() }
        }
        // The HUD's close (X) cancels the dictation — same path as Esc. Set after
        // all stored properties are initialized so the closure can capture self.
        // Safe to call from the click handler: the panel is non-activating so the
        // click never pulls key focus from the frontmost paste target.
        hudController.onCancel = { [weak self] in
            self?.cancelDictation()
        }
        log("App started. \(Self.runtimeIdentityDescription())")
        log("Microphone: \(microphoneName), permission=\(microphonePermissionStatus)")
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        log("Bootstrap started")
        reloadSettings()
        await reloadHistory()
        startOllamaReachabilityMonitoring()
        guard configureBackend() else { return }
        guard ensureAccessibility(prompt: true) else { return }
        installHotkey()
    }

    /// Probes Ollama once now and then on a periodic timer so the badge stays
    /// honest as the local server starts or stops.
    private func startOllamaReachabilityMonitoring() {
        refreshOllamaReachability()
        ollamaProbeTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshOllamaReachability() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ollamaProbeTimer = timer
    }

    /// Kicks off an async reachability probe of the local Ollama endpoint and
    /// caches the result in `ollamaReachable`. Cheap and side-effect-free, so it
    /// is safe to call on launch, on settings change, and periodically.
    private func refreshOllamaReachability() {
        let url = LLMProvider.ollama.defaultBaseURL?.appendingPathComponent("models")
        guard let url else { return }
        Task { @MainActor [weak self] in
            let reachable = await Self.probeOllama(modelsURL: url)
            guard let self else { return }
            if self.ollamaReachable != reachable {
                self.log("Ollama reachability changed: \(reachable)")
            }
            self.ollamaReachable = reachable
        }
    }

    /// GETs the Ollama OpenAI-compatible `/v1/models` with a short timeout. Any
    /// HTTP response (even an error status) means the server is up; a transport
    /// error or timeout means it is unreachable.
    nonisolated private static func probeOllama(modelsURL: URL) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// A settings/credentials change arrived while a dictation was in flight, so
    /// the backend/hotkey rebuild was deferred to avoid stranding the recording.
    private var reloadPending = false

    func reloadConfiguration() {
        // Rebuilding the backend uninstalls the tap and replaces the
        // dictationSession. Doing that mid-recording (e.g. the user clicks a mode
        // chip while still holding the key) strands the in-progress recording and
        // loses the words. Defer the teardown until the interaction finishes.
        guard !isRecording, !isTranscribing else {
            reloadPending = true
            log("Configuration reload deferred — dictation in progress")
            return
        }
        reloadPending = false
        log("Reloading configuration")
        reloadSettings()
        refreshOllamaReachability()
        guard configureBackend() else { return }
        if ensureAccessibility(prompt: false) {
            installHotkey()
        } else {
            statusMessage = String(localized: "Grant Accessibility in System Settings, then relaunch.", comment: "Status message")
        }
    }

    /// Runs a configuration reload that was deferred because a dictation was in
    /// flight. Called once the interaction settles (completed/cancelled/failed).
    func runDeferredReloadIfNeeded() {
        guard reloadPending else { return }
        guard !isRecording, !isTranscribing else { return }
        log("Running deferred configuration reload")
        reloadConfiguration()
    }

    private func reloadSettings() {
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        microphoneName = Self.defaultMicrophoneName()
        microphonePermissionStatus = Self.microphoneAuthorizationStatusTitle()
        log(
            "Settings loaded: shortcut=\(loadedSettings.shortcut.rawValue), language=\(loadedSettings.language.rawValue), backend=\(loadedSettings.speechBackend.rawValue), paste=\(loadedSettings.pasteAutomatically), hud=\(loadedSettings.showHUD), microphonePermission=\(microphonePermissionStatus)"
        )
        historyStore = DictationHistoryStore(
            fileURL: Self.defaultHistoryFileURL(),
            maxRecentCount: loadedSettings.historyLimit
        )
        if !loadedSettings.showHUD {
            hideHUD()
        }
        Task { await reloadHistory() }
    }

    func log(_ message: String) {
        let entry = AppDebugLogEntry(createdAt: Date(), message: message)
        debugLogEntries.insert(entry, at: 0)
        if debugLogEntries.count > 120 {
            debugLogEntries.removeLast(debugLogEntries.count - 120)
        }
        Self.appendDebugLogLine(entry.line)
    }

    private static func defaultHistoryFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("vara", isDirectory: true)
            .appendingPathComponent("dictation-history.json")
    }

    static func debugLogFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("vara", isDirectory: true)
            .appendingPathComponent("debug.log")
    }

    private static func appendDebugLogLine(_ line: String) {
        let fileURL = debugLogFileURL()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data((line + "\n").utf8)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Logging must never break dictation.
        }
    }

    private static func defaultMicrophoneName() -> String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "macOS System Default"
    }

    static func microphoneAuthorizationStatusTitle(
        _ status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    ) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
    }

    private static func runtimeIdentityDescription() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown-bundle-id"
        let bundlePath = Bundle.main.bundleURL.path
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "unknown-executable"
        return "Runtime identity: bundleID=\(bundleID), bundlePath=\(bundlePath), executablePath=\(executablePath), pid=\(ProcessInfo.processInfo.processIdentifier)"
    }
}

/// Per-session lifecycle of WhisperKit's one-time CoreML/ANE specialization.
/// App-side only (never crosses into VaraCore — `prewarm()` takes no state type).
enum WhisperKitWarmState: Equatable {
    /// WhisperKit isn't the active backend, or its model isn't downloaded yet
    /// (the download UI owns that phase); no prewarm is pending.
    case notNeeded
    /// Prewarm is running; `since` lets the UI show how long it's been going.
    case warming(since: Date)
    /// Specialization is paid and cached in-process — first dictation is fast.
    case warm
    /// Prewarm failed; the string is the user-facing error for the retry row.
    case failed(String)

    var isWarm: Bool {
        if case .warm = self { return true }
        return false
    }
}

struct AppStateTimeoutError: Error, CustomStringConvertible, Sendable {
    let seconds: Double

    var description: String {
        "Operation timed out after \(String(format: "%.0f", seconds)) seconds"
    }
}

/// Transcription failed or timed out, but the captured audio was preserved so
/// the dictation is recoverable. The `description` is the user-facing message
/// (DictationSession turns it into `.failed(message:)`) and deliberately omits
/// any HTTP body — it must never echo the transcript. The underlying error is
/// kept only for the in-memory ring; it is never persisted verbatim.
struct DictationTranscriptionFailure: Error, CustomStringConvertible, Sendable {
    let underlying: any Error
    let recoveredAudioPath: String?

    var description: String {
        // Prefer a specific, actionable reason (bad key / no credit / rate limit /
        // no access / offline). Falls back to the generic recoverable message for
        // anything we can't classify — and we never echo a raw provider body, which
        // could carry the transcript.
        if let reason = APIFailureReason.reason(for: underlying),
           let message = Self.specificMessage(for: reason) {
            return message
        }
        return Self.genericMessage(recoverable: recoveredAudioPath != nil)
    }

    /// Fixed, localized, actionable line per known failure reason. `nil` for
    /// `.other`/unrecognized so the generic message is used (no raw-string echo).
    static func specificMessage(for reason: APIFailureReason) -> String? {
        switch reason {
        case .invalidKey:
            return String(localized: "Your API key was rejected. Check it under Settings › Engine.", comment: "Dictation error: provider returned 401, the key is wrong/revoked")
        case .insufficientQuota:
            return String(localized: "Your account is out of credit. Add billing with your provider, then try again.", comment: "Dictation error: provider returned 429 insufficient_quota — no money on the account")
        case .rateLimited:
            return String(localized: "Too many requests right now. Wait a moment and try again.", comment: "Dictation error: provider rate limit")
        case .noAccess:
            return String(localized: "Your account can't use this engine's model. Pick another engine under Settings › Engine.", comment: "Dictation error: 403/404, account lacks access to the model")
        case .network:
            return String(localized: "No connection to the transcription service. Check your internet and try again.", comment: "Dictation error: offline/network failure")
        case .server:
            return String(localized: "The transcription service had a problem. Try again in a moment.", comment: "Dictation error: provider 5xx outage")
        case .other:
            return nil
        }
    }

    static func genericMessage(recoverable: Bool) -> String {
        recoverable
            ? String(localized: "Transcription failed, but your audio was kept and can be recovered. Please try again.", comment: "Error shown when transcription fails but the recording was saved")
            : String(localized: "Transcription failed. Please try again.", comment: "Error shown when transcription fails and no audio could be recovered")
    }
}

/// Tees the dictation audio to a temp WAV file as it streams to the backend, so
/// that if transcription fails the user's words are not gone with the consumed
/// one-shot stream. On success the capture is discarded; on failure
/// `finalizeForRecovery()` returns the saved path. PCM streams are written to a
/// fresh WAV; a `.file` request is left untouched and recovered by copying it
/// to a stable location (the backend may delete its own temp input).
actor RecoverableAudioCapture {
    /// The audio to hand to the backend — for PCM, a teed stream that forwards
    /// every chunk downstream while buffering a copy to disk.
    nonisolated let audio: SpeechToTextAudio

    private let sourceFileURL: URL?
    private let recoveryURL: URL
    private let sampleRate: Int
    private let log: @Sendable (String) async -> Void

    /// Accumulates the PCM bytes as the teed stream drains, returning the full
    /// buffer once the stream finishes. Awaited by `finalizeForRecovery()` so
    /// the WAV is written only after every chunk has been seen.
    private let captureTask: Task<Data, Never>?
    private var finalized = false
    private var savedPath: String?

    init(audio: SpeechToTextAudio, log: @escaping @Sendable (String) async -> Void) {
        self.log = log
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL
            .appendingPathComponent("vara", isDirectory: true)
            .appendingPathComponent("recovered-audio", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        switch audio {
        case .file(let url):
            self.sourceFileURL = url
            self.sampleRate = 0
            let suffix = url.pathExtension.isEmpty ? "audio" : url.pathExtension
            self.recoveryURL = directory.appendingPathComponent("dictation-\(stamp).\(suffix)")
            self.audio = audio
            self.captureTask = nil
        case .pcm16Stream(let stream, let sampleRate):
            self.sourceFileURL = nil
            self.sampleRate = sampleRate
            self.recoveryURL = directory.appendingPathComponent("dictation-\(stamp).wav")
            // Tee: forward every chunk to the backend while buffering a copy so a
            // failed transcription still has the audio.
            let (teedStream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            self.audio = .pcm16Stream(teedStream, sampleRate: sampleRate)
            self.captureTask = Task {
                var pcm = Data()
                for await chunk in stream {
                    pcm.append(chunk)
                    continuation.yield(chunk)
                }
                continuation.finish()
                return pcm
            }
        }
    }

    /// Persists whatever audio was captured and returns the file path, or nil if
    /// nothing could be saved. Safe to call repeatedly — later calls return the
    /// already-saved path.
    func finalizeForRecovery() async -> String? {
        guard !finalized else { return savedPath }
        finalized = true

        do {
            try FileManager.default.createDirectory(
                at: recoveryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            await log("Could not create recovery directory: \(error)")
            return nil
        }

        if let sourceFileURL {
            do {
                if FileManager.default.fileExists(atPath: recoveryURL.path) {
                    try FileManager.default.removeItem(at: recoveryURL)
                }
                try FileManager.default.copyItem(at: sourceFileURL, to: recoveryURL)
                savedPath = recoveryURL.path
                return savedPath
            } catch {
                await log("Could not preserve recovery audio file: \(error)")
                return nil
            }
        }

        let pcm = await captureTask?.value ?? Data()
        guard !pcm.isEmpty else { return nil }
        let wav = Self.wavData(pcm16: pcm, sampleRate: sampleRate)
        do {
            try wav.write(to: recoveryURL, options: .atomic)
            savedPath = recoveryURL.path
            return savedPath
        } catch {
            await log("Could not write recovered WAV: \(error)")
            return nil
        }
    }

    /// Drops the captured audio; called after a successful transcription so we
    /// don't accumulate orphaned recordings. The teed PCM buffer is freed when
    /// the capture task finishes; source files are the backend's own input and
    /// are left alone.
    func discard() {
        finalized = true
    }

    /// Wraps raw little-endian PCM16 mono samples in a minimal WAV container.
    private static func wavData(pcm16: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm16.count)
        let riffSize = 36 + dataSize

        var header = Data()
        func appendASCII(_ string: String) { header.append(contentsOf: string.utf8) }
        func appendUInt32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendUInt32(riffSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)            // PCM fmt chunk size
        appendUInt16(1)             // PCM format
        appendUInt16(channels)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendASCII("data")
        appendUInt32(dataSize)

        var out = header
        out.append(pcm16)
        return out
    }
}

struct AppDebugLogEntry: Identifiable, Hashable {
    let id = UUID()
    let createdAt: Date
    let message: String

    var line: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(formatter.string(from: createdAt)) \(message)"
    }
}

/// Copies text to the clipboard and simulates ⌘V into the frontmost app.
/// Restores the previous clipboard after a short delay.
@MainActor
enum ClipboardPaster {
    /// The pending clipboard-restore for the previous paste, cancelled when a
    /// new paste starts so back-to-back dictations never restore stale contents
    /// over each other.
    private static var pendingRestore: DispatchWorkItem?

    static func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func pasteAtCursor(text: String) {
        // A new paste supersedes any pending restore from the previous one.
        pendingRestore?.cancel()
        pendingRestore = nil

        let pasteboard = NSPasteboard.general
        let savedTypes = pasteboard.types ?? []
        let savedItems: [(NSPasteboard.PasteboardType, Data)] = savedTypes.compactMap { type in
            guard let data = pasteboard.data(forType: type) else { return nil }
            return (type, data)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Snapshot the changeCount right after we own the pasteboard. We only
        // restore the previous contents if nothing else (the user, the synthetic
        // ⌘V's consumer, or another app) has touched the pasteboard since — that
        // way the restore can't clobber a value the user just copied, and it
        // can't race the paste itself.
        let ownedChangeCount = pasteboard.changeCount

        simulateCmdV()

        let restore = DispatchWorkItem {
            guard NSPasteboard.general.changeCount == ownedChangeCount else {
                // Pasteboard changed since we set the transcript — leave it be.
                pendingRestore = nil
                return
            }
            NSPasteboard.general.clearContents()
            for (type, data) in savedItems {
                NSPasteboard.general.setData(data, forType: type)
            }
            pendingRestore = nil
        }
        pendingRestore = restore
        // Slightly longer than before so the synthetic ⌘V is reliably consumed
        // by the target app before we put the user's clipboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: restore)
    }

    private static func simulateCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9  // V on ANSI layout

        // Synthetic Cmd+V: the flag overrides physical modifier state per Apple docs.
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand

        let loc = CGEventTapLocation.cgSessionEventTap
        vDown?.post(tap: loc)
        vUp?.post(tap: loc)
    }
}

struct PendingDictationHistoryEntry: Sendable {
    let rawResult: TranscriptionResult
    let outcome: DictationModeOutcome
    let modeName: String
    let targetAppName: String?
    let requestedLanguage: String?
    /// The dictation generation this entry belongs to. The save side dequeues by
    /// generation so a forge cancelled mid-flight (Esc/X during forging) can
    /// enqueue an entry that is later drained instead of saved — see
    /// `PendingDictationHistoryStore.take(matching:)`.
    let generation: Int

    var cleanedTranscriptForHistory: String? {
        guard outcome.usedLLM, outcome.text != rawResult.text else { return nil }
        return outcome.text
    }
}

/// Holds transcription outcomes between the transcribe step and the history
/// save, which run on separate async tasks. A FIFO queue (not a single slot) so
/// back-to-back dictations can't clobber each other: a second dictation's
/// enqueue no longer overwrites the first's still-unsaved entry. Each dictation
/// enqueues exactly one entry and dequeues exactly one, so the queue stays
/// balanced.
actor PendingDictationHistoryStore {
    private var entries: [PendingDictationHistoryEntry] = []

    func replace(_ entry: PendingDictationHistoryEntry) {
        entries.append(entry)
        // Safety bound. Legitimate coexistence is at most ~2 (a completed
        // dictation's entry awaiting its async save while the next is enqueued);
        // anything beyond is accumulated orphans from forges cancelled before they
        // completed (drained lazily by `take(matching:)`). Cap so a user who
        // repeatedly forges-then-cancels without ever completing can't grow this
        // unbounded. The dropped entries are always the oldest = most stale.
        let cap = 16
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
    }

    /// Dequeues the entry for `generation`, discarding any stale entries ahead of
    /// it. A forge cancelled mid-flight can race: it passes the enqueue point and
    /// appends an entry, but its `apply` then drops the result without dequeuing
    /// (the generation moved). Draining by generation here guarantees that
    /// orphan is never saved and never shifts the FIFO for the next dictation, so
    /// the "enqueue one, save one" balance holds under any cancel interleaving.
    func take(matching generation: Int) -> PendingDictationHistoryEntry? {
        while let first = entries.first {
            if first.generation == generation {
                return entries.removeFirst()
            }
            entries.removeFirst()
        }
        return nil
    }
}

extension DictationHistoryItem {
    var displayTranscript: String {
        cleanedTranscript ?? rawTranscript
    }
}

enum LLMConfigurationError: Error, CustomStringConvertible {
    case missingAPIKey(provider: String)
    case unknownCustomEndpoint

    var description: String {
        switch self {
        case .missingAPIKey(let provider):
            return "Missing API key for LLM provider '\(provider)'. Add it in Settings → Intelligence."
        case .unknownCustomEndpoint:
            return "The custom LLM endpoint for this mode no longer exists."
        }
    }
}

extension VaraLanguageChoice {
    var languageCode: String? {
        switch self {
        case .automatic: nil
        case .danish: "da"
        case .english: "en"
        }
    }
}
