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
            return true
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
        guard configureBackend() else { return }
        guard ensureAccessibility(prompt: true) else { return }
        installHotkey()
    }

    private func reloadConfiguration() {
        log("Reloading configuration")
        reloadSettings()
        guard configureBackend() else { return }
        if ensureAccessibility(prompt: false) {
            installHotkey()
        } else {
            statusMessage = String(localized: "Grant Accessibility in System Settings, then relaunch.", comment: "Status message")
        }
    }

    private func reloadSettings() {
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        microphoneName = Self.defaultMicrophoneName()
        microphonePermissionStatus = Self.microphoneAuthorizationStatusTitle()
        log(
            "Settings loaded: shortcut=\(loadedSettings.shortcut.rawValue), language=\(loadedSettings.language.rawValue), backend=\(loadedSettings.speechBackend.rawValue), cleanup=\(loadedSettings.cleanupMode.rawValue), paste=\(loadedSettings.pasteAutomatically), hud=\(loadedSettings.showHUD), microphonePermission=\(microphonePermissionStatus)"
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
            statusMessage = String(localized: "Install Hviske in Settings", comment: "Status message")
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
        })

        return DictationSession(
            mode: .pushToTalk,
            recorder: recorder,
            languageCode: languageCode,
            transcribe: { [weak self] request in
                let instrumentedRequest = SpeechToTextRequest(
                    audio: instrumentAudio(request.audio),
                    languageCode: request.languageCode
                )
                let rawResult = try await Self.withTimeout(seconds: timeoutSeconds) {
                    try await backend.transcribe(instrumentedRequest)
                }

                guard let (mode, processor, targetAppName) = await resolveProcessing() else {
                    return rawResult
                }
                let outcome = await processor.process(transcript: rawResult.text, mode: mode)
                if let llmError = outcome.llmErrorDescription {
                    // The raw transcript is inserted instead — never lose words.
                    await MainActor.run {
                        self?.log("LLM step fell back to raw transcript: \(llmError)")
                    }
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

    /// Persists a new default mode and notifies so configuration reloads.
    func selectMode(_ mode: DictationMode) {
        guard settings.selectedModeID != mode.id else { return }
        settings.selectedModeID = mode.id
        try? settingsStore.save(settings)
        log("Selected mode: \(mode.name)")
        NotificationCenter.default.post(name: .lstnrSettingsDidChange, object: nil)
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
        case .failed(let message):
            isRecording = false
            isTranscribing = false
            activeModeOverride = nil
            activeAppRuleMode = nil
            lastError = message
            statusMessage = String(localized: "Something went wrong", comment: "Status on dictation error")
            log("Dictation failed: \(message)")
            hudState.transcriptPreview = ""
            hudState.phase = .error(message: message)
            hideHUDAfterDelay(seconds: 4.0)
            playFeedbackSound("Basso", volume: 0.25)
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
            lastError = "Microphone permission is denied for this Lstnr.app build."
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
enum ClipboardPaster {
    static func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func pasteAtCursor(text: String) {
        let pasteboard = NSPasteboard.general
        let savedTypes = pasteboard.types ?? []
        let savedItems: [(NSPasteboard.PasteboardType, Data)] = savedTypes.compactMap { type in
            guard let data = pasteboard.data(forType: type) else { return nil }
            return (type, data)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulateCmdV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            for (type, data) in savedItems {
                pasteboard.setData(data, forType: type)
            }
        }
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

private actor PendingDictationHistoryStore {
    private var entry: PendingDictationHistoryEntry?

    func replace(_ entry: PendingDictationHistoryEntry) {
        self.entry = entry
    }

    func take() -> PendingDictationHistoryEntry? {
        let currentEntry = entry
        entry = nil
        return currentEntry
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
