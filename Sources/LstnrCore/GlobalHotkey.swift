@preconcurrency import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum HotkeyError: Error, CustomStringConvertible {
    case accessibilityNotGranted
    case cannotCreateTap

    public var description: String {
        switch self {
        case .accessibilityNotGranted:
            return """
            Accessibility permission is required for global hotkeys.
            Open System Settings → Privacy & Security → Accessibility and enable Vara.
            """
        case .cannotCreateTap:
            return """
            Failed to create CGEventTap. Accessibility permission is probably missing.
            Open System Settings → Privacy & Security → Accessibility and enable Vara.
            """
        }
    }
}

/// CGEventTap-based global hotkey that listens for modifier-key transitions and
/// fires onDown/onUp. The keyCode identifies the physical modifier key, while
/// the normal modifier flag tells us whether that key transition is down/up.
/// Re-enables the tap on timeout / user-input-secure-input interruptions, and
/// after sleep/wake and lock/unlock.
public final class GlobalHotkey: @unchecked Sendable {
    public enum Key: UInt16, CaseIterable, Sendable {
        case rightOption = 61
        case leftOption = 58
        case rightCommand = 54
        case leftCommand = 55
        case rightControl = 62
        case function = 63
    }

    public struct Shortcut: Sendable, Hashable {
        public let keys: Set<Key>

        public init(keys: Set<Key>) {
            self.keys = keys
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var watchdogTimer: Timer?
    private var pressedKeys: Set<Key> = []
    private var isDown = false
    let shortcut: Shortcut
    let diagnosticLog: (@Sendable (String) -> Void)?
    let onDown: @Sendable () -> Void
    let onUp: @Sendable () -> Void

    /// Fired for regular key presses while the shortcut is held (the tap is
    /// listen-only, so the event still reaches the frontmost app). Used for
    /// Esc-to-cancel and 1–9 mode selection during dictation.
    public var onKeyDownWhileActive: (@Sendable (UInt16) -> Void)?

    /// Decides whether regular key presses should be forwarded via
    /// `onKeyDownWhileActive`. AppState wires this to `isRecording` so
    /// Esc-to-cancel and 1–9 mode selection keep working even when the
    /// hotkey's own `isDown` was reset by a watchdog rearm while the
    /// shortcut is still physically held. When `nil`, falls back to the
    /// `isDown` gate.
    public var shouldForwardKeyDown: (@Sendable () -> Bool)?

    /// Fired by the watchdog when the tap was found disabled. Carries the PID
    /// of the process holding secure keyboard input, if any — while secure
    /// input is held, macOS keeps every keyboard tap disabled and the hotkey
    /// cannot work.
    public var onTapBlocked: (@Sendable (pid_t?) -> Void)?

    /// PID of the process currently holding secure keyboard input, if any.
    public static func secureInputHolderPID() -> pid_t? {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = sessionInfo["kCGSSessionSecureInputPID"] as? Int else {
            return nil
        }
        return pid_t(pid)
    }

    public init(
        key: Key = .rightOption,
        diagnosticLog: (@Sendable (String) -> Void)? = nil,
        onDown: @escaping @Sendable () -> Void,
        onUp: @escaping @Sendable () -> Void
    ) {
        self.shortcut = Shortcut(keys: [key])
        self.diagnosticLog = diagnosticLog
        self.onDown = onDown
        self.onUp = onUp
    }

    public init(
        shortcut: Shortcut,
        diagnosticLog: (@Sendable (String) -> Void)? = nil,
        onDown: @escaping @Sendable () -> Void,
        onUp: @escaping @Sendable () -> Void
    ) {
        self.shortcut = shortcut
        self.diagnosticLog = diagnosticLog
        self.onDown = onDown
        self.onUp = onUp
    }

    /// Checks whether this process has the Accessibility entitlement.
    /// Pass `prompt: true` to show the system prompt if it hasn't been requested yet.
    public static func hasAccessibility(prompt: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt resolves to the CFString "AXTrustedCheckOptionPrompt".
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": prompt]
        return AXIsProcessTrustedWithOptions(options)
    }

    public func install() throws {
        let eventMask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Active tap (not listen-only): macOS 26 keeps listen-only keyboard
        // taps permanently disabled unless Input Monitoring is granted, while
        // active taps are governed by Accessibility, which Vara already holds.
        // The callback always returns the event unmodified, so this behaves
        // exactly like a listener.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(refcon).takeUnretainedValue()
                hotkey.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            throw HotkeyError.cannotCreateTap
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        diagnosticLog?("Global hotkey event tap installed. shortcut=\(describe(shortcut.keys))")

        // Re-arm the tap after sleep/wake (macOS Tahoe frequently disables it).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.rearm() }

        // Re-arm after screen unlock.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.rearm() }

        // Watchdog: macOS only tells us about a disabled tap via the next
        // event through the callback — which never arrives if the tap is dead.
        // Poll and revive it.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.rearm()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    public func uninstall() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = unlockObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        eventTap = nil
        runLoopSource = nil
        wakeObserver = nil
        unlockObserver = nil
        pressedKeys = []
        isDown = false
    }

    private func rearm() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            pressedKeys = []
            isDown = false
            CGEvent.tapEnable(tap: tap, enable: true)
            let holderPID = Self.secureInputHolderPID()
            if let holderPID {
                diagnosticLog?("Global hotkey event tap disabled — secure input held by pid \(holderPID).")
            } else {
                diagnosticLog?("Global hotkey event tap was found disabled; re-enabled.")
            }
            onTapBlocked?(holderPID)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pressedKeys = []
            isDown = false
            let reason = type == .tapDisabledByTimeout
                ? "timeout (process too slow — App Nap?)"
                : "secure input (password field active)"
            diagnosticLog?("Global hotkey event tap disabled by macOS: \(reason). Rearming.")
            rearm()
            return
        }
        if type == .keyDown {
            // Decouple in-dictation key handling from `isDown`: a watchdog
            // rearm forces `isDown` to false even while the shortcut is still
            // held, which would otherwise drop Esc-to-cancel and 1–9 mode
            // selection. Prefer the AppState-supplied predicate (isRecording);
            // fall back to the `isDown` gate when no predicate is set.
            let shouldForward = shouldForwardKeyDown?() ?? isDown
            guard shouldForward else { return }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            onKeyDownWhileActive?(keyCode)
            return
        }

