import LstnrCore
import SwiftUI

struct MenuBarContent: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

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

            Button {
                state.toggleDictationFromMenu()
            } label: {
                Label(state.isRecording ? "Stop Dictation" : "Start Dictation", systemImage: state.isRecording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isTranscribing)

            Button {
                openWindow(id: "main")
            } label: {
                Label("Open App", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

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

            if !state.historyItems.isEmpty {
                Divider()
                HStack {
                    Text("History")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Clear") {
                        state.clearHistory()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                }

                VStack(spacing: 6) {
                    ForEach(Array(state.historyItems.prefix(5))) { item in
                        HistoryRow(
                            item: item,
                            copy: { state.copyTranscript(item) },
                            reinsert: { state.reinsertTranscript(item) },
                            delete: { state.deleteHistoryItem(item) }
                        )
                    }
                }
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
                Text("Hold \(state.settings.shortcut.title) to dictate")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Text("Settings")
                }
                .buttonStyle(.borderless)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

private struct HistoryRow: View {
    let item: DictationHistoryItem
    let copy: () -> Void
    let reinsert: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayTranscript)
                .font(.system(size: 12))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(item.createdAt, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(item.insertionStatus.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy")
                .buttonStyle(.borderless)

                Button {
                    reinsert()
                } label: {
                    Image(systemName: "arrow.turn.down.left")
                }
                .help("Reinsert")
                .buttonStyle(.borderless)

                Button {
                    delete()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete")
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension DictationHistoryItem {
    var displayTranscript: String {
        cleanedTranscript ?? rawTranscript
    }
}

private extension DictationInsertionStatus {
    var title: String {
        switch self {
        case .inserted: "Inserted"
        case .notInserted: "Saved"
        case .failed: "Failed"
        }
    }
}
