import Foundation
import VaraCore

// Speech-to-text backend wiring: picks and builds the active backend and
// resolves the API keys each provider needs.
extension AppState {
    @discardableResult
    func configureBackend() -> Bool {
        switch settings.speechBackend {
        case .elevenLabsScribe:
            return configureElevenLabsBackend()
        case .groqWhisper:
            return configureGroqBackend()
        case .openAIRealtimeWhisper:
            return configureOpenAIRealtimeWhisperBackend()
        case .openAIGPT4OTranscribe:
            return configureOpenAIAudioTranscriptionBackend(
                modelID: "gpt-4o-transcribe",
                displayName: "OpenAI GPT-4o Transcribe"
            )
        case .openAIGPT4OMiniTranscribe20251215:
            return configureOpenAIAudioTranscriptionBackend(
                modelID: "gpt-4o-mini-transcribe-2025-12-15",
                displayName: "OpenAI GPT-4o Mini Transcribe 2025-12-15"
            )
        case .localHviske:
            return configureLocalHviskeBackend()
        case .localWhisperKit:
            return configureWhisperKitBackend()
        }
    }

    @discardableResult
    private func configureElevenLabsBackend() -> Bool {
        do {
            let key = try resolveElevenLabsAPIKey()
            let backend = ScribeRealtimeBackend(
                apiKey: key,
                diagnosticLog: { [weak self] message in
                    await MainActor.run { self?.log(message) }
                }
            )
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            lastError = nil
            log("ElevenLabs backend ready. API key source resolved without exposing key.")
            return true
        } catch {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Add an ElevenLabs API key in Settings", comment: "Status message")
            lastError = "\(error)"
            log("API key/backend setup failed: \(error)")
            return false
        }
    }

    @discardableResult
    private func configureGroqBackend() -> Bool {
        do {
            let key = try resolveGroqAPIKey()
            let backend = GroqWhisperBackend(apiKey: key)
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            lastError = nil
            statusMessage = readyStatusMessage
            log("Groq Whisper backend ready. API key source resolved without exposing key.")
            return true
        } catch {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Add a Groq API key in Settings", comment: "Status message")
            lastError = "\(error)"
            log("Groq API key/backend setup failed: \(error)")
            return false
        }
    }

    @discardableResult
    private func configureOpenAIAudioTranscriptionBackend(modelID: String, displayName: String) -> Bool {
        do {
            let key = try resolveOpenAIAPIKey()
            let backend = OpenAIAudioTranscriptionBackend(
                apiKey: key,
                modelID: modelID,
                displayName: displayName
            )
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            lastError = nil
            statusMessage = readyStatusMessage
            log("\(displayName) backend ready. API key source resolved without exposing key.")
            return true
        } catch {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Add an OpenAI API key in Settings", comment: "Status message")
            lastError = "\(error)"
            log("OpenAI API key/backend setup failed: \(error)")
            return false
        }
    }

    @discardableResult
    private func configureOpenAIRealtimeWhisperBackend() -> Bool {
        do {
            let key = try resolveOpenAIAPIKey()
            let backend = OpenAIRealtimeWhisperBackend(
                apiKey: key,
                diagnosticLog: { [weak self] message in
                    await MainActor.run { self?.log(message) }
                }
            )
            self.backend = backend
            dictationSession = makeDictationSession(backend: backend)
            lastError = nil
            statusMessage = readyStatusMessage
            log("OpenAI GPT Realtime Whisper backend ready. API key source resolved without exposing key.")
            return true
        } catch {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Add an OpenAI API key in Settings", comment: "Status message")
            lastError = "\(error)"
            log("OpenAI Realtime API key/backend setup failed: \(error)")
            return false
        }
    }

    @discardableResult
    private func configureLocalHviskeBackend() -> Bool {
        let runtimeStatus = LocalHviskeBackend.runtimeStatus()
        guard runtimeStatus.isReady else {
            backend = nil
            dictationSession = nil
            hotkey?.uninstall()
            hotkey = nil
            statusMessage = String(localized: "Set up Hviske in Terminal — see Settings > Advanced.", comment: "Status message when Hviske runtime is not set up")
            lastError = "Local Hviske runtime or model is missing."
            log("Local Hviske backend not ready. runtime=\(runtimeStatus.hasPythonRuntime), model=\(runtimeStatus.hasModelSnapshot), hfHome=\(runtimeStatus.hfHomeURL.path)")
            return false
        }

        let backend = LocalHviskeBackend(
            diagnosticLog: { [weak self] message in
                await MainActor.run { self?.log(message) }
            }
        )
        self.backend = backend
        dictationSession = makeDictationSession(backend: backend)
        lastError = nil
        statusMessage = readyStatusMessage
        log("Local Hviske backend ready. hfHome=\(runtimeStatus.hfHomeURL.path)")
        return true
    }

    @discardableResult
    private func configureWhisperKitBackend() -> Bool {
        // WhisperKit needs no key and no Terminal setup: the CoreML model is
        // fetched + cached automatically on the first dictation, so we can wire
        // the backend up eagerly. The (potentially slow) first-run download and
        // model load happen lazily inside the backend and are surfaced via the
        // diagnostic log.
        let model = settings.whisperKitModel
        let backend = WhisperKitBackend(
            model: model,
            diagnosticLog: { [weak self] message in
                await MainActor.run { self?.log(message) }
            }
        )
        self.backend = backend
        dictationSession = makeDictationSession(backend: backend)
        lastError = nil
        statusMessage = readyStatusMessage
        log("Local WhisperKit backend ready. model=\(model). Model downloads on first use to \(WhisperKitBackend.downloadBaseURL.path)")
        return true
    }

    private func resolveElevenLabsAPIKey() throws -> String {
        if let key = try credentialStore.credential(for: .elevenLabs), !key.isEmpty {
            return key
        }

        return try EnvLoader.resolveForApp("ELEVENLABS_API_KEY")
    }

    private func resolveGroqAPIKey() throws -> String {
        if let key = try credentialStore.credential(for: .groq), !key.isEmpty {
            return key
        }

        return try EnvLoader.resolveForApp("GROQ_API_KEY")
    }

    private func resolveOpenAIAPIKey() throws -> String {
        if let key = try credentialStore.credential(for: .openAI), !key.isEmpty {
            return key
        }

        return try EnvLoader.resolveForApp("OPENAI_API_KEY")
    }
}
