import AppKit
import LstnrCore
import Security
import ServiceManagement
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
    @State private var openAIAPIKey: String = ""
    @State private var openAICredentialStatus: String?
    @State private var anthropicAPIKey: String = ""
    @State private var anthropicCredentialStatus: String?
    @State private var accessibilityGranted = false
    @State private var localHviskeStatus = LocalHviskeBackend.runtimeStatus()
    @State private var localHviskeInstallStatus: String?
    @State private var isInstallingLocalHviske = false
    @State private var editingModeIndex: Int?
    @State private var isAddingEndpoint = false
    @State private var newEndpointName = ""
    @State private var newEndpointURL = ""
    @State private var newRuleBundleID: String?
    @State private var newRuleModeID: UUID?
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
                case .engine:
                    engineSection
                case .intelligence:
                    intelligenceSection
                case .privacy:
                    privacySection
                case .about:
                    aboutSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.vertical, 10)
            .navigationTitle(selectedSection.title)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 480, idealHeight: 560)
        .sheet(isPresented: Binding(
            get: { editingModeIndex != nil },
            set: { isPresented in if !isPresented { editingModeIndex = nil } }
        )) {
            if let index = editingModeIndex, draft.modes.indices.contains(index) {
                ModeEditorView(
                    mode: $draft.modes[index],
                    customEndpoints: draft.customEndpoints,
                    onDelete: draft.modes[index].isBuiltIn ? nil : {
                        draft.modes.remove(at: index)
                    }
                )
            }
        }
        .onChange(of: draft) { _, newDraft in
            guard let store else { return }
            try? store.save(LstnrAppSettings(draft: newDraft))
            NotificationCenter.default.post(name: .lstnrSettingsDidChange, object: nil)
        }
        .onAppear {
            loadCredentials()
            refreshAccessibility(prompt: false)
            refreshLocalHviskeStatus()
            if let pendingSection = SettingsDeepLink.consumePending() {
                selectedSection = pendingSection
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lstnrShowSettingsSection)) { _ in
            if let pendingSection = SettingsDeepLink.consumePending() {
                selectedSection = pendingSection
            }
        }
    }

    private var dictationSection: some View {
        Section {
            Picker(selection: $draft.shortcut) {
                ForEach(LstnrShortcutChoice.allCases) { shortcut in
                    Text(shortcut.title).tag(shortcut)
                }
            } label: {
                Text("Shortcut", comment: "Settings field")
            }

            ShortcutRecorderButton(shortcut: $draft.shortcut) {
                refreshAccessibility(prompt: false)
            }

            shortcutAccessRow

            Picker(selection: $draft.language) {
                ForEach(LstnrLanguageChoice.allCases) { language in
                    Text(language.title).tag(language)
                }
            } label: {
                Text("Language", comment: "Settings field")
            }

            Toggle(isOn: $draft.pasteAutomatically) {
                Text("Paste transcript automatically", comment: "Settings toggle")
            }
            Toggle(isOn: $draft.showHUD) {
                Text("Show floating HUD while dictating", comment: "Settings toggle")
            }
            Toggle(isOn: $draft.playSounds) {
                Text("Sound feedback when dictating", comment: "Settings toggle")
            }
            Toggle(isOn: launchAtLoginBinding) {
                Text("Start Vara at login", comment: "Settings toggle")
            }
        } header: {
            Text("Dictation", comment: "Settings section header")
        } footer: {
            Text("Vara records from macOS' default input device — change the microphone in System Settings → Sound. What happens to the text is decided by the selected mode.", comment: "Settings dictation footer")
        }
    }

    /// Launch-at-login is system state (SMAppService), not part of our
    /// settings model — read and written live.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            SMAppService.mainApp.status == .enabled
        } set: { enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Surfacing via the standard error row would be noise here;
                // the toggle simply snaps back on next render.
            }
        }
    }

    // MARK: Engine (speech-to-text)

    private var engineSection: some View {
        Group {
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(LstnrSpeechBackendChoice.allCases) { backend in
                        EngineCard(
                            backend: backend,
                            isSelected: draft.speechBackend == backend,
                            keyStatus: engineKeyStatus(for: backend)
                        ) {
                            draft.speechBackend = backend
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Speech engine", comment: "Settings section header")
            } footer: {
                Text("The engine turns your voice into raw text. Hviske runs entirely on this Mac (CC BY-NC 4.0 — non-commercial use only).", comment: "Engine section footer")
            }

            if let provider = draft.speechBackend.credentialProvider {
                apiKeySection(for: provider)
            }

            if draft.speechBackend == .localHviske {
                localHviskeSection
            }
        }
    }

    private func engineKeyStatus(for backend: LstnrSpeechBackendChoice) -> EngineCard.KeyStatus {
        guard let provider = backend.credentialProvider else { return .notNeeded }
        return hasKey(for: provider) ? .present : .missing
    }

    private func hasKey(for provider: LstnrCredentialProvider) -> Bool {
        let savedKey: String? = switch provider {
        case .elevenLabs: elevenLabsAPIKey
        case .groq: groqAPIKey
        case .openAI: openAIAPIKey
        case .anthropic: anthropicAPIKey
        }
        if let savedKey, !savedKey.isEmpty { return true }
        return (try? EnvLoader.resolveForApp(provider.environmentVariableName)).map { !$0.isEmpty } ?? false
    }

    @ViewBuilder
    private func apiKeySection(for provider: LstnrCredentialProvider) -> some View {
        Section {
            SecureField(text: keyBinding(for: provider)) {
                Text("API key", comment: "API key field label")
            }
            .textContentType(.password)

            HStack {
                Button {
                    saveKey(for: provider)
                } label: {
                    Text("Save key", comment: "Save API key button")
                }

                Button {
                    deleteKey(for: provider)
                } label: {
                    Text("Remove key", comment: "Remove API key button")
                }
                .disabled(keyBinding(for: provider).wrappedValue.isEmpty)

                Spacer()

                if let status = keyStatus(for: provider) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(verbatim: provider.displayTitle)
        } footer: {
            Text("Stored in Keychain. Without a saved key, Vara falls back to \(provider.environmentVariableName) from the environment.", comment: "API key section footer")
        }
    }

    private var localHviskeSection: some View {
        Section {
            LabeledContent {
                Label(
                    localHviskeStatus.hasPythonRuntime
                        ? String(localized: "Installed", comment: "Hviske runtime status")
                        : String(localized: "Not installed", comment: "Hviske runtime status"),
                    systemImage: localHviskeStatus.hasPythonRuntime ? "checkmark.circle" : "arrow.down.circle"
                )
                .foregroundStyle(localHviskeStatus.hasPythonRuntime ? .green : .secondary)
            } label: {
                Text("Runtime", comment: "Hviske status row label")
            }

            LabeledContent {
                Label(
                    localHviskeStatus.hasModelSnapshot
                        ? String(localized: "Downloaded", comment: "Hviske model status")
                        : String(localized: "Not downloaded", comment: "Hviske model status"),
                    systemImage: localHviskeStatus.hasModelSnapshot ? "checkmark.circle" : "arrow.down.circle"
                )
                .foregroundStyle(localHviskeStatus.hasModelSnapshot ? .green : .secondary)
            } label: {
                Text("Model", comment: "Hviske status row label")
            }

            HStack {
                Button {
                    installLocalHviske()
                } label: {
                    localHviskeStatus.isReady
                        ? Text("Reinstall Hviske", comment: "Hviske install button")
                        : Text("Install Hviske", comment: "Hviske install button")
                }
                .disabled(isInstallingLocalHviske)

                Button {
                    refreshLocalHviskeStatus()
                } label: {
                    Text("Refresh", comment: "Hviske refresh button")
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
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } header: {
            Text("Hviske on this Mac", comment: "Hviske section header")
        }
    }

    // MARK: Intelligence (LLM + modes)

    private var intelligenceSection: some View {
        Group {
            Section {
                LLMSelectionPicker(
                    selection: $draft.defaultLLM,
                    customEndpoints: draft.customEndpoints,
                    allowsDefault: false
                )

                if let provider = draft.defaultLLM?.provider {
                    switch provider {
                    case .openAI where !hasKey(for: .openAI),
                         .groq where !hasKey(for: .groq),
                         .anthropic where !hasKey(for: .anthropic):
                        Label {
                            Text("Missing API key — add it below.", comment: "Missing LLM key warning")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                    case .ollama:
                        Label {
                            Text("Runs against http://localhost:11434 — everything stays on this Mac.", comment: "Ollama info")
                        } icon: {
                            Image(systemName: "lock.fill")
                        }
                        .foregroundStyle(.green)
                    default:
                        EmptyView()
                    }
                }
            } header: {
                Text("Default model", comment: "Settings section header")
            } footer: {
                Text("Modes that rewrite or answer use this model unless they pin their own. Raw works without any model.", comment: "Default LLM footer")
            }

            if let provider = draft.defaultLLM?.provider, providerNeedsKeySection(provider) {
                apiKeySection(for: credentialProvider(for: provider)!)
            }

            Section {
                ForEach(Array(draft.modes.enumerated()), id: \.element.id) { index, mode in
                    Button {
                        editingModeIndex = index
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: mode.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(BSTheme.teal)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayTitle)
                                    .foregroundStyle(.primary)
                                Text(mode.displaySubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if mode.id == draft.selectedModeID {
                                Text("Active", comment: "Active mode badge in settings")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(BSTheme.teal.opacity(0.18), in: Capsule())
                                    .foregroundStyle(BSTheme.teal)
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    let newMode = DictationMode(
                        name: String(localized: "New mode", comment: "Default name for a created mode"),
                        symbolName: "star",
                        behavior: .rewrite,
                        systemPrompt: ""
                    )
                    draft.modes.append(newMode)
                    editingModeIndex = draft.modes.count - 1
                } label: {
                    Label {
                        Text("Add mode", comment: "Add mode button")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            } header: {
                Text("Modes", comment: "Settings section header")
            } footer: {
                Text("Press 1–9 while dictating to use a mode for a single dictation.", comment: "Modes section footer")
            }

            appRulesSection

            customEndpointsSection
        }
    }

    // MARK: Per-app mode rules

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

    private var appRulesSection: some View {
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

    private func providerNeedsKeySection(_ provider: LLMProvider) -> Bool {
        switch provider {
        case .openAI, .groq, .anthropic: true
        case .ollama, .custom: false
        }
    }

    private func credentialProvider(for provider: LLMProvider) -> LstnrCredentialProvider? {
        switch provider {
        case .openAI: .openAI
        case .groq: .groq
        case .anthropic: .anthropic
        case .ollama, .custom: nil
        }
    }

    private var customEndpointsSection: some View {
        Section {
            ForEach(draft.customEndpoints) { endpoint in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.name)
                        Text(endpoint.baseURLString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        draft.customEndpoints.removeAll { $0.id == endpoint.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if isAddingEndpoint {
                TextField(text: $newEndpointName, prompt: Text(verbatim: "DGX Spark")) {
                    Text("Name", comment: "Custom endpoint name field")
                }
                TextField(text: $newEndpointURL, prompt: Text(verbatim: "http://spark.local:11434/v1")) {
                    Text("Base URL", comment: "Custom endpoint URL field")
                }
                .autocorrectionDisabled()
                HStack {
                    Button {
                        let trimmedURL = newEndpointURL.trimmingCharacters(in: .whitespaces)
                        let trimmedName = newEndpointName.trimmingCharacters(in: .whitespaces)
                        guard !trimmedName.isEmpty, URL(string: trimmedURL) != nil else { return }
                        draft.customEndpoints.append(
                            CustomLLMEndpoint(name: trimmedName, baseURLString: trimmedURL)
                        )
                        newEndpointName = ""
                        newEndpointURL = ""
                        isAddingEndpoint = false
                    } label: {
                        Text("Add", comment: "Confirm adding custom endpoint")
                    }
                    Button {
                        isAddingEndpoint = false
                        newEndpointName = ""
                        newEndpointURL = ""
                    } label: {
                        Text("Cancel", comment: "Cancel adding custom endpoint")
                    }
                }
            } else {
                Button {
                    isAddingEndpoint = true
                } label: {
                    Label {
                        Text("Add OpenAI-compatible endpoint", comment: "Add custom endpoint button")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }
        } header: {
            Text("Custom endpoints", comment: "Settings section header")
        } footer: {
            Text("Any OpenAI-compatible server: Ollama on another machine, LM Studio, vLLM …", comment: "Custom endpoints footer")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle(isOn: $draft.keepRecentTranscript) {
                Text("Keep latest transcript visible in the menu bar", comment: "Settings toggle")
            }

            Stepper(value: $draft.historyLimit, in: 10...200, step: 10) {
                LabeledContent {
                    Text(verbatim: "\(draft.historyLimit)")
                } label: {
                    Text("History limit", comment: "Settings field")
                }
            }

            LabeledContent {
                Text(verbatim: draft.speechBackend.processingTitle)
            } label: {
                Text("Audio", comment: "Privacy row: where audio is processed")
            }

            LabeledContent {
                if let llm = draft.defaultLLM {
                    Text(verbatim: "\(llm.provider.displayTitle) · \(llm.model)")
                } else {
                    Text("No LLM configured", comment: "Privacy row value when no LLM is set")
                }
            } label: {
                Text("Text processing", comment: "Privacy row: where text is processed")
            }

            if draft.speechBackend.isLocal, draft.defaultLLM?.provider.runsLocally ?? false {
                Label {
                    Text("Everything runs on this Mac — nothing leaves the machine.", comment: "Fully local privacy badge")
                } icon: {
                    Image(systemName: "lock.shield.fill")
                }
                .foregroundStyle(.green)
            }
        } header: {
            Text("Privacy", comment: "Settings section header")
        } footer: {
            Text("History is stored locally on this Mac. API keys live in Keychain. The clipboard is briefly used for pasting and then restored.", comment: "Privacy footer")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            } label: {
                Text("Version", comment: "About row")
            }

            LabeledContent {
                Link("brokk-sindre.dk", destination: URL(string: "https://brokk-sindre.dk")!)
            } label: {
                Text("Forged by", comment: "About row")
            }

            Button {
                UserDefaults.standard.set(false, forKey: VaraOnboarding.completedDefaultsKey)
                NotificationCenter.default.post(name: .lstnrSettingsDidChange, object: nil)
            } label: {
                Text("Show welcome guide again", comment: "Reopen onboarding button")
            }
        } header: {
            Text(verbatim: "Vara")
        } footer: {
            Text("Vara is named after Vár — the goddess who hears oaths and promises.", comment: "About footer")
        }
    }

    private func loadCredentials() {
        for provider in LstnrCredentialProvider.allCases {
            do {
                let key = try credentialStore?.credential(for: provider) ?? ""
                keyBinding(for: provider).wrappedValue = key
                keyStatusBinding(for: provider).wrappedValue = key.isEmpty
                    ? String(localized: "No saved key", comment: "Key status")
                    : String(localized: "Saved in Keychain", comment: "Key status")
            } catch {
                keyStatusBinding(for: provider).wrappedValue = String(localized: "Keychain read failed", comment: "Key status")
            }
        }
    }

    private func keyBinding(for provider: LstnrCredentialProvider) -> Binding<String> {
        switch provider {
        case .elevenLabs: $elevenLabsAPIKey
        case .groq: $groqAPIKey
        case .openAI: $openAIAPIKey
        case .anthropic: $anthropicAPIKey
        }
    }

    private func keyStatusBinding(for provider: LstnrCredentialProvider) -> Binding<String?> {
        switch provider {
        case .elevenLabs: $elevenLabsCredentialStatus
        case .groq: $groqCredentialStatus
        case .openAI: $openAICredentialStatus
        case .anthropic: $anthropicCredentialStatus
        }
    }

    private func keyStatus(for provider: LstnrCredentialProvider) -> String? {
        keyStatusBinding(for: provider).wrappedValue
    }

    private func saveKey(for provider: LstnrCredentialProvider) {
        let binding = keyBinding(for: provider)
        let trimmedKey = binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try credentialStore?.saveCredential(trimmedKey, for: provider)
            binding.wrappedValue = trimmedKey
            keyStatusBinding(for: provider).wrappedValue = trimmedKey.isEmpty
                ? String(localized: "Removed", comment: "Key status")
                : String(localized: "Saved", comment: "Key status")
            NotificationCenter.default.post(name: .lstnrCredentialsDidChange, object: nil)
        } catch {
            keyStatusBinding(for: provider).wrappedValue = String(localized: "Save failed", comment: "Key status")
        }
    }

    private func deleteKey(for provider: LstnrCredentialProvider) {
        do {
            try credentialStore?.deleteCredential(for: provider)
            keyBinding(for: provider).wrappedValue = ""
            keyStatusBinding(for: provider).wrappedValue = String(localized: "Removed", comment: "Key status")
            NotificationCenter.default.post(name: .lstnrCredentialsDidChange, object: nil)
        } catch {
            keyStatusBinding(for: provider).wrappedValue = String(localized: "Remove failed", comment: "Key status")
        }
    }

    private var shortcutAccessRow: some View {
        HStack {
            LabeledContent(String(localized: "Global hotkey access", comment: "Settings label")) {
                Label(accessibilityGranted ? String(localized: "Ready", comment: "Accessibility status") : String(localized: "Needs Accessibility", comment: "Accessibility status"), systemImage: accessibilityGranted ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(accessibilityGranted ? .green : .orange)
            }

            Spacer()

            Button(accessibilityGranted ? String(localized: "Check again", comment: "Accessibility button") : String(localized: "Open Accessibility", comment: "Accessibility button")) {
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
    var modes: [DictationMode]
    var selectedModeID: UUID
    var defaultLLM: LLMSelection?
    var customEndpoints: [CustomLLMEndpoint]
    var appModeRules: [AppModeRule]
    var playSounds: Bool

    static let defaults = LstnrAppSettings(
        shortcut: .rightCommand,
        language: .automatic,
        speechBackend: .groqWhisper,
        cleanupMode: .raw,
        pasteAutomatically: true,
        showHUD: true,
        inputDevice: .previewDevices[0],
        inputGain: 0.72,
        reduceNoise: true,
        keepRecentTranscript: true,
        historyLimit: 100,
        modes: DictationMode.builtInModes(),
        selectedModeID: DictationMode.rawModeID,
        // Groq is the zero-cost default for BOTH layers: one free key from
        // console.groq.com unlocks Whisper (STT) and Llama 3.3 (cleanup).
        // Mode stays Raw until a key exists; onboarding upgrades to Clean text
        // once the LLM is configured.
        defaultLLM: LLMSelection(provider: .groq, model: "llama-3.3-70b-versatile"),
        customEndpoints: [],
        appModeRules: [],
        playSounds: true
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
        historyLimit: Int,
        modes: [DictationMode],
        selectedModeID: UUID,
        defaultLLM: LLMSelection?,
        customEndpoints: [CustomLLMEndpoint],
        appModeRules: [AppModeRule],
        playSounds: Bool
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
        self.modes = Self.withBuiltInModes(modes)
        self.selectedModeID = selectedModeID
        self.defaultLLM = defaultLLM
        self.customEndpoints = customEndpoints
        self.appModeRules = appModeRules
        self.playSounds = playSounds
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
            historyLimit: draft.historyLimit,
            modes: draft.modes,
            selectedModeID: draft.selectedModeID,
            defaultLLM: draft.defaultLLM,
            customEndpoints: draft.customEndpoints,
            appModeRules: draft.appModeRules,
            playSounds: draft.playSounds
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
            historyLimit: min(max(historyLimit, 10), 200),
            modes: modes,
            selectedModeID: selectedModeID,
            defaultLLM: defaultLLM,
            customEndpoints: customEndpoints,
            appModeRules: appModeRules,
            playSounds: playSounds
        )
    }

    /// The active mode; falls back to Raw if the selected ID disappeared.
    var selectedMode: DictationMode {
        modes.first { $0.id == selectedModeID }
            ?? modes.first { $0.id == DictationMode.rawModeID }
            ?? DictationMode.builtInModes()[0]
    }

    /// Ensures every built-in mode exists (re-adds ones missing after upgrades)
    /// while preserving user edits to built-ins and custom modes.
    private static func withBuiltInModes(_ modes: [DictationMode]) -> [DictationMode] {
        let existingIDs = Set(modes.map(\.id))
        let missingBuiltIns = DictationMode.builtInModes().filter { !existingIDs.contains($0.id) }
        return missingBuiltIns + modes
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
        case modes
        case selectedModeID
        case defaultLLM
        case customEndpoints
        case appModeRules
        case playSounds
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
            historyLimit: try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? Self.defaults.historyLimit,
            modes: try container.decodeIfPresent([DictationMode].self, forKey: .modes) ?? Self.defaults.modes,
            selectedModeID: try container.decodeIfPresent(UUID.self, forKey: .selectedModeID) ?? Self.defaults.selectedModeID,
            defaultLLM: try container.decodeIfPresent(LLMSelection.self, forKey: .defaultLLM) ?? Self.defaults.defaultLLM,
            customEndpoints: try container.decodeIfPresent([CustomLLMEndpoint].self, forKey: .customEndpoints) ?? Self.defaults.customEndpoints,
            appModeRules: try container.decodeIfPresent([AppModeRule].self, forKey: .appModeRules) ?? Self.defaults.appModeRules,
            playSounds: try container.decodeIfPresent(Bool.self, forKey: .playSounds) ?? Self.defaults.playSounds
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
    case openAI
    case anthropic

    var id: String { rawValue }

    var keychainAccount: String {
        switch self {
        case .elevenLabs: "elevenlabs.api-key"
        case .groq: "groq.api-key"
        case .openAI: "openai.api-key"
        case .anthropic: "anthropic.api-key"
        }
    }
}

protocol LstnrCredentialStoring {
    func credential(for provider: LstnrCredentialProvider) throws -> String?
    func saveCredential(_ credential: String, for provider: LstnrCredentialProvider) throws
    func deleteCredential(for provider: LstnrCredentialProvider) throws
    func credential(forCustomEndpoint id: UUID) throws -> String?
    func saveCredential(_ credential: String, forCustomEndpoint id: UUID) throws
}

struct LstnrKeychainCredentialStore: LstnrCredentialStoring {
    var service: String

    init(service: String = Bundle.main.bundleIdentifier.map { "\($0).credentials" } ?? "dk.56n.lstnr.credentials") {
        self.service = service
    }

    func credential(for provider: LstnrCredentialProvider) throws -> String? {
        try credential(account: provider.keychainAccount)
    }

    func saveCredential(_ credential: String, for provider: LstnrCredentialProvider) throws {
        try saveCredential(credential, account: provider.keychainAccount)
    }

    func deleteCredential(for provider: LstnrCredentialProvider) throws {
        try deleteCredential(account: provider.keychainAccount)
    }

    func credential(forCustomEndpoint id: UUID) throws -> String? {
        try credential(account: Self.customEndpointAccount(id))
    }

    func saveCredential(_ credential: String, forCustomEndpoint id: UUID) throws {
        try saveCredential(credential, account: Self.customEndpointAccount(id))
    }

    private static func customEndpointAccount(_ id: UUID) -> String {
        "custom-endpoint.\(id.uuidString).api-key"
    }

    private func credential(account: String) throws -> String? {
        var query = baseQuery(account: account)
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

    private func saveCredential(_ credential: String, account: String) throws {
        guard !credential.isEmpty else {
            try deleteCredential(account: account)
            return
        }

        let data = Data(credential.utf8)
        let query = baseQuery(account: account)
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

    private func deleteCredential(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LstnrKeychainError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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
    var modes: [DictationMode]
    var selectedModeID: UUID
    var defaultLLM: LLMSelection?
    var customEndpoints: [CustomLLMEndpoint]
    var appModeRules: [AppModeRule]
    var playSounds: Bool

    static let preview = LstnrAppSettings.defaults.draft
}

enum LstnrSpeechBackendChoice: String, CaseIterable, Codable, Identifiable {
    case elevenLabsScribe
    case groqWhisper
    case openAIRealtimeWhisper
    case openAIGPT4OTranscribe
    case openAIGPT4OMiniTranscribe20251215
    case localHviske

    var id: String { rawValue }

    var title: String {
        switch self {
        case .elevenLabsScribe: "ElevenLabs Scribe"
        case .groqWhisper: "Groq Whisper Large v3"
        case .openAIRealtimeWhisper: "OpenAI GPT Realtime Whisper"
        case .openAIGPT4OTranscribe: "OpenAI GPT-4o Transcribe"
        case .openAIGPT4OMiniTranscribe20251215: "OpenAI GPT-4o Mini Transcribe 2025-12-15"
        case .localHviske: "Local Hviske v5.3"
        }
    }

    var processingTitle: String {
        switch self {
        case .elevenLabsScribe: "Realtime network transcription"
        case .groqWhisper: "Network file transcription via Groq"
        case .openAIRealtimeWhisper: "Realtime network transcription via OpenAI"
        case .openAIGPT4OTranscribe: "Network file transcription via OpenAI"
        case .openAIGPT4OMiniTranscribe20251215: "Network file transcription via OpenAI"
        case .localHviske: "Local transcription on this Mac"
        }
    }
}

enum LstnrSettingsSection: String, CaseIterable, Identifiable {
    case dictation
    case engine
    case intelligence
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: String(localized: "Dictation", comment: "Settings sidebar item")
        case .engine: String(localized: "Engine", comment: "Settings sidebar item")
        case .intelligence: String(localized: "Intelligence", comment: "Settings sidebar item")
        case .privacy: String(localized: "Privacy", comment: "Settings sidebar item")
        case .about: String(localized: "About", comment: "Settings sidebar item")
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: "text.bubble"
        case .engine: "waveform"
        case .intelligence: "wand.and.stars"
        case .privacy: "lock"
        case .about: "info.circle"
        }
    }
}

/// Selectable card for one speech-to-text engine.
struct EngineCard: View {
    enum KeyStatus {
        case notNeeded
        case present
        case missing
    }

    let backend: LstnrSpeechBackendChoice
    let isSelected: Bool
    let keyStatus: KeyStatus
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: backend.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? BSTheme.cyan : BSTheme.teal)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(BSTheme.cyan)
                    }
                }

                Text(backend.shortTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(backend.latencyHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    badge(
                        backend.isLocal
                            ? String(localized: "Local", comment: "Engine badge")
                            : String(localized: "Cloud", comment: "Engine badge"),
                        tint: backend.isLocal ? .green : BSTheme.teal
                    )

                    switch keyStatus {
                    case .notNeeded:
                        EmptyView()
                    case .present:
                        badge(String(localized: "Key ✓", comment: "Engine badge: key present"), tint: .green)
                    case .missing:
                        badge(String(localized: "Key missing", comment: "Engine badge: key missing"), tint: .orange)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? BSTheme.teal.opacity(0.12) : BSTheme.surface,
                in: RoundedRectangle(cornerRadius: BSTheme.smallCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BSTheme.smallCornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? BSTheme.teal : BSTheme.border, lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
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
        case .rightCommand: String(localized: "Right Command", comment: "Shortcut key name")
        case .leftCommand: String(localized: "Left Command", comment: "Shortcut key name")
        case .rightOption: String(localized: "Right Option", comment: "Shortcut key name")
        case .leftOption: String(localized: "Left Option", comment: "Shortcut key name")
        case .functionKey: String(localized: "Function key (best effort)", comment: "Shortcut key name")
        case .leftCommandLeftOption: String(localized: "Left Command + Left Option", comment: "Shortcut key name")
        case .leftCommandRightOption: String(localized: "Left Command + Right Option", comment: "Shortcut key name")
        case .rightCommandLeftOption: String(localized: "Right Command + Left Option", comment: "Shortcut key name")
        case .rightCommandRightOption: String(localized: "Right Command + Right Option", comment: "Shortcut key name")
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
    @State private var status: String = String(localized: "Press record, then press and release a shortcut.", comment: "Shortcut recorder status")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LabeledContent(String(localized: "Recorded shortcut", comment: "Shortcut recorder label")) {
                    Text(shortcut.title)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(isRecording ? String(localized: "Cancel", comment: "Shortcut recorder button") : String(localized: "Record shortcut", comment: "Shortcut recorder button")) {
                    if isRecording {
                        stopRecording(status: String(localized: "Recording cancelled.", comment: "Shortcut recorder status"))
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
            return String(localized: "Recording \(Self.title(for: capturedKeys)). Release all keys to save.", comment: "Shortcut recorder status")
        }
        if isRecording {
            return String(localized: "Press a modifier key, or Command + Option together.", comment: "Shortcut recorder status")
        }
        return status
    }

    private func startRecording() {
        removeEventMonitor()
        activeKeys = []
        capturedKeys = []
        status = String(localized: "Press a modifier key, or Command + Option together.", comment: "Shortcut recorder status")
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
            stopRecording(status: String(localized: "Unsupported shortcut: \(Self.title(for: capturedKeys)).", comment: "Shortcut recorder status"))
            return
        }

        shortcut = recordedShortcut
        stopRecording(status: String(localized: "Recorded \(recordedShortcut.title).", comment: "Shortcut recorder status"))
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
        case .leftCommand: String(localized: "Left Command", comment: "Shortcut key name")
        case .rightCommand: String(localized: "Right Command", comment: "Shortcut key name")
        case .leftOption: String(localized: "Left Option", comment: "Shortcut key name")
        case .rightOption: String(localized: "Right Option", comment: "Shortcut key name")
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
        case .automatic: String(localized: "Automatic", comment: "Language choice")
        case .danish: String(localized: "Danish", comment: "Language choice")
        case .english: String(localized: "English", comment: "Language choice")
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
