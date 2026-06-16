import AppKit
import AVFoundation
import Foundation
import VaraCore

// The push-to-talk dictation flow: begin/end/toggle/cancel, the DictationSession
// builder and LLM processor, HUD presentation, and the audio instrumentation,
// timeout and redaction helpers those use.
extension AppState {
    func cancelDictation() {
        guard let dictationSession else { return }
        log("Cancelling dictation")
        // Bump the generation FIRST so any in-flight forge's late result (paste +
        // history append) is dropped on arrival — see `dictationGeneration`. This
        // is the authoritative guard: cancelling `forgingTask` can't stop an
        // uncancellable WhisperKit inference or a paste already mid-flight.
        dictationGeneration &+= 1
        let wasForging = isTranscribing
        isRecording = false
        isTranscribing = false
        // Abandon the stored forge task (best-effort; a cancellable network LLM
        // step aborts, an uncancellable inference is simply ignored).
        forgingTask?.cancel()
        forgingTask = nil
        if wasForging {
            // During forging the session is .transcribing/.inserting, so
            // `cancelRecording()` would no-op. Drive the cancelled HUD directly
            // instead and insert NOTHING — Esc/click during forge means cancel.
            activeModeOverride = nil
            activeAppRuleMode = nil
            statusMessage = readyStatusMessage
            log("Dictation cancelled during forging")
            hudState.phase = .cancelled
            hideHUDAfterDelay()
            runDeferredReloadIfNeeded()
            return
        }
        // Cancelling while still recording: let the session discard the audio.
        // Do NOT await the abandoned forge task here.
        Task { @MainActor [weak self] in
            let result = await dictationSession.cancelRecording()
            self?.apply(commandResult: result)
        }
    }

    func toggleDictationFromMenu() {
        log("Dictation toggle requested. isRecording=\(isRecording), isTranscribing=\(isTranscribing)")
        if isRecording {
            endDictationInteraction()
        } else {
            beginDictationInteraction()
        }
    }

    /// Changes the default mode. Only `activeMode` (and the HUD, if a dictation
    /// is in flight) depend on the selection — the backend and hotkey do not — so
    /// this deliberately does NOT post `.varaSettingsDidChange`, which would
    /// rebuild the backend/hotkey and could strand an in-progress recording.
    func selectMode(_ mode: DictationMode) {
        guard settings.selectedModeID != mode.id else { return }
        settings.selectedModeID = mode.id
        try? settingsStore.save(settings)
        log("Selected mode: \(mode.name)")
        // Reflect the new default in the HUD if it would now be the active mode
        // (no digit override or per-app rule taking precedence).
        if isRecording, activeModeOverride == nil, activeAppRuleMode == nil {
            hudState.modeTitle = mode.displayTitle
            hudState.modeSymbol = mode.symbolName
        }
    }

    /// Records which app the dictation targets and applies a matching
    /// per-app mode rule, if one exists and its LLM is configured.
    private func captureDictationTarget() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        dictationTargetAppName = frontmost?.localizedName
        activeAppRuleMode = nil