        guard type == .flagsChanged else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let changedKey = Key(rawValue: keyCode) else { return }

        // Self-correcting: read pressed/released from the event's actual
        // modifier flags rather than toggling. A missed transition (watchdog
        // rearm, app launched with the key held, tap gap) can no longer invert
        // onDown/onUp. The keyCode identifies WHICH physical key changed; the
        // generic flag mask (.maskCommand/.maskAlternate/.maskControl, or the
        // function-key flag) tells us whether that modifier class is pressed.
        // Left/right keys of the same modifier share one mask, so we keep
        // keyCode-based identity for chord support: when the mask is set the
        // changed key is down; when it clears, no key of that class is held,
        // so we also drop its sibling to stay in sync.
        let flags = event.flags
        if changedKey.isActive(in: flags) {
            pressedKeys.insert(changedKey)
        } else {
            pressedKeys.remove(changedKey)
            if let sibling = changedKey.sibling {
                pressedKeys.remove(sibling)
            }
        }

        let isCurrentlyDown = !shortcut.keys.isEmpty && shortcut.keys.isSubset(of: pressedKeys)
        diagnosticLog?(
            "Global hotkey flagsChanged key=\(changedKey.displayTitle), pressed=\(describe(pressedKeys)), target=\(describe(shortcut.keys)), matched=\(isCurrentlyDown)"
        )
        if isCurrentlyDown, !isDown {
            isDown = true
            diagnosticLog?("Global hotkey down")
            onDown()
        } else if !isCurrentlyDown, isDown {
            isDown = false
            diagnosticLog?("Global hotkey up")
            onUp()
        }
    }

    private func describe(_ keys: Set<Key>) -> String {
        guard !keys.isEmpty else { return "none" }
        return keys.sorted { $0.sortOrder < $1.sortOrder }
            .map(\.displayTitle)
            .joined(separator: "+")
    }
}

private extension GlobalHotkey.Key {
    /// The generic CoreGraphics modifier mask for this key's modifier class.
    /// Left/right keys of the same modifier share one mask (e.g. both Command
    /// keys report `.maskCommand`), so the mask alone cannot tell left from
    /// right — that is what the keyCode is for.
    var modifierMask: CGEventFlags {
        switch self {
        case .leftCommand, .rightCommand: .maskCommand
        case .leftOption, .rightOption: .maskAlternate
        case .rightControl: .maskControl
        case .function: .maskSecondaryFn
        }
    }

    /// Whether this key's modifier class is currently pressed according to the
    /// event's actual modifier flags.
    func isActive(in flags: CGEventFlags) -> Bool {
        flags.contains(modifierMask)
    }

    /// The left/right counterpart that shares this key's modifier mask, if any.
    /// When a modifier mask clears, neither side is held, so the sibling must
    /// be dropped from `pressedKeys` to stay in sync.
    var sibling: GlobalHotkey.Key? {
        switch self {
        case .leftCommand: .rightCommand
        case .rightCommand: .leftCommand
        case .leftOption: .rightOption
        case .rightOption: .leftOption
        case .rightControl, .function: nil
        }
    }

    var displayTitle: String {
        switch self {
        case .leftCommand: "leftCommand"
        case .rightCommand: "rightCommand"
        case .leftOption: "leftOption"
        case .rightOption: "rightOption"
        case .rightControl: "rightControl"
        case .function: "function"
        }
    }

    var sortOrder: Int {
        switch self {
        case .leftCommand: 10
        case .rightCommand: 11
        case .leftOption: 20
        case .rightOption: 21
        case .rightControl: 30
        case .function: 40
        }
    }
}
