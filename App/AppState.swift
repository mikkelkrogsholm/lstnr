import AppKit
import CoreGraphics
import Foundation
import LstnrCore
import Observation

@MainActor
@Observable
final class AppState {
    var isRecording: Bool = false
    var lastTranscript: String = ""
    var lastError: String?
    var statusMessage: String = "Starting…"

    private var backend: ScribeRealtimeBackend?
    private var dictationSession: DictationSession?
    private var hotkey: GlobalHotkey?

    init() {
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        guard loadAPIKey() else { return }
        guard ensureAccessibility() else { return }
        installHotkey()
    }

    @discardableResult
    private func loadAPIKey() -> Bool {
        do {
            let key = try EnvLoader.resolveForApp("ELEVENLABS_API_KEY")
            let backend = ScribeRealtimeBackend(apiKey: key)
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            return true
        } catch {
            statusMessage = "Missing ELEVENLABS_API_KEY"
            lastError = "\(error)"
            return false
        }
    }

    @discardableResult
    private func ensureAccessibility() -> Bool {
        if GlobalHotkey.hasAccessibility(prompt: true) { return true }
        statusMessage = "Grant Accessibility in System Settings, then relaunch."
        return false
    }

    private func installHotkey() {
        let hotkey = GlobalHotkey(
            key: .rightOption,
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
            statusMessage = "Hold ⌥ to dictate"
        } catch {
            statusMessage = "Hotkey setup failed"
            lastError = "\(error)"
        }
    }

    private func makeDictationSession(backend: ScribeRealtimeBackend) -> DictationSession {
        DictationSession(
            mode: .pushToTalk,
            recorder: MicrophoneDictationAudioRecorder(),
            transcribe: { request in
                try await backend.transcribe(request)
            },
            textSink: { text in
                await MainActor.run {
                    ClipboardPaster.pasteAtCursor(text: text)
                }
            }
        )
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
            lastError = nil
            statusMessage = "Recording…"
        case .ignored:
            return
        case .completed(let insertedText):
            if let insertedText {
                lastTranscript = insertedText
            }
            isRecording = false
            statusMessage = "Hold ⌥ to dictate"
        case .failed(let message):
            isRecording = false
            lastError = message
            statusMessage = "Error"
        }
    }
}

/// Copies text to the clipboard and simulates ⌘V into the frontmost app.
/// Restores the previous clipboard after a short delay.
enum ClipboardPaster {
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
