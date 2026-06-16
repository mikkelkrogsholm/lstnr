import Combine
import Sparkle
import SwiftUI

/// Tracks whether Sparkle can currently start an update check, so the menu item
/// disables itself while a check is already in flight (the pattern Sparkle's
/// SwiftUI guide recommends).
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// A "Check for Updates…" button wired to the Sparkle updater. Dropped into the
/// menu bar popover's footer.
struct CheckForUpdatesButton: View {
    private let updater: SPUUpdater
    @StateObject private var viewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button {
            updater.checkForUpdates()
        } label: {
            Text("Check for Updates…", comment: "Menu bar footer button: check for app updates")
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
