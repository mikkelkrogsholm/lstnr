import os
import Sparkle
import SwiftUI

/// Owns the Sparkle updater and surfaces "an update is available" to SwiftUI, so
/// the app can show a visible banner + button instead of relying only on the
/// buried "Check for Updates…" menu item and Sparkle's occasional modal.
///
/// On launch it does a SILENT check (`checkForUpdateInformation()` — no modal);
/// when the appcast has a newer build, `availableVersion` is published and the
/// dashboard banner appears. "Update now" then runs Sparkle's normal install UI.
@MainActor
final class VaraUpdateModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// The newer version users can install right now, or nil if up to date.
    @Published private(set) var availableVersion: String?

    nonisolated private static let log = Logger(subsystem: "dk.56n.vara", category: "updates")
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // startingUpdater:true keeps Sparkle's scheduled background checks running
        // (cadence via SUScheduledCheckInterval); the delegate lets us also react
        // to a silent, modal-free probe.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.checkForUpdateInformation()
    }

    var updater: SPUUpdater { controller.updater }

    /// Run Sparkle's standard download/install/relaunch flow (the "Update now" button).
    func installUpdate() {
        controller.updater.checkForUpdates()
    }

    /// Re-probe silently (e.g. when the dashboard appears) so the banner stays current.
    func refresh() {
        controller.updater.checkForUpdateInformation()
    }

    // MARK: SPUUpdaterDelegate (Sparkle calls these on the main thread)

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Self.log.notice("Update available: \(version, privacy: .public)")
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Self.log.info("No update found — up to date")
        Task { @MainActor in self.availableVersion = nil }
    }
}
