import LstnrCore
import SwiftUI

/// Vara's home window: status hero, mode picker, stats, try-it scratchpad and
/// searchable history. Replaces the old developer-tool layout.
struct LstnrDashboardView: View {
    let state: AppState
    @State private var scratchpadText = ""
    @State private var searchText = ""
    @State private var accessibilityGranted = true
    @State private var expandedHistoryItemID: UUID?
    @State private var collapsedAppGroups: Set<String> = []
    @FocusState private var scratchpadIsFocused: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader
                permissionWarnings
                modePicker
                statsRow
                scratchpadCard
                historySection
                footer
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(BSTheme.background)
        .frame(minWidth: 640, minHeight: 560)
        .onAppear {
            accessibilityGranted = state.checkAccessibilityGranted()
        }
    }

    // MARK: Hero

    private var heroHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            statusOrb

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Vara")
                    .font(BSTheme.display(30, weight: .semibold))
                    .foregroundStyle(BSTheme.textPrimary)

                Text(state.statusMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(BSTheme.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                KeyCapView(keys: shortcutKeyCaps, size: 30)
                Text("Hold — speak — release", comment: "Hero hint under the shortcut key caps")
                    .font(.system(size: 11))
                    .foregroundStyle(BSTheme.textMuted)
            }
        }
    }

    private var statusOrb: some View {
        ZStack {
            Circle()
                .fill(orbTint.opacity(0.16))
                .frame(width: 54, height: 54)

            Circle()
                .strokeBorder(orbTint.opacity(0.4), lineWidth: 1)
                .frame(width: 54, height: 54)

            Image(systemName: orbSymbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(orbTint)
                .contentTransition(.symbolEffect(.replace))
        }
        .emberGlow(active: state.isRecording)
        .animation(.spring(duration: 0.3), value: state.isRecording)
    }

    private var orbTint: Color {
        if state.isRecording { return BSTheme.stateRecording }
        if state.isTranscribing { return BSTheme.stateForging }
        return BSTheme.stateIdle
    }

    private var orbSymbol: String {
        if state.isRecording { return "mic.fill" }
        if state.isTranscribing { return "hammer.fill" }
        return "mic"
    }

    private var shortcutKeyCaps: [String] {
        let title = state.settings.shortcut.title
        let symbol = state.settings.shortcut.symbol
        if symbol.count > 1, symbol != "fn" {
            return symbol.map(String.init)
        }
        return [symbol.isEmpty ? title : symbol]
    }

    // MARK: Permissions (only shown when something is wrong)

    @ViewBuilder
    private var permissionWarnings: some View {
        let micDenied = state.microphonePermissionStatus != "authorized"
            && state.microphonePermissionStatus != "notDetermined"
        if micDenied || !accessibilityGranted || state.lastError != nil {
            BSCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    if micDenied {
                        HStack {
                            StatusPill(
                                text: String(localized: "Microphone access missing", comment: "Permission warning pill"),
                                tint: BSTheme.stateError,
                                systemImage: "mic.slash.fill"
                            )
                            Spacer()
                            Button {
                                openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                            } label: {
                                Text("Open System Settings", comment: "Button opening macOS privacy settings")
                            }
                            .controlSize(.small)
                        }
                    }

                    if !accessibilityGranted {
                        HStack {
                            StatusPill(
                                text: String(localized: "Accessibility access missing — the hotkey and pasting need it", comment: "Permission warning pill"),
                                tint: BSTheme.stateError,
                                systemImage: "lock.shield"
                            )
                            Spacer()
                            Button {
                                accessibilityGranted = state.requestAccessibilityPermission()
                            } label: {
                                Text("Grant access", comment: "Button requesting accessibility permission")
                            }
                            .controlSize(.small)
                        }
                    }

                    if let error = state.lastError {
                        Text(error)
                            .font(BSTheme.mono(10))
                            .foregroundStyle(BSTheme.stateError)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    // MARK: Modes

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(String(localized: "Mode", comment: "Dashboard section title"), systemImage: "wand.and.stars")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(state.settings.modes.enumerated()), id: \.element.id) { index, mode in
                        ModeChip(
                            mode: mode,
                            index: index + 1,
                            isSelected: mode.id == state.settings.selectedModeID,
                            isReady: state.isModeReady(mode)
                        ) {
                            if state.isModeReady(mode) {
                                state.selectMode(mode)
                            } else {
                                SettingsDeepLink.request(.intelligence)
                                openSettings()
                            }
                        }
                    }
                }
            }

            Text("Tip: press 1–9 while dictating to use another mode for that dictation only.", comment: "Mode picker hint")
                .font(.system(size: 11))
                .foregroundStyle(BSTheme.textMuted)
        }
    }

    // MARK: Stats

    private var stats: DictationStats {
        DictationStats.compute(items: state.historyItems)
    }

    private var statsRow: some View {
        let stats = stats
        let averageSeconds = state.historyItems.isEmpty
            ? 0
            : state.historyItems.map(\.elapsedTranscriptionSeconds).reduce(0, +) / Double(state.historyItems.count)

        return HStack(spacing: 12) {
            StatCard(
                value: "\(stats.wordsToday)",
                label: String(localized: "Words today", comment: "Stat card label"),
                systemImage: "text.word.spacing"
            )
            StatCard(
                value: "\(stats.wordsThisWeek)",
                label: String(localized: "This week", comment: "Stat card label"),
                systemImage: "calendar"
            )
            StatCard(
                value: Self.formatDuration(stats.estimatedSavedSeconds),
                label: String(localized: "Time saved", comment: "Stat card label"),
                systemImage: "hourglass"
            )
            StatCard(
                value: averageSeconds > 0 ? String(format: "%.1f s", averageSeconds) : "—",
                label: String(localized: "Avg. per dictation", comment: "Stat card label"),
                systemImage: "bolt.fill"
            )
        }
    }

    // MARK: Scratchpad

    private var scratchpadCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(String(localized: "Try it", comment: "Dashboard section title"), systemImage: "text.cursor")
                Spacer()
                Button {
                    scratchpadText = ""
                    scratchpadIsFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(BSTheme.textMuted)
                }
                .help(String(localized: "Clear", comment: "Clear scratchpad tooltip"))
                .buttonStyle(.borderless)
            }

            TextEditor(text: $scratchpadText)
                .focused($scratchpadIsFocused)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 96)
                .background(BSTheme.surface, in: RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous)
                        .strokeBorder(scratchpadIsFocused ? BSTheme.teal.opacity(0.6) : BSTheme.border)
                }
                .overlay(alignment: .topLeading) {
                    if scratchpadText.isEmpty {
                        Text("Click here, hold \(state.settings.shortcut.symbol) and say hello to Vara.", comment: "Scratchpad placeholder")
                            .font(.system(size: 13))
                            .foregroundStyle(BSTheme.textMuted)
                            .padding(.top, 14)
                            .padding(.leading, 17)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: History

    private var filteredHistory: [DictationHistoryItem] {
        guard !searchText.isEmpty else { return state.historyItems }
        return state.historyItems.filter { item in
            item.rawTranscript.localizedCaseInsensitiveContains(searchText)
                || (item.cleanedTranscript?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// History grouped by the app the text landed in; unknown targets fall
    /// under "General". Groups ordered by most recent activity.
    private var historyByApp: [(app: String, items: [DictationHistoryItem])] {
        let generalTitle = String(localized: "General", comment: "History group for dictations without a known target app")
        let groups = Dictionary(grouping: filteredHistory) { $0.targetAppName ?? generalTitle }
        return groups
            .map { (app: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { ($0.items.first?.createdAt ?? .distantPast) > ($1.items.first?.createdAt ?? .distantPast) }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                sectionTitle(String(localized: "History", comment: "Dashboard section title"), systemImage: "clock.arrow.circlepath")

                Spacer()

                if !state.historyItems.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(BSTheme.textMuted)
                        TextField(
                            String(localized: "Search", comment: "History search placeholder"),
                            text: $searchText
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 140)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(BSTheme.surface, in: Capsule())
                    .overlay { Capsule().strokeBorder(BSTheme.border) }

                    Button {
                        state.clearHistory()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(BSTheme.textMuted)
                    }
                    .help(String(localized: "Clear history", comment: "Clear history tooltip"))
                    .buttonStyle(.borderless)
                }
            }

            if state.historyItems.isEmpty {
                BSCard {
                    HStack(spacing: 12) {
                        Image(systemName: "mic.badge.plus")
                            .font(.system(size: 22))
                            .foregroundStyle(BSTheme.teal)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Nothing dictated yet", comment: "Empty history title")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(BSTheme.textPrimary)
                            Text("Your dictations land here so you can copy or reinsert them later.", comment: "Empty history subtitle")
                                .font(.system(size: 12))
                                .foregroundStyle(BSTheme.textMuted)
                        }
                    }
                }
            } else if filteredHistory.isEmpty {
                Text("No matches for “\(searchText)”", comment: "Empty search result message")
                    .font(.system(size: 12))
                    .foregroundStyle(BSTheme.textMuted)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(historyByApp, id: \.app) { group in
                        let isCollapsed = collapsedAppGroups.contains(group.app)

                        Button {
                            withAnimation(.spring(duration: 0.25)) {
                                if isCollapsed {
                                    collapsedAppGroups.remove(group.app)
                                } else {
                                    collapsedAppGroups.insert(group.app)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                                Image(systemName: "macwindow")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(group.app)
                                    .textCase(.uppercase)
                                Text(verbatim: "· \(group.items.count)")
                                Spacer()
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BSTheme.textMuted)
                            .padding(.top, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if !isCollapsed {
                            ForEach(group.items) { item in
                                HistoryRow(
                                    item: item,
                                    isExpanded: expandedHistoryItemID == item.id,
                                    toggleExpanded: {
                                        withAnimation(.spring(duration: 0.25)) {
                                            expandedHistoryItemID = expandedHistoryItemID == item.id ? nil : item.id
                                        }
                                    },
                                    copy: { state.copyTranscript(item) },
                                    reinsert: {
                                        scratchpadIsFocused = true
                                        state.reinsertTranscript(item)
                                    },
                                    delete: { state.deleteHistoryItem(item) }
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Row timestamp: time alone for today, short date otherwise.
    static func rowTimestamp(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                openURL(URL(string: "https://brokk-sindre.dk")!)
            } label: {
                Text("Forged by Brokk & Sindre", comment: "Footer branding link")
                    .font(BSTheme.display(12, weight: .medium))
                    .foregroundStyle(BSTheme.textMuted)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .font(BSTheme.display(14, weight: .semibold))
                .foregroundStyle(BSTheme.textPrimary)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BSTheme.teal)
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(localized: "<1 min", comment: "Duration under a minute")
        }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return String(localized: "\(minutes) min", comment: "Duration in minutes")
        }
        let hours = Double(minutes) / 60
        return String(localized: "\(hours.formatted(.number.precision(.fractionLength(1)))) h", comment: "Duration in hours")
    }
}

// MARK: - Components

private struct ModeChip: View {
    let mode: DictationMode
    let index: Int
    let isSelected: Bool
    let isReady: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                if index <= 9, isReady {
                    Text("\(index)")
                        .font(BSTheme.mono(9, weight: .semibold))
                        .foregroundStyle(isSelected ? BSTheme.petrol.opacity(0.7) : BSTheme.textMuted)
                        .frame(width: 13, height: 13)
                        .background(
                            (isSelected ? Color.white.opacity(0.35) : BSTheme.surfaceHover),
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                }
                if !isReady {
                    Image(systemName: "key.slash")
                        .font(.system(size: 9, weight: .semibold))
                }
                Image(systemName: mode.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.displayTitle)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? BSTheme.petrol : (isReady ? BSTheme.textPrimary : BSTheme.textMuted))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                isSelected ? AnyShapeStyle(BSTheme.cyan) : AnyShapeStyle(BSTheme.surface),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(isSelected ? Color.clear : BSTheme.border)
            }
            .opacity(isReady ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .help(
            isReady
                ? mode.displaySubtitle
                : String(localized: "Requires setup — click to open Settings", comment: "Tooltip on a mode without a configured LLM")
        )
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        BSCard(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BSTheme.teal)
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(BSTheme.textMuted)
                        .lineLimit(1)
                }
                Text(value)
                    .font(BSTheme.display(22, weight: .semibold))
                    .foregroundStyle(BSTheme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

private struct HistoryRow: View {
    let item: DictationHistoryItem
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    let copy: () -> Void
    let reinsert: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.displayTranscript)
                .font(.system(size: 12.5))
                .foregroundStyle(BSTheme.textPrimary)
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isExpanded, let cleaned = item.cleanedTranscript, cleaned != item.rawTranscript {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Raw transcript", comment: "Expanded history label")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BSTheme.textMuted)
                        .textCase(.uppercase)
                    Text(item.rawTranscript)
                        .font(.system(size: 12))
                        .foregroundStyle(BSTheme.textMuted)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BSTheme.surfaceHover, in: RoundedRectangle(cornerRadius: BSTheme.smallCornerRadius))
            }

            HStack(spacing: 8) {
                Text(LstnrDashboardView.rowTimestamp(for: item.createdAt))
                if let modeName = item.modeName {
                    metaChip(modeName)
                }
                metaChip("\(DictationStats.wordCount(of: item.displayTranscript)) " + String(localized: "words", comment: "Word count unit in history row"))
                if let duration = item.audioDurationSeconds {
                    metaChip(String(format: "%.0f s", duration))
                }

                Spacer()

                if isHovering {
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help(String(localized: "Copy", comment: "History action tooltip"))

                    Button(action: reinsert) {
                        Image(systemName: "arrow.turn.down.left")
                    }
                    .help(String(localized: "Reinsert", comment: "History action tooltip"))

                    Button(action: delete) {
                        Image(systemName: "trash")
                    }
                    .help(String(localized: "Delete", comment: "History action tooltip"))
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .foregroundStyle(BSTheme.textMuted)
        }
        .padding(12)
        .background(
            isHovering ? BSTheme.surfaceHover : BSTheme.surface,
            in: RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous)
                .strokeBorder(BSTheme.border)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleExpanded)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(BSTheme.surfaceHover, in: Capsule())
    }
}

#Preview("Dashboard") {
    LstnrDashboardView(state: AppState())
}
