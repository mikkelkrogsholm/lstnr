import AppKit
import VaraCore
import Security
import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let varaCredentialsDidChange = Notification.Name("dk.56n.vara.credentialsDidChange")
    static let varaSettingsDidChange = Notification.Name("dk.56n.vara.settingsDidChange")
}

struct VaraSettingsView: View {
    @State private var draft: VaraSettingsDraft
    @State private var selectedSection: VaraSettingsSection = .dictation
    @State private var elevenLabsAPIKey: String = ""
    @State private var elevenLabsCredentialStatus: String?
    @State private var groqAPIKey: String = ""
    @State private var groqCredentialStatus: String?
    @State private var openAIAPIKey: String = ""
    @State private var openAICredentialStatus: String?
    @State private var anthropicAPIKey: String = ""
    @State private var anthropicCredentialStatus: String?
    @State private var geminiAPIKey: String = ""
    @State private var geminiCredentialStatus: String?
    // Installed coding CLIs (claude/codex/gemini), resolved once on appear so the
    // picker never re-stats the filesystem on every SwiftUI re-render.
    @State private var installedCLITools: Set<VaraCLITool> = []
    @State private var accessibilityGranted = false
    @State private var editingModeIndex: Int?
    // Optional so the #Preview / `store: nil` path (no injected AppState) yields
    // nil instead of trapping; the warming/failed rows just fall back to .notNeeded.
    @Environment(AppState.self) private var appState: AppState?
    private let store: VaraSettingsStore?
    private let credentialStore: VaraCredentialStoring?

