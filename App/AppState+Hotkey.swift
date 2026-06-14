import AppKit
import Foundation
import LstnrCore

// Global hotkey lifecycle and the Accessibility permission it depends on,
// plus secure-input / tap-blocked reporting and in-dictation key handling.
extension AppState {
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
    func ensureAccessibility(prompt: Bool) -> Bool {
        let granted = GlobalHotkey.hasAccessibility(prompt: prompt)
        log("Accessibility check: granted=\(granted), prompt=\(prompt)")
        if granted { return true }
        statusMessage = String(localized: "Grant Accessibility in System Settings, then relaunch.", comment: "Status message")
        return false
    }

    func installHotkey() {
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

    /// Whether the app currently holds the Accessibility permission.
    func checkAccessibilityGranted() -> Bool {
        GlobalHotkey.hasAccessibility(prompt: false)
    }

    var readyStatusMessage: String {
        String(localized: "Hold \(settings.shortcut.symbol) — Vara is listening", comment: "Status message when ready to dictate")
    }
}
