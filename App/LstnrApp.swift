import SwiftUI

@main
struct LstnrApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: state)
        } label: {
            Label(
                state.isRecording ? "lstnr •" : "lstnr",
                systemImage: state.isRecording ? "mic.fill" : "mic"
            )
        }
        .menuBarExtraStyle(.window)
    }
}
