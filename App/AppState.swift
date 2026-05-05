import AppKit
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
    var statusMessage: String = "Starting…"
    var historyItems: [DictationHistoryItem] = []
    var settings: LstnrAppSettings

    private var backend: ScribeRealtimeBackend?
    private var dictationSession: DictationSession?
    private var hotkey: GlobalHotkey?
    private let credentialStore = LstnrKeychainCredentialStore()
    private let settingsStore = LstnrSettingsStore()
    private var historyStore: DictationHistoryStore
    private let pendingHistory = PendingDictationHistoryStore()
    private let hudController = RecordingHUDWindowController()
    private var credentialsObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    init() {
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
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
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        reloadSettings()
        await reloadHistory()
        guard loadAPIKey() else { return }
        guard ensureAccessibility() else { return }
        installHotkey()
    }

    private func reloadConfiguration() {
        reloadSettings()
        guard loadAPIKey() else { return }
        if ensureAccessibility() {
            installHotkey()
        } else {
            statusMessage = "Grant Accessibility in System Settings, then relaunch."
        }
    }

    private func reloadSettings() {
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
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
    private func loadAPIKey() -> Bool {
        do {
            let key = try resolveElevenLabsAPIKey()
            let backend = ScribeRealtimeBackend(apiKey: key)
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            lastError = nil
            return true
        } catch {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = "Add ElevenLabs API key in Settings"
            lastError = "\(error)"
            return false
        }
    }

    private func resolveElevenLabsAPIKey() throws -> String {
        if let key = try credentialStore.credential(for: .elevenLabs), !key.isEmpty {
            return key
        }

        return try EnvLoader.resolveForApp("ELEVENLABS_API_KEY")
    }

    @discardableResult
    private func ensureAccessibility() -> Bool {
        if GlobalHotkey.hasAccessibility(prompt: true) { return true }
        statusMessage = "Grant Accessibility in System Settings, then relaunch."
        return false
    }

    private func installHotkey() {
        hotkey?.uninstall()
        let hotkey = GlobalHotkey(
            key: settings.shortcut.globalHotkeyKey,
            onDown: { [weak self] in
                Task { @MainActor in self?.beginDictationInteraction() }
            },
            onUp: { [weak self] in
                Task { @MainActor in self?.endDictationInteraction() }
            }
        )
        do {
            try hotkey.install()
            self.hotkey = hotkey
            statusMessage = "Hold \(settings.shortcut.symbol) to dictate"
        } catch {
            statusMessage = "Hotkey setup failed"
            lastError = "\(error)"
        }
    }

    private func makeDictationSession(backend: ScribeRealtimeBackend) -> DictationSession {
        let cleanupMode = settings.cleanupMode.transcriptCleanupMode
        let cleanupProvider = settings.cleanupMode.cleanupProvider
        let languageCode = settings.language.languageCode
        let pasteAutomatically = settings.pasteAutomatically
        let pendingHistory = pendingHistory

        return DictationSession(
            mode: .pushToTalk,
            recorder: MicrophoneDictationAudioRecorder(),
            languageCode: languageCode,
            transcribe: { request in
                let rawResult = try await backend.transcribe(request)
                let cleanupResult = try await cleanupProvider.cleanup(
                    TranscriptCleanupRequest(rawText: rawResult.text, mode: cleanupMode)
                )
                await pendingHistory.replace(
                    PendingDictationHistoryEntry(
                        rawResult: rawResult,
                        cleanupResult: cleanupResult,
                        requestedLanguage: request.languageCode
                    )
                )
                return TranscriptionResult(
                    text: cleanupResult.cleanedText,
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
                }
            }
        )
    }

    func toggleDictationFromMenu() {
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
        statusMessage = "Reinserted from history"
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
        guard let dictationSession else { return }
        Task { @MainActor [weak self] in
            let result = await dictationSession.beginInteraction()
            self?.apply(commandResult: result)
        }
    }

    private func endDictationInteraction() {
        guard let dictationSession else { return }
        if isRecording {
            statusMessage = "Transcribing…"
            isTranscribing = true
            showHUD(phase: .transcribing)
        }
        isRecording = false
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
            statusMessage = "Recording…"
            showHUD(phase: .recording)
        case .ignored:
            return
        case .completed(let insertedText):
            if let insertedText {
                lastTranscript = insertedText
            }
            isRecording = false
            isTranscribing = false
            statusMessage = "Hold \(settings.shortcut.symbol) to dictate"
            let insertionStatus: DictationInsertionStatus = settings.pasteAutomatically ? .inserted : .notInserted
            Task { @MainActor [weak self] in
                await self?.savePendingHistory(insertionStatus: insertionStatus)
            }
            if let insertedText {
                showHUD(phase: .inserted, transcriptPreview: insertedText)
                hideHUDAfterDelay()
            } else {
                hideHUD()
            }
        case .failed(let message):
            isRecording = false
            isTranscribing = false
            lastError = message
            statusMessage = "Error"
            showHUD(phase: .error, transcriptPreview: message)
        }
    }

    private func savePendingHistory(insertionStatus: DictationInsertionStatus) async {
        guard let pendingEntry = await pendingHistory.take() else { return }
        do {
            _ = try await historyStore.add(
                rawTranscript: pendingEntry.rawResult.text,
                cleanedTranscript: pendingEntry.cleanedTranscriptForHistory,
                backend: pendingEntry.rawResult.backend,
                detectedLanguage: pendingEntry.rawResult.detectedLanguage,
                requestedLanguage: pendingEntry.requestedLanguage,
                audioDurationSeconds: pendingEntry.rawResult.audioDurationSeconds,
                elapsedTranscriptionSeconds: pendingEntry.rawResult.elapsedSeconds,
                insertionStatus: insertionStatus
            )
            await reloadHistory()
        } catch {
            lastError = "\(error)"
        }
    }

    private func reloadHistory() async {
        do {
            historyItems = try await historyStore.listRecent()
        } catch {
            lastError = "\(error)"
        }
    }

    private func showHUD(phase: RecordingHUDPhase, transcriptPreview: String = "") {
        guard settings.showHUD else { return }
        hudController.show(
            model: RecordingHUDModel(
                phase: phase,
                level: phase == .recording ? 0.62 : 0,
                transcriptPreview: transcriptPreview
            )
        )
    }

    private func hideHUD() {
        hudController.hide()
    }

    private func hideHUDAfterDelay() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.hideHUD()
        }
    }

    private static func defaultHistoryFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("lstnr", isDirectory: true)
            .appendingPathComponent("dictation-history.json")
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
    let cleanupResult: TranscriptCleanupResult
    let requestedLanguage: String?

    var cleanedTranscriptForHistory: String? {
        guard cleanupResult.mode != .raw else { return nil }
        guard cleanupResult.cleanedText != rawResult.text else { return nil }
        return cleanupResult.cleanedText
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

private extension LstnrCleanupModeChoice {
    var transcriptCleanupMode: TranscriptCleanupMode {
        switch self {
        case .raw: .raw
        case .clean: .clean
        }
    }

    var cleanupProvider: any TranscriptCleanupProvider {
        switch self {
        case .raw: RawTranscriptCleanupProvider()
        case .clean: BasicTranscriptCleanupProvider()
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

private extension LstnrShortcutChoice {
    var globalHotkeyKey: GlobalHotkey.Key {
        switch self {
        case .rightOption: .rightOption
        case .leftOption: .leftOption
        case .functionKey: .function
        }
    }

    var symbol: String {
        switch self {
        case .rightOption: "⌥"
        case .leftOption: "⌥"
        case .functionKey: "fn"
        }
    }
}