        if let bundleID = frontmost?.bundleIdentifier,
           let rule = settings.appModeRules.first(where: { $0.bundleID == bundleID }),
           let ruleMode = settings.modes.first(where: { $0.id == rule.modeID }) {
            if isModeReady(ruleMode) {
                activeAppRuleMode = ruleMode
                log("App rule applied: \(rule.appName) → \(ruleMode.name)")
            } else {
                log("App rule for \(rule.appName) skipped — mode '\(ruleMode.name)' is not configured")
            }
        }
    }

    func makeDictationSession(backend: any SpeechToTextBackend) -> DictationSession {
        let languageCode = settings.language.languageCode
        let pasteAutomatically = settings.pasteAutomatically
        let pendingHistory = pendingHistory
        let timeoutSeconds = backend.capabilities.runsLocally
            ? 180.0
            : (backend.capabilities.supportsStreamingTranscription ? 30.0 : 120.0)
        // The long transcription budget stays (a first WhisperKit model download
        // genuinely needs it) now that .forging is escapable, but the LLM cleanup
        // gets a tighter 15s local budget so a hung Ollama/DGX falls back to the
        // raw transcript faster; network backends answer fast so 20s is plenty.
        // Either way the words are kept — the timeout always falls back to raw.
        //
        // A CLI provider (claude/codex/gemini) is far slower — ~6-16s typical — so
        // a 15/20s budget would trip on a normal run and defeat the feature. When
        // the default OR any available mode could resolve to a CLI provider, raise
        // the ceiling to 60s. Because the timeout only ever falls back to raw
        // (never loses words), the broad check is low-risk; a per-digit override
        // to a CLI mode that wasn't anticipated just gets the 15/20s budget and
        // falls back to raw — annoying, not data-losing.
        let usesCLIProvider = (settings.defaultLLM?.provider.isCLI ?? false)
            || settings.modes.contains { $0.llm?.provider.isCLI == true }
        let llmTimeoutSeconds: Double
        if usesCLIProvider {
            llmTimeoutSeconds = 60.0
        } else {
            llmTimeoutSeconds = backend.capabilities.runsLocally ? 15.0 : 20.0
        }
        let instrumentAudio: @Sendable (SpeechToTextAudio) -> SpeechToTextAudio = { [weak self] audio in
            Self.instrument(audio: audio) { message in
                await MainActor.run { self?.log(message) }
            }
        }
        // Snapshot the vocabulary-biasing terms at session-build time; the
        // transcribe closure threads them onto every request. Backends that
        // can't use them (OpenAI realtime, WhisperKit) ignore them.
        let vocabulary = settings.vocabulary
        // Snapshot of mode + processor taken at transcription time so digit
        // overrides during the recording take effect.
        let resolveProcessing: @Sendable () async -> (DictationMode, DictationModeProcessor, String?)? = { [weak self] in
            await MainActor.run {
                guard let self else { return nil }
                return (self.activeMode, self.makeModeProcessor(), self.dictationTargetAppName)
            }
        }
        // The generation this forge belongs to, read live on the MainActor and
        // stamped onto the history entry. A cancel can land between any check here
        // and `apply`, so the enqueue itself cannot be reliably gated; instead the
        // save side drains entries whose generation is no longer current. (Because
        // the session is `isBusy` while forging, no second forge can overlap, so
        // `activeForgeGeneration` is stable for the life of this forge.)
        let forgeGeneration: @Sendable () async -> Int = { [weak self] in
            await MainActor.run { self?.activeForgeGeneration ?? 0 }
        }
        let recorder = MicrophoneDictationAudioRecorder(onLevel: { [weak self] level in
            Task { @MainActor in
                self?.hudState.pushLevel(level)
            }
        }, onDiagnostic: { [weak self] message in
            Task { @MainActor in self?.log(message) }
        })

        return DictationSession(
            mode: .pushToTalk,
            recorder: recorder,
            languageCode: languageCode,
            transcribe: { [weak self] request in
                // One sendable logger for the whole closure so we don't repeatedly
                // capture `self` across the sending boundaries of `withTimeout`.
                let logMessage: @Sendable (String) async -> Void = { message in
                    await MainActor.run { self?.log(message) }
                }
                // Tee the captured audio to a recoverable temp file as it flows
                // to the backend. The one-shot stream is consumed during
                // transcription, so if transcription FAILS this file is the only
                // copy left — without it the user's words would vanish silently.
                let recoverable = RecoverableAudioCapture(audio: request.audio, log: logMessage)
                let instrumentedRequest = SpeechToTextRequest(
                    audio: instrumentAudio(recoverable.audio),
                    languageCode: request.languageCode,
                    vocabulary: vocabulary
                )

                let rawResult: TranscriptionResult
                do {
                    rawResult = try await Self.withTimeout(seconds: timeoutSeconds) {
                        try await backend.transcribe(instrumentedRequest)
                    }
                } catch {
                    // Transcription failed/timed out. Keep the captured audio so
                    // the dictation is recoverable, log its path, and surface a
                    // clear message — never a silent loss.
                    let savedPath = await recoverable.finalizeForRecovery()
                    if let savedPath {
                        await logMessage("Transcription failed: \(error). Captured audio kept at \(savedPath)")
                    } else {
                        await logMessage("Transcription failed: \(error). No audio could be recovered.")
                    }
                    throw DictationTranscriptionFailure(
                        underlying: error,
                        recoveredAudioPath: savedPath
                    )
                }

                // Transcription succeeded — the captured audio is no longer
                // needed, so discard the recovery file.
                await recoverable.discard()

                guard let (mode, processor, targetAppName) = await resolveProcessing() else {
                    return rawResult
                }
                // Wrap the LLM cleanup in a timeout: a hung Ollama/DGX must never
                // freeze the HUD in 'forging' with the words trapped. On timeout
                // (or any failure) we fall through to the RAW transcript.
                let outcome: DictationModeOutcome
                do {
                    outcome = try await Self.withTimeout(seconds: llmTimeoutSeconds) {
                        await processor.process(transcript: rawResult.text, mode: mode)
                    }
                } catch {
                    await logMessage("LLM step timed out; inserting raw transcript")
                    outcome = DictationModeOutcome(
                        text: rawResult.text,
                        usedLLM: false,
                        llmErrorDescription: "LLM timed out"
                    )
                }
                if let llmError = outcome.llmErrorDescription {
                    // The raw transcript is inserted instead — never lose words.
                    // `llmError` may carry an HTTP body that echoes the
                    // transcript, so redact it before it reaches debug.log.
                    let safeError = Self.redactedLogDescription(llmError)
                    await logMessage("LLM step fell back to raw transcript: \(safeError)")
                }

                // Always enqueue, stamped with this forge's generation. If the
                // user cancelled during forging, `apply` drops the result without
                // saving and the matching `take(matching:)` later drains this
                // orphan — so a cancelled dictation never reaches history and the
                // FIFO stays balanced regardless of when the cancel lands.
                let forgeGen = await forgeGeneration()
                await pendingHistory.replace(
                    PendingDictationHistoryEntry(
                        rawResult: rawResult,
                        outcome: outcome,
                        modeName: mode.displayTitle,
                        targetAppName: targetAppName,
                        requestedLanguage: request.languageCode,
                        generation: forgeGen
                    )
                )
                return TranscriptionResult(
                    text: outcome.text,
                    detectedLanguage: rawResult.detectedLanguage,
                    languageConfidence: rawResult.languageConfidence,
                    audioDurationSeconds: rawResult.audioDurationSeconds,
                    elapsedSeconds: rawResult.elapsedSeconds,
                    backend: rawResult.backend,
                    rawJSON: rawResult.rawJSON
                )
            },
            textSink: { [weak self] text in
                guard pasteAutomatically else { return }
                await MainActor.run {
                    guard let self else { return }
                    // Drop a late paste from an abandoned forge: if the user
                    // cancelled (or started a new interaction) the generation has
                    // moved past the one this interaction owns, so pasting now
                    // would dump text the user explicitly cancelled.
                    guard self.dictationGeneration == self.activeForgeGeneration else {
                        self.log("Paste dropped — dictation was cancelled during forging")
                        return
                    }
                    ClipboardPaster.pasteAtCursor(text: text)
                    self.log("Inserted transcript using cursor paste")
                }
            }
        )
    }

    /// Builds the LLM processor with credentials resolved lazily so keychain
    /// access happens off the hot path only when a mode actually needs an LLM.
    private func makeModeProcessor() -> DictationModeProcessor {
        DictationModeProcessor(
            defaultLLM: settings.defaultLLM,
            makeChatClient: Self.chatClientFactory(
                credentialStore: credentialStore,
                customEndpoints: settings.customEndpoints
            )
        )
    }

    nonisolated private static func chatClientFactory(
        credentialStore: VaraKeychainCredentialStore,
        customEndpoints: [CustomLLMEndpoint]
    ) -> DictationModeProcessor.ChatClientFactory {
        { selection in
            switch selection.provider {
            case .openAI:
                let key = try Self.resolveLLMKey(credentialStore, .openAI, env: "OPENAI_API_KEY")
                return OpenAICompatibleChatClient(
                    id: "openai",
                    baseURL: LLMProvider.openAI.defaultBaseURL!,
                    apiKey: key,
                    model: selection.model
                )
            case .groq:
                let key = try Self.resolveLLMKey(credentialStore, .groq, env: "GROQ_API_KEY")
                return OpenAICompatibleChatClient(
                    id: "groq",
                    baseURL: LLMProvider.groq.defaultBaseURL!,
                    apiKey: key,
                    model: selection.model
                )
            case .anthropic:
                let key = try Self.resolveLLMKey(credentialStore, .anthropic, env: "ANTHROPIC_API_KEY")
                return AnthropicChatClient(apiKey: key, model: selection.model)
            case .ollama:
                return OpenAICompatibleChatClient(
                    id: "ollama",
                    baseURL: LLMProvider.ollama.defaultBaseURL!,
                    apiKey: nil,
                    model: selection.model
                )
            case .gemini:
                // Google's OpenAI-compatible endpoint: same client shape as the
                // openAI/groq cases, just a different base URL + key.
                let key = try Self.resolveLLMKey(credentialStore, .gemini, env: "GEMINI_API_KEY")
                return OpenAICompatibleChatClient(
                    id: "gemini",
                    baseURL: LLMProvider.gemini.defaultBaseURL!,
                    apiKey: key,
                    model: selection.model
                )
            case .claudeCLI, .codexCLI, .geminiCLI:
                // Shell out to the installed coding CLI under the user's own
                // subscription — no API key. The provider's `cliTool` names which
                // binary; `selection.model` stays the authoritative model string.
                guard let tool = selection.provider.cliTool else {
                    throw LLMConfigurationError.unknownCustomEndpoint
                }
                return CLIChatClient(tool: tool, model: selection.model)
            case .custom(let endpointID):
                guard let endpoint = customEndpoints.first(where: { $0.id == endpointID }),
                      let baseURL = endpoint.baseURL else {
                    throw LLMConfigurationError.unknownCustomEndpoint
                }
                let key = endpoint.requiresAPIKey
                    ? try credentialStore.credential(forCustomEndpoint: endpointID)
                    : nil
                return OpenAICompatibleChatClient(
                    id: endpoint.name,
                    baseURL: baseURL,
                    apiKey: key,
                    model: selection.model
                )
            }
        }
    }

    nonisolated private static func resolveLLMKey(
        _ store: VaraKeychainCredentialStore,
        _ provider: VaraCredentialProvider,
        env: String
    ) throws -> String {
        if let key = try? store.credential(for: provider), !key.isEmpty {
            return key
        }
        if let key = try? EnvLoader.resolveForApp(env), !key.isEmpty {
            return key
        }
        throw LLMConfigurationError.missingAPIKey(provider: provider.rawValue)
    }

    func beginDictationInteraction() {
        guard let dictationSession else {
            log("Begin dictation requested, but session is missing. Reloading configuration.")
            reloadConfiguration()
            return
        }
        guard ensureMicrophonePermissionBeforeRecording() else {
            return
        }
        captureDictationTarget()
        statusMessage = String(localized: "Starting the microphone …", comment: "Status message")
        log("Begin dictation interaction")
        Task { @MainActor [weak self] in
            let result = await dictationSession.beginInteraction()
            self?.apply(commandResult: result)
        }
    }

    func endDictationInteraction() {
        guard let dictationSession else {
            log("End dictation requested, but session is missing. Reloading configuration.")
            reloadConfiguration()
            return
        }
        if isRecording {
            statusMessage = String(localized: "Vara is forging the text …", comment: "Status while transcribing/cleaning")
            isTranscribing = true
            hudState.phase = .forging
            // Recompute fresh every forge (true OR false) so the flag never bleeds
            // into a later already-warm forge: show the one-time-prep title only
            // when WhisperKit is active AND not yet warm. Covers a cold dictation
            // that beats prewarm — it legitimately waits on the gate for the
            // compile, so the prep message is the correct thing to show.
            hudState.forgePreparingModel = (settings.speechBackend == .localWhisperKit && !whisperKitWarmState.isWarm)
            presentHUD()
        }
        isRecording = false
        log("End dictation interaction")
        // Take a fresh generation for this forge. The paste and `apply` paths
        // compare the live `dictationGeneration` against `activeForgeGeneration`;
        // a later cancel bumps `dictationGeneration` so this result is dropped.
        dictationGeneration &+= 1
        activeForgeGeneration = dictationGeneration
        let generation = dictationGeneration
        forgingTask = Task { @MainActor [weak self] in
            let result = await dictationSession.endInteraction()
            self?.apply(commandResult: result, generation: generation)
        }
    }

    /// Applies a session result to UI/HUD state. When `generation` is non-nil
    /// (the forge path), the result is dropped if the dictation generation has
    /// advanced since the forge launched — i.e. the user cancelled or started a
    /// new interaction. The non-forge callers (begin/cancel-while-recording) pass
    /// nil and always apply.
    private func apply(commandResult: DictationSessionCommandResult, generation: Int? = nil) {
        if let generation, generation != dictationGeneration {
            // Stale forge result — the interaction it belongs to was superseded.
            // Insert nothing, touch no HUD state; the cancel path already drove
            // the HUD to .cancelled.
            log("Forge result dropped — generation \(generation) superseded by \(dictationGeneration)")
            return
        }
        if generation != nil {
            // This forge has now settled; drop the handle so cancel doesn't try
            // to abandon an already-finished task.
            forgingTask = nil
        }
        switch commandResult {
        case .startedRecording:
            isRecording = true
            isTranscribing = false
            lastError = nil
            statusMessage = String(localized: "Vara is listening …", comment: "Status while recording")
            log("Recording started")
            let mode = activeMode
            hudState.modeTitle = mode.displayTitle
            hudState.modeSymbol = mode.symbolName
            hudState.beginRecording(startedAt: Date())
            presentHUD()
            playFeedbackSound("Tink", volume: 0.25)
        case .ignored:
            log("Dictation command ignored")
            return
        case .cancelled:
            isRecording = false
            isTranscribing = false
            activeModeOverride = nil
            activeAppRuleMode = nil
            statusMessage = readyStatusMessage
            log("Dictation cancelled")
            hudState.phase = .cancelled
            hideHUDAfterDelay()
            runDeferredReloadIfNeeded()
        case .completed(let insertedText):
            if let insertedText {
                lastTranscript = insertedText
            }
            isRecording = false
            isTranscribing = false
            activeModeOverride = nil
            activeAppRuleMode = nil
            statusMessage = readyStatusMessage
            let insertionStatus: DictationInsertionStatus = settings.pasteAutomatically ? .inserted : .notInserted
            // Save this forge's own entry by generation so any orphan left by a
            // cancelled forge is drained, never saved (see take(matching:)).
            let saveGeneration = generation ?? dictationGeneration
            Task { @MainActor [weak self] in
                await self?.savePendingHistory(insertionStatus: insertionStatus, generation: saveGeneration)
            }
            if let insertedText {
                log("Dictation completed. Inserted text length=\(insertedText.count), insertionStatus=\(insertionStatus.rawValue)")
                hudState.transcriptPreview = insertedText
                hudState.phase = .inserted(words: DictationStats.wordCount(of: insertedText))
                hideHUDAfterDelay()
                playFeedbackSound("Pop", volume: 0.3)
            } else {
                log("Dictation completed with empty transcript")
                statusMessage = String(localized: "Vara heard nothing", comment: "Status for empty transcript")
                hudState.phase = .heardNothing
                hideHUDAfterDelay(seconds: 2.0)
            }
            runDeferredReloadIfNeeded()
        case .failed(let message):
            isRecording = false
            isTranscribing = false
            activeModeOverride = nil
            activeAppRuleMode = nil
            // A transcription failure carries a friendly, body-free message and
            // notes that the captured audio was kept; other failures get a
            // generic message. Either way debug.log only sees a redacted line so
            // an HTTP body can never echo the transcript to disk.
            let userMessage = message
            lastError = userMessage
            statusMessage = String(localized: "Something went wrong", comment: "Status on dictation error")
            log("Dictation failed: \(Self.redactedLogDescription(message))")
            hudState.transcriptPreview = ""
            hudState.phase = .error(message: userMessage)
            hideHUDAfterDelay(seconds: 4.0)
            playFeedbackSound("Basso", volume: 0.25)
            runDeferredReloadIfNeeded()
        }
    }

    @discardableResult
    private func ensureMicrophonePermissionBeforeRecording() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphonePermissionStatus = Self.microphoneAuthorizationStatusTitle(status)
        log("Microphone permission check: \(microphonePermissionStatus)")

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            statusMessage = String(localized: "Grant microphone access", comment: "Status message")
            log("Requesting Microphone permission")
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                self?.microphonePermissionStatus = Self.microphoneAuthorizationStatusTitle()
                self?.log("Microphone permission response: granted=\(granted)")
                if granted {
                    self?.statusMessage = String(localized: "Microphone ready", comment: "Status message")
                    self?.beginDictationInteraction()
                } else {
                    self?.statusMessage = String(localized: "Grant microphone access in System Settings", comment: "Status message")
                }
            }
            return false
        case .denied:
            statusMessage = String(localized: "Grant microphone access in System Settings", comment: "Status message")
            lastError = "Microphone permission is denied for this Vara build."
            log("Microphone permission denied")
            return false
        case .restricted:
            statusMessage = String(localized: "Microphone is restricted", comment: "Status message")
            lastError = "Microphone permission is restricted by macOS."
            log("Microphone permission restricted")
            return false
        @unknown default:
            statusMessage = String(localized: "Microphone unavailable", comment: "Status message")
            lastError = "Unknown Microphone permission state."
            log("Microphone permission unknown status")
            return false
        }
    }

    /// Subtle audio confirmation for push-to-talk states; system sounds at
    /// low volume so they never dominate.
    private func playFeedbackSound(_ name: String, volume: Float) {
        guard settings.playSounds else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }

    private func presentHUD() {
        guard settings.showHUD else { return }
        hudController.show()
    }

    func hideHUD() {
        hudController.hide()
    }

    private func hideHUDAfterDelay(seconds: Double = 1.4) {
        let phaseAtSchedule = hudState.phase
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            // A new dictation may have started in the meantime — don't hide it.
            if self.hudState.phase == phaseAtSchedule {
                self.hideHUD()
            }
        }
    }

    nonisolated private static func instrument(
        audio: SpeechToTextAudio,
        log: @escaping @Sendable (String) async -> Void
    ) -> SpeechToTextAudio {
        switch audio {
        case .file:
            return audio
        case .pcm16Stream(let stream, let sampleRate):
            let streamID = String(UUID().uuidString.prefix(8))
            let (instrumentedStream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            Task.detached {
                await log("Audio stream \(streamID) opened. sampleRate=\(sampleRate)")
                var chunks = 0
                var bytes = 0
                var peak = 0
                var nonZeroBytes = 0

                for await chunk in stream {
                    chunks += 1
                    bytes += chunk.count
                    let chunkStats = pcm16Stats(chunk)
                    peak = max(peak, chunkStats.peak)
                    nonZeroBytes += chunkStats.nonZeroBytes

                    if chunks == 1 || chunks % 20 == 0 {
                        await log(
                            "Audio stream \(streamID) chunk=\(chunks), totalBytes=\(bytes), chunkBytes=\(chunk.count), peak=\(peak), nonZeroBytes=\(nonZeroBytes)"
                        )
                    }

                    continuation.yield(chunk)
                }

                continuation.finish()
                let duration = sampleRate > 0 ? Double(bytes / 2) / Double(sampleRate) : 0
                let durationText = String(format: "%.2f", duration)
                await log(
                    "Audio stream \(streamID) finished. chunks=\(chunks), bytes=\(bytes), duration=\(durationText)s, peak=\(peak), nonZeroBytes=\(nonZeroBytes)"
                )
            }
            return .pcm16Stream(instrumentedStream, sampleRate: sampleRate)
        }
    }

    nonisolated private static func pcm16Stats(_ data: Data) -> (peak: Int, nonZeroBytes: Int) {
        var peak = 0
        var nonZeroBytes = 0
        let bytes = [UInt8](data)

        for byte in bytes where byte != 0 {
            nonZeroBytes += 1
        }

        var index = 0
        while index + 1 < bytes.count {
            let unsignedSample = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            let sample = Int16(bitPattern: unsignedSample)
            let magnitude = sample == Int16.min ? Int(Int16.max) + 1 : abs(Int(sample))
            peak = max(peak, magnitude)
            index += 2
        }

        return (peak: peak, nonZeroBytes: nonZeroBytes)
    }

    /// Strips any HTTP response body from an already-stringified chat error
    /// before it is written to debug.log. `ChatClientError.httpError` formats as
    /// `"Chat completion HTTP <status>: <body>"`, and that body can echo the
    /// user's transcript — so we replace it with a byte count, mirroring
    /// `ChatClientError.redactedDescription`. Anything else passes through.
    nonisolated private static func redactedLogDescription(_ message: String) -> String {
        let marker = "Chat completion HTTP "
        guard let markerRange = message.range(of: marker),
              let colonRange = message.range(of: ": ", range: markerRange.upperBound..<message.endIndex) else {
            return message
        }
        let status = message[markerRange.upperBound..<colonRange.lowerBound]
        let body = message[colonRange.upperBound...]
        let byteCount = Data(body.utf8).count
        return "Chat completion HTTP \(status): <\(byteCount) bytes redacted>"
    }

    /// Runs `operation`, throwing `AppStateTimeoutError` if it does not finish in
    /// `seconds`. Unlike a structured task group — which on timeout would block
    /// until the operation child finishes — this races via a resume-once
    /// continuation: whichever of operation/timeout wins resumes the caller, and a
    /// stuck operation is ABANDONED rather than awaited. Critical for WhisperKit:
    /// a single CoreML inference can't be cancelled, so without this a hung model
    /// would freeze the dictation forever instead of falling back to raw.
    nonisolated private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let latch = ResumeOnceLatch()
        let opBox = CancellableTaskBox()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let timeout = Task {
                try? await Task.sleep(for: .seconds(seconds))
                if latch.claim() {
                    cont.resume(throwing: AppStateTimeoutError(seconds: seconds))
                    // Best-effort cancel of the in-flight operation: a cancellable
                    // network op (LLM cleanup over Ollama/DGX) aborts its request;
                    // an uncancellable CoreML inference ignores it and is simply
                    // abandoned (its later resume is dropped by the latch).
                    opBox.cancel()
                }
            }
            let op = Task {
                defer { timeout.cancel() }
                do {
                    let result = try await operation()
                    if latch.claim() { cont.resume(returning: result) }
                } catch {
                    if latch.claim() { cont.resume(throwing: error) }
                }
            }
            opBox.set(op)
        }
    }
}

/// One-shot latch so a `CheckedContinuation` is resumed exactly once when two
/// tasks (operation vs. timeout) race — resuming a continuation twice traps.
private final class ResumeOnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Thread-safe holder so the timeout task can cancel the operation task that is
/// created just after it (resolves the chicken-and-egg of two racing tasks).
private final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func set(_ task: Task<Void, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task }?.cancel() }
}
