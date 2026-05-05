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
    private var hotkey: GlobalHotkey?
    private var recorder: AudioRecorder?
    private var currentTask: Task<Void, Never>?

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
            backend = ScribeRealtimeBackend(apiKey: key)
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
                Task { @MainActor in self?.startRecording() }
            },
            onUp: { [weak self] in
                Task { @MainActor in self?.stopRecording() }
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

    private func startRecording() {
        guard !isRecording, currentTask == nil, let backend else { return }
        let recorder: AudioRecorder
        let stream: AsyncStream<Data>
        do {
            recorder = try AudioRecorder()
            stream = try recorder.start()
        } catch {
            lastError = "\(error)"
            statusMessage = "Mic failed"
            return
        }
        self.recorder = recorder
        isRecording = true
        lastError = nil
        statusMessage = "Recording…"

        currentTask = Task { @MainActor [weak self] in
            do {
                let result = try await backend.transcribe(pcmChunks: stream, language: nil)
                self?.complete(result: result)
            } catch {
                self?.fail(error: error)
            }
            self?.currentTask = nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recorder?.stop()
        recorder = nil
        statusMessage = "Transcribing…"
    }

    private func complete(result: TranscriptionResult) {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastTranscript = text
        statusMessage = "Hold ⌥ to dictate"
        guard !text.isEmpty else { return }

        ClipboardPaster.pasteAtCursor(text: text)
    }

    private func fail(error: Error) {
        lastError = "\(error)"
        statusMessage = "Error"
        isRecording = false
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
