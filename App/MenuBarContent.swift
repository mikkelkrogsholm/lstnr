import SwiftUI

struct MenuBarContent: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: state.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(state.isRecording ? .red : .secondary)
                    .font(.system(size: 14, weight: .semibold))
                Text(state.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !state.lastTranscript.isEmpty {
                Divider()
                Text(state.lastTranscript)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if let error = state.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }

            Divider()
            HStack {
                Text("Hold ⌥ Right Option to dictate")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
