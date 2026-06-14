import AVFoundation
import LstnrCore
import SwiftUI

/// Vara's first-run welcome flow: meet Vara, grant the two permissions,
/// choose an engine and intelligence, then dictate for the first time.
struct OnboardingView: View {
    let state: AppState

    private enum Step: Int, CaseIterable {
        case welcome
        case microphone
        case accessibility
        case engine
        case intelligence
        case tryIt
    }

    @State private var step: Step = .welcome
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted = false
    @State private var engineAPIKey = ""
    @State private var llmAPIKey = ""
    @State private var localHviskeStatus = LocalHviskeBackend.runtimeStatus()
    @State private var isInstallingHviske = false
    @State private var hviskeInstallMessage: String?
    @State private var tryItText = ""
    /// The transcript count at the moment the try-it step appeared. A real
    /// dictation increments `state.lastTranscript`; typing into the editor does
    /// not — so success is only declared when an ACTUAL dictation landed, never
    /// on arbitrary typed text.
    @State private var tryItBaselineTranscript = ""
    @State private var didDictateSuccessfully = false
    /// Bumped whenever a key is saved so the readiness gating (which reads the
    /// keychain, not an observable property) re-evaluates immediately.
    @State private var keyStateRevision = 0
    @FocusState private var tryItFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 56)
                .padding(.top, 40)

            controls
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
        }
        .background(BSTheme.background)
        .frame(minWidth: 640, minHeight: 560)
        .task(id: step) {
            // Live-refresh permissions while their step is visible.
            while !Task.isCancelled, step == .microphone || step == .accessibility {
                microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                accessibilityGranted = state.checkAccessibilityGranted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onAppear {
            accessibilityGranted = state.checkAccessibilityGranted()
            engineAPIKey = currentEngineKey()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .microphone: microphoneStep
        case .accessibility: accessibilityStep
        case .engine: engineStep
        case .intelligence: intelligenceStep
        case .tryIt: tryItStep
        }
    }

    // MARK: Step 1 — Meet Vara

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer()

            Circle()
                .fill(BSTheme.teal.opacity(0.14))
                .frame(width: 92, height: 92)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(BSTheme.tealLight)
                }
                .emberGlow(active: true)

            Text(verbatim: "Vara")
                .font(BSTheme.display(46, weight: .semibold))
                .foregroundStyle(BSTheme.textPrimary)

            Text("Vara hears your words — hold the key, speak, let go.", comment: "Onboarding welcome tagline")
                .font(.system(size: 16))
                .foregroundStyle(BSTheme.textMuted)
                .multilineTextAlignment(.center)

            KeyCapView(keys: [state.settings.shortcut.symbol], size: 40)
                .padding(.top, 6)

            Spacer()

            Text("Forged by Brokk & Sindre", comment: "Onboarding welcome footer")
                .font(BSTheme.display(12, weight: .medium))
                .foregroundStyle(BSTheme.textMuted)
        }
    }

    // MARK: Step 2 — Microphone

    private var microphoneStep: some View {
        permissionStep(
            systemImage: "mic.fill",
            title: String(localized: "Vara needs to hear you", comment: "Onboarding microphone title"),
            explanation: String(localized: "The microphone is only used while you hold the dictation key. Nothing is recorded in the background.", comment: "Onboarding microphone explanation"),
            granted: microphoneStatus == .authorized,
            grantedText: String(localized: "Microphone access granted", comment: "Permission status"),
            missingText: microphoneStatus == .denied
                ? String(localized: "Access denied — open System Settings", comment: "Permission status")
                : String(localized: "Microphone access not granted yet", comment: "Permission status")
        ) {
            if microphoneStatus == .notDetermined {
                Button {
                    Task { @MainActor in
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                } label: {
                    Text("Allow microphone", comment: "Onboarding button")
                }
                .buttonStyle(.borderedProminent)
                .tint(BSTheme.teal)
            } else if microphoneStatus != .authorized {
                Button {
                    openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                } label: {
                    Text("Open System Settings", comment: "Onboarding button")
                }
            }
        }
    }

    // MARK: Step 3 — Accessibility

    private var accessibilityStep: some View {
        permissionStep(
            systemImage: "lock.shield",
            title: String(localized: "One more permission", comment: "Onboarding accessibility title"),
            explanation: String(localized: "Accessibility lets Vara see the dictation key everywhere and paste the text where your cursor is. Without it, nothing works globally.", comment: "Onboarding accessibility explanation"),
            granted: accessibilityGranted,
            grantedText: String(localized: "Accessibility access granted", comment: "Permission status"),
            missingText: String(localized: "Accessibility access not granted yet", comment: "Permission status")
        ) {
            if !accessibilityGranted {
                HStack(spacing: 10) {
                    Button {
                        accessibilityGranted = state.requestAccessibilityPermission()
                    } label: {
                        Text("Request access", comment: "Onboarding button")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BSTheme.teal)

                    Button {
                        openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    } label: {
                        Text("Open System Settings", comment: "Onboarding button")
                    }
                }
            }
        }
    }

    // MARK: Step 4 — Engine

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(
                systemImage: "waveform",
                title: String(localized: "Choose your speech engine", comment: "Onboarding engine title"),
                explanation: String(localized: "The engine turns voice into text. You can switch any time in Settings.", comment: "Onboarding engine explanation")
            )

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(LstnrSpeechBackendChoice.allCases) { backend in
                    EngineCard(
                        backend: backend,
                        isSelected: state.settings.speechBackend == backend,
                        keyStatus: backend.credentialProvider == nil
                            ? .notNeeded
                            : (hasEngineKey(backend) ? .present : .missing)
                    ) {
                        state.updateSettings { $0.speechBackend = backend }
                        engineAPIKey = currentEngineKey()
                    }
                }
            }

            if let provider = state.settings.speechBackend.credentialProvider {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SecureField(text: $engineAPIKey) {
                            Text(verbatim: "\(provider.displayTitle) API key")
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            state.saveCredential(engineAPIKey, for: provider)
                            keyStateRevision += 1
                        } label: {
                            Text("Save", comment: "Onboarding save key button")
                        }
                        .disabled(engineAPIKey.isEmpty)

                        if hasEngineKey(state.settings.speechBackend) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }

                    getKeyLink(for: provider)
                }
            }

            if state.settings.speechBackend == .localHviske {
                HStack(spacing: 10) {
                    if localHviskeStatus.isReady {
                        Label {
                            Text("Hviske is installed and ready", comment: "Onboarding Hviske status")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .foregroundStyle(.green)
                    } else {
                        Button {
                            installHviske()
                        } label: {
                            if isInstallingHviske {
                                ProgressView().controlSize(.small)
                            }
                            Text("Install Hviske (downloads the model)", comment: "Onboarding Hviske install button")
                        }
                        .disabled(isInstallingHviske)

                        if let hviskeInstallMessage {
                            Text(hviskeInstallMessage)
                                .font(.caption)
                                .foregroundStyle(BSTheme.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            // Explain why Next is held back so the gating isn't a dead end.
            if !selectedEngineUsable {
                Text("Add this engine's key (or install Hviske) to continue.", comment: "Onboarding engine-not-ready hint")
                    .font(.system(size: 12))
                    .foregroundStyle(BSTheme.stateError)
            }

            Spacer()
        }
    }

    // MARK: Step 5 — Intelligence

    private var intelligenceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(
                systemImage: "wand.and.stars",
                title: String(localized: "Choose Vara's intelligence", comment: "Onboarding intelligence title"),
                explanation: String(localized: "A language model cleans up your dictation: punctuation, filler words, polish. Skip it and Vara inserts the raw transcript.", comment: "Onboarding intelligence explanation")
            )

            Form {
                LLMSelectionPicker(
                    selection: Binding(
                        get: { state.settings.defaultLLM },
                        set: { newValue in
                            state.updateSettings { settings in
                                settings.defaultLLM = newValue
                                // A configured LLM makes Clean text the natural default mode.
                                if newValue != nil, settings.selectedModeID == DictationMode.rawModeID {
                                    settings.selectedModeID = DictationMode.cleanModeID
                                } else if newValue == nil {
                                    settings.selectedModeID = DictationMode.rawModeID
                                }
                            }
                        }
                    ),
                    customEndpoints: state.settings.customEndpoints,
                    allowsDefault: false
                )
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: 130)

            if let provider = state.settings.defaultLLM?.provider {
                switch provider {
                case .ollama:
                    // Only claim the local-private chain when Ollama actually
                    // answered its reachability probe; otherwise point the user at
                    // starting it. Wording stays truthful (the app is not
                    // sandboxed) — "sends nothing to the cloud", not OS isolation.
                    if state.ollamaReachable == true {
                        Label {
                            Text("Combined with Hviske, this runs locally on your Mac — this chain sends nothing to the cloud.", comment: "Onboarding local LLM highlight")
                        } icon: {
                            Image(systemName: "lock.shield.fill")
                        }
                        .foregroundStyle(.green)
                    } else {
                        Label {
                            Text("Ollama isn't reachable yet. Start it (ollama serve) — then this chain runs locally on your Mac.", comment: "Onboarding Ollama not running hint")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(BSTheme.stateError)
                    }
                case .openAI, .groq, .anthropic:
                    if let credentialProvider = onboardingCredentialProvider(provider) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                SecureField(text: $llmAPIKey) {
                                    Text(verbatim: "\(credentialProvider.displayTitle) API key")
                                }
                                .textFieldStyle(.roundedBorder)

                                Button {
                                    state.saveCredential(llmAPIKey, for: credentialProvider)
                                    keyStateRevision += 1
                                } label: {
                                    Text("Save", comment: "Onboarding save key button")
                                }
                                .disabled(llmAPIKey.isEmpty)

                                if !state.savedCredential(for: credentialProvider).isEmpty {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }

                            getKeyLink(for: credentialProvider)
                        }
                    }
                case .custom:
                    EmptyView()
                }
            } else {
                Text("No model chosen — Vara starts in Raw mode.", comment: "Onboarding no-LLM note")
                    .font(.system(size: 12))
                    .foregroundStyle(BSTheme.textMuted)
            }

            Spacer()
        }
    }

    // MARK: Step 6 — Try it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(
                systemImage: "mic.badge.plus",
                title: String(localized: "Say hello to Vara", comment: "Onboarding try-it title"),
                explanation: String(localized: "Click the field, hold \(state.settings.shortcut.symbol), say something — and let go.", comment: "Onboarding try-it explanation")
            )

            TextEditor(text: $tryItText)
                .focused($tryItFocused)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 140)
                .background(BSTheme.surface, in: RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous)
                        .strokeBorder(tryItFocused ? BSTheme.teal.opacity(0.6) : BSTheme.border)
                }
                .onAppear {
                    tryItFocused = true
                    // Snapshot the current transcript so only a NEW dictation (not
                    // pre-existing history or typed text) counts as success.
                    tryItBaselineTranscript = state.lastTranscript
                    didDictateSuccessfully = false
                }

            // Success only lights once a real dictation produced a transcript —
            // observed via state.lastTranscript, never on arbitrary typed text.
            if didDictateSuccessfully {
                HStack(spacing: 10) {
                    EmberBurst()
                    Text("Vara is ready.", comment: "Onboarding success message")
                        .font(BSTheme.display(16, weight: .semibold))
                        .foregroundStyle(BSTheme.textPrimary)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("Hold \(state.settings.shortcut.symbol) and speak — Vara inserts the text right here.", comment: "Onboarding try-it hint before first dictation")
                    .font(.system(size: 12))
                    .foregroundStyle(BSTheme.textMuted)
            }

            Spacer()
        }
        .animation(.spring(duration: 0.4), value: didDictateSuccessfully)
        .onChange(of: state.lastTranscript) { _, newValue in
            // A real dictation landed: the transcript changed from the baseline
            // and is non-empty. Typing in the editor never touches this value.
            if !newValue.isEmpty, newValue != tryItBaselineTranscript {
                didDictateSuccessfully = true
            }
        }
    }

    // MARK: Chrome

    private var controls: some View {
        HStack {
            Button {
                VaraOnboarding.markCompleted()
            } label: {
                Text("Skip", comment: "Onboarding skip button")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(BSTheme.textMuted)

            Spacer()

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { dotStep in
                    Circle()
                        .fill(dotStep == step ? BSTheme.tealLight : BSTheme.surfaceHover)
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                if step != .welcome {
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            step = Step(rawValue: step.rawValue - 1) ?? .welcome
                        }
                    } label: {
                        Text("Back", comment: "Onboarding back button")
                    }
                }

                if step == .tryIt {
                    Button {
                        VaraOnboarding.markCompleted()
                    } label: {
                        Text("Done", comment: "Onboarding finish button")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BSTheme.teal)
                    .keyboardShortcut(.defaultAction)
                    // Don't let a user finish with a dead app: the chosen engine
                    // must actually be usable. "Skip" stays as the escape hatch.
                    .disabled(!selectedEngineUsable)
                } else {
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            step = Step(rawValue: step.rawValue + 1) ?? .tryIt
                        }
                    } label: {
                        Text("Next", comment: "Onboarding next button")
                    }
                    // Can't leave the engine step until the chosen engine can
                    // transcribe — keeps the default Groq path the smooth one.
                    .disabled(step == .engine && !selectedEngineUsable)
                    .buttonStyle(.borderedProminent)
                    .tint(BSTheme.teal)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func stepHeader(systemImage: String, title: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(BSTheme.tealLight)

            Text(title)
                .font(BSTheme.display(24, weight: .semibold))
                .foregroundStyle(BSTheme.textPrimary)

            Text(explanation)
                .font(.system(size: 13))
                .foregroundStyle(BSTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionStep(
        systemImage: String,
        title: String,
        explanation: String,
        granted: Bool,
        grantedText: String,
        missingText: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(systemImage: systemImage, title: title, explanation: explanation)

            StatusPill(
                text: granted ? grantedText : missingText,
                tint: granted ? .green : BSTheme.stateError,
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )

            actions()

            Spacer()
        }
    }

    // MARK: Helpers

    private func currentEngineKey() -> String {
        guard let provider = state.settings.speechBackend.credentialProvider else { return "" }
        return state.savedCredential(for: provider)
    }

    private func hasEngineKey(_ backend: LstnrSpeechBackendChoice) -> Bool {
        guard let provider = backend.credentialProvider else { return true }
        if !state.savedCredential(for: provider).isEmpty { return true }
        return ((try? EnvLoader.resolveForApp(provider.environmentVariableName)) ?? "").isEmpty == false
    }

    /// Whether the chosen engine can actually transcribe right now: a cloud
    /// engine needs its key saved (or in the environment); local Hviske needs
    /// its runtime + model installed. Gates leaving the engine step and finishing
    /// so a default-engine user can't end onboarding with a dead app.
    private var selectedEngineUsable: Bool {
        // Touch keyStateRevision so saving a key re-evaluates this gate (it reads
        // the keychain, not an observable property).
        _ = keyStateRevision
        let backend = state.settings.speechBackend
        if backend == .localHviske {
            return localHviskeStatus.isReady
        }
        return hasEngineKey(backend)
    }

    private func onboardingCredentialProvider(_ provider: LLMProvider) -> LstnrCredentialProvider? {
        switch provider {
        case .openAI: .openAI
        case .groq: .groq
        case .anthropic: .anthropic
        case .ollama, .custom: nil
        }
    }

    /// Where to get a key for a provider, so a default-engine user isn't stuck
    /// with a key field and no way to fill it. Groq's is free — the zero-cost
    /// default for both layers.
    private func keySignupURL(for provider: LstnrCredentialProvider) -> URL? {
        switch provider {
        case .groq: URL(string: "https://console.groq.com/keys")
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/settings/api-keys")
        }
    }

    /// "Get a free key" link beside a provider's key field. Groq is highlighted
    /// as free; the others just link to where the key is created.
    @ViewBuilder
    private func getKeyLink(for provider: LstnrCredentialProvider) -> some View {
        if let url = keySignupURL(for: provider) {
            if provider == .groq {
                Link(destination: url) {
                    Text("Get a free key — Groq is free", comment: "Onboarding free Groq key link")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BSTheme.tealLight)
            } else {
                Link(destination: url) {
                    Text("Get a key for \(provider.displayTitle)", comment: "Onboarding get key link")
                }
                .font(.system(size: 12))
                .foregroundStyle(BSTheme.tealLight)
            }
        }
    }

    private func installHviske() {
        isInstallingHviske = true
        hviskeInstallMessage = String(localized: "Starting install …", comment: "Hviske install progress")
        Task {
            do {
                try await LocalHviskeBackend.installManagedRuntime { message in
                    await MainActor.run { hviskeInstallMessage = message }
                }
                await MainActor.run {
                    isInstallingHviske = false
                    localHviskeStatus = LocalHviskeBackend.runtimeStatus()
                    hviskeInstallMessage = nil
                    NotificationCenter.default.post(name: .lstnrSettingsDidChange, object: nil)
                }
            } catch {
                await MainActor.run {
                    isInstallingHviske = false
                    hviskeInstallMessage = String(describing: error)
                    localHviskeStatus = LocalHviskeBackend.runtimeStatus()
                }
            }
        }
    }
}

/// Small one-shot burst of ember sparks for the first successful dictation.
private struct EmberBurst: View {
    @State private var burst = false

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Circle()
                    .fill(index.isMultiple(of: 2) ? BSTheme.emberGlow : BSTheme.tealLight)
                    .frame(width: 5, height: 5)
                    .offset(
                        x: burst ? cos(Double(index) / 8 * 2 * .pi) * 18 : 0,
                        y: burst ? sin(Double(index) / 8 * 2 * .pi) * 18 : 0
                    )
                    .opacity(burst ? 0 : 1)
            }

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(BSTheme.tealLight)
                .scaleEffect(burst ? 1 : 0.4)
        }
        .frame(width: 44, height: 44)
        .onAppear {
            withAnimation(.spring(duration: 0.6)) {
                burst = true
            }
        }
    }
}
