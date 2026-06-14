// Per-app automatic mode rules.

import AppKit
import LstnrCore
import SwiftUI

/// Lists per-app mode rules (with delete) and pickers to add a rule mapping a
/// running app to a mode. All mutations go through the shared `draft.appModeRules`.
struct AppRulesSection: View {
    @Binding var draft: LstnrSettingsDraft

    @State private var newRuleBundleID: String?
    @State private var newRuleModeID: UUID?

    private struct RunningAppChoice: Hashable, Identifiable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    private var runningAppChoices: [RunningAppChoice] {
        var seenBundleIDs = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> RunningAppChoice? in
                guard let bundleID = app.bundleIdentifier,
                      let name = app.localizedName,
                      seenBundleIDs.insert(bundleID).inserted else { return nil }
                return RunningAppChoice(bundleID: bundleID, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Section {
            ForEach(draft.appModeRules) { rule in
                HStack {
                    Text(rule.appName)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(draft.modes.first { $0.id == rule.modeID }?.displayTitle ?? "—")
                        .foregroundStyle(BSTheme.teal)
                    Spacer()
                    Button {
                        draft.appModeRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                Picker(selection: $newRuleBundleID) {
                    Text("Choose app", comment: "App rule picker placeholder").tag(String?.none)
                    ForEach(runningAppChoices) { app in
                        Text(app.name).tag(String?.some(app.bundleID))
                    }
                } label: {
                    Text("App", comment: "App rule field")
                }
                .labelsHidden()

                Picker(selection: $newRuleModeID) {
                    Text("Choose mode", comment: "App rule picker placeholder").tag(UUID?.none)
                    ForEach(draft.modes) { mode in
                        Text(mode.displayTitle).tag(UUID?.some(mode.id))
                    }
                } label: {
                    Text("Mode", comment: "App rule field")
                }
                .labelsHidden()

                Button {
                    guard let bundleID = newRuleBundleID,
                          let modeID = newRuleModeID,
                          let app = runningAppChoices.first(where: { $0.bundleID == bundleID }) else { return }
                    draft.appModeRules.removeAll { $0.bundleID == bundleID }
                    draft.appModeRules.append(
                        AppModeRule(bundleID: bundleID, appName: app.name, modeID: modeID)
                    )
                    newRuleBundleID = nil
                    newRuleModeID = nil
                } label: {
                    Text("Add rule", comment: "Add app rule button")
                }
                .disabled(newRuleBundleID == nil || newRuleModeID == nil)
            }
        } header: {
            Text("Automatic modes per app", comment: "Settings section header")
        } footer: {
            Text("When you dictate into one of these apps, Vara switches to that mode automatically — e.g. VibeCode in your editor and Professional in Mail. A 1–9 press still wins. The app list shows currently running apps.", comment: "App rules footer")
        }
    }
}
