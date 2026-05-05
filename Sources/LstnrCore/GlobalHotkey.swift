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
            Open System Settings → Privacy & Security → Accessibility and enable lstnr.
            """
        case .cannotCreateTap:
            return """
            Failed to create CGEventTap. Accessibility permission is probably missing.
            Open System Settings → Privacy & Security → Accessibility and enable lstnr.
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
    private var pressedKeys: Set<Key> = []
    private var isDown = false
    let shortcut: Shortcut
    let diagnosticLog: (@Sendable (String) -> Void)?
    let onDown: @Sendable () -> Void
    let onUp: @Sendable () -> Void

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
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pressedKeys = []
            isDown = false
            diagnosticLog?("Global hotkey event tap disabled by macOS. Rearming.")
            rearm()
            return
        }
        guard type == .flagsChanged else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let changedKey = Key(rawValue: keyCode) else { return }

        if pressedKeys.contains(changedKey) {
            pressedKeys.remove(changedKey)
        } else {
            pressedKeys.insert(changedKey)
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
