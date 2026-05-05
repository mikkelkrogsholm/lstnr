import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class RecordingHUDWindowController {
    struct Placement {
        enum Anchor {
            case insertionPoint
            case menuBar
        }

        var anchor: Anchor
        var screen: NSScreen?
        var topInset: CGFloat

        @MainActor
        static let menuBar = Placement(anchor: .menuBar, screen: nil, topInset: 72)

        @MainActor
        static let insertionPoint = Placement(anchor: .insertionPoint, screen: nil, topInset: 72)
    }

    private let placement: Placement
    private var panel: RecordingHUDPanel?
    private var hostingView: NSHostingView<RecordingHUDView>?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    init(placement: Placement = .menuBar) {
        self.placement = placement
    }

    func show(model: RecordingHUDModel) {
        let panel = panel(for: model)
        update(model: model)
        position(panel)
        panel.orderFrontRegardless()
    }

    func update(model: RecordingHUDModel) {
        guard let hostingView else { return }
        hostingView.rootView = RecordingHUDView(model: model)
        hostingView.layoutSubtreeIfNeeded()
        panel?.setContentSize(hostingView.fittingSize)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func panel(for model: RecordingHUDModel) -> RecordingHUDPanel {
        if let panel {
            return panel
        }

        let hostingView = NSHostingView(rootView: RecordingHUDView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let panel = RecordingHUDPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = hostingView
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        self.hostingView = hostingView
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        if placement.anchor == .insertionPoint, let insertionRect = TextInsertionPointLocator.locate() {
            position(panel, near: insertionRect)
            return
        }

        let screenFrame = (placement.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - placement.topInset - panelSize.height
        )
        panel.setFrameOrigin(origin)
    }

    private func position(_ panel: NSPanel, near insertionRect: NSRect) {
        let panelSize = panel.frame.size
        let screenFrame = screen(containing: insertionRect)?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let spacing: CGFloat = 10
        let preferredRightX = insertionRect.maxX + spacing
        let preferredLeftX = insertionRect.minX - panelSize.width - spacing
        let x = preferredRightX + panelSize.width <= screenFrame.maxX
            ? preferredRightX
            : preferredLeftX
        let y = insertionRect.midY - panelSize.height / 2

        panel.setFrameOrigin(
            NSPoint(
                x: min(max(x, screenFrame.minX + spacing), screenFrame.maxX - panelSize.width - spacing),
                y: min(max(y, screenFrame.minY + spacing), screenFrame.maxY - panelSize.height - spacing)
            )
        )
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.intersects(rect) }
            ?? NSScreen.screens.first { $0.frame.intersects(rect) }
    }
}

private final class RecordingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

private enum TextInsertionPointLocator {
    static func locate() -> NSRect? {
        guard let focusedElement = focusedUIElement() else {
            return nil
        }
        guard let selectedRange = selectedTextRange(in: focusedElement) else {
            return nil
        }
        return bounds(for: selectedRange, in: focusedElement)
    }

    private static func focusedUIElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard error == .success else {
            return nil
        }
        return (focusedValue as! AXUIElement)
    }

    private static func selectedTextRange(in element: AXUIElement) -> CFRange? {
        var selectedRangeValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )
        guard error == .success, let selectedRangeValue else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue as! AXValue, .cfRange, &selectedRange) else {
            return nil
        }
        return selectedRange
    }

    private static func bounds(for selectedRange: CFRange, in element: AXUIElement) -> NSRect? {
        var requestedRange = selectedRange
        guard let rangeValue = AXValueCreate(.cfRange, &requestedRange) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )
        guard error == .success, let boundsValue else {
            return nil
        }

        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds) else {
            return nil
        }
        guard bounds.isFinite else {
            return nil
        }

        return convertAccessibilityRectToAppKitScreenRect(bounds)
    }

    private static func convertAccessibilityRectToAppKitScreenRect(_ rect: CGRect) -> NSRect? {
        let normalizedHeight = max(rect.height, 18)
        let directRect = NSRect(x: rect.minX, y: rect.minY, width: max(rect.width, 2), height: normalizedHeight)
        if isOnScreen(directRect) {
            return directRect
        }

        guard let likelyScreen = NSScreen.screens.first(where: { $0.frame.minX <= rect.midX && rect.midX <= $0.frame.maxX })
            ?? NSScreen.main else {
            return nil
        }

        let flippedRect = NSRect(
            x: rect.minX,
            y: likelyScreen.frame.maxY - rect.minY - normalizedHeight,
            width: max(rect.width, 2),
            height: normalizedHeight
        )
        return isOnScreen(flippedRect) ? flippedRect : directRect
    }

    private static func isOnScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(rect) || $0.visibleFrame.intersects(rect) }
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
            && !isNull
            && !isInfinite
    }
}
