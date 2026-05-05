import LstnrCore
import SwiftUI

struct LstnrDashboardView: View {
    let state: AppState
    @State private var scratchpadText = ""
    @FocusState private var scratchpadIsFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            HStack(spacing: 0) {
                scratchpad
                    .frame(minWidth: 360)

                Divider()

                VStack(spacing: 0) {
                    historyPanel
                    Divider()
                    debugLogPanel
                }
                .frame(width: 330)
            }
            .navigationTitle("Lstnr")
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            scratchpadIsFocused = true
            state.setInAppTextInsertionTargetFocused(true)
        }
        .onDisappear {
            state.setInAppTextInsertionTargetFocused(false)
        }
        .onChange(of: scratchpadIsFocused) { _, isFocused in
            state.setInAppTextInsertionTargetFocused(isFocused)
        }
        .onChange(of: state.latestTextInsertion?.id) { _, _ in
            guard scratchpadIsFocused, let insertion = state.latestTextInsertion else { return }
            insertIntoScratchpad(insertion.text)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusHeader

            VStack(spacing: 10) {
                Button {
                    state.toggleDictationFromMenu()
                } label: {
                    Label(
                        state.isRecording ? "Stop Dictation" : "Start Dictation",
                        systemImage: state.isRecording ? "stop.fill" : "mic.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(state.isTranscribing)

                Button {
                    scratchpadIsFocused = true
                } label: {
                    Label("Focus Test Area", systemImage: "cursorarrow.click")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Divider()

            LabeledContent("Shortcut") {
                Text(state.settings.shortcut.title)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Language") {
                Text(state.settings.language.title)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Cleanup") {
                Text(state.settings.cleanupMode.title)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Paste") {
                Text(state.settings.pasteAutomatically ? "On" : "Off")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Microphone") {
                Text(state.microphoneName)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("Mic Access") {
                Text(state.microphonePermissionStatus)
                    .foregroundStyle(.secondary)
            }

            Button {
                _ = state.requestAccessibilityPermission()
            } label: {
                Label("Check Accessibility", systemImage: "lock.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Spacer()

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusTint.opacity(0.14))
                        .frame(width: 38, height: 38)

                    Image(systemName: statusImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(statusTint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("lstnr")
                        .font(.system(size: 18, weight: .semibold))

                    Text(state.statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let error = state.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
    }

    private var scratchpad: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Test Area", systemImage: "text.cursor")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    scratchpadText = ""
                    scratchpadIsFocused = true
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Clear")
                .buttonStyle(.borderless)
            }

            TextEditor(text: $scratchpadText)
                .focused($scratchpadIsFocused)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08))
                }

            if !state.lastTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(state.lastTranscript)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(18)
    }

    private func insertIntoScratchpad(_ text: String) {
        if scratchpadText.isEmpty || scratchpadText.hasSuffix("\n") {
            scratchpadText += text
        } else {
            scratchpadText += "\n" + text
        }
        scratchpadIsFocused = true
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    state.clearHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear History")
                .buttonStyle(.borderless)
                .disabled(state.historyItems.isEmpty)
            }

            if state.historyItems.isEmpty {
                ContentUnavailableView("No Dictations", systemImage: "mic")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(state.historyItems) { item in
                            DashboardHistoryRow(
                                item: item,
                                copy: { state.copyTranscript(item) },
                                reinsert: {
                                    scratchpadIsFocused = true
                                    state.reinsertTranscript(item)
                                },
                                delete: { state.deleteHistoryItem(item) }
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var debugLogPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Debug Log", systemImage: "stethoscope")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    state.copyDebugLog()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy Debug Log")
                .buttonStyle(.borderless)

                Button {
                    state.clearDebugLog()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear Debug Log")
                .buttonStyle(.borderless)
            }

            Text(state.debugLogFilePath)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if state.debugLogEntries.isEmpty {
                Text("No events yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(state.debugLogEntries.prefix(20)) { entry in
                            Text(entry.line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(minHeight: 180, maxHeight: 220)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusImage: String {
        if state.isRecording { return "mic.fill" }
        if state.isTranscribing { return "text.bubble" }
        return "mic"
    }

    private var statusTint: Color {
        if state.isRecording { return .red }
        if state.isTranscribing { return .blue }
        return .secondary
    }
}

private struct DashboardHistoryRow: View {
    let item: DictationHistoryItem
    let copy: () -> Void
    let reinsert: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.displayTranscript)
                .font(.system(size: 12))
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(item.createdAt, style: .time)
                    .foregroundStyle(.secondary)
                Text(item.insertionStatus.title)
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
            .font(.system(size: 10))
        }
        .padding(10)
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
