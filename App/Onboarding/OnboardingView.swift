import AVFoundation
import LstnrCore
import SwiftUI

/// Vara's first-run welcome flow: meet Vara, grant the two permissions, connect
/// one cloud key (Groq/OpenAI) that powers both transcription and cleanup, see a
/// confirmation, then dictate for the first time. Advanced engines (ElevenLabs,
/// on-device Hviske, your own model) live in Settings › Advanced and are pointed
/// to from the Connect step — onboarding stays focused on the mainstream path.
struct OnboardingView: View {
    let state: AppState

    private enum Step: Int, CaseIterable {
        case welcome
        case permissions
        case connect
        case ready
        case tryIt
    }

    /// The two providers the Connect step offers. Each one wires BOTH layers —
    /// transcription and cleanup — from a single key.
    private enum ConnectProvider: Hashable {
        case groq
        case openAI

        var credentialProvider: LstnrCredentialProvider {
            switch self {
            case .groq: .groq
            case .openAI: .openAI
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted = false
    /// Which cloud provider the user is connecting. Groq is pre-selected — it is
    /// the zero-cost default for both layers.
    @State private var selectedProvider: ConnectProvider = .groq
    @State private var engineAPIKey = ""
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
    /// Drives the welcome step's staged reveal cascade.
    @State private var welcomeRevealed = false
    /// Drives the welcome medallion's slow breathing scale.
    @State private var welcomeBreathing = false
    /// Drives the ready step's staggered recap reveal after the ember ignites.
    @State private var readyRevealed = false
    /// Drives the try-it focus border breathing and the pulsing keycap.
    @State private var tryItBreathing = false
    @FocusState private var tryItFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 56)
                .padding(.top, 40)
                .transition(stepTransition)
                .id(step)

            controls
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
        }
        .background(BSTheme.background)
        .frame(minWidth: 640, minHeight: 560)
        .task(id: step) {
            // Live-refresh permissions while the permissions step is visible.
            while !Task.isCancelled, step == .permissions {
                microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                accessibilityGranted = state.checkAccessibilityGranted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onAppear {
            accessibilityGranted = state.checkAccessibilityGranted()
            engineAPIKey = currentProviderKey()
        }
    }

    /// Asymmetric slide+fade so forward and back feel directional.
    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .connect: connectStep
        case .ready: readyStep
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
                .scaleEffect(welcomeBreathing ? 1.03 : 1.0)
                .opacity(welcomeRevealed ? 1 : 0)

            Text(verbatim: "Vara")
                .font(BSTheme.display(46, weight: .semibold))
                .foregroundStyle(BSTheme.textPrimary)
                .opacity(welcomeRevealed ? 1 : 0)
                .offset(y: welcomeRevealed ? 0 : 8)

            Text("Hold the key. Speak. Let go.", comment: "Onboarding welcome tagline")
                .font(.system(size: 16))
                .foregroundStyle(BSTheme.textMuted)
                .multilineTextAlignment(.center)
                .opacity(welcomeRevealed ? 1 : 0)
                .offset(y: welcomeRevealed ? 0 : 8)

            Text("Vara is forged on Vár — the Norse goddess who hears every word you speak.", comment: "Onboarding welcome persona subline")
                .font(.system(size: 13))
                .foregroundStyle(BSTheme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(welcomeRevealed ? 0.85 : 0)
                .offset(y: welcomeRevealed ? 0 : 8)

            KeyCapView(keys: [state.settings.shortcut.symbol], size: 40)
                .padding(.top, 6)
                .opacity(welcomeRevealed ? 1 : 0)
                .offset(y: welcomeRevealed ? 0 : 8)

            Spacer()

            Text("Forged by Brokk & Sindre", comment: "Onboarding welcome footer")
                .font(BSTheme.display(12, weight: .medium))
                .foregroundStyle(BSTheme.textMuted)
                .opacity(welcomeRevealed ? 1 : 0)
        }
        .onAppear {
            // Staged reveal: medallion, then wordmark/tagline, persona, keycap.
            withAnimation(.spring(duration: 0.6)) { welcomeRevealed = true }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                welcomeBreathing = true
            }
        }
    }

