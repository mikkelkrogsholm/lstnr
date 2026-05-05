import SwiftUI

@main
struct LstnrApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Lstnr", id: "main") {
            LstnrDashboardView(state: state)
        }
        .defaultSize(width: 860, height: 620)

        MenuBarExtra {
            MenuBarContent(state: state)
        } label: {
            Label(
                state.isRecording ? "lstnr •" : "lstnr",
                systemImage: state.isRecording ? "mic.fill" : "mic"
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            LstnrSettingsView()
        }
    }
}
