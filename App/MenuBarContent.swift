import VaraCore
import SwiftUI

/// Vara's menu bar popover: status, mode quick-switch, dictation toggle,
/// latest transcript and recent history.
struct MenuBarContent: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader
            modeQuickSwitch
            toggleButton

            if state.settings.keepRecentTranscript, !state.lastTranscript.isEmpty {
                latestTranscript
            }

            if !state.historyItems.isEmpty {
                recentHistory
            }

            if let error = state.lastError {
                Text(error)
                    .font(BSTheme.mono(10))
                    .foregroundStyle(BSTheme.stateError)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            footer
        }
        .padding(14)
        .frame(width: 348)
    }

    // MARK: Sections

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
                .emberGlow(active: state.isRecording)

            Text(verbatim: "Vara")
                .font(BSTheme.display(14, weight: .semibold))
                .foregroundStyle(BSTheme.textPrimary)

            Text(state.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(BSTheme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
    }

    private var statusTint: Color {
        if state.isRecording { return BSTheme.stateRecording }
        if state.isTranscribing { return BSTheme.stateForging }
        return BSTheme.stateIdle
    }

    private var modeQuickSwitch: some View {
        HStack(spacing: 5) {
            ForEach(state.settings.modes) { mode in
                let isSelected = mode.id == state.settings.selectedModeID
                let isReady = state.isModeReady(mode)
                Button {
                    if isReady {
                        state.selectMode(mode)
                    } else {
                        SettingsDeepLink.request(.intelligence)
                        openSettings()
                    }
                } label: {
                    Image(systemName: isReady ? mode.symbolName : "key.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? BSTheme.petrol : BSTheme.textMuted)
                        .frame(width: 30, height: 24)
                        .background(
                            isSelected ? AnyShapeStyle(BSTheme.cyan) : AnyShapeStyle(BSTheme.surfaceHover),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .opacity(isReady ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .help(
                    isReady
                        ? mode.displayTitle
                        : String(localized: "Requires setup — click to open Settings", comment: "Tooltip on a mode without a configured LLM")
                )
            }

            Spacer()

            Text(state.activeMode.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BSTheme.tealLight)
                .lineLimit(1)
        }
    }

    private var toggleButton: some View {
        Button {
            state.toggleDictationFromMenu()
        } label: {
            Label {
                state.isRecording
                    ? Text("Stop dictation", comment: "Menu bar primary button while recording")
                    : Text("Start dictation", comment: "Menu bar primary button when idle")
            } icon: {
                Image(systemName: state.isRecording ? "stop.fill" : "mic.fill")
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(state.isRecording ? BSTheme.ember : BSTheme.teal)
        .disabled(state.isTranscribing)
    }

    private var latestTranscript: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Latest", comment: "Menu bar latest transcript label")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BSTheme.textMuted)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    ClipboardPaster.copyToClipboard(text: state.lastTranscript)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Copy", comment: "Copy tooltip"))
            }

            Text(state.lastTranscript)
                .font(.system(size: 12))
                .foregroundStyle(BSTheme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(BSTheme.surfaceHover.opacity(0.6), in: RoundedRectangle(cornerRadius: BSTheme.smallCornerRadius))
    }

    private var recentHistory: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent", comment: "Menu bar recent history label")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BSTheme.textMuted)
                .textCase(.uppercase)

            ForEach(Array(state.historyItems.prefix(3))) { item in
                MenuHistoryRow(
                    item: item,
                    copy: { state.copyTranscript(item) },
                    reinsert: { state.reinsertTranscript(item) }
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Link(destination: URL(string: "https://brokk-sindre.dk")!) {
                Text(verbatim: "Brokk & Sindre")
                    .font(BSTheme.display(10, weight: .medium))
                    .foregroundStyle(BSTheme.textMuted)
            }
            .help(String(localized: "Forged by Brokk & Sindre", comment: "Footer branding link"))

            Spacer()

            Button {
                openWindow(id: "main")
            } label: {
                Text("Open Vara", comment: "Menu bar footer button")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))

            SettingsLink {
                Text("Settings", comment: "Menu bar footer button")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))

            Button {
                openWindow(id: "diagnostics")
            } label: {
                Text("Diagnostics", comment: "Menu bar footer button")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit", comment: "Menu bar footer button")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .keyboardShortcut("q")
        }
    }
}

private struct MenuHistoryRow: View {
    let item: DictationHistoryItem
    let copy: () -> Void
    let reinsert: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.cleanedTranscript ?? item.rawTranscript)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BSTheme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.createdAt, style: .time)
                    .font(.system(size: 9.5))
                    .foregroundStyle(BSTheme.textMuted)
            }

            if isHovering {
                HStack(spacing: 4) {
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .help(String(localized: "Copy", comment: "Copy tooltip"))

                    Button(action: reinsert) {
                        Image(systemName: "arrow.turn.down.left")
                            .font(.system(size: 10))
                    }
                    .help(String(localized: "Reinsert", comment: "Reinsert tooltip"))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(
            isHovering ? BSTheme.surfaceHover : Color.clear,
            in: RoundedRectangle(cornerRadius: BSTheme.smallCornerRadius)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
