import AppKit
import LstnrCore
import Security
import SwiftUI

extension Notification.Name {
    static let lstnrCredentialsDidChange = Notification.Name("dk.56n.lstnr.credentialsDidChange")
    static let lstnrSettingsDidChange = Notification.Name("dk.56n.lstnr.settingsDidChange")
}

struct LstnrSettingsView: View {
    @State private var draft: LstnrSettingsDraft
    @State private var selectedSection: LstnrSettingsSection = .dictation
    @State private var elevenLabsAPIKey: String = ""
    @State private var elevenLabsCredentialStatus: String?
    @State private var groqAPIKey: String = ""
    @State private var groqCredentialStatus: String?
    @State private var accessibilityGranted = false
    @State private var localHviskeStatus = LocalHviskeBackend.runtimeStatus()
    @State private var localHviskeInstallStatus: String?
    @State private var isInstallingLocalHviske = false
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
            guard let store else { return }
            try? store.save(LstnrAppSettings(draft: newDraft))
            NotificationCenter.default.post(name: .lstnrSettingsDidChange, object: nil)
        }
        .onAppear {
            loadCredentials()
            refreshAccessibility(prompt: false)
            refreshLocalHviskeStatus()
        }
    }

    private var dictationSection: some View {
        Section {
            Picker("Shortcut", selection: $draft.shortcut) {
                ForEach(LstnrShortcutChoice.allCases) { shortcut in
                    Text(shortcut.title).tag(shortcut)
                }
            }

            ShortcutRecorderButton(shortcut: $draft.shortcut) {
                refreshAccessibility(prompt: false)
            }

            shortcutAccessRow

            Picker("Language", selection: $draft.language) {
                ForEach(LstnrLanguageChoice.allCases) { language in
                    Text(language.title).tag(language)
                }
            }

            Picker("Backend", selection: $draft.speechBackend) {
                ForEach(LstnrSpeechBackendChoice.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }

            Picker("Cleanup", selection: $draft.cleanupMode) {
                ForEach(LstnrCleanupModeChoice.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Toggle("Paste transcript automatically", isOn: $draft.pasteAutomatically)
            Toggle("Show floating recording HUD", isOn: $draft.showHUD)
        } header: {
            Text("Dictation")
        } footer: {
            Text("Raw mode inserts the direct transcript. Clean mode lightly tidies spacing and punctuation before insertion.")
        }
    }

    private var providersSection: some View {
        Group {
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

                    if let elevenLabsCredentialStatus {
                        Text(elevenLabsCredentialStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("ElevenLabs")
            } footer: {
                Text("Keys are stored in Keychain. If no key is saved here, lstnr falls back to ELEVENLABS_API_KEY from the environment for development.")
            }

            Section {
                SecureField("API key", text: $groqAPIKey)
                    .textContentType(.password)

                HStack {
                    Button("Save Key") {
                        saveGroqAPIKey()
                    }

                    Button("Remove Key") {
                        deleteGroqAPIKey()
                    }
                    .disabled(groqAPIKey.isEmpty)

                    Spacer()

                    if let groqCredentialStatus {
                        Text(groqCredentialStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Groq")
            } footer: {
                Text("Keys are stored in Keychain. If no key is saved here, lstnr falls back to GROQ_API_KEY from the environment for development.")
            }

            Section {
                LabeledContent("Runtime") {
                    Label(
                        localHviskeStatus.hasPythonRuntime ? "Installed" : "Not installed",
                        systemImage: localHviskeStatus.hasPythonRuntime ? "checkmark.circle" : "arrow.down.circle"
                    )
                    .foregroundStyle(localHviskeStatus.hasPythonRuntime ? .green : .secondary)
                }

                LabeledContent("Model") {
                    Label(
                        localHviskeStatus.hasModelSnapshot ? "Downloaded" : "Not downloaded",
                        systemImage: localHviskeStatus.hasModelSnapshot ? "checkmark.circle" : "arrow.down.circle"
                    )
                    .foregroundStyle(localHviskeStatus.hasModelSnapshot ? .green : .secondary)
                }

                LabeledContent("Cache") {
                    Text(localHviskeStatus.hfHomeURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(localHviskeStatus.isReady ? "Reinstall Local Hviske" : "Install Local Hviske") {
                        installLocalHviske()
                    }
                    .disabled(isInstallingLocalHviske)

                    Button("Refresh") {
                        refreshLocalHviskeStatus()
                    }
                    .disabled(isInstallingLocalHviske)

                    Spacer()

                    if isInstallingLocalHviske {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let localHviskeInstallStatus {
                        Text(localHviskeInstallStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Local Hviske")
            } footer: {
                Text("Hviske runs locally on this Mac. The model is non-commercial only under CC BY-NC 4.0; use it only when your use complies with the model license.")
            }
        }
    }

    private var audioSection: some View {
        Section {
            LabeledContent("Input device") {
                Text("macOS System Default")
                    .foregroundStyle(.secondary)
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
            Text("The MVP records from macOS' default input device. Change the microphone in System Settings → Sound → Input.")
        }
    }

    private var privacySection: some View {
        Section {
            Toggle("Keep recent transcript visible in menu bar", isOn: $draft.keepRecentTranscript)

            Stepper(value: $draft.historyLimit, in: 10...200, step: 10) {
                LabeledContent("History limit") {
                    Text("\(draft.historyLimit) items")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Processing") {
                Text(draft.speechBackend.processingTitle)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Clipboard") {
                Text(draft.pasteAutomatically ? "Temporarily used for paste" : "Not used automatically")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("History is stored locally on this Mac. API keys are stored in Keychain.")
        }
    }

    private func loadCredentials() {
        do {
            elevenLabsAPIKey = try credentialStore?.credential(for: .elevenLabs) ?? ""
            elevenLabsCredentialStatus = elevenLabsAPIKey.isEmpty ? "No saved key" : "Saved in Keychain"
        } catch {
            elevenLabsCredentialStatus = "Keychain read failed"
        }

        do {
            groqAPIKey = try credentialStore?.credential(for: .groq) ?? ""
            groqCredentialStatus = groqAPIKey.isEmpty ? "No saved key" : "Saved in Keychain"
        } catch {
            groqCredentialStatus = "Keychain read failed"
        }
    }

    private func saveElevenLabsAPIKey() {
        let trimmedKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try credentialStore?.saveCredential(trimmedKey, for: .elevenLabs)
            elevenLabsAPIKey = trimmedKey
            elevenLabsCredentialStatus = trimmedKey.isEmpty ? "Removed" : "Saved"
            NotificationCenter.default.post(name: .lstnrCredentialsDidChange, object: nil)
        } catch {
            elevenLabsCredentialStatus = "Save failed"
        }
    }

    private func deleteElevenLabsAPIKey() {
        do {
            try credentialStore?.deleteCredential(for: .elevenLabs)
            elevenLabsAPIKey = ""
            elevenLabsCredentialStatus = "Removed"
            NotificationCenter.default.post(name: .lstnrCredentialsDidChange, object: nil)
        } catch {
            elevenLabsCredentialStatus = "Remove failed"
        }
    }

    private func saveGroqAPIKey() {
        let trimmedKey = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try credentialStore?.saveCredential(trimmedKey, for: .groq)
            groqAPIKey = trimmedKey
            groqCredentialStatus = trimmedKey.isEmpty ? "Removed" : "Saved"
            NotificationCenter.default.post(name: .lstnrCredentialsDidChange, object: nil)
        } catch {
            groqCredentialStatus = "Save failed"
        }
    }

    private func deleteGroqAPIKey() {
        do {
            try credentialStore?.deleteCredential(for: .groq)
            groqAPIKey = ""
            groqCredentialStatus = "Removed"
            NotificationCenter.default.post(name: .lstnrCredentialsDidChange, object: nil)
        } catch {
            groqCredentialStatus = "Remove failed"
        }
    }

    private var shortcutAccessRow: some View {
        HStack {
            LabeledContent("Global hotkey access") {
                Label(accessibilityGranted ? "Ready" : "Needs Accessibility", systemImage: accessibilityGranted ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(accessibilityGranted ? .green : .orange)
            }

            Spacer()

            Button(accessibilityGranted ? "Check Again" : "Open Accessibility") {
                refreshAccessibility(prompt: true)
            }
        }
    }

    private func refreshAccessibility(prompt: Bool) {
        accessibilityGranted = GlobalHotkey.hasAccessibility(prompt: prompt)
        if accessibilityGranted {
            NotificationCenter.default.post(name: .lstnrSettingsDidChange, object: nil)
        }
    }

    private func refreshLocalHviskeStatus() {
        localHviskeStatus = LocalHviskeBackend.runtimeStatus()
    }

    private func installLocalHviske() {
        isInstallingLocalHviske = true
        localHviskeInstallStatus = "Starting install"

        Task {
            do {
                try await LocalHviskeBackend.installManagedRuntime { message in
                    await MainActor.run {
                        localHviskeInstallStatus = message
                    }
                }
                await MainActor.run {
                    isInstallingLocalHviske = false
                    localHviskeInstallStatus = "Ready"
                    refreshLocalHviskeStatus()
                    NotificationCenter.default.post(name: .lstnrSettingsDidChange, object: nil)
                }
            } catch {
                await MainActor.run {
                    isInstallingLocalHviske = false
                    localHviskeInstallStatus = String(describing: error)
                    refreshLocalHviskeStatus()
                }
            }
        }
    }
}

struct LstnrAppSettings: Codable, Hashable {
    var shortcut: LstnrShortcutChoice
    var language: LstnrLanguageChoice
    var speechBackend: LstnrSpeechBackendChoice
    var cleanupMode: LstnrCleanupModeChoice
    var pasteAutomatically: Bool
    var showHUD: Bool
    var inputDevice: LstnrInputDeviceChoice
    var inputGain: Double
    var reduceNoise: Bool
    var keepRecentTranscript: Bool
    var historyLimit: Int

    static let defaults = LstnrAppSettings(
        shortcut: .rightCommand,
        language: .automatic,
        speechBackend: .elevenLabsScribe,
        cleanupMode: .raw,
        pasteAutomatically: true,
        showHUD: true,
        inputDevice: .previewDevices[0],
        inputGain: 0.72,
        reduceNoise: true,
        keepRecentTranscript: true,
        historyLimit: 100
    )

    init(
        shortcut: LstnrShortcutChoice,
        language: LstnrLanguageChoice,
        speechBackend: LstnrSpeechBackendChoice,
        cleanupMode: LstnrCleanupModeChoice,
        pasteAutomatically: Bool,
        showHUD: Bool,
        inputDevice: LstnrInputDeviceChoice,
        inputGain: Double,
        reduceNoise: Bool,
        keepRecentTranscript: Bool,
        historyLimit: Int
    ) {
        self.shortcut = shortcut
        self.language = language
        self.speechBackend = speechBackend
        self.cleanupMode = cleanupMode
        self.pasteAutomatically = pasteAutomatically
        self.showHUD = showHUD
        self.inputDevice = inputDevice
        self.inputGain = inputGain
        self.reduceNoise = reduceNoise
        self.keepRecentTranscript = keepRecentTranscript
        self.historyLimit = historyLimit
    }

    init(draft: LstnrSettingsDraft) {
        self.init(
            shortcut: draft.shortcut,
            language: draft.language,
            speechBackend: draft.speechBackend,
            cleanupMode: draft.cleanupMode,
            pasteAutomatically: draft.pasteAutomatically,
            showHUD: draft.showHUD,
            inputDevice: draft.inputDevice,
            inputGain: draft.inputGain,
            reduceNoise: draft.reduceNoise,
            keepRecentTranscript: draft.keepRecentTranscript,
            historyLimit: draft.historyLimit
        )
    }

    var draft: LstnrSettingsDraft {
        LstnrSettingsDraft(
            shortcut: shortcut,
            language: language,
            speechBackend: speechBackend,
            cleanupMode: cleanupMode,
            pasteAutomatically: pasteAutomatically,
            showHUD: showHUD,
            inputDevice: inputDevice,
            inputGain: min(max(inputGain, 0), 1),
            reduceNoise: reduceNoise,
            keepRecentTranscript: keepRecentTranscript,
            historyLimit: min(max(historyLimit, 10), 200)
        )
    }

    enum CodingKeys: String, CodingKey {
        case shortcut
        case language
        case speechBackend
        case cleanupMode
        case pasteAutomatically
        case showHUD
        case inputDevice
        case inputGain
        case reduceNoise
        case keepRecentTranscript
        case historyLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            shortcut: try container.decodeIfPresent(LstnrShortcutChoice.self, forKey: .shortcut) ?? Self.defaults.shortcut,
            language: try container.decodeIfPresent(LstnrLanguageChoice.self, forKey: .language) ?? Self.defaults.language,
            speechBackend: try container.decodeIfPresent(LstnrSpeechBackendChoice.self, forKey: .speechBackend) ?? Self.defaults.speechBackend,
            cleanupMode: try container.decodeIfPresent(LstnrCleanupModeChoice.self, forKey: .cleanupMode) ?? Self.defaults.cleanupMode,
            pasteAutomatically: try container.decodeIfPresent(Bool.self, forKey: .pasteAutomatically) ?? Self.defaults.pasteAutomatically,
            showHUD: try container.decodeIfPresent(Bool.self, forKey: .showHUD) ?? Self.defaults.showHUD,
            inputDevice: try container.decodeIfPresent(LstnrInputDeviceChoice.self, forKey: .inputDevice) ?? Self.defaults.inputDevice,
            inputGain: try container.decodeIfPresent(Double.self, forKey: .inputGain) ?? Self.defaults.inputGain,
            reduceNoise: try container.decodeIfPresent(Bool.self, forKey: .reduceNoise) ?? Self.defaults.reduceNoise,
            keepRecentTranscript: try container.decodeIfPresent(Bool.self, forKey: .keepRecentTranscript) ?? Self.defaults.keepRecentTranscript,
            historyLimit: try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? Self.defaults.historyLimit
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
    case groq

    var id: String { rawValue }

    var keychainAccount: String {
        switch self {
        case .elevenLabs: "elevenlabs.api-key"
        case .groq: "groq.api-key"
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
    var speechBackend: LstnrSpeechBackendChoice
    var cleanupMode: LstnrCleanupModeChoice
    var pasteAutomatically: Bool
    var showHUD: Bool
    var inputDevice: LstnrInputDeviceChoice
    var inputGain: Double
    var reduceNoise: Bool
    var keepRecentTranscript: Bool
    var historyLimit: Int

    static let preview = LstnrAppSettings.defaults.draft
}

enum LstnrSpeechBackendChoice: String, CaseIterable, Codable, Identifiable {
    case elevenLabsScribe
    case groqWhisper
    case localHviske

    var id: String { rawValue }

    var title: String {
        switch self {
        case .elevenLabsScribe: "ElevenLabs Scribe"
        case .groqWhisper: "Groq Whisper Large v3"
        case .localHviske: "Local Hviske v5.3"
        }
    }

    var processingTitle: String {
        switch self {
        case .elevenLabsScribe: "Realtime network transcription"
        case .groqWhisper: "Network file transcription via Groq"
        case .localHviske: "Local transcription on this Mac"
        }
    }
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
    case rightCommand
    case leftCommand
    case rightOption
    case leftOption
    case functionKey
    case leftCommandLeftOption
    case leftCommandRightOption
    case rightCommandLeftOption
    case rightCommandRightOption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightCommand: "Right Command"
        case .leftCommand: "Left Command"
        case .rightOption: "Right Option"
        case .leftOption: "Left Option"
        case .functionKey: "Function key (best effort)"
        case .leftCommandLeftOption: "Left Command + Left Option"
        case .leftCommandRightOption: "Left Command + Right Option"
        case .rightCommandLeftOption: "Right Command + Left Option"
        case .rightCommandRightOption: "Right Command + Right Option"
        }
    }

    var symbol: String {
        switch self {
        case .rightCommand, .leftCommand: "⌘"
        case .rightOption, .leftOption: "⌥"
        case .functionKey: "fn"
        case .leftCommandLeftOption,
             .leftCommandRightOption,
             .rightCommandLeftOption,
             .rightCommandRightOption:
            "⌘⌥"
        }
    }

    var globalHotkeyShortcut: GlobalHotkey.Shortcut {
        GlobalHotkey.Shortcut(keys: shortcutKeys)
    }

    static let recordableKeys: Set<GlobalHotkey.Key> = [
        .leftCommand,
        .rightCommand,
        .leftOption,
        .rightOption,
        .function
    ]

    init?(keys: Set<GlobalHotkey.Key>) {
        switch keys {
        case Set<GlobalHotkey.Key>([.rightCommand]):
            self = .rightCommand
        case Set<GlobalHotkey.Key>([.leftCommand]):
            self = .leftCommand
        case Set<GlobalHotkey.Key>([.rightOption]):
            self = .rightOption
        case Set<GlobalHotkey.Key>([.leftOption]):
            self = .leftOption
        case Set<GlobalHotkey.Key>([.function]):
            self = .functionKey
        case Set<GlobalHotkey.Key>([.leftCommand, .leftOption]):
            self = .leftCommandLeftOption
        case Set<GlobalHotkey.Key>([.leftCommand, .rightOption]):
            self = .leftCommandRightOption
        case Set<GlobalHotkey.Key>([.rightCommand, .leftOption]):
            self = .rightCommandLeftOption
        case Set<GlobalHotkey.Key>([.rightCommand, .rightOption]):
            self = .rightCommandRightOption
        default:
            return nil
        }
    }

    private var shortcutKeys: Set<GlobalHotkey.Key> {
        switch self {
        case .rightCommand:
            [.rightCommand]
        case .leftCommand:
            [.leftCommand]
        case .rightOption:
            [.rightOption]
        case .leftOption:
            [.leftOption]
        case .functionKey:
            [.function]
        case .leftCommandLeftOption:
            [.leftCommand, .leftOption]
        case .leftCommandRightOption:
            [.leftCommand, .rightOption]
        case .rightCommandLeftOption:
            [.rightCommand, .leftOption]
        case .rightCommandRightOption:
            [.rightCommand, .rightOption]
        }
    }
}

private struct ShortcutRecorderButton: View {
    @Binding var shortcut: LstnrShortcutChoice
    var onRecorded: () -> Void
    @State private var activeKeys: Set<GlobalHotkey.Key> = []
    @State private var capturedKeys: Set<GlobalHotkey.Key> = []
    @State private var eventMonitor: Any?
    @State private var isRecording = false
    @State private var status: String = "Press record, then press and release a shortcut."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LabeledContent("Recorded shortcut") {
                    Text(shortcut.title)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(isRecording ? "Cancel" : "Record Shortcut") {
                    if isRecording {
                        stopRecording(status: "Recording cancelled.")
                    } else {
                        startRecording()
                    }
                }
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(isRecording ? .primary : .secondary)
        }
        .onDisappear {
            stopRecording(status: status)
        }
    }

    private var statusText: String {
        if isRecording, !capturedKeys.isEmpty {
            return "Recording \(Self.title(for: capturedKeys)). Release all keys to save."
        }
        if isRecording {
            return "Press a modifier key, or Command + Option together."
        }
        return status
    }

    private func startRecording() {
        removeEventMonitor()
        activeKeys = []
        capturedKeys = []
        status = "Press a modifier key, or Command + Option together."
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            record(event: event)
            return nil
        }
    }

    private func record(event: NSEvent) {
        guard isRecording else { return }
        guard let key = GlobalHotkey.Key(rawValue: UInt16(event.keyCode)) else { return }
        guard LstnrShortcutChoice.recordableKeys.contains(key) else { return }

        if activeKeys.contains(key) {
            activeKeys.remove(key)
        } else {
            activeKeys.insert(key)
        }
        capturedKeys.insert(key)
        capturedKeys.formUnion(activeKeys)

        guard activeKeys.isEmpty else { return }
        guard let recordedShortcut = LstnrShortcutChoice(keys: capturedKeys) else {
            stopRecording(status: "Unsupported shortcut: \(Self.title(for: capturedKeys)).")
            return
        }

        shortcut = recordedShortcut
        stopRecording(status: "Recorded \(recordedShortcut.title).")
        onRecorded()
    }

    private func stopRecording(status newStatus: String) {
        removeEventMonitor()
        activeKeys = []
        capturedKeys = []
        isRecording = false
        status = newStatus
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    private static func title(for keys: Set<GlobalHotkey.Key>) -> String {
        keys.sorted { $0.sortOrder < $1.sortOrder }
            .map(\.displayTitle)
            .joined(separator: " + ")
    }
}

private extension GlobalHotkey.Key {
    var displayTitle: String {
        switch self {
        case .leftCommand: "Left Command"
        case .rightCommand: "Right Command"
        case .leftOption: "Left Option"
        case .rightOption: "Right Option"
        case .rightControl: "Right Control"
        case .function: "Function key"
        }
    }

    var sortOrder: Int {
        switch self {
        case .leftCommand: 10
        case .rightCommand: 11
        case .leftOption: 20
        case .rightOption: 21
        case .rightControl: 30
        case .function: 40
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

enum LstnrCleanupModeChoice: String, CaseIterable, Codable, Identifiable {
    case raw
    case clean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw: "Raw"
        case .clean: "Clean"
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