    init(
        draft: VaraSettingsDraft? = nil,
        store: VaraSettingsStore? = VaraSettingsStore(),
        credentialStore: VaraCredentialStoring? = VaraKeychainCredentialStore()
    ) {
        self.store = store
        self.credentialStore = credentialStore
        let initialDraft = draft ?? store?.load().draft ?? .preview
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationSplitView {
            List(VaraSettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Form {
                switch selectedSection {
                case .dictation:
                    dictationSection
                    vocabularySection
                case .engine:
                    engineSection
                    if draft.speechBackend == .openAIRealtimeWhisper {
                        microphoneSection
                    }
                case .intelligence:
                    intelligenceSection
                case .advanced:
                    advancedSection
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
                    installedCLITools: installedCLITools,
                    onDelete: draft.modes[index].isBuiltIn ? nil : {
                        draft.modes.remove(at: index)
                    }
                )
            }
        }
        .onChange(of: draft) { _, newDraft in
            guard let store else { return }
            try? store.save(VaraAppSettings(draft: newDraft))
            NotificationCenter.default.post(name: .varaSettingsDidChange, object: nil)
        }
        .onAppear {
            loadCredentials()
            installedCLITools = CLIChatClient.detectInstalledTools()
            refreshAccessibility(prompt: false)
            if let pendingSection = SettingsDeepLink.consumePending() {
                selectedSection = pendingSection
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .varaShowSettingsSection)) { _ in
            if let pendingSection = SettingsDeepLink.consumePending() {
                selectedSection = pendingSection
            }
        }
    }

    private var dictationSection: some View {
        Section {
            Picker(selection: $draft.shortcut) {
                ForEach(VaraShortcutChoice.allCases) { shortcut in
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
                ForEach(VaraLanguageChoice.allCases) { language in
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

    /// Microphone profile (OpenAI realtime only): maps to the realtime
    /// `noise_reduction` type. Shown only when that backend is active.
    private var microphoneSection: some View {
        Section {
            Picker(selection: $draft.microphoneProfile) {
                Text("Headset / close mic", comment: "Microphone profile option (near-field)")
                    .tag(MicrophoneProfile.nearField)
                Text("Laptop / room mic", comment: "Microphone profile option (far-field)")
                    .tag(MicrophoneProfile.farField)
            } label: {
                Text("Microphone", comment: "Settings field: microphone profile")
            }
        } header: {
            Text("Microphone", comment: "Settings section header: microphone profile")
        } footer: {
            Text("Tunes OpenAI Realtime's input noise reduction. Pick the option that matches how close you speak to the mic.", comment: "Microphone profile footer")
        }
    }

    /// Custom vocabulary: free text, one term/phrase per line. Biases the RAW
    /// transcript before LLM cleanup. Threaded into SpeechToTextRequest and mapped
    /// per backend (Whisper `prompt`, ElevenLabs `keyterms`).
    private var vocabularySection: some View {
        Section {
            TextEditor(text: vocabularyText)
                .font(.system(size: 13))
                .frame(minHeight: 88)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(Text("Custom vocabulary", comment: "Accessibility label for the vocabulary editor"))
        } header: {
            Text("Words Vara should get right", comment: "Settings section header: custom vocabulary")
        } footer: {
            Text("Names, jargon, product terms, preferred spellings — one per line. Vara nudges the speech engine to spell these correctly (Groq, OpenAI GPT-4o Transcribe, ElevenLabs). ElevenLabs caps each entry at 20 characters and 50 entries; on-device WhisperKit and OpenAI Realtime ignore them for now.", comment: "Settings custom vocabulary footer")
        }
    }

    /// Bridges the `[String]` model to a multi-line text field. Empty lines are
    /// preserved while typing (so Enter works); the backends trim/drop blanks.
    private var vocabularyText: Binding<String> {
        Binding(
            get: { draft.vocabulary.joined(separator: "\n") },
            set: { newValue in
                draft.vocabulary = newValue
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        )
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
                engineGrid(for: .recommended)
                    .padding(.vertical, 4)
            } header: {
                Text("Recommended", comment: "Engine tier header")
            }

            Section {
                engineGrid(for: .advanced)
                    .padding(.vertical, 4)
            } header: {
                Text("Advanced integrations", comment: "Engine tier header")
            } footer: {
                Text("Most people use Groq or OpenAI. ElevenLabs and on-device Hviske are advanced — set them up under the Advanced tab.", comment: "Engine section footer")
            }

            if draft.speechBackend == .localWhisperKit {
                WhisperKitModelSection(
                    draft: $draft,
                    warmState: appState?.whisperKitWarmState ?? .notNeeded,
                    onRetryPrewarm: { appState?.retryWhisperKitPrewarm() }
                )
            }

            if let provider = draft.speechBackend.credentialProvider {
                apiKeySection(for: provider)
            }
        }
    }

    /// The engine cards for one tier. Groq leads the Recommended grid since it is
    /// the zero-cost default; the rest keep their declaration order.
    private func engineGrid(for tier: VaraEngineTier) -> some View {
        let backends = VaraSpeechBackendChoice.allCases
            .filter { $0.tier == tier }
            .sorted { lhs, _ in lhs == .groqWhisper }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(backends) { backend in
                EngineCard(
                    backend: backend,
                    isSelected: draft.speechBackend == backend,
                    keyStatus: engineKeyStatus(for: backend)
                ) {
                    draft.speechBackend = backend
                }
            }
        }
    }

    private func engineKeyStatus(for backend: VaraSpeechBackendChoice) -> EngineCard.KeyStatus {
        guard let provider = backend.credentialProvider else { return .notNeeded }
        return hasKey(for: provider) ? .present : .missing
    }

    private func hasKey(for provider: VaraCredentialProvider) -> Bool {
        let savedKey: String? = switch provider {
        case .elevenLabs: elevenLabsAPIKey
        case .groq: groqAPIKey
        case .openAI: openAIAPIKey
        case .anthropic: anthropicAPIKey
        case .gemini: geminiAPIKey
        }
        if let savedKey, !savedKey.isEmpty { return true }
        return (try? EnvLoader.resolveForApp(provider.environmentVariableName)).map { !$0.isEmpty } ?? false
    }

    @ViewBuilder
    private func apiKeySection(for provider: VaraCredentialProvider) -> some View {
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

    // MARK: Advanced (integrations the user sets up themselves)

    private var advancedSection: some View {
        Group {
            LocalHviskeSection()

            CustomEndpointsSection(draft: $draft)

            Section {
                EmptyView()
            } footer: {
                Text("Advanced integrations need the last bit of setup from you. ElevenLabs and OpenAI's niche engines just need a key on the Engine tab; Ollama and custom endpoints run a model on your own machine.", comment: "Advanced section footer")
            }
        }
    }

    // MARK: Intelligence (LLM + modes)

    private var intelligenceSection: some View {
        Group {
            Section {
                LLMSelectionPicker(
                    selection: $draft.defaultLLM,
                    customEndpoints: draft.customEndpoints,
                    allowsDefault: false,
                    installedCLITools: installedCLITools
                )

                if let provider = draft.defaultLLM?.provider {
                    switch provider {
                    case .openAI where !hasKey(for: .openAI),
                         .groq where !hasKey(for: .groq),
                         .anthropic where !hasKey(for: .anthropic),
                         .gemini where !hasKey(for: .gemini):
                        Label {
                            Text("Missing API key — add it below.", comment: "Missing LLM key warning")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                    case .ollama:
                        Label {
                            Text("Runs against http://localhost:11434 — this chain sends nothing to the cloud. Start Ollama if it isn't running.", comment: "Ollama info")
                        } icon: {
                            Image(systemName: "lock.fill")
                        }
                        .foregroundStyle(.green)
                    case .claudeCLI, .codexCLI, .geminiCLI:
                        Label {
                            Text("No key needed — uses your \(provider.displayTitle) subscription · slower.", comment: "CLI provider model footnote")
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

            AppRulesSection(draft: $draft)
        }
    }

    private func providerNeedsKeySection(_ provider: LLMProvider) -> Bool {
        switch provider {
        case .openAI, .groq, .anthropic, .gemini: true
        case .ollama, .custom, .claudeCLI, .codexCLI, .geminiCLI: false
        }
    }

    private func credentialProvider(for provider: LLMProvider) -> VaraCredentialProvider? {
        switch provider {
        case .openAI: .openAI
        case .groq: .groq
        case .anthropic: .anthropic
        case .gemini: .gemini
        case .ollama, .custom, .claudeCLI, .codexCLI, .geminiCLI: nil
        }
    }

    /// Whether the LLM half of the chain stays on the local machine/network:
    /// built-in Ollama, a custom OpenAI-compatible endpoint (DGX/LM Studio on the
    /// LAN), or a CLI running under the user's own subscription on this Mac.
    /// Cloud providers (OpenAI/Groq/Anthropic/Gemini) and an unset model do not
    /// qualify.
    private func isLocalLLMChain(_ provider: LLMProvider?) -> Bool {
        switch provider {
        case .ollama, .custom, .claudeCLI, .codexCLI, .geminiCLI: true
        case .openAI, .groq, .anthropic, .gemini, .none: false
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

            // The local-chain badge lights when the engine is Hviske AND the LLM
            // stays on the LAN — either built-in Ollama or a custom endpoint
            // (DGX/LM Studio). A custom endpoint could in theory be a cloud URL,
            // so the wording stays truthful about the chain rather than implying
            // OS-enforced isolation (the app is intentionally not sandboxed).
            if draft.speechBackend.isLocal, isLocalLLMChain(draft.defaultLLM?.provider) {
                Label {
                    Text("Runs locally on this Mac — this chain sends nothing to the cloud.", comment: "Fully local privacy badge")
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
                NotificationCenter.default.post(name: .varaSettingsDidChange, object: nil)
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
        for provider in VaraCredentialProvider.allCases {
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

    private func keyBinding(for provider: VaraCredentialProvider) -> Binding<String> {
        switch provider {
        case .elevenLabs: $elevenLabsAPIKey
        case .groq: $groqAPIKey
        case .openAI: $openAIAPIKey
        case .anthropic: $anthropicAPIKey
        case .gemini: $geminiAPIKey
        }
    }

    private func keyStatusBinding(for provider: VaraCredentialProvider) -> Binding<String?> {
        switch provider {
        case .elevenLabs: $elevenLabsCredentialStatus
        case .groq: $groqCredentialStatus
        case .openAI: $openAICredentialStatus
        case .anthropic: $anthropicCredentialStatus
        case .gemini: $geminiCredentialStatus
        }
    }

    private func keyStatus(for provider: VaraCredentialProvider) -> String? {
        keyStatusBinding(for: provider).wrappedValue
    }

    private func saveKey(for provider: VaraCredentialProvider) {
        let binding = keyBinding(for: provider)
        let trimmedKey = binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try credentialStore?.saveCredential(trimmedKey, for: provider)
            binding.wrappedValue = trimmedKey
            keyStatusBinding(for: provider).wrappedValue = trimmedKey.isEmpty
                ? String(localized: "Removed", comment: "Key status")
                : String(localized: "Saved", comment: "Key status")
            NotificationCenter.default.post(name: .varaCredentialsDidChange, object: nil)
        } catch {
            keyStatusBinding(for: provider).wrappedValue = String(localized: "Save failed", comment: "Key status")
        }
    }

    private func deleteKey(for provider: VaraCredentialProvider) {
        do {
            try credentialStore?.deleteCredential(for: provider)
            keyBinding(for: provider).wrappedValue = ""
            keyStatusBinding(for: provider).wrappedValue = String(localized: "Removed", comment: "Key status")
            NotificationCenter.default.post(name: .varaCredentialsDidChange, object: nil)
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
            NotificationCenter.default.post(name: .varaSettingsDidChange, object: nil)
        }
    }
}

private struct ShortcutRecorderButton: View {
    @Binding var shortcut: VaraShortcutChoice
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
        guard VaraShortcutChoice.recordableKeys.contains(key) else { return }

        if activeKeys.contains(key) {
            activeKeys.remove(key)
        } else {
            activeKeys.insert(key)
        }
        capturedKeys.insert(key)
        capturedKeys.formUnion(activeKeys)

        guard activeKeys.isEmpty else { return }
        guard let recordedShortcut = VaraShortcutChoice(keys: capturedKeys) else {
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

#Preview("Settings") {
    VaraSettingsView(draft: .preview, store: nil)
}
