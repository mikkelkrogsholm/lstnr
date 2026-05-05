import AppKit
import SwiftUI

@MainActor
final class RecordingHUDWindowController {
    struct Placement {
        var screen: NSScreen?
        var topInset: CGFloat

        @MainActor
        static let menuBar = Placement(screen: nil, topInset: 72)
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
        let screenFrame = (placement.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - placement.topInset - panelSize.height
        )
        panel.setFrameOrigin(origin)
    }
}

private final class RecordingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
