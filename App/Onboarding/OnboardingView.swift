import AVFoundation
import VaraCore
import SwiftUI

/// Vara's first-run welcome flow: meet Vara, grant the two permissions, choose
/// how Vara listens (privacy-first — local engines first, cloud keys second),
/// set up the chosen engine, pick how the text is cleaned up, optionally choose
/// an AI for cleanup, see a confirmation, then dictate for the first time. The
/// engine/cleanup steps reuse the same Settings components (no parallel UI) so
/// the full provider set is available right here. "Skip" stays available on
/// every step.
struct OnboardingView: View {
    let state: AppState

    /// Ordered first-run steps. Int rawValue + CaseIterable drive the Back/Next
    /// arithmetic, the progress rail and the `.id(step)` transition. The AI step
    /// is part of the order but is SKIPPED (not removed) when the chosen engine
    /// already bundles an LLM — see `nextStep`/`previousStep`.
    private enum Step: Int, CaseIterable {
        case welcome
        case permissions
        case engine
        case setup
        case mode
        case ai
        case ready
        case tryIt
    }

    @State private var step: Step = .welcome
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted = false
    /// The speech engine the user is configuring. WhisperKit is pre-selected: the
    /// private, on-device default. The user actively confirms it (no auto-download).
    @State private var selectedEngine: VaraSpeechBackendChoice = .localWhisperKit
    /// The cleanup mode the user is configuring. Clean text is the adaptive
    /// recommended default; it flips to Raw for a local engine with no LLM yet.
    @State private var selectedModeID: UUID = DictationMode.cleanModeID
    /// The Form-binding source for the embedded Section components (WhisperKit,
    /// Hviske, custom endpoints, the LLM picker). Seeded from `state.settings`
    /// on appear and persisted back through `state.updateSettings` so the backend
    /// reconfigures and prewarm fires.
    @State private var draft: VaraSettingsDraft = VaraAppSettings.defaults.draft
    /// Installed coding CLIs, resolved once so the AI step never re-stats the
    /// filesystem on every re-render.
    @State private var installedCLITools: Set<VaraCLITool> = []
    @State private var engineAPIKey = ""
    @State private var tryItText = ""
    /// The transcript at the moment the try-it step appeared. A real dictation
    /// increments `state.lastTranscript`; typing into the editor does not — so
    /// success is only declared when an ACTUAL dictation landed.
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
    /// Reveals the AI step's CLI + extra-cloud options behind a disclosure so the
    /// recommended local/Groq picks aren't buried in a wall of providers.
    @State private var aiMoreOptionsExpanded = false
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
            // Seed the embedded-Form draft and engine/mode selection from live
            // settings so a returning user lands on their current configuration.
            draft = state.settings.draft
            selectedEngine = state.settings.speechBackend
            selectedModeID = state.settings.selectedModeID
            installedCLITools = CLIChatClient.detectInstalledTools()
            engineAPIKey = currentEngineKey()
        }
        .onChange(of: draft) { _, newDraft in
            // Mirror VaraSettingsView: persist the embedded-Form mutations
            // (whisperKitModel, customEndpoints, defaultLLM) back through the
            // same single write path so the backend reconfigures.
            state.updateSettings { settings in
                settings.whisperKitModel = newDraft.whisperKitModel
                settings.customEndpoints = newDraft.customEndpoints
                settings.defaultLLM = newDraft.defaultLLM
            }
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
        case .engine: engineStep
        case .setup: setupStep
        case .mode: modeStep
        case .ai: aiStep
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

    // MARK: Step 3 — Engine chooser (privacy-first, ordered list)

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(
                systemImage: "waveform",
                title: String(localized: "Choose how Vara listens", comment: "Onboarding engine chooser title"),
                explanation: String(localized: "Start local and private — or use a key. You can change this later.", comment: "Onboarding engine chooser explanation")
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    engineGroup(
                        header: String(localized: "ON THIS MAC — PRIVATE, OFFLINE", comment: "Onboarding engine group: local"),
                        engines: [.localWhisperKit, .localHviske]
                    )

                    engineGroup(
                        header: String(localized: "OVER THE NETWORK — FAST, NO DOWNLOAD", comment: "Onboarding engine group: cloud"),
                        engines: [.groqWhisper, .openAIGPT4OMiniTranscribe20251215, .elevenLabsScribe]
                    )
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
        }
    }

    private func engineGroup(header: String, engines: [VaraSpeechBackendChoice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BSTheme.textMuted)
                .kerning(0.5)

            ForEach(engines) { engine in
                EngineRow(
                    backend: engine,
                    isSelected: selectedEngine == engine,
                    hasKey: engineHasKey(engine)
                ) {
                    selectEngine(engine)
                }
            }
        }
    }

    // MARK: Step 4 — Routed setup (only the chosen engine's setup)

    @ViewBuilder
    private var setupStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(
                systemImage: selectedEngine.symbolName,
                title: setupTitle,
                explanation: setupExplanation
            )

            switch selectedEngine {
            case .localWhisperKit:
                EmbeddedSettingsForm {
                    WhisperKitModelSection(
                        draft: $draft,
                        warmState: state.whisperKitWarmState,
                        onRetryPrewarm: { state.retryWhisperKitPrewarm() }
                    )
                }
            case .localHviske:
                EmbeddedSettingsForm {
                    LocalHviskeSection()
                }
            case .elevenLabsScribe, .groqWhisper, .openAIRealtimeWhisper,
                 .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215:
                cloudKeySetup
            }

            Spacer()
        }
    }

    /// Inline compact key field + Save + green check + get-key link for the cloud
    /// engines, lifted from the deleted Connect step.
    @ViewBuilder
    private var cloudKeySetup: some View {
        if let provider = selectedEngine.credentialProvider {
            VStack(alignment: .leading, spacing: 8) {
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

                    if engineHasKey(selectedEngine) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                getKeyLink(for: provider)

                if !engineReady(selectedEngine) {
                    Text("Add your key to continue — Groq is free.", comment: "Onboarding cloud key not-ready hint")
                        .font(.system(size: 12))
                        .foregroundStyle(BSTheme.stateError)
                }
            }
        }
    }

    // MARK: Step 5 — Cleanup mode picker

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(
                systemImage: "wand.and.stars",
                title: String(localized: "How should Vara polish your text?", comment: "Onboarding mode picker title"),
                explanation: String(localized: "Choose what happens to your dictation before it is inserted. Switch anytime with 1–9.", comment: "Onboarding mode picker explanation")
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(builtInModeOrder, id: \.self) { modeID in
                        ModeRow(
                            title: modeTitle(modeID),
                            subtitle: modeSubtitle(modeID),
                            symbolName: modeSymbol(modeID),
                            isSelected: selectedModeID == modeID,
                            isOffline: modeID == DictationMode.rawModeID,
                            isRecommended: modeID == recommendedModeID
                        ) {
                            selectMode(modeID)
                        } expandedContent: {
                            // A selected mode that transforms the text shows a concrete
                            // before→after so its value is obvious at a glance.
                            if selectedModeID == modeID, let example = modeExample(modeID) {
                                modeExampleView(before: example.before, after: example.after)
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
        }
    }

    /// A before→after illustration for the modes that transform the text, so a
    /// first-timer sees what each does at a glance. Raw (no AI) and Ask AI (answers,
    /// not a transform) have none. Danish examples — Vara is Danish-first.
    private func modeExample(_ modeID: UUID) -> (before: String, after: String)? {
        switch modeID {
        case DictationMode.cleanModeID:
            return (
                String(localized: "øhm ja jeg tænkte at vi måske skulle ses på tirsdag …", comment: "Onboarding Clean text example: before"),
                String(localized: "Jeg tænkte, vi måske skulle ses på tirsdag, hvis det passer.", comment: "Onboarding Clean text example: after")
            )
        case DictationMode.professionalModeID:
            return (
                String(localized: "øh ja rapporten ser fin ud men der er lige nogle tal der skal tjekkes", comment: "Onboarding Professional example: before"),
                String(localized: "Rapporten ser god ud. Der er dog enkelte tal, der bør gennemgås, før vi sender den.", comment: "Onboarding Professional example: after")
            )
        case DictationMode.vibeCodeModeID:
            return (
                String(localized: "lav en funktion der henter brugere og cacher dem i fem minutter", comment: "Onboarding VibeCode example: before"),
                String(localized: "Lav en funktion, der henter brugere og cacher resultatet i 5 minutter. Returnér cached data ved gentagne kald, og invalidér efter 5 min.", comment: "Onboarding VibeCode example: after")
            )
        default:
            return nil
        }
    }

    private func modeExampleView(before: String, after: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(before)
                .font(.system(size: 12))
                .foregroundStyle(BSTheme.textMuted)

            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(BSTheme.tealLight)

            Text(after)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BSTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(BSTheme.background, in: RoundedRectangle(cornerRadius: BSTheme.smallCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BSTheme.smallCornerRadius, style: .continuous)
                .strokeBorder(BSTheme.border)
        }
    }

    // MARK: Step 6 — AI chooser (conditional, privacy-first)

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(
                systemImage: "brain",
                title: String(localized: "Which AI cleans up your text?", comment: "Onboarding AI chooser title"),
                explanation: String(localized: "Your engine transcribes; an AI does the cleanup. Local stays on your network.", comment: "Onboarding AI chooser explanation")
            )

            if isFullyLocal {
                StatusPill(
                    text: String(localized: "Runs entirely on this Mac", comment: "Onboarding fully-local badge"),
                    tint: .green,
                    systemImage: "lock.shield.fill"
                )
            }

            EmbeddedSettingsForm(height: 280) {
                Section {
                    // Local-first ordering (Ollama → CLIs → custom → Groq → …) and,
                    // until "More options" is opened, only the two recommended picks
                    // (Ollama-if-reachable + free Groq) so a new user isn't buried
                    // under the full provider list. The recommended pick stays
                    // pre-selected, so they can just continue.
                    LLMSelectionPicker(
                        selection: $draft.defaultLLM,
                        customEndpoints: draft.customEndpoints,
                        allowsDefault: false,
                        installedCLITools: installedCLITools,
                        localFirst: true,
                        recommendedOnly: !aiMoreOptionsExpanded
                    )

                    aiProviderNote
                } header: {
                    Text("Cleanup model", comment: "Onboarding AI section header")
                } footer: {
                    aiRecommendationFooter
                }

                if aiMoreOptionsExpanded {
                    // Expanded: the picker now also lists the CLIs + the extra cloud
                    // providers; the custom-endpoint editor appears alongside them.
                    CustomEndpointsSection(draft: $draft)
                } else {
                    Section {
                        Button {
                            aiMoreOptionsExpanded = true
                        } label: {
                            Label {
                                Text("More options", comment: "Onboarding AI more-options disclosure")
                            } icon: {
                                Image(systemName: "chevron.down")
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .onAppear {
            // If a returning user already picked one of the gated secondary
            // providers, open the disclosure so the picker shows their selection
            // (a collapsed picker only lists Ollama + Groq and would render blank).
            if currentLLMIsGated { aiMoreOptionsExpanded = true }
        }
    }

    /// Privacy/no-key footnote mirroring VaraSettingsView's Intelligence section,
    /// so the AI step explains the chosen provider without re-implementing it.
    @ViewBuilder
    private var aiProviderNote: some View {
        if let provider = draft.defaultLLM?.provider {
            switch provider {
            case .ollama:
                Label {
                    Text("On this Mac or your network — e.g. your DGX. Nothing goes to the cloud.", comment: "Onboarding Ollama note")
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .font(.caption)
                .foregroundStyle(.green)
            case .claudeCLI, .codexCLI, .geminiCLI:
                Label {
                    Text("No key needed — uses your \(provider.displayTitle) subscription · slower.", comment: "Onboarding CLI provider note")
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .font(.caption)
                .foregroundStyle(.green)
            case .openAI, .groq, .anthropic, .gemini:
                if !aiReady(draft.defaultLLM) {
                    Label {
                        Text("Add a \(provider.displayTitle) key to use this — or pick Skip.", comment: "Onboarding AI missing-key note")
                    } icon: {
                        Image(systemName: "key.horizontal")
                    }
                    .font(.caption)
                    .foregroundStyle(BSTheme.stateError)
                }
            case .custom:
                EmptyView()
            }
        }
    }

    /// Whether the currently-selected cleanup LLM is one of the "More options"
    /// gated providers (anything other than the two always-visible recommended
    /// picks, Ollama + Groq). Used to auto-open the disclosure so the selection
    /// is never hidden behind a collapsed picker.
    private var currentLLMIsGated: Bool {
        guard let provider = draft.defaultLLM?.provider else { return false }
        switch provider {
        case .ollama, .groq:
            return false
        case .openAI, .anthropic, .gemini, .claudeCLI, .codexCLI, .geminiCLI, .custom:
            return true
        }
    }

    @ViewBuilder
    private var aiRecommendationFooter: some View {
        if state.ollamaReachable == true {
            Text("Ollama is reachable — recommended for a fully private setup. Groq is free if you'd rather use a key.", comment: "Onboarding AI footer: Ollama reachable")
        } else {
            Text("Groq is free and fast. Or run Ollama on this Mac or your network to stay fully private.", comment: "Onboarding AI footer: Groq")
        }
    }

    // MARK: Step 7 — Ready (confirmation beat)

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

            if isFullyLocal {
                StatusPill(
                    text: String(localized: "Runs entirely on this Mac", comment: "Onboarding fully-local badge"),
                    tint: .green,
                    systemImage: "lock.shield.fill"
                )
                .opacity(readyRevealed ? 1 : 0)
            }

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

    // MARK: Step 8 — Try it

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
                            step = previousStep(before: step)
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
                    .disabled(!engineReady(selectedEngine))
                } else {
                    Button {
                        withAnimation(.spring(duration: 0.35)) {
                            step = nextStep(after: step)
                        }
                    } label: {
                        primaryButtonTitle
                    }
                    // Per-step readiness; "Skip" stays the escape hatch for slow
                    // out-of-app local setup.
                    .disabled(!canLeaveCurrentStep)
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
        case .engine: Text("Set up", comment: "Onboarding primary button: engine")
        case .setup: Text("Continue", comment: "Onboarding primary button: setup")
        case .mode: Text("Continue", comment: "Onboarding primary button: mode")
        case .ai: Text("Continue", comment: "Onboarding primary button: ai")
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

    // MARK: Navigation

    /// The next step in the order, hopping over the AI step when it shouldn't be
    /// shown (the engine already bundles an LLM).
    private func nextStep(after current: Step) -> Step {
        var candidate = Step(rawValue: current.rawValue + 1) ?? .tryIt
        if candidate == .ai, !shouldShowAIStep {
            candidate = Step(rawValue: candidate.rawValue + 1) ?? .tryIt
        }
        return candidate
    }

    /// The previous step in the order, hopping over the AI step when skipped.
    private func previousStep(before current: Step) -> Step {
        var candidate = Step(rawValue: current.rawValue - 1) ?? .welcome
        if candidate == .ai, !shouldShowAIStep {
            candidate = Step(rawValue: candidate.rawValue - 1) ?? .welcome
        }
        return candidate
    }

    /// Whether the conditional AI step is shown: the chosen mode uses an LLM
    /// (not Raw) AND the chosen STT engine does NOT already bundle an LLM. Groq
    /// and OpenAI STT bundle their own cleanup from the one key, so they skip it;
    /// local engines and ElevenLabs (cloud STT, no LLM) need a separate AI pick.
    private var shouldShowAIStep: Bool {
        let usesLLM = selectedModeID != DictationMode.rawModeID
        let bundlesLLM = !(selectedEngine.isLocal || selectedEngine == .elevenLabsScribe)
        return usesLLM && !bundlesLLM
    }

    /// Whether the primary CTA may advance from the current step.
    private var canLeaveCurrentStep: Bool {
        switch step {
        case .welcome: true
        case .permissions: bothPermissionsGranted
        case .engine: true
        // Skip stays the bypass for slow out-of-app local setup.
        case .setup: engineReady(selectedEngine)
        case .mode: true
        case .ai: aiReady(draft.defaultLLM)
        case .ready: true
        case .tryIt: engineReady(selectedEngine)
        }
    }

    // MARK: Engine selection + readiness

    /// Writes the chosen speech backend immediately (so AppState reconfigures the
    /// backend and starts background prewarm), and seeds the cleanup layer:
    /// Groq/OpenAI carry a bundled LLM + Clean text from the one key; local and
    /// ElevenLabs default to Raw until the AI step is reached.
    private func selectEngine(_ engine: VaraSpeechBackendChoice) {
        selectedEngine = engine
        let bundlesLLM = !(engine.isLocal || engine == .elevenLabsScribe)
        // The LLM the bundled-key engines carry, computed once so it can be written
        // to BOTH settings AND the draft. Writing only settings would be clobbered:
        // the `draft.speechBackend = engine` line below fires `.onChange(of: draft)`,
        // which mirrors the STALE `draft.defaultLLM` back over settings. Seeding the
        // draft here makes that round-trip a no-op. nil = non-bundling engines, whose
        // draft.defaultLLM is left untouched (the AI step owns it).
        let bundledLLM: LLMSelection?
        switch engine {
        case .groqWhisper:
            bundledLLM = LLMSelection(provider: .groq, model: LLMProvider.groq.defaultModel)
        case .openAIGPT4OMiniTranscribe20251215, .openAIGPT4OTranscribe, .openAIRealtimeWhisper:
            bundledLLM = LLMSelection(provider: .openAI, model: LLMProvider.openAI.defaultModel)
        case .localWhisperKit, .localHviske, .elevenLabsScribe:
            bundledLLM = nil
        }
        state.updateSettings { settings in
            settings.speechBackend = engine
            if let bundledLLM {
                settings.defaultLLM = bundledLLM
                settings.selectedModeID = DictationMode.cleanModeID
            } else {
                // No bundled LLM yet — start at Raw so a local-only user is
                // immediately usable; the mode/AI steps can upgrade to Clean text.
                settings.selectedModeID = DictationMode.rawModeID
            }
        }
        // Keep the local mirror in sync with what we just wrote.
        selectedModeID = bundlesLLM ? DictationMode.cleanModeID : DictationMode.rawModeID
        // Seed the draft's LLM to match settings for bundling engines so the
        // onChange round-trip can't reset settings.defaultLLM. Non-bundling engines
        // keep whatever the draft (and AI step) already hold.
        if let bundledLLM {
            draft.defaultLLM = bundledLLM
        }
        draft.speechBackend = engine
        engineAPIKey = currentEngineKey()
    }

    private func currentEngineKey() -> String {
        guard let provider = selectedEngine.credentialProvider else { return "" }
        return state.savedCredential(for: provider)
    }

    private func engineHasKey(_ engine: VaraSpeechBackendChoice) -> Bool {
        guard let provider = engine.credentialProvider else { return false }
        return hasCredential(provider)
    }

    private func hasCredential(_ provider: VaraCredentialProvider) -> Bool {
        if !state.savedCredential(for: provider).isEmpty { return true }
        return ((try? EnvLoader.resolveForApp(provider.environmentVariableName)) ?? "").isEmpty == false
    }

    /// Whether the chosen engine can actually transcribe right now. Cloud engines
    /// need a key (saved or in ~/.vara/.env); WhisperKit needs its model on disk
    /// (prewarm continues in the background, not required to finish); Hviske needs
    /// its runtime ready. Gates leaving the setup step and finishing.
    private func engineReady(_ engine: VaraSpeechBackendChoice) -> Bool {
        // Touch keyStateRevision so saving a key re-evaluates this gate (it reads
        // the keychain, not an observable property).
        _ = keyStateRevision
        if let provider = engine.credentialProvider {
            return hasCredential(provider)
        }
        switch engine {
        case .localWhisperKit:
            return WhisperKitBackend.isModelDownloaded(draft.whisperKitModel)
        case .localHviske:
            return LocalHviskeBackend.runtimeStatus().isReady
        default:
            return true
        }
    }

    /// Whether the chosen cleanup AI is usable. Raw/no LLM is always fine; a CLI
    /// must be installed; a cloud provider needs a key; Ollama is assumed reachable
    /// (the probe is best-effort) and a custom endpoint must exist.
    private func aiReady(_ selection: LLMSelection?) -> Bool {
        _ = keyStateRevision
        guard let provider = selection?.provider else { return true }
        switch provider {
        case .ollama:
            return state.ollamaReachable ?? true
        case .claudeCLI:
            return installedCLITools.contains(.claude)
        case .codexCLI:
            return installedCLITools.contains(.codex)
        case .geminiCLI:
            return installedCLITools.contains(.gemini)
        case .openAI:
            return hasCredential(.openAI)
        case .groq:
            return hasCredential(.groq)
        case .anthropic:
            return hasCredential(.anthropic)
        case .gemini:
            return hasCredential(.gemini)
        case .custom(let endpointID):
            return draft.customEndpoints.contains { $0.id == endpointID }
        }
    }

    /// True when both the STT engine and the cleanup LLM stay on this Mac / the
    /// local network — feeds the "Runs entirely on this Mac" payoff. Raw cleanup
    /// (no LLM) on a local engine also counts as fully local.
    private var isFullyLocal: Bool {
        guard selectedEngine.isLocal else { return false }
        if let provider = draft.defaultLLM?.provider, selectedModeID != DictationMode.rawModeID {
            return provider.runsLocally
        }
        return true
    }

    // MARK: Mode selection

    private let builtInModeOrder: [UUID] = [
        DictationMode.rawModeID,
        DictationMode.cleanModeID,
        DictationMode.professionalModeID,
        DictationMode.vibeCodeModeID,
        DictationMode.askAIModeID,
    ]

    /// The adaptive recommended mode: Clean text when an LLM is available (a cloud
    /// STT key powers cleanup, or an AI provider will be chosen), else Raw.
    private var recommendedModeID: UUID {
        let llmAvailable = !(selectedEngine.isLocal || selectedEngine == .elevenLabsScribe)
            || state.ollamaReachable == true
        return llmAvailable ? DictationMode.cleanModeID : DictationMode.rawModeID
    }

    private func selectMode(_ modeID: UUID) {
        selectedModeID = modeID
        state.updateSettings { settings in
            settings.selectedModeID = modeID
        }
    }

    private func modeTitle(_ modeID: UUID) -> String {
        switch modeID {
        case DictationMode.rawModeID: String(localized: "Raw", comment: "Onboarding mode title")
        case DictationMode.cleanModeID: String(localized: "Clean text", comment: "Onboarding mode title")
        case DictationMode.professionalModeID: String(localized: "Professional", comment: "Onboarding mode title")
        case DictationMode.vibeCodeModeID: String(localized: "VibeCode", comment: "Onboarding mode title")
        case DictationMode.askAIModeID: String(localized: "Ask AI", comment: "Onboarding mode title")
        default: ""
        }
    }

    private func modeSubtitle(_ modeID: UUID) -> String {
        switch modeID {
        case DictationMode.rawModeID:
            String(localized: "Your words, exactly as said — no AI", comment: "Onboarding mode subtitle: raw")
        case DictationMode.cleanModeID:
            String(localized: "Fixes filler words and punctuation, keeps your wording", comment: "Onboarding mode subtitle: clean")
        case DictationMode.professionalModeID:
            String(localized: "Tightens to a clear, professional tone", comment: "Onboarding mode subtitle: professional")
        case DictationMode.vibeCodeModeID:
            String(localized: "For dictating code and technical notes", comment: "Onboarding mode subtitle: vibecode")
        case DictationMode.askAIModeID:
            String(localized: "Answers your question instead of writing it down", comment: "Onboarding mode subtitle: ask ai")
        default: ""
        }
    }

    private func modeSymbol(_ modeID: UUID) -> String {
        switch modeID {
        case DictationMode.rawModeID: "waveform"
        case DictationMode.cleanModeID: "sparkles"
        case DictationMode.professionalModeID: "briefcase"
        case DictationMode.vibeCodeModeID: "chevron.left.forwardslash.chevron.right"
        case DictationMode.askAIModeID: "questionmark.bubble"
        default: "circle"
        }
    }

    // MARK: Recap helpers

    private var bothPermissionsGranted: Bool {
        microphoneStatus == .authorized && accessibilityGranted
    }

    /// Setup-step title, routed by the chosen engine.
    private var setupTitle: String {
        switch selectedEngine {
        case .localWhisperKit:
            String(localized: "Download the on-device model", comment: "Onboarding setup title: WhisperKit")
        case .localHviske:
            String(localized: "Set up Hviske on this Mac", comment: "Onboarding setup title: Hviske")
        default:
            String(localized: "Add your key", comment: "Onboarding setup title: cloud key")
        }
    }

    private var setupExplanation: String {
        switch selectedEngine {
        case .localWhisperKit:
            String(localized: "Downloads once, then runs entirely on your Mac — no internet needed.", comment: "Onboarding setup explanation: WhisperKit")
        case .localHviske:
            String(localized: "Run one setup command in Terminal, then Vara detects it here.", comment: "Onboarding setup explanation: Hviske")
        default:
            String(localized: "Your key powers transcription. It is stored in your Keychain.", comment: "Onboarding setup explanation: cloud key")
        }
    }

    /// Engine name for the Ready recap, read from the connected settings.
    private var connectedEngineTitle: String {
        state.settings.speechBackend.shortTitle
    }

    /// Cleanup model for the Ready recap, or "Raw" when no LLM is configured.
    private var cleanupTitle: String {
        if state.settings.selectedModeID == DictationMode.rawModeID {
            return String(localized: "Raw", comment: "Onboarding recap: no cleanup model")
        }
        if let llm = state.settings.defaultLLM {
            return "\(llm.provider.displayTitle) · \(llm.model)"
        }
        return String(localized: "Raw", comment: "Onboarding recap: no cleanup model")
    }

    /// Where to get a key for a provider, so a user isn't stuck with a key field
    /// and no way to fill it. Groq's is free — the zero-cost default.
    private func keySignupURL(for provider: VaraCredentialProvider) -> URL? {
        switch provider {
        case .groq: URL(string: "https://console.groq.com/keys")
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        }
    }

    /// "Get a free key" link beside a provider's key field. Groq is highlighted
    /// as free; others just link to where the key is created.
    @ViewBuilder
    private func getKeyLink(for provider: VaraCredentialProvider) -> some View {
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

/// A list row for one speech engine in the onboarding engine chooser. A small
/// privacy-first row (NOT the Settings grid `EngineCard`): symbol, title,
/// subtitle, badges, with an ember-gold border + teal check when selected.
/// Mirrors the Connect step's selection chrome so it isn't duplicated.
private struct EngineRow: View {
    let backend: VaraSpeechBackendChoice
    let isSelected: Bool
    let hasKey: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: backend.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? BSTheme.cyan : BSTheme.teal)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(backend.onboardingTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)

                        ForEach(badges, id: \.text) { badge in
                            Text(badge.text)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(badge.tint.opacity(0.14), in: Capsule())
                                .foregroundStyle(badge.tint)
                        }

                        if hasKey {
                            Text("Key ✓", comment: "Onboarding engine badge: key present")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.14), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }

                    Text(backend.onboardingSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BSTheme.cyan)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private struct Badge { let text: String; let tint: Color }

    /// Per-engine badges (free / recommended / advanced / your key), driven off
    /// BackendMetadata tier + the privacy-first ordering.
    private var badges: [Badge] {
        var result: [Badge] = []
        switch backend {
        case .localWhisperKit:
            result.append(Badge(text: String(localized: "Free", comment: "Onboarding engine badge: free"), tint: .green))
            result.append(Badge(text: String(localized: "Recommended", comment: "Onboarding engine badge: recommended"), tint: BSTheme.emberGlow))
        case .localHviske:
            result.append(Badge(text: String(localized: "Advanced", comment: "Onboarding engine badge: advanced"), tint: BSTheme.tealLight))
        case .groqWhisper:
            result.append(Badge(text: String(localized: "Free", comment: "Onboarding engine badge: free"), tint: .green))
        case .elevenLabsScribe, .openAIRealtimeWhisper, .openAIGPT4OTranscribe, .openAIGPT4OMiniTranscribe20251215:
            result.append(Badge(text: String(localized: "Your key", comment: "Onboarding engine badge: your key"), tint: BSTheme.teal))
        }
        return result
    }
}

/// A list row for one cleanup mode in the onboarding mode picker. Icon, title,
/// subtitle, an Offline badge for Raw, ember border + check when selected, and an
/// optional expanded example slot (used by Clean text).
private struct ModeRow<Expanded: View>: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let isSelected: Bool
    let isOffline: Bool
    let isRecommended: Bool
    let select: () -> Void
    @ViewBuilder let expandedContent: () -> Expanded

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? BSTheme.cyan : BSTheme.teal)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)

                            if isRecommended {
                                Text("Recommended", comment: "Onboarding mode badge: recommended")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(BSTheme.emberGlow.opacity(0.14), in: Capsule())
                                    .foregroundStyle(BSTheme.emberGlow)
                            }

                            if isOffline {
                                Text("Offline", comment: "Onboarding mode badge: offline")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }

                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(BSTheme.cyan)
                    }
                }

                expandedContent()
                    .padding(.leading, 36)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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

/// Hosts the Section-based Settings components (WhisperKit / Hviske / custom
/// endpoints / LLM picker) inside the free-form onboarding canvas. Those views
/// are `Section`s that only render correctly inside `Form { … }.formStyle(.grouped)`,
/// so this wraps them in a fixed-height, clipped, themed container.
private struct EmbeddedSettingsForm<Content: View>: View {
    var height: CGFloat = 320
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(height: height)
        .background(BSTheme.surface, in: RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous)
                .strokeBorder(BSTheme.border)
        }
        .clipShape(RoundedRectangle(cornerRadius: BSTheme.cornerRadius, style: .continuous))
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
