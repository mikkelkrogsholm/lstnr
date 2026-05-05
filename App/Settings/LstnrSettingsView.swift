import Security
import SwiftUI

extension Notification.Name {
    static let lstnrCredentialsDidChange = Notification.Name("dk.56n.lstnr.credentialsDidChange")
}

struct LstnrSettingsView: View {
    @State private var draft: LstnrSettingsDraft
    @State private var selectedSection: LstnrSettingsSection = .dictation
    @State private var elevenLabsAPIKey: String = ""
    @State private var credentialStatus: String?
    private let store: LstnrSettingsStore?
    private let credentialStore: LstnrCredentialStoring?

    init(
        draft: LstnrSettingsDraft? = nil,
        store: LstnrSettingsStore? = LstnrSettingsStore(),
        credentialStore: LstnrCredentialStoring? = LstnrKeychainCredentialStore()
    ) {
        self.store = store
        self.credentialStore = credentialStore
        let initialDraft = draft ?? store?.load().draft ?? .preview
        _draft = State(initialValue: initialDraft)
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
                case .providers:
                    providersSection
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
        .onChange(of: draft) { _, newDraft in
            try? store?.save(LstnrAppSettings(draft: newDraft))
        }
        .onAppear {
            loadCredentials()
        }
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
            Text("Preferences are saved locally and are not wired into dictation runtime behavior yet.")
        }
    }

    private var providersSection: some View {
        Section {
            SecureField("API key", text: $elevenLabsAPIKey)
                .textContentType(.password)

            HStack {
                Button("Save Key") {
                    saveElevenLabsAPIKey()
                }

                Button("Remove Key") {
                    deleteElevenLabsAPIKey()
                }
                .disabled(elevenLabsAPIKey.isEmpty)

                Spacer()

                if let credentialStatus {
                    Text(credentialStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("ElevenLabs")
        } footer: {
            Text("Keys are stored in Keychain. If no key is saved here, lstnr falls back to ELEVENLABS_API_KEY from the environment for development.")
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

    private func loadCredentials() {
        do {
            elevenLabsAPIKey = try credentialStore?.credential(for: .elevenLabs) ?? ""
            credentialStatus = elevenLabsAPIKey.isEmpty ? "No saved key" : "Saved in Keychain"
        } catch {
            credentialStatus = "Keychain read failed"
        }
    }

    private func saveElevenLabsAPIKey() {
        let trimmedKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try credentialStore?.saveCredential(trimmedKey, for: .elevenLabs)
            elevenLabsAPIKey = trimmedKey
            credentialStatus = trimmedKey.isEmpty ? "Removed" : "Saved"
            NotificationCenter.default.post(name: .lstnrCredentialsDidChange, object: nil)
        } catch {
            credentialStatus = "Save failed"
        }
    }

    private func deleteElevenLabsAPIKey() {
        do {
            try credentialStore?.deleteCredential(for: .elevenLabs)
            elevenLabsAPIKey = ""
            credentialStatus = "Removed"
            NotificationCenter.default.post(name: .lstnrCredentialsDidChange, object: nil)
        } catch {
            credentialStatus = "Remove failed"
        }
    }
}

struct LstnrAppSettings: Codable, Hashable {
    var shortcut: LstnrShortcutChoice
    var language: LstnrLanguageChoice
    var pasteAutomatically: Bool
    var showHUD: Bool
    var inputDevice: LstnrInputDeviceChoice
    var inputGain: Double
    var reduceNoise: Bool
    var keepRecentTranscript: Bool

    static let defaults = LstnrAppSettings(
        shortcut: .rightOption,
        language: .automatic,
        pasteAutomatically: true,
        showHUD: true,
        inputDevice: .previewDevices[0],
        inputGain: 0.72,
        reduceNoise: true,
        keepRecentTranscript: true
    )

    init(
        shortcut: LstnrShortcutChoice,
        language: LstnrLanguageChoice,
        pasteAutomatically: Bool,
        showHUD: Bool,
        inputDevice: LstnrInputDeviceChoice,
        inputGain: Double,
        reduceNoise: Bool,
        keepRecentTranscript: Bool
    ) {
        self.shortcut = shortcut
        self.language = language
        self.pasteAutomatically = pasteAutomatically
        self.showHUD = showHUD
        self.inputDevice = inputDevice
        self.inputGain = inputGain
        self.reduceNoise = reduceNoise
        self.keepRecentTranscript = keepRecentTranscript
    }

    init(draft: LstnrSettingsDraft) {
        self.init(
            shortcut: draft.shortcut,
            language: draft.language,
            pasteAutomatically: draft.pasteAutomatically,
            showHUD: draft.showHUD,
            inputDevice: draft.inputDevice,
            inputGain: draft.inputGain,
            reduceNoise: draft.reduceNoise,
            keepRecentTranscript: draft.keepRecentTranscript
        )
    }

    var draft: LstnrSettingsDraft {
        LstnrSettingsDraft(
            shortcut: shortcut,
            language: language,
            pasteAutomatically: pasteAutomatically,
            showHUD: showHUD,
            inputDevice: inputDevice,
            inputGain: min(max(inputGain, 0), 1),
            reduceNoise: reduceNoise,
            keepRecentTranscript: keepRecentTranscript
        )
    }
}

final class LstnrSettingsStore {
    private let defaults: UserDefaults
    private let key: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = "dk.56n.lstnr.settings.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> LstnrAppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }

        return (try? decoder.decode(LstnrAppSettings.self, from: data)) ?? .defaults
    }

    func save(_ settings: LstnrAppSettings) throws {
        let data = try encoder.encode(settings)
        defaults.set(data, forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }
}

enum LstnrCredentialProvider: String, CaseIterable, Identifiable {
    case elevenLabs

    var id: String { rawValue }

    var keychainAccount: String {
        switch self {
        case .elevenLabs: "elevenlabs.api-key"
        }
    }
}

protocol LstnrCredentialStoring {
    func credential(for provider: LstnrCredentialProvider) throws -> String?
    func saveCredential(_ credential: String, for provider: LstnrCredentialProvider) throws
    func deleteCredential(for provider: LstnrCredentialProvider) throws
}

struct LstnrKeychainCredentialStore: LstnrCredentialStoring {
    var service: String

    init(service: String = Bundle.main.bundleIdentifier.map { "\($0).credentials" } ?? "dk.56n.lstnr.credentials") {
        self.service = service
    }

    func credential(for provider: LstnrCredentialProvider) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw LstnrKeychainError.unhandledStatus(status)
        }

        guard let data = item as? Data else {
            throw LstnrKeychainError.invalidData
        }

        return String(data: data, encoding: .utf8)
    }

    func saveCredential(_ credential: String, for provider: LstnrCredentialProvider) throws {
        guard !credential.isEmpty else {
            try deleteCredential(for: provider)
            return
        }

        let data = Data(credential.utf8)
        let query = baseQuery(for: provider)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw LstnrKeychainError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw LstnrKeychainError.unhandledStatus(addStatus)
        }
    }

    func deleteCredential(for provider: LstnrCredentialProvider) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LstnrKeychainError.unhandledStatus(status)
        }
    }

    private func baseQuery(for provider: LstnrCredentialProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainAccount
        ]
    }
}

enum LstnrKeychainError: Error, Equatable {
    case invalidData
    case unhandledStatus(OSStatus)
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

    static let preview = LstnrAppSettings.defaults.draft
}

enum LstnrSettingsSection: String, CaseIterable, Identifiable {
    case dictation
    case providers
    case audio
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .providers: "Providers"
        case .audio: "Audio"
        case .privacy: "Privacy"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: "text.bubble"
        case .providers: "key"
        case .audio: "waveform"
        case .privacy: "lock"
        }
    }
}

enum LstnrShortcutChoice: String, CaseIterable, Codable, Identifiable {
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

enum LstnrLanguageChoice: String, CaseIterable, Codable, Identifiable {
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

struct LstnrInputDeviceChoice: Codable, Hashable, Identifiable {
    let id: String
    let name: String

    static let previewDevices = [
        LstnrInputDeviceChoice(id: "default", name: "System Default"),
        LstnrInputDeviceChoice(id: "studio-display", name: "Studio Display Microphone"),
        LstnrInputDeviceChoice(id: "airpods", name: "AirPods Pro")
    ]
}

#Preview("Settings") {
    LstnrSettingsView(draft: .preview, store: nil)
}
