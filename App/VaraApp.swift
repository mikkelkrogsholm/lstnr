import Sparkle
import SwiftUI

@main
struct VaraApp: App {
    @State private var state = AppState()
    /// Sparkle auto-updater + "update available" state for the in-app banner.
    /// Created once for the app's lifetime; does scheduled background checks AND a
    /// silent launch check so the dashboard can show a visible update prompt.
    @StateObject private var updateModel = VaraUpdateModel()

    var body: some Scene {
        WindowGroup("Vara", id: "main") {
            MainWindowRoot(state: state, updateModel: updateModel)
        }
        .defaultSize(width: 860, height: 620)

        MenuBarExtra {
            MenuBarContent(state: state, updater: updateModel.updater)
        } label: {
            Label(
                state.isRecording ? "Vara •" : "Vara",
                systemImage: state.isRecording ? "mic.fill" : "mic"
            )
        }
        .menuBarExtraStyle(.window)

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(state: state)
        }
        .defaultSize(width: 640, height: 420)

        Settings {
            // Inject AppState so WhisperKitModelSection can read the warm state.
            VaraSettingsView().environment(state)
        }
    }
}

/// Shows the welcome flow on first launch (or when reopened from Settings),
/// otherwise the dashboard.
private struct MainWindowRoot: View {
    let state: AppState
    @ObservedObject var updateModel: VaraUpdateModel
    @AppStorage(VaraOnboarding.completedDefaultsKey) private var onboardingCompleted = false

    var body: some View {
        if onboardingCompleted {
            VaraDashboardView(state: state, updateModel: updateModel)
        } else {
            OnboardingView(state: state)
        }
    }
}
