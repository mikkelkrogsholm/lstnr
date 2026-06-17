import Foundation

/// Validates a provider API key with a minimal *real* request, so the app can
/// tell the user "this key works and your account can transcribe" — instead of
/// only "a key is stored". Returns `nil` on success, or the [APIFailureReason]
/// explaining why it won't work (bad key, no credit, no access, offline …).
public enum CredentialValidator {
    public enum Provider: String, Sendable, CaseIterable {
        case openAI, groq, elevenLabs, anthropic, gemini
    }

    public static func validate(provider: Provider, key: String) async -> APIFailureReason? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidKey }
        // Bound every probe so the Settings status can't sit on "checking …" forever
        // if a connection stalls — the OpenAI transcription probe otherwise inherits
        // the shared session's 60s default, unlike the GET probes (15s).
        return await withDeadline(seconds: 20) { await probe(provider: provider, key: trimmed) }
    }

    private static func probe(provider: Provider, key trimmed: String) async -> APIFailureReason? {
        switch provider {
        case .openAI:
            // Real transcription probe: exercises the exact endpoint dictation uses,
            // so it catches a bad key (401), no credit (429 insufficient_quota) AND
            // no access to the transcription model (403/404) in one shot.
            return await transcriptionProbe(key: trimmed)
        case .groq:
            return await authProbe(
                URL(string: "https://api.groq.com/openai/v1/models")!,
                headers: ["Authorization": "Bearer \(trimmed)"]
            )
        case .elevenLabs:
            return await authProbe(
                URL(string: "https://api.elevenlabs.io/v1/user")!,
                headers: ["xi-api-key": trimmed]
            )
        case .anthropic:
            return await authProbe(
                URL(string: "https://api.anthropic.com/v1/models")!,
                headers: ["x-api-key": trimmed, "anthropic-version": "2023-06-01"]
            )
        case .gemini:
            return await authProbe(
                URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmed)")!,
                headers: [:]
            )
        }
    }

    // MARK: - Deadline

    /// Run `operation`, but if it doesn't finish within `seconds`, give up and
    /// report `.network` — a stalled probe is, to the user, "couldn't reach the
    /// provider". (The lingering request is abandoned; it harms nothing.)
    private static func withDeadline(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> APIFailureReason?
    ) async -> APIFailureReason? {
        await withTaskGroup(of: APIFailureReason?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .network
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - OpenAI transcription probe

    private static func transcriptionProbe(key: String) async -> APIFailureReason? {
        // Use the canonical alias (always the current GA mini model), not a pinned
        // dated snapshot — validation should reflect "can this account transcribe",
        // not whether one specific snapshot is enabled.
        let backend = OpenAIAudioTranscriptionBackend(
            apiKey: key,
            modelID: "gpt-4o-mini-transcribe",
            displayName: "credential validation"
        )
        let wavURL: URL
        do {
            wavURL = try writeSilentWAV(seconds: 1.0)
        } catch {
            return .other(status: nil, message: "could not build probe audio")
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        do {
            _ = try await backend.transcribe(audio: wavURL, language: nil)
            return nil
        } catch {
            return APIFailureReason.reason(for: error) ?? .other(status: nil, message: "\(error)")
        }
    }

    // MARK: - Generic key/auth probe (GET, no billing)

    private static func authProbe(_ url: URL, headers: [String: String]) async -> APIFailureReason? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .other(status: nil, message: "non-HTTP response")
            }
            if (200..<300).contains(http.statusCode) { return nil }
            let body = String(data: data, encoding: .utf8) ?? ""
            return APIFailureReason.classify(status: http.statusCode, body: body)
        } catch {
            return APIFailureReason.reason(for: error) ?? .network
        }
    }

    // MARK: - Silent WAV builder (s16le mono)

    /// A WAV file of `seconds` of silence at `sampleRate` Hz — small enough that
    /// the probe costs a fraction of a cent, long enough that the endpoint won't
    /// reject it as "too short".
    static func writeSilentWAV(seconds: Double, sampleRate: Int = 16_000) throws -> URL {
        let frameCount = max(1, Int(Double(sampleRate) * seconds))
        let dataBytes = frameCount * 2 // 16-bit mono

        var data = Data()
        func appendLE32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func appendLE16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }

        data.append(Data("RIFF".utf8))
        appendLE32(UInt32(36 + dataBytes))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendLE32(16)                          // fmt chunk size (PCM)
        appendLE16(1)                           // audio format = PCM
        appendLE16(1)                           // channels = mono
        appendLE32(UInt32(sampleRate))          // sample rate
        appendLE32(UInt32(sampleRate * 2))      // byte rate = rate * blockAlign
        appendLE16(2)                           // block align = channels * bytesPerSample
        appendLE16(16)                          // bits per sample
        data.append(Data("data".utf8))
        appendLE32(UInt32(dataBytes))
        data.append(Data(count: dataBytes))     // silence

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vara-credcheck-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}
