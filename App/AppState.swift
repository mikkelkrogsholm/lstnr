import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import LstnrCore
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
    var settings: LstnrAppSettings
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

    private var backend: (any SpeechToTextBackend)?
    private var dictationSession: DictationSession?
    private var hotkey: GlobalHotkey?
    private let credentialStore = LstnrKeychainCredentialStore()
    private let settingsStore = LstnrSettingsStore()
    private var historyStore: DictationHistoryStore
    private let pendingHistory = PendingDictationHistoryStore()
    private let hudController: RecordingHUDWindowController
    private var credentialsObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    /// Mode picked with 1–9 during the current dictation; cleared afterwards.
    private var activeModeOverride: DictationMode?

    /// Mode chosen by a per-app rule for the current dictation.
    private var activeAppRuleMode: DictationMode?
    /// App that was frontmost when the current dictation started — where the
    /// text will land. Used for history grouping and per-app mode rules.
    private var dictationTargetAppName: String?

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
        case .ollama:
            // Only "ready" if a probe has actually reached the local endpoint.
            // Before the first probe (nil) we optimistically allow it so the
            // badge isn't briefly wrong on a working setup; once probed, the
            // cached truth wins.
            return ollamaReachable ?? true
        case .custom(let endpointID):
            return settings.customEndpoints.contains { $0.id == endpointID }
        }
    }

    private func hasLLMKey(_ provider: LstnrCredentialProvider) -> Bool {
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
            forName: .lstnrCredentialsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadConfiguration() }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .lstnrSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadConfiguration() }
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

    private func reloadConfiguration() {
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
    private func runDeferredReloadIfNeeded() {
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

    @discardableResult
    private func configureBackend() -> Bool {
        switch settings.speechBackend {
        case .elevenLabsScribe:
            return configureElevenLabsBackend()
        case .groqWhisper:
            return configureGroqBackend()
        case .openAIRealtimeWhisper:
            return configureOpenAIRealtimeWhisperBackend()
        case .openAIGPT4OTranscribe:
            return configureOpenAIAudioTranscriptionBackend(
                modelID: "gpt-4o-transcribe",
                displayName: "OpenAI GPT-4o Transcribe"
            )
        case .openAIGPT4OMiniTranscribe20251215:
            return configureOpenAIAudioTranscriptionBackend(
                modelID: "gpt-4o-mini-transcribe-2025-12-15",
                displayName: "OpenAI GPT-4o Mini Transcribe 2025-12-15"
            )
        case .localHviske:
            return configureLocalHviskeBackend()
        case .localWhisperKit:
            return configureWhisperKitBackend()
        }
    }

    @discardableResult
    private func configureElevenLabsBackend() -> Bool {
        do {
            let key = try resolveElevenLabsAPIKey()
            let backend = ScribeRealtimeBackend(
                apiKey: key,
                diagnosticLog: { [weak self] message in
                    await MainActor.run { self?.log(message) }
                }
            )
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            lastError = nil
            log("ElevenLabs backend ready. API key source resolved without exposing key.")
            return true
        } catch {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Add an ElevenLabs API key in Settings", comment: "Status message")
            lastError = "\(error)"
            log("API key/backend setup failed: \(error)")
            return false
        }
    }

    @discardableResult
    private func configureGroqBackend() -> Bool {
        do {
            let key = try resolveGroqAPIKey()
            let backend = GroqWhisperBackend(apiKey: key)
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            lastError = nil
            statusMessage = readyStatusMessage
            log("Groq Whisper backend ready. API key source resolved without exposing key.")
            return true
        } catch {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Add a Groq API key in Settings", comment: "Status message")
            lastError = "\(error)"
            log("Groq API key/backend setup failed: \(error)")
            return false
        }
    }

    @discardableResult
    private func configureOpenAIAudioTranscriptionBackend(modelID: String, displayName: String) -> Bool {
        do {
            let key = try resolveOpenAIAPIKey()
            let backend = OpenAIAudioTranscriptionBackend(
                apiKey: key,
                modelID: modelID,
                displayName: displayName
            )
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            lastError = nil
            statusMessage = readyStatusMessage
            log("\(displayName) backend ready. API key source resolved without exposing key.")
            return true
        } catch {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Add an OpenAI API key in Settings", comment: "Status message")
            lastError = "\(error)"
            log("OpenAI API key/backend setup failed: \(error)")
            return false
        }
    }

    @discardableResult
    private func configureOpenAIRealtimeWhisperBackend() -> Bool {
        do {
            let key = try resolveOpenAIAPIKey()
            let backend = OpenAIRealtimeWhisperBackend(
                apiKey: key,
                diagnosticLog: { [weak self] message in
                    await MainActor.run { self?.log(message) }
                }
            )
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            lastError = nil
            statusMessage = readyStatusMessage
            log("OpenAI GPT Realtime Whisper backend ready. API key source resolved without exposing key.")
            return true
        } catch {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Add an OpenAI API key in Settings", comment: "Status message")
            lastError = "\(error)"
            log("OpenAI Realtime API key/backend setup failed: \(error)")
            return false
        }
    }

    @discardableResult
    private func configureLocalHviskeBackend() -> Bool {
        let runtimeStatus = LocalHviskeBackend.runtimeStatus()
        guard runtimeStatus.isReady else {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Set up Hviske in Terminal — see Settings > Advanced.", comment: "Status message when Hviske runtime is not set up")
            lastError = "Local Hviske runtime or model is missing."
            log("Local Hviske backend not ready. runtime=\(runtimeStatus.hasPythonRuntime), model=\(runtimeStatus.hasModelSnapshot), hfHome=\(runtimeStatus.hfHomeURL.path)")
            return false
        }

        let backend = LocalHviskeBackend(
            diagnosticLog: { [weak self] message in
                await MainActor.run { self?.log(message) }
            }
        )
        self.backend = backend
        dictationSession = makeDictationSession(backend: backend)
        lastError = nil
        statusMessage = readyStatusMessage
        log("Local Hviske backend ready. hfHome=\(runtimeStatus.hfHomeURL.path)")
        return true
    }

    @discardableResult
    private func configureWhisperKitBackend() -> Bool {
        // WhisperKit needs no key and no Terminal setup: the CoreML model is
        // fetched + cached automatically on the first dictation, so we can wire
        // the backend up eagerly. The (potentially slow) first-run download and
        // model load happen lazily inside the backend and are surfaced via the
        // diagnostic log.
        let model = settings.whisperKitModel
        let backend = WhisperKitBackend(
            model: model,
            diagnosticLog: { [weak self] message in
                await MainActor.run { self?.log(message) }
            }
        )
        self.backend = backend
        dictationSession = makeDictationSession(backend: backend)
        lastError = nil
        statusMessage = readyStatusMessage
        log("Local WhisperKit backend ready. model=\(model). Model downloads on first use to \(WhisperKitBackend.downloadBaseURL.path)")
        return true
    }

    private func resolveElevenLabsAPIKey() throws -> String {
        if let key = try credentialStore.credential(for: .elevenLabs), !key.isEmpty {
            return key
        }

        return try EnvLoader.resolveForApp("ELEVENLABS_API_KEY")
    }

    private func resolveGroqAPIKey() throws -> String {
        if let key = try credentialStore.credential(for: .groq), !key.isEmpty {
            return key
        }

        return try EnvLoader.resolveForApp("GROQ_API_KEY")
    }

    private func resolveOpenAIAPIKey() throws -> String {
        if let key = try credentialStore.credential(for: .openAI), !key.isEmpty {
            return key
        }

        return try EnvLoader.resolveForApp("OPENAI_API_KEY")
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        log("User requested Accessibility permission check")
        let granted = ensureAccessibility(prompt: true)
        if granted {
            log("Accessibility is granted; installing hotkey from permission check")
            if configureBackend() {
                installHotkey()
            }
        }
        return granted
    }

    @discardableResult
    private func ensureAccessibility(prompt: Bool) -> Bool {
        let granted = GlobalHotkey.hasAccessibility(prompt: prompt)
        log("Accessibility check: granted=\(granted), prompt=\(prompt)")
        if granted { return true }
        statusMessage = String(localized: "Grant Accessibility in System Settings, then relaunch.", comment: "Status message")
        return false
    }

    private func installHotkey() {
        log("Installing hotkey: \(settings.shortcut.rawValue)")
        hotkey?.uninstall()
        let hotkey = GlobalHotkey(
            shortcut: settings.shortcut.globalHotkeyShortcut,
            diagnosticLog: { [weak self] message in
                Task { @MainActor in self?.log(message) }
            },
            onDown: { [weak self] in
                Task { @MainActor in self?.beginDictationInteraction() }
            },
            onUp: { [weak self] in
                Task { @MainActor in self?.endDictationInteraction() }
            }
        )
        hotkey.onKeyDownWhileActive = { [weak self] keyCode in
            Task { @MainActor in self?.handleKeyWhileDictating(keyCode: keyCode) }
        }
        // Forward Esc/1–9 based on whether we're recording, not the hotkey's own
        // `isDown` flag — a watchdog rearm can reset `isDown` while the shortcut
        // is still physically held, which would otherwise drop Esc-to-cancel and
        // digit mode selection mid-dictation.
        hotkey.shouldForwardKeyDown = { [weak self] in
            MainActor.assumeIsolated { self?.isRecording ?? false }
        }
        hotkey.onTapBlocked = { [weak self] holderPID in
            Task { @MainActor in self?.reportTapBlocked(holderPID: holderPID) }
        }
        do {
            try hotkey.install()
            self.hotkey = hotkey
            statusMessage = readyStatusMessage
            log("Hotkey installed")
        } catch {
            statusMessage = String(localized: "Hotkey setup failed", comment: "Status message")
            lastError = "\(error)"
            log("Hotkey install failed: \(error)")
        }
    }

    private var readyStatusMessage: String {
        String(localized: "Hold \(settings.shortcut.symbol) — Vara is listening", comment: "Status message when ready to dictate")
    }

    /// Last secure-input holder we warned about, to avoid repeating the
    /// message on every 5-second watchdog tick.
    private var lastReportedSecureInputPID: pid_t?

    private func reportTapBlocked(holderPID: pid_t?) {
        guard let holderPID else {
            // Tap was re-enabled and no one holds secure input — clear stale warning.
            if lastReportedSecureInputPID != nil {
                lastReportedSecureInputPID = nil
                lastError = nil
                statusMessage = readyStatusMessage
            }
            return
        }
        guard holderPID != lastReportedSecureInputPID else { return }
        lastReportedSecureInputPID = holderPID

        let holderName = NSRunningApplication(processIdentifier: holderPID)?.localizedName
            ?? "pid \(holderPID)"
        statusMessage = String(localized: "Keyboard blocked by \(holderName)", comment: "Status when secure input blocks the hotkey")
        lastError = String(
            localized: "“\(holderName)” is holding secure keyboard input (e.g. a password field), so macOS blocks the dictation key everywhere. Close the password prompt or quit that app to release it.",
            comment: "Explanation when secure input blocks the hotkey"
        )
        log("Secure input held by \(holderName) (pid \(holderPID)) — hotkey blocked system-wide")
    }

    /// Esc cancels; 1–9 picks a mode for the ongoing dictation only.
    private func handleKeyWhileDictating(keyCode: UInt16) {
        guard isRecording else { return }

        let escKeyCode: UInt16 = 53
        if keyCode == escKeyCode {
            cancelDictation()
            return
        }

        let digitKeyCodes: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        ]
        guard let digit = digitKeyCodes[keyCode] else { return }
        let modes = settings.modes
        guard digit <= modes.count else { return }

        let mode = modes[digit - 1]
        guard isModeReady(mode) else {
            log("Mode override via digit \(digit) ignored — '\(mode.name)' is not configured")
            return
        }
        activeModeOverride = mode
        hudState.modeTitle = mode.displayTitle
        hudState.modeSymbol = mode.symbolName
        log("Mode override via digit \(digit): \(mode.name)")
    }

    /// Records which app the dictation targets and applies a matching
    /// per-app mode rule, if one exists and its LLM is configured.
    private func captureDictationTarget() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        dictationTargetAppName = frontmost?.localizedName
        activeAppRuleMode = nil

        if let bundleID = frontmost?.bundleIdentifier,
           let rule = settings.appModeRules.first(where: { $0.bundleID == bundleID }),
           let ruleMode = settings.modes.first(where: { $0.id == rule.modeID }) {
            if isModeReady(ruleMode) {
                activeAppRuleMode = ruleMode
                log("App rule applied: \(rule.appName) → \(ruleMode.name)")
            } else {
                log("App rule for \(rule.appName) skipped — mode '\(ruleMode.name)' is not configured")
            }
        }
    }

    func cancelDictation() {
        guard let dictationSession else { return }
        log("Cancelling dictation")
        isRecording = false
        isTranscribing = false
        Task { @MainActor [weak self] in
            let result = await dictationSession.cancelRecording()
            self?.apply(commandResult: result)
        }
    }

    private func makeDictationSession(backend: any SpeechToTextBackend) -> DictationSession {
        let languageCode = settings.language.languageCode
        let pasteAutomatically = settings.pasteAutomatically
        let pendingHistory = pendingHistory
        let timeoutSeconds = backend.capabilities.runsLocally
            ? 180.0
            : (backend.capabilities.supportsStreamingTranscription ? 30.0 : 120.0)
        // Local backends (Hviske) can be slow on first model load but stream no
        // intermediate signal, so give the LLM cleanup the same generous budget;
        // network backends usually answer fast, so 20s is plenty before we fall
        // back to the raw transcript. Either way the words are kept.
        let llmTimeoutSeconds = backend.capabilities.runsLocally ? 30.0 : 20.0
        let instrumentAudio: @Sendable (SpeechToTextAudio) -> SpeechToTextAudio = { [weak self] audio in
            Self.instrument(audio: audio) { message in
                await MainActor.run { self?.log(message) }
            }
        }
        // Snapshot of mode + processor taken at transcription time so digit
        // overrides during the recording take effect.
        let resolveProcessing: @Sendable () async -> (DictationMode, DictationModeProcessor, String?)? = { [weak self] in
            await MainActor.run {
                guard let self else { return nil }
                return (self.activeMode, self.makeModeProcessor(), self.dictationTargetAppName)
            }
        }
        let recorder = MicrophoneDictationAudioRecorder(onLevel: { [weak self] level in
            Task { @MainActor in
                self?.hudState.pushLevel(level)
            }
        }, onDiagnostic: { [weak self] message in
            Task { @MainActor in self?.log(message) }
        })

        return DictationSession(
            mode: .pushToTalk,
            recorder: recorder,
            languageCode: languageCode,
            transcribe: { [weak self] request in
                // One sendable logger for the whole closure so we don't repeatedly
                // capture `self` across the sending boundaries of `withTimeout`.
                let logMessage: @Sendable (String) async -> Void = { message in
                    await MainActor.run { self?.log(message) }
                }
                // Tee the captured audio to a recoverable temp file as it flows
                // to the backend. The one-shot stream is consumed during
                // transcription, so if transcription FAILS this file is the only
                // copy left — without it the user's words would vanish silently.
                let recoverable = RecoverableAudioCapture(audio: request.audio, log: logMessage)
                let instrumentedRequest = SpeechToTextRequest(
                    audio: instrumentAudio(recoverable.audio),
                    languageCode: request.languageCode
                )

                let rawResult: TranscriptionResult
                do {
                    rawResult = try await Self.withTimeout(seconds: timeoutSeconds) {
                        try await backend.transcribe(instrumentedRequest)
                    }
                } catch {
                    // Transcription failed/timed out. Keep the captured audio so
                    // the dictation is recoverable, log its path, and surface a
                    // clear message — never a silent loss.
                    let savedPath = await recoverable.finalizeForRecovery()
                    if let savedPath {
                        await logMessage("Transcription failed: \(error). Captured audio kept at \(savedPath)")
                    } else {
                        await logMessage("Transcription failed: \(error). No audio could be recovered.")
                    }
                    throw DictationTranscriptionFailure(
                        underlying: error,
                        recoveredAudioPath: savedPath
                    )
                }

                // Transcription succeeded — the captured audio is no longer
                // needed, so discard the recovery file.
                await recoverable.discard()

                guard let (mode, processor, targetAppName) = await resolveProcessing() else {
                    return rawResult
                }
                // Wrap the LLM cleanup in a timeout: a hung Ollama/DGX must never
                // freeze the HUD in 'forging' with the words trapped. On timeout
                // (or any failure) we fall through to the RAW transcript.
                let outcome: DictationModeOutcome
                do {
                    outcome = try await Self.withTimeout(seconds: llmTimeoutSeconds) {
                        await processor.process(transcript: rawResult.text, mode: mode)
                    }
                } catch {
                    await logMessage("LLM step timed out; inserting raw transcript")
                    outcome = DictationModeOutcome(
                        text: rawResult.text,
                        usedLLM: false,
                        llmErrorDescription: "LLM timed out"
                    )
                }
                if let llmError = outcome.llmErrorDescription {
                    // The raw transcript is inserted instead — never lose words.
                    // `llmError` may carry an HTTP body that echoes the
                    // transcript, so redact it before it reaches debug.log.
                    let safeError = Self.redactedLogDescription(llmError)
                    await logMessage("LLM step fell back to raw transcript: \(safeError)")
                }

                await pendingHistory.replace(
                    PendingDictationHistoryEntry(
                        rawResult: rawResult,
                        outcome: outcome,
                        modeName: mode.displayTitle,
                        targetAppName: targetAppName,
                        requestedLanguage: request.languageCode
                    )
                )
                return TranscriptionResult(
                    text: outcome.text,
                    detectedLanguage: rawResult.detectedLanguage,
                    languageConfidence: rawResult.languageConfidence,
                    audioDurationSeconds: rawResult.audioDurationSeconds,
                    elapsedSeconds: rawResult.elapsedSeconds,
                    backend: rawResult.backend,
                    rawJSON: rawResult.rawJSON
                )
            },
            textSink: { text in
                guard pasteAutomatically else { return }
                await MainActor.run {
                    ClipboardPaster.pasteAtCursor(text: text)
                    self.log("Inserted transcript using cursor paste")
                }
            }
        )
    }

    /// Builds the LLM processor with credentials resolved lazily so keychain
    /// access happens off the hot path only when a mode actually needs an LLM.
    private func makeModeProcessor() -> DictationModeProcessor {
        DictationModeProcessor(
            defaultLLM: settings.defaultLLM,
            makeChatClient: Self.chatClientFactory(
                credentialStore: credentialStore,
                customEndpoints: settings.customEndpoints
            )
        )
    }

    nonisolated private static func chatClientFactory(
        credentialStore: LstnrKeychainCredentialStore,
        customEndpoints: [CustomLLMEndpoint]
    ) -> DictationModeProcessor.ChatClientFactory {
        { selection in
            switch selection.provider {
            case .openAI:
                let key = try Self.resolveLLMKey(credentialStore, .openAI, env: "OPENAI_API_KEY")
                return OpenAICompatibleChatClient(
                    id: "openai",
                    baseURL: LLMProvider.openAI.defaultBaseURL!,
                    apiKey: key,
                    model: selection.model
                )
            case .groq:
                let key = try Self.resolveLLMKey(credentialStore, .groq, env: "GROQ_API_KEY")
                return OpenAICompatibleChatClient(
                    id: "groq",
                    baseURL: LLMProvider.groq.defaultBaseURL!,
                    apiKey: key,
                    model: selection.model
                )
            case .anthropic:
                let key = try Self.resolveLLMKey(credentialStore, .anthropic, env: "ANTHROPIC_API_KEY")
                return AnthropicChatClient(apiKey: key, model: selection.model)
            case .ollama:
                return OpenAICompatibleChatClient(
                    id: "ollama",
                    baseURL: LLMProvider.ollama.defaultBaseURL!,
                    apiKey: nil,
                    model: selection.model
                )
            case .custom(let endpointID):
                guard let endpoint = customEndpoints.first(where: { $0.id == endpointID }),
                      let baseURL = endpoint.baseURL else {
                    throw LLMConfigurationError.unknownCustomEndpoint
                }
                let key = endpoint.requiresAPIKey
                    ? try credentialStore.credential(forCustomEndpoint: endpointID)
                    : nil
                return OpenAICompatibleChatClient(
                    id: endpoint.name,
                    baseURL: baseURL,
                    apiKey: key,
                    model: selection.model
                )
            }
        }
    }

    nonisolated private static func resolveLLMKey(
        _ store: LstnrKeychainCredentialStore,
        _ provider: LstnrCredentialProvider,
        env: String
    ) throws -> String {
        if let key = try? store.credential(for: provider), !key.isEmpty {
            return key
        }
        if let key = try? EnvLoader.resolveForApp(env), !key.isEmpty {
            return key
        }
        throw LLMConfigurationError.missingAPIKey(provider: provider.rawValue)
    }

    /// Changes the default mode. Only `activeMode` (and the HUD, if a dictation
    /// is in flight) depend on the selection — the backend and hotkey do not — so
    /// this deliberately does NOT post `.lstnrSettingsDidChange`, which would
    /// rebuild the backend/hotkey and could strand an in-progress recording.
    func selectMode(_ mode: DictationMode) {
        guard settings.selectedModeID != mode.id else { return }
        settings.selectedModeID = mode.id
        try? settingsStore.save(settings)
        log("Selected mode: \(mode.name)")
        // Reflect the new default in the HUD if it would now be the active mode
        // (no digit override or per-app rule taking precedence).
        if isRecording, activeModeOverride == nil, activeAppRuleMode == nil {
            hudState.modeTitle = mode.displayTitle
            hudState.modeSymbol = mode.symbolName
        }
    }

    /// Mutates, persists and broadcasts settings — used by onboarding.
    func updateSettings(_ mutate: (inout LstnrAppSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        settings = updated
        try? settingsStore.save(updated)
        NotificationCenter.default.post(name: .lstnrSettingsDidChange, object: nil)
    }

    /// Saves an API key from onboarding and reloads configuration.
    func saveCredential(_ key: String, for provider: LstnrCredentialProvider) {
        try? credentialStore.saveCredential(
            key.trimmingCharacters(in: .whitespacesAndNewlines),
            for: provider
        )
        NotificationCenter.default.post(name: .lstnrCredentialsDidChange, object: nil)
    }

    func savedCredential(for provider: LstnrCredentialProvider) -> String {
        (try? credentialStore.credential(for: provider)) ?? ""
    }

    /// Whether the app currently holds the Accessibility permission.
    func checkAccessibilityGranted() -> Bool {
        GlobalHotkey.hasAccessibility(prompt: false)
    }

    func toggleDictationFromMenu() {
        log("Dictation toggle requested. isRecording=\(isRecording), isTranscribing=\(isTranscribing)")
        if isRecording {
            endDictationInteraction()
        } else {
            beginDictationInteraction()
        }
    }

    func copyTranscript(_ item: DictationHistoryItem) {
        ClipboardPaster.copyToClipboard(text: item.displayTranscript)
    }

    func reinsertTranscript(_ item: DictationHistoryItem) {
        ClipboardPaster.pasteAtCursor(text: item.displayTranscript)
        lastTranscript = item.displayTranscript
        statusMessage = String(localized: "Reinserted from history", comment: "Status message")
    }

    func deleteHistoryItem(_ item: DictationHistoryItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await historyStore.delete(id: item.id)
                await reloadHistory()
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func clearHistory() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await historyStore.clear()
                await reloadHistory()
            } catch {
                lastError = "\(error)"
            }
        }
    }

    private func beginDictationInteraction() {
        guard let dictationSession else {
            log("Begin dictation requested, but session is missing. Reloading configuration.")
            reloadConfiguration()
            return
        }
        guard ensureMicrophonePermissionBeforeRecording() else {
            return
        }
        captureDictationTarget()
        statusMessage = String(localized: "Starting the microphone …", comment: "Status message")
        log("Begin dictation interaction")
        Task { @MainActor [weak self] in
            let result = await dictationSession.beginInteraction()
            self?.apply(commandResult: result)
        }
    }

    private func endDictationInteraction() {
        guard let dictationSession else {
            log("End dictation requested, but session is missing. Reloading configuration.")
            reloadConfiguration()
            return
        }
        if isRecording {
            statusMessage = String(localized: "Vara is forging the text …", comment: "Status while transcribing/cleaning")
            isTranscribing = true
            hudState.phase = .forging
            presentHUD()
        }
        isRecording = false
        log("End dictation interaction")
        Task { @MainActor [weak self] in
            let result = await dictationSession.endInteraction()
            self?.apply(commandResult: result)
        }
    }

    private func apply(commandResult: DictationSessionCommandResult) {
        switch commandResult {
        case .startedRecording:
            isRecording = true
            isTranscribing = false
            lastError = nil
            statusMessage = String(localized: "Vara is listening …", comment: "Status while recording")
            log("Recording started")
            let mode = activeMode
            hudState.modeTitle = mode.displayTitle
            hudState.modeSymbol = mode.symbolName
            hudState.beginRecording(startedAt: Date())
            presentHUD()
            playFeedbackSound("Tink", volume: 0.25)
        case .ignored:
            log("Dictation command ignored")
            return
        case .cancelled:
            isRecording = false
            isTranscribing = false
            activeModeOverride = nil
            activeAppRuleMode = nil
            statusMessage = readyStatusMessage
            log("Dictation cancelled")
            hudState.phase = .cancelled
            hideHUDAfterDelay()
            runDeferredReloadIfNeeded()
        case .completed(let insertedText):
            if let insertedText {
                lastTranscript = insertedText
            }
            isRecording = false
            isTranscribing = false
            activeModeOverride = nil
            activeAppRuleMode = nil
            statusMessage = readyStatusMessage
            let insertionStatus: DictationInsertionStatus = settings.pasteAutomatically ? .inserted : .notInserted
            Task { @MainActor [weak self] in
                await self?.savePendingHistory(insertionStatus: insertionStatus)
            }
            if let insertedText {
                log("Dictation completed. Inserted text length=\(insertedText.count), insertionStatus=\(insertionStatus.rawValue)")
                hudState.transcriptPreview = insertedText
                hudState.phase = .inserted(words: DictationStats.wordCount(of: insertedText))
                hideHUDAfterDelay()
                playFeedbackSound("Pop", volume: 0.3)
            } else {
                log("Dictation completed with empty transcript")
                statusMessage = String(localized: "Vara heard nothing", comment: "Status for empty transcript")
                hudState.phase = .heardNothing
                hideHUDAfterDelay(seconds: 2.0)
            }
            runDeferredReloadIfNeeded()
        case .failed(let message):
            isRecording = false
            isTranscribing = false
            activeModeOverride = nil
            activeAppRuleMode = nil
            // A transcription failure carries a friendly, body-free message and
            // notes that the captured audio was kept; other failures get a
            // generic message. Either way debug.log only sees a redacted line so
            // an HTTP body can never echo the transcript to disk.
            let userMessage = message
            lastError = userMessage
            statusMessage = String(localized: "Something went wrong", comment: "Status on dictation error")
            log("Dictation failed: \(Self.redactedLogDescription(message))")
            hudState.transcriptPreview = ""
            hudState.phase = .error(message: userMessage)
            hideHUDAfterDelay(seconds: 4.0)
            playFeedbackSound("Basso", volume: 0.25)
            runDeferredReloadIfNeeded()
        }
    }

    @discardableResult
    private func ensureMicrophonePermissionBeforeRecording() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphonePermissionStatus = Self.microphoneAuthorizationStatusTitle(status)
        log("Microphone permission check: \(microphonePermissionStatus)")

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            statusMessage = String(localized: "Grant microphone access", comment: "Status message")
            log("Requesting Microphone permission")
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                self?.microphonePermissionStatus = Self.microphoneAuthorizationStatusTitle()
                self?.log("Microphone permission response: granted=\(granted)")
                if granted {
                    self?.statusMessage = String(localized: "Microphone ready", comment: "Status message")
                    self?.beginDictationInteraction()
                } else {
                    self?.statusMessage = String(localized: "Grant microphone access in System Settings", comment: "Status message")
                }
            }
            return false
        case .denied:
            statusMessage = String(localized: "Grant microphone access in System Settings", comment: "Status message")
            lastError = "Microphone permission is denied for this Vara build."
            log("Microphone permission denied")
            return false
        case .restricted:
            statusMessage = String(localized: "Microphone is restricted", comment: "Status message")
            lastError = "Microphone permission is restricted by macOS."
            log("Microphone permission restricted")
            return false
        @unknown default:
            statusMessage = String(localized: "Microphone unavailable", comment: "Status message")
            lastError = "Unknown Microphone permission state."
            log("Microphone permission unknown status")
            return false
        }
    }

    private func savePendingHistory(insertionStatus: DictationInsertionStatus) async {
        guard let pendingEntry = await pendingHistory.take() else { return }
        do {
            _ = try await historyStore.add(
                rawTranscript: pendingEntry.rawResult.text,
                cleanedTranscript: pendingEntry.cleanedTranscriptForHistory,
                backend: pendingEntry.rawResult.backend,
                modeName: pendingEntry.modeName,
                targetAppName: pendingEntry.targetAppName,
                detectedLanguage: pendingEntry.rawResult.detectedLanguage,
                requestedLanguage: pendingEntry.requestedLanguage,
                audioDurationSeconds: pendingEntry.rawResult.audioDurationSeconds,
                elapsedTranscriptionSeconds: pendingEntry.rawResult.elapsedSeconds,
                insertionStatus: insertionStatus
            )
            await reloadHistory()
            log("History saved. insertionStatus=\(insertionStatus.rawValue)")
        } catch {
            lastError = "\(error)"
            log("History save failed: \(error)")
        }
    }

    private func reloadHistory() async {
        do {
            historyItems = try await historyStore.listRecent()
            log("History loaded. itemCount=\(historyItems.count)")
        } catch {
            lastError = "\(error)"
            log("History load failed: \(error)")
        }
    }

    func copyDebugLog() {
        let text = debugLogEntries
            .reversed()
            .map(\.line)
            .joined(separator: "\n")
        ClipboardPaster.copyToClipboard(text: text)
        log("Debug log copied to clipboard")
    }

    func clearDebugLog() {
        debugLogEntries.removeAll()
        try? FileManager.default.removeItem(at: Self.debugLogFileURL())
        log("Debug log cleared")
    }

    private func log(_ message: String) {
        let entry = AppDebugLogEntry(createdAt: Date(), message: message)
        debugLogEntries.insert(entry, at: 0)
        if debugLogEntries.count > 120 {
            debugLogEntries.removeLast(debugLogEntries.count - 120)
        }
        Self.appendDebugLogLine(entry.line)
    }

    /// Subtle audio confirmation for push-to-talk states; system sounds at
    /// low volume so they never dominate.
    private func playFeedbackSound(_ name: String, volume: Float) {
        guard settings.playSounds else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }

    private func presentHUD() {
        guard settings.showHUD else { return }
        hudController.show()
    }

    private func hideHUD() {
        hudController.hide()
    }

    private func hideHUDAfterDelay(seconds: Double = 1.4) {
        let phaseAtSchedule = hudState.phase
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            // A new dictation may have started in the meantime — don't hide it.
            if self.hudState.phase == phaseAtSchedule {
                self.hideHUD()
            }
        }
    }

    private static func defaultHistoryFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("lstnr", isDirectory: true)
            .appendingPathComponent("dictation-history.json")
    }

    private static func debugLogFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("lstnr", isDirectory: true)
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

    private static func microphoneAuthorizationStatusTitle(
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

    nonisolated private static func instrument(
        audio: SpeechToTextAudio,
        log: @escaping @Sendable (String) async -> Void
    ) -> SpeechToTextAudio {
        switch audio {
        case .file:
            return audio
        case .pcm16Stream(let stream, let sampleRate):
            let streamID = String(UUID().uuidString.prefix(8))
            let (instrumentedStream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            Task.detached {
                await log("Audio stream \(streamID) opened. sampleRate=\(sampleRate)")
                var chunks = 0
                var bytes = 0
                var peak = 0
                var nonZeroBytes = 0

                for await chunk in stream {
                    chunks += 1
                    bytes += chunk.count
                    let chunkStats = pcm16Stats(chunk)
                    peak = max(peak, chunkStats.peak)
                    nonZeroBytes += chunkStats.nonZeroBytes

                    if chunks == 1 || chunks % 20 == 0 {
                        await log(
                            "Audio stream \(streamID) chunk=\(chunks), totalBytes=\(bytes), chunkBytes=\(chunk.count), peak=\(peak), nonZeroBytes=\(nonZeroBytes)"
                        )
                    }

                    continuation.yield(chunk)
                }

                continuation.finish()
                let duration = sampleRate > 0 ? Double(bytes / 2) / Double(sampleRate) : 0
                let durationText = String(format: "%.2f", duration)
                await log(
                    "Audio stream \(streamID) finished. chunks=\(chunks), bytes=\(bytes), duration=\(durationText)s, peak=\(peak), nonZeroBytes=\(nonZeroBytes)"
                )
            }
            return .pcm16Stream(instrumentedStream, sampleRate: sampleRate)
        }
    }

    nonisolated private static func pcm16Stats(_ data: Data) -> (peak: Int, nonZeroBytes: Int) {
        var peak = 0
        var nonZeroBytes = 0
        let bytes = [UInt8](data)

        for byte in bytes where byte != 0 {
            nonZeroBytes += 1
        }

        var index = 0
        while index + 1 < bytes.count {
            let unsignedSample = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            let sample = Int16(bitPattern: unsignedSample)
            let magnitude = sample == Int16.min ? Int(Int16.max) + 1 : abs(Int(sample))
            peak = max(peak, magnitude)
            index += 2
        }

        return (peak: peak, nonZeroBytes: nonZeroBytes)
    }

    /// Strips any HTTP response body from an already-stringified chat error
    /// before it is written to debug.log. `ChatClientError.httpError` formats as
    /// `"Chat completion HTTP <status>: <body>"`, and that body can echo the
    /// user's transcript — so we replace it with a byte count, mirroring
    /// `ChatClientError.redactedDescription`. Anything else passes through.
    nonisolated private static func redactedLogDescription(_ message: String) -> String {
        let marker = "Chat completion HTTP "
        guard let markerRange = message.range(of: marker),
              let colonRange = message.range(of: ": ", range: markerRange.upperBound..<message.endIndex) else {
            return message
        }
        let status = message[markerRange.upperBound..<colonRange.lowerBound]
        let body = message[colonRange.upperBound...]
        let byteCount = Data(body.utf8).count
        return "Chat completion HTTP \(status): <\(byteCount) bytes redacted>"
    }

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AppStateTimeoutError(seconds: seconds)
            }

            guard let result = try await group.next() else {
                throw AppStateTimeoutError(seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }
}

private struct AppStateTimeoutError: Error, CustomStringConvertible, Sendable {
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
private struct DictationTranscriptionFailure: Error, CustomStringConvertible, Sendable {
    let underlying: any Error
    let recoveredAudioPath: String?

    var description: String {
        if recoveredAudioPath != nil {
            return String(
                localized: "Transcription failed, but your audio was kept and can be recovered. Please try again.",
                comment: "Error shown when transcription fails but the recording was saved"
            )
        }
        return String(
            localized: "Transcription failed. Please try again.",
            comment: "Error shown when transcription fails and no audio could be recovered"
        )
    }
}

/// Tees the dictation audio to a temp WAV file as it streams to the backend, so
/// that if transcription fails the user's words are not gone with the consumed
/// one-shot stream. On success the capture is discarded; on failure
/// `finalizeForRecovery()` returns the saved path. PCM streams are written to a
/// fresh WAV; a `.file` request is left untouched and recovered by copying it
/// to a stable location (the backend may delete its own temp input).
private actor RecoverableAudioCapture {
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
            .appendingPathComponent("lstnr", isDirectory: true)
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

private struct PendingDictationHistoryEntry: Sendable {
    let rawResult: TranscriptionResult
    let outcome: DictationModeOutcome
    let modeName: String
    let targetAppName: String?
    let requestedLanguage: String?

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
private actor PendingDictationHistoryStore {
    private var entries: [PendingDictationHistoryEntry] = []

    func replace(_ entry: PendingDictationHistoryEntry) {
        entries.append(entry)
    }

    func take() -> PendingDictationHistoryEntry? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }
}

private extension DictationHistoryItem {
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

private extension LstnrLanguageChoice {
    var languageCode: String? {
        switch self {
        case .automatic: nil
        case .danish: "da"
        case .english: "en"
        }
    }
}