    // MARK: Step 2 — Permissions (microphone + accessibility on one screen)

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                systemImage: "checkmark.shield",
                title: String(localized: "Two permissions, then you are set", comment: "Onboarding permissions title"),
                explanation: String(localized: "Vara needs both to work everywhere on your Mac. Nothing runs in the background.", comment: "Onboarding permissions explanation")
            )

            permissionRow(
                systemImage: "mic.fill",
                title: String(localized: "Microphone", comment: "Onboarding permission row title"),
                why: String(localized: "Used only while you hold the key.", comment: "Onboarding microphone why"),
                granted: microphoneStatus == .authorized
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

            permissionRow(
                systemImage: "lock.shield",
                title: String(localized: "Accessibility", comment: "Onboarding permission row title"),
                why: String(localized: "Lets Vara see the key everywhere and paste at your cursor.", comment: "Onboarding accessibility why"),
                granted: accessibilityGranted
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

            if bothPermissionsGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Vara is listening for the key.", comment: "Onboarding both permissions granted")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BSTheme.textPrimary)
                }
                .transition(.scale.combined(with: .opacity))
            }

            Spacer()
        }
        .animation(.spring(duration: 0.4), value: bothPermissionsGranted)
    }

    // MARK: Step 3 — Connect (one key, both layers)

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(
                systemImage: "key.horizontal",
                title: String(localized: "One key, and Vara just works", comment: "Onboarding connect title"),
                explanation: String(localized: "Your key powers both transcription and cleanup. Groq is free — grab a key in 30 seconds.", comment: "Onboarding connect explanation")
            )

            HStack(spacing: 12) {
                ProviderChoiceCard(
                    title: String(localized: "Groq", comment: "Onboarding provider name"),
                    subline: String(localized: "Fast Whisper + Llama 3.3. No cost.", comment: "Onboarding Groq card subline"),
                    symbolName: "bolt.fill",
                    badges: [
                        ProviderBadge(text: String(localized: "Free", comment: "Onboarding Groq badge: free"), tint: .green),
                        ProviderBadge(text: String(localized: "Recommended", comment: "Onboarding Groq badge: recommended"), tint: BSTheme.emberGlow),
                    ],
                    isSelected: selectedProvider == .groq,
                    hasKey: hasProviderKey(.groq)
                ) {
                    selectProvider(.groq)
                }

                ProviderChoiceCard(
                    title: String(localized: "OpenAI", comment: "Onboarding provider name"),
                    subline: String(localized: "GPT-4o transcription + cleanup.", comment: "Onboarding OpenAI card subline"),
                    symbolName: "cloud",
                    badges: [
                        ProviderBadge(text: String(localized: "Your key", comment: "Onboarding OpenAI badge"), tint: BSTheme.teal),
                    ],
                    isSelected: selectedProvider == .openAI,
                    hasKey: hasProviderKey(.openAI)
                ) {
                    selectProvider(.openAI)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SecureField(text: $engineAPIKey) {
                        Text(verbatim: "\(selectedProvider.credentialProvider.displayTitle) API key")
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        state.saveCredential(engineAPIKey, for: selectedProvider.credentialProvider)
                        keyStateRevision += 1
                    } label: {
                        Text("Save", comment: "Onboarding save key button")
                    }
                    .disabled(engineAPIKey.isEmpty)

                    if hasProviderKey(selectedProvider) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                getKeyLink(for: selectedProvider.credentialProvider)
            }

            if selectedEngineUsable {
                Text("We will confirm it works in a moment.", comment: "Onboarding connect ready note")
                    .font(.system(size: 12))
                    .foregroundStyle(BSTheme.textMuted)
            } else {
                Text("Add your key to continue — it is free for Groq.", comment: "Onboarding connect not-ready hint")
                    .font(.system(size: 12))
                    .foregroundStyle(BSTheme.stateError)
            }

            // One quiet pointer for tech-savvy users. Onboarding stays finishable
            // on the cloud path; advanced engines are set up later in Settings.
            Button {
                SettingsDeepLink.request(.advanced)
            } label: {
                Text("Using ElevenLabs, a local engine, or your own model? Set it up later in Settings › Advanced.", comment: "Onboarding advanced engines pointer")
                    .font(.system(size: 12))
                    .foregroundStyle(BSTheme.tealLight)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            Spacer()
        }
    }

    // MARK: Step 4 — Ready (confirmation beat)

    private var readyStep: some View {
        VStack(spacing: 18) {
            Spacer()

            EmberIgnite()

            Text("Vara is forged.", comment: "Onboarding ready headline")
                .font(BSTheme.display(30, weight: .semibold))
                .foregroundStyle(BSTheme.textPrimary)

            Text("Everything is connected. Let us hear your voice.", comment: "Onboarding ready subline")
                .font(.system(size: 14))
                .foregroundStyle(BSTheme.textMuted)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                recapRow(
                    label: String(localized: "Engine", comment: "Onboarding recap label"),
                    index: 0
                ) {
                    StatusPill(
                        text: connectedEngineTitle,
                        tint: BSTheme.teal,
                        systemImage: "waveform"
                    )
                }

                recapRow(
                    label: String(localized: "Cleanup", comment: "Onboarding recap label"),
                    index: 1
                ) {
                    StatusPill(
                        text: cleanupTitle,
                        tint: BSTheme.tealLight,
                        systemImage: "wand.and.stars"
                    )
                }

                recapRow(
                    label: String(localized: "Shortcut", comment: "Onboarding recap label"),
                    index: 2
                ) {
                    KeyCapView(keys: [state.settings.shortcut.symbol], size: 28)
                }
            }
            .frame(maxWidth: 360)
            .padding(.top, 6)

            Spacer()
        }
        .onAppear {
            readyRevealed = false
            // Recap rows stagger in after the ember ignite settles.
            withAnimation(.spring(duration: 0.5).delay(0.5)) {
                readyRevealed = true
            }
        }
    }

    /// One recap row: a fixed-width label and its status control, staggered in.
    private func recapRow(
        label: String,
        index: Int,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BSTheme.textMuted)
                .frame(width: 90, alignment: .leading)

            Spacer()

            content()
        }
        .opacity(readyRevealed ? 1 : 0)
        .offset(y: readyRevealed ? 0 : 8)
        .animation(.spring(duration: 0.45).delay(0.5 + Double(index) * 0.1), value: readyRevealed)
    }

    // MARK: Step 5 — Try it

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
                        .strokeBorder(
                            tryItFocused ? BSTheme.teal.opacity(tryItBreathing ? 0.75 : 0.4) : BSTheme.border,
                            lineWidth: tryItFocused ? 1.5 : 1
                        )
                }
                .onAppear {
                    tryItFocused = true
                    // Snapshot the current transcript so only a NEW dictation (not
                    // pre-existing history or typed text) counts as success.
                    tryItBaselineTranscript = state.lastTranscript
                    didDictateSuccessfully = false
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        tryItBreathing = true
                    }
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
                HStack(spacing: 10) {
                    KeyCapView(keys: [state.settings.shortcut.symbol], size: 26)
                        .scaleEffect(tryItBreathing ? 1.06 : 1.0)
                    Text("Hold and speak — Vara writes it right here.", comment: "Onboarding try-it hint before first dictation")
                        .font(.system(size: 12))
                        .foregroundStyle(BSTheme.textMuted)
                }
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

            progressRail

            Spacer()

            HStack(spacing: 10) {
                if step != .welcome {
                    Button {
                        withAnimation(.spring(duration: 0.35)) {
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
                        primaryButtonTitle
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BSTheme.ember)
                    .keyboardShortcut(.defaultAction)
                    // Don't let a user finish with a dead app: the chosen engine
                    // must actually be usable. "Skip" stays as the escape hatch.
                    .disabled(!selectedEngineUsable)
                } else {
                    Button {
                        withAnimation(.spring(duration: 0.35)) {
                            step = Step(rawValue: step.rawValue + 1) ?? .tryIt
                        }
                    } label: {
                        primaryButtonTitle
                    }
                    // Can't leave permissions until both are granted, nor leave
                    // Connect until the chosen engine can transcribe — keeps the
                    // default Groq path the smooth one.
                    .disabled(
                        (step == .permissions && !bothPermissionsGranted)
                            || (step == .connect && !selectedEngineUsable)
                    )
                    .buttonStyle(.borderedProminent)
                    .tint(BSTheme.ember)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Per-step verb label for the primary CTA.
    private var primaryButtonTitle: Text {
        switch step {
        case .welcome: Text("Begin", comment: "Onboarding primary button: welcome")
        case .permissions: Text("Continue", comment: "Onboarding primary button: permissions")
        case .connect: Text("Connect", comment: "Onboarding primary button: connect")
        case .ready: Text("Try it", comment: "Onboarding primary button: ready")
        case .tryIt: Text("Done", comment: "Onboarding primary button: finish")
        }
    }

    /// Thin progress rail: teal track with an ember-filled portion that advances
    /// on each step and an ember-glowing node at the active step.
    private var progressRail: some View {
        GeometryReader { geo in
            let total = Step.allCases.count
            let fraction = total > 1 ? Double(step.rawValue) / Double(total - 1) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(BSTheme.teal.opacity(0.25))
                    .frame(height: 3)

                Capsule()
                    .fill(BSTheme.ember)
                    .frame(width: max(6, geo.size.width * fraction), height: 3)

                Circle()
                    .fill(BSTheme.emberGlow)
                    .frame(width: 9, height: 9)
                    .emberGlow(active: true)
                    .offset(x: geo.size.width * fraction - 4.5)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 160, height: 12)
        .animation(.spring(duration: 0.35), value: step)
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

    /// One permission line: icon, title, one-line why, status, inline action.
    private func permissionRow(
        systemImage: String,
        title: String,
        why: String,
        granted: Bool,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        BSCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(granted ? .green : BSTheme.tealLight)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(BSTheme.textPrimary)

                        Spacer()

                        if granted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    Text(why)
                        .font(.system(size: 12))
                        .foregroundStyle(BSTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if !granted {
                        actions()
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var bothPermissionsGranted: Bool {
        microphoneStatus == .authorized && accessibilityGranted
    }

    /// Wires BOTH layers from one provider choice: the matching speech backend,
    /// the matching default LLM, and Clean text as the starting mode — so a
    /// single key makes Vara transcribe and clean up out of the box.
    private func selectProvider(_ provider: ConnectProvider) {
        selectedProvider = provider
        state.updateSettings { settings in
            switch provider {
            case .groq:
                settings.speechBackend = .groqWhisper
                settings.defaultLLM = LLMSelection(provider: .groq, model: "llama-3.3-70b-versatile")
            case .openAI:
                settings.speechBackend = .openAIGPT4OMiniTranscribe20251215
                settings.defaultLLM = LLMSelection(provider: .openAI, model: "gpt-4o-mini")
            }
            settings.selectedModeID = DictationMode.cleanModeID
        }
        engineAPIKey = currentProviderKey()
    }

    private func currentProviderKey() -> String {
        state.savedCredential(for: selectedProvider.credentialProvider)
    }

    private func hasProviderKey(_ provider: ConnectProvider) -> Bool {
        hasCredential(provider.credentialProvider)
    }

    private func hasCredential(_ provider: LstnrCredentialProvider) -> Bool {
        if !state.savedCredential(for: provider).isEmpty { return true }
        return ((try? EnvLoader.resolveForApp(provider.environmentVariableName)) ?? "").isEmpty == false
    }

    /// Whether the connected cloud engine can actually transcribe right now: its
    /// key must be saved (or in the environment). Gates leaving the Connect step
    /// and finishing so a user can't end onboarding with a dead app.
    private var selectedEngineUsable: Bool {
        // Touch keyStateRevision so saving a key re-evaluates this gate (it reads
        // the keychain, not an observable property).
        _ = keyStateRevision
        return hasProviderKey(selectedProvider)
    }

    /// Engine name for the Ready recap, read from the connected settings.
    private var connectedEngineTitle: String {
        state.settings.speechBackend.shortTitle
    }

    /// Cleanup model for the Ready recap, or "Raw" when no LLM is configured.
    private var cleanupTitle: String {
        if let llm = state.settings.defaultLLM {
            return "\(llm.provider.displayTitle) · \(llm.model)"
        }
        return String(localized: "Raw", comment: "Onboarding recap: no cleanup model")
    }

    /// Where to get a key for a provider, so a user isn't stuck with a key field
    /// and no way to fill it. Groq's is free — the zero-cost default for both
    /// layers.
    private func keySignupURL(for provider: LstnrCredentialProvider) -> URL? {
        switch provider {
        case .groq: URL(string: "https://console.groq.com/keys")
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/settings/api-keys")
        }
    }

    /// "Get a free key" link beside a provider's key field. Groq is highlighted
    /// as free; OpenAI just links to where the key is created.
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
}

/// A badge shown on a provider choice card.
private struct ProviderBadge: Identifiable {
    let id = UUID()
    let text: String
    let tint: Color
}

/// One of the two cloud-provider cards on the Connect step. Unlike `EngineCard`
/// this is keyed to a single bring-your-own-key cloud provider and shows the
/// one-key-both-layers framing (no latency hints), with an ember-glow ring when
/// selected.
private struct ProviderChoiceCard: View {
    let title: String
    let subline: String
    let symbolName: String
    let badges: [ProviderBadge]
    let isSelected: Bool
    let hasKey: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? BSTheme.cyan : BSTheme.teal)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(BSTheme.cyan)
                    }
                }

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(subline)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    ForEach(badges) { badge in
                        Text(badge.text)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(badge.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(badge.tint)
                    }

                    if hasKey {
                        Text("Key ✓", comment: "Onboarding provider badge: key present")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.14), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(
                isSelected ? BSTheme.teal.opacity(0.12) : BSTheme.surface,
                in: RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? BSTheme.ember : BSTheme.border, lineWidth: isSelected ? 1.5 : 1)
            }
            .emberGlow(active: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// Larger one-shot ember ignite for the Ready confirmation beat: a glowing
/// medallion that sparks outward once when the step appears.
private struct EmberIgnite: View {
    @State private var ignited = false

    var body: some View {
        ZStack {
            ForEach(0..<10, id: \.self) { index in
                Circle()
                    .fill(index.isMultiple(of: 2) ? BSTheme.emberGlow : BSTheme.ember)
                    .frame(width: 6, height: 6)
                    .offset(
                        x: ignited ? cos(Double(index) / 10 * 2 * .pi) * 56 : 0,
                        y: ignited ? sin(Double(index) / 10 * 2 * .pi) * 56 : 0
                    )
                    .opacity(ignited ? 0 : 1)
            }

            Circle()
                .fill(BSTheme.ember.opacity(0.16))
                .frame(width: 108, height: 108)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(BSTheme.emberGlow)
                        .scaleEffect(ignited ? 1 : 0.3)
                }
                .emberGlow(active: true)
                .scaleEffect(ignited ? 1 : 0.7)
        }
        .frame(width: 120, height: 120)
        .onAppear {
            withAnimation(.spring(duration: 0.6)) {
                ignited = true
            }
        }
    }
}
