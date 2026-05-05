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
    var statusMessage: String = "Starting…"
    var historyItems: [DictationHistoryItem] = []
    var settings: LstnrAppSettings
    var microphoneName: String
    var microphonePermissionStatus: String
    var debugLogEntries: [AppDebugLogEntry] = []

    var debugLogFilePath: String {
        Self.debugLogFileURL().path
    }

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
        guard loadAPIKey() else { return }
        guard ensureAccessibility(prompt: true) else { return }
        installHotkey()
    }

    private func reloadConfiguration() {
        log("Reloading configuration")
        reloadSettings()
        guard loadAPIKey() else { return }
        if ensureAccessibility(prompt: false) {
            installHotkey()
        } else {
            statusMessage = "Grant Accessibility in System Settings, then relaunch."
        }
    }

    private func reloadSettings() {
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        microphoneName = Self.defaultMicrophoneName()
        microphonePermissionStatus = Self.microphoneAuthorizationStatusTitle()
        log(
            "Settings loaded: shortcut=\(loadedSettings.shortcut.rawValue), language=\(loadedSettings.language.rawValue), cleanup=\(loadedSettings.cleanupMode.rawValue), paste=\(loadedSettings.pasteAutomatically), hud=\(loadedSettings.showHUD), microphonePermission=\(microphonePermissionStatus)"
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
    private func loadAPIKey() -> Bool {
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
            statusMessage = "Add ElevenLabs API key in Settings"
            lastError = "\(error)"
            log("API key/backend setup failed: \(error)")
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
    func requestAccessibilityPermission() -> Bool {
        log("User requested Accessibility permission check")
        let granted = ensureAccessibility(prompt: true)
        if granted {
            log("Accessibility is granted; installing hotkey from permission check")
            _ = loadAPIKey()
            installHotkey()
        }
        return granted
    }

    @discardableResult
    private func ensureAccessibility(prompt: Bool) -> Bool {
        let granted = GlobalHotkey.hasAccessibility(prompt: prompt)
        log("Accessibility check: granted=\(granted), prompt=\(prompt)")
        if granted { return true }
        statusMessage = "Grant Accessibility in System Settings, then relaunch."
        return false
    }

    private func installHotkey() {
        log("Installing hotkey: \(settings.shortcut.rawValue)")
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
            log("Hotkey installed")
        } catch {
            statusMessage = "Hotkey setup failed"
            lastError = "\(error)"
            log("Hotkey install failed: \(error)")
        }
    }

    private func makeDictationSession(backend: ScribeRealtimeBackend) -> DictationSession {
        let cleanupMode = settings.cleanupMode.transcriptCleanupMode
        let cleanupProvider = settings.cleanupMode.cleanupProvider
        let languageCode = settings.language.languageCode
        let pasteAutomatically = settings.pasteAutomatically
        let pendingHistory = pendingHistory
        let instrumentAudio: @Sendable (SpeechToTextAudio) -> SpeechToTextAudio = { [weak self] audio in
            Self.instrument(audio: audio) { message in
                await MainActor.run { self?.log(message) }
            }
        }

        return DictationSession(
            mode: .pushToTalk,
            recorder: MicrophoneDictationAudioRecorder(),
            languageCode: languageCode,
            transcribe: { request in
                let instrumentedRequest = SpeechToTextRequest(
                    audio: instrumentAudio(request.audio),
                    languageCode: request.languageCode
                )
                let rawResult = try await Self.withTimeout(seconds: 30) {
                    try await backend.transcribe(instrumentedRequest)
                }
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
        guard let dictationSession else {
            log("Begin dictation requested, but session is missing. Reloading configuration.")
            reloadConfiguration()
            return
        }
        guard ensureMicrophonePermissionBeforeRecording() else {
            return
        }
        statusMessage = "Starting microphone…"
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
            statusMessage = "Transcribing…"
            isTranscribing = true
            showHUD(phase: .transcribing)
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
            statusMessage = "Recording…"
            log("Recording started")
            showHUD(phase: .recording)
        case .ignored:
            log("Dictation command ignored")
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
                log("Dictation completed. Inserted text length=\(insertedText.count), insertionStatus=\(insertionStatus.rawValue)")
                showHUD(phase: .inserted, transcriptPreview: insertedText)
                hideHUDAfterDelay()
            } else {
                log("Dictation completed with empty transcript")
                statusMessage = "No speech detected"
                hideHUD()
            }
        case .failed(let message):
            isRecording = false
            isTranscribing = false
            lastError = message
            statusMessage = "Error"
            log("Dictation failed: \(message)")
            showHUD(phase: .error, transcriptPreview: message)
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
            statusMessage = "Grant Microphone permission"
            log("Requesting Microphone permission")
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                self?.microphonePermissionStatus = Self.microphoneAuthorizationStatusTitle()
                self?.log("Microphone permission response: granted=\(granted)")
                if granted {
                    self?.statusMessage = "Microphone ready"
                    self?.beginDictationInteraction()
                } else {
                    self?.statusMessage = "Grant Microphone in System Settings"
                }
            }
            return false
        case .denied:
            statusMessage = "Grant Microphone in System Settings"
            lastError = "Microphone permission is denied for this Lstnr.app build."
            log("Microphone permission denied")
            return false
        case .restricted:
            statusMessage = "Microphone restricted"
            lastError = "Microphone permission is restricted by macOS."
            log("Microphone permission restricted")
            return false
        @unknown default:
            statusMessage = "Microphone unavailable"
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
        case .rightCommand: .rightCommand
        case .rightOption: .rightOption
        case .leftOption: .leftOption
        case .functionKey: .function
        }
    }

    var symbol: String {
        switch self {
        case .rightCommand: "⌘"
        case .rightOption: "⌥"
        case .leftOption: "⌥"
        case .functionKey: "fn"
        }
    }
}
