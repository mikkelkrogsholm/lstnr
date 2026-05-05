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
    private static var selectedTextMarkerRangeAttribute: CFString {
        "AXSelectedTextMarkerRange" as CFString
    }

    private static var boundsForTextMarkerRangeParameterizedAttribute: CFString {
        "AXBoundsForTextMarkerRange" as CFString
    }

    static func locate() -> NSRect? {
        guard let focusedElement = focusedUIElement() else {
            return nil
        }

        if let selectedRange = selectedTextRange(in: focusedElement),
           let rangeBounds = bounds(for: selectedRange, in: focusedElement) {
            return rangeBounds
        }

        return boundsForSelectedTextMarkerRange(in: focusedElement)
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

    private static func selectedTextMarkerRange(in element: AXUIElement) -> CFTypeRef? {
        var markerRangeValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            selectedTextMarkerRangeAttribute,
            &markerRangeValue
        )
        guard error == .success else {
            return nil
        }
        return markerRangeValue
    }

    private static func boundsForSelectedTextMarkerRange(in element: AXUIElement) -> NSRect? {
        guard let markerRange = selectedTextMarkerRange(in: element) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            boundsForTextMarkerRangeParameterizedAttribute,
            markerRange,
            &boundsValue
        )
        guard error == .success,
              let boundsValue,
              let bounds = accessibilityRect(from: boundsValue) else {
            return nil
        }

        return convertAccessibilityRectToAppKitScreenRect(bounds)
    }

    private static func bounds(for selectedRange: CFRange, in element: AXUIElement) -> NSRect? {
        let candidateRanges = caretCandidateRanges(for: selectedRange)
        for range in candidateRanges {
            guard let bounds = bounds(forRange: range, in: element) else {
                continue
            }
            return caretRect(from: bounds, using: range, originalRange: selectedRange)
        }
        return nil
    }

    private static func caretCandidateRanges(for selectedRange: CFRange) -> [CFRange] {
        if selectedRange.length > 0 {
            return [selectedRange]
        }

        var ranges = [selectedRange]
        ranges.append(CFRange(location: selectedRange.location, length: 1))
        if selectedRange.location > 0 {
            ranges.append(CFRange(location: selectedRange.location - 1, length: 1))
        }
        return ranges
    }

    private static func bounds(forRange range: CFRange, in element: AXUIElement) -> NSRect? {
        var requestedRange = range
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

        guard let bounds = accessibilityRect(from: boundsValue) else {
            return nil
        }

        return convertAccessibilityRectToAppKitScreenRect(bounds)
    }

    private static func accessibilityRect(from value: CFTypeRef) -> CGRect? {
        if CFGetTypeID(value) == AXValueGetTypeID() {
            var rect = CGRect.zero
            guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.isFinite else {
                return nil
            }
            return rect
        }

        guard let value = value as? NSValue else {
            return nil
        }
        let rect = value.rectValue
        return rect.isFinite ? rect : nil
    }

    private static func caretRect(from bounds: NSRect, using range: CFRange, originalRange: CFRange) -> NSRect {
        guard originalRange.length == 0 else {
            return bounds
        }

        let caretX = range.location < originalRange.location ? bounds.maxX : bounds.minX
        return NSRect(
            x: caretX,
            y: bounds.minY,
            width: 2,
            height: max(bounds.height, 18)
        )
    }

    private static func convertAccessibilityRectToAppKitScreenRect(_ rect: CGRect) -> NSRect? {
        guard let desktopFrame = desktopFrame else {
            return nil
        }

        let normalizedHeight = max(rect.height, 18)
        let flippedRect = NSRect(
            x: rect.minX,
            y: desktopFrame.maxY - rect.minY - normalizedHeight,
            width: max(rect.width, 2),
            height: normalizedHeight
        )
        return isOnScreen(flippedRect) ? flippedRect : nil
    }

    private static func isOnScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(rect) || $0.visibleFrame.intersects(rect) }
    }

    private static var desktopFrame: NSRect? {
        NSScreen.screens
            .map(\.frame)
            .reduce(nil) { partial, frame in
                guard let partial else { return frame }
                return partial.union(frame)
            }
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
