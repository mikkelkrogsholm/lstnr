import SwiftUI

struct LstnrSettingsView: View {
    @State private var draft: LstnrSettingsDraft
    @State private var selectedSection: LstnrSettingsSection = .dictation

    init(draft: LstnrSettingsDraft = .preview) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationSplitView {
            List(LstnrSettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Form {
                switch selectedSection {
                case .dictation:
                    dictationSection
                case .audio:
                    audioSection
                case .privacy:
                    privacySection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.vertical, 10)
            .navigationTitle(selectedSection.title)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 420, idealHeight: 460)
    }

    private var dictationSection: some View {
        Section {
            Picker("Shortcut", selection: $draft.shortcut) {
                ForEach(LstnrShortcutChoice.allCases) { shortcut in
                    Text(shortcut.title).tag(shortcut)
                }
            }

            Picker("Language", selection: $draft.language) {
                ForEach(LstnrLanguageChoice.allCases) { language in
                    Text(language.title).tag(language)
                }
            }

            Toggle("Paste transcript automatically", isOn: $draft.pasteAutomatically)
            Toggle("Show floating recording HUD", isOn: $draft.showHUD)
        } header: {
            Text("Dictation")
        } footer: {
            Text("These settings are placeholder UI state until the native preferences model is wired.")
        }
    }

    private var audioSection: some View {
        Section {
            Picker("Input device", selection: $draft.inputDevice) {
                ForEach(LstnrInputDeviceChoice.previewDevices) { device in
                    Text(device.name).tag(device)
                }
            }

            HStack {
                Slider(value: $draft.inputGain, in: 0...1)
                Text(draft.inputGain.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Toggle("Reduce background noise", isOn: $draft.reduceNoise)
        } header: {
            Text("Audio")
        } footer: {
            Text("Device names are sample values and do not query the audio backend.")
        }
    }

    private var privacySection: some View {
        Section {
            Toggle("Keep recent transcript visible in menu bar", isOn: $draft.keepRecentTranscript)

            LabeledContent("Processing") {
                Text("Realtime transcription service")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Clipboard") {
                Text(draft.pasteAutomatically ? "Temporarily used for paste" : "Not used automatically")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Privacy copy is intentionally descriptive only; backend behavior remains unchanged.")
        }
    }
}

struct LstnrSettingsDraft: Hashable {
    var shortcut: LstnrShortcutChoice
    var language: LstnrLanguageChoice
    var pasteAutomatically: Bool
    var showHUD: Bool
    var inputDevice: LstnrInputDeviceChoice
    var inputGain: Double
    var reduceNoise: Bool
    var keepRecentTranscript: Bool

    static let preview = LstnrSettingsDraft(
        shortcut: .rightOption,
        language: .automatic,
        pasteAutomatically: true,
        showHUD: true,
        inputDevice: .previewDevices[0],
        inputGain: 0.72,
        reduceNoise: true,
        keepRecentTranscript: true
    )
}

enum LstnrSettingsSection: String, CaseIterable, Identifiable {
    case dictation
    case audio
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .audio: "Audio"
        case .privacy: "Privacy"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: "text.bubble"
        case .audio: "waveform"
        case .privacy: "lock"
        }
    }
}

enum LstnrShortcutChoice: String, CaseIterable, Identifiable {
    case rightOption
    case leftOption
    case functionKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: "Right Option"
        case .leftOption: "Left Option"
        case .functionKey: "Function key"
        }
    }
}

enum LstnrLanguageChoice: String, CaseIterable, Identifiable {
    case automatic
    case danish
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .danish: "Danish"
        case .english: "English"
        }
    }
}

struct LstnrInputDeviceChoice: Hashable, Identifiable {
    let id: String
    let name: String

    static let previewDevices = [
        LstnrInputDeviceChoice(id: "default", name: "System Default"),
        LstnrInputDeviceChoice(id: "studio-display", name: "Studio Display Microphone"),
        LstnrInputDeviceChoice(id: "airpods", name: "AirPods Pro")
    ]
}

#Preview("Settings") {
    LstnrSettingsView()
}
