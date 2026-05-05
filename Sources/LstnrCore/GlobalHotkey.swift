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
/// fires onDown/onUp. Uses per-side NX bits so Right Option is distinguished
/// from Left Option. Re-enables the tap on timeout / user-input-secure-input
/// interruptions, and after sleep/wake and lock/unlock.
public final class GlobalHotkey: @unchecked Sendable {
    public enum Key: UInt16, Sendable {
        case rightOption = 61
        case leftOption = 58
        case rightCommand = 54
        case rightControl = 62
        case function = 63

        /// Raw NX device bitmask for this specific side.
        /// From IOKit/hidsystem/IOLLEvent.h.
        public var sideMask: UInt64 {
            switch self {
            case .rightOption:  return 0x0000_0040
            case .leftOption:   return 0x0000_0020
            case .rightCommand: return 0x0000_0010
            case .rightControl: return 0x0000_2000
            case .function:     return 0  // Fn doesn't expose a side bit
            }
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var isDown = false
    let key: Key
    let onDown: @Sendable () -> Void
    let onUp: @Sendable () -> Void

    public init(
        key: Key = .rightOption,
        onDown: @escaping @Sendable () -> Void,
        onUp: @escaping @Sendable () -> Void
    ) {
        self.key = key
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
    }

    private func rearm() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            rearm()
            return
        }
        guard type == .flagsChanged else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == key.rawValue else { return }
        let sideMask = key.sideMask
        guard sideMask != 0 else {
            // Fallback for Fn which lacks a side bit: use transition toggle.
            isDown.toggle()
            if isDown { onDown() } else { onUp() }
            return
        }
        let isCurrentlyDown = (event.flags.rawValue & sideMask) != 0
        if isCurrentlyDown && !isDown {
            isDown = true
            onDown()
        } else if !isCurrentlyDown && isDown {
            isDown = false
            onUp()
        }
    }
}
