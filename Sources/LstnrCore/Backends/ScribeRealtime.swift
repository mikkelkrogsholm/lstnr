import Foundation

public struct ScribeRealtimeBackend: ASRBackend, SpeechToTextBackend {
    public let name: String
    public let apiKey: String
    public let baseURL: URL
    public let modelID: String
    public let chunkMilliseconds: Int
    public let diagnosticLog: (@Sendable (String) async -> Void)?

    static let sampleRate = 16_000

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "wss://api.elevenlabs.io")!,
        modelID: String = "scribe_v2_realtime",
        chunkMilliseconds: Int = 200,
        diagnosticLog: (@Sendable (String) async -> Void)? = nil
    ) {
        self.name = "scribe-realtime"
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelID = modelID
        self.chunkMilliseconds = chunkMilliseconds
        self.diagnosticLog = diagnosticLog
    }

    public var id: String { name }

    public var displayName: String { "ElevenLabs Scribe v2 Realtime" }

    public var capabilities: SpeechToTextBackendCapabilities {
        SpeechToTextBackendCapabilities(
            supportsFileTranscription: true,
            supportsStreamingTranscription: true,
            supportsLanguageHints: true,
            supportsTimestamps: true,
            runsLocally: false,
            requiresNetwork: true,
            requiredCredentialKeys: ["ELEVENLABS_API_KEY"],
            supportedSampleRates: [Self.sampleRate]
        )
    }

    public func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult {
        switch request.audio {
        case .file(let url):
            return try await transcribe(audio: url, language: request.languageCode)
        case .pcm16Stream(let stream, let sampleRate):
            guard sampleRate == Self.sampleRate else {
                throw SpeechToTextBackendError.unsupportedAudio(
                    backendID: id,
                    reason: "Scribe realtime expects PCM s16le mono at \(Self.sampleRate) Hz; received \(sampleRate) Hz."
                )
            }
            return try await transcribe(pcmChunks: stream, language: request.languageCode)
        }
    }

    /// File-based convenience: reads the whole file, converts to PCM s16le 16kHz mono,
    /// chunks it on a background task, and streams to Scribe Realtime.
    public func transcribe(audio: URL, language: String?) async throws -> TranscriptionResult {
        let pcm = try AudioReader.readPCM16(url: audio, targetSampleRate: Double(Self.sampleRate))
        let durationSeconds = Double(pcm.count / 2) / Double(Self.sampleRate)

        let bytesPerChunk = max(320, Self.sampleRate * 2 * chunkMilliseconds / 1000)
        let (stream, cont) = AsyncStream<Data>.makeStream()
        Task.detached {
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + bytesPerChunk, pcm.count)
                cont.yield(pcm.subdata(in: offset..<end))
                offset = end
            }
            cont.finish()
        }

        let result = try await transcribe(pcmChunks: stream, language: language)
        return TranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            languageConfidence: result.languageConfidence,
            audioDurationSeconds: durationSeconds,
            elapsedSeconds: result.elapsedSeconds,
            backend: result.backend,
            rawJSON: result.rawJSON
        )
    }

    /// Live-streaming API: the caller pushes PCM s16le 16kHz mono frames on `pcmChunks`
    /// and signals end-of-utterance by finishing the stream.
    public func transcribe(
        pcmChunks: AsyncStream<Data>,
        language: String?
    ) async throws -> TranscriptionResult {
        let task = try openSocket(language: language)
        let start = Date()

        do {
            await diagnosticLog?("Scribe Realtime websocket opened. language=\(language ?? "automatic")")
            async let reader = readUntilCommitted(task: task)

            // Server requires ≥0.3s uncommitted audio before it accepts commit.
            // Pad with silence when the user stops too quickly.
            let minCommitBytes = Self.sampleRate * 2 * 400 / 1000  // 400ms

            var totalBytes = 0
            var buffered: Data?
            for await chunk in pcmChunks {
                totalBytes += chunk.count
                if let prev = buffered {
                    try await send(task: task, data: prev, commit: false)
                }
                buffered = chunk
            }
            var finalChunk = buffered ?? Data()
            if totalBytes < minCommitBytes {
                finalChunk.append(Data(count: minCommitBytes - totalBytes))
            }
            await diagnosticLog?("Scribe Realtime committing. totalBytes=\(totalBytes), finalChunkBytes=\(finalChunk.count)")
            try await send(task: task, data: finalChunk, commit: true)

            let (text, detected) = try await reader
            task.cancel(with: .normalClosure, reason: nil)
            await diagnosticLog?("Scribe Realtime committed. textLength=\(text.count), language=\(detected ?? "unknown")")

            let duration = Double(totalBytes / 2) / Double(Self.sampleRate)
            return TranscriptionResult(
                text: text,
                detectedLanguage: detected,
                languageConfidence: nil,
                audioDurationSeconds: duration,
                elapsedSeconds: Date().timeIntervalSince(start),
                backend: name,
                rawJSON: nil
            )
        } catch {
            task.cancel(with: .abnormalClosure, reason: nil)
            throw error
        }
    }

    private func openSocket(language: String?) throws -> URLSessionWebSocketTask {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/speech-to-text/realtime"),
            resolvingAgainstBaseURL: false
        )!
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http" { components.scheme = "ws" }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "include_language_detection", value: "true"),
        ]
        if let language { items.append(URLQueryItem(name: "language_code", value: language)) }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()
        return task
    }

    private func send(task: URLSessionWebSocketTask, data: Data, commit: Bool) async throws {
        let message = RealtimeOut(
            message_type: "input_audio_chunk",
            audio_base_64: data.base64EncodedString(),
            commit: commit,
            sample_rate: Self.sampleRate
        )
        let jsonData = try JSONEncoder().encode(message)
        guard let string = String(data: jsonData, encoding: .utf8) else {
            throw ScribeRealtimeError.encodingFailed
        }
        try await task.send(.string(string))
    }

    private func readUntilCommitted(task: URLSessionWebSocketTask) async throws -> (text: String, language: String?) {
        var collected = ""
        var detectedLanguage: String?
        let decoder = JSONDecoder()

        while true {
            let message = try await task.receive()
            switch message {
            case .string(let str):
                guard let data = str.data(using: .utf8) else { continue }
                let evt = try decoder.decode(RealtimeIn.self, from: data)
                switch evt.message_type {
                case "session_started", "partial_transcript":
                    await diagnosticLog?("Scribe Realtime event: \(evt.message_type), textLength=\(evt.text?.count ?? 0)")
                    continue
                case "committed_transcript", "committed_transcript_with_timestamps":
                    await diagnosticLog?("Scribe Realtime event: \(evt.message_type), textLength=\(evt.text?.count ?? 0)")
                    if let text = evt.text {
                        if !collected.isEmpty && !collected.hasSuffix(" ") { collected += " " }
                        collected += text
                    }
                    if detectedLanguage == nil { detectedLanguage = evt.language_code }
                    return (collected, detectedLanguage)
                default:
                    if evt.message_type.contains("error") || evt.error != nil {
                        await diagnosticLog?("Scribe Realtime error event: \(evt.message_type), detail=\(evt.error ?? "")")
                        throw ScribeRealtimeError.serverError(type: evt.message_type, detail: evt.error ?? "")
                    }
                }
            case .data:
                continue
            @unknown default:
                continue
            }
        }
    }
}

private struct RealtimeOut: Encodable {
    let message_type: String
    let audio_base_64: String
    let commit: Bool
    let sample_rate: Int
}

private struct RealtimeIn: Decodable {
    let message_type: String
    let text: String?
    let language_code: String?
    let error: String?
}

public enum ScribeRealtimeError: Error, CustomStringConvertible {
    case encodingFailed
    case serverError(type: String, detail: String)

    public var description: String {
        switch self {
        case .encodingFailed:
            return "Scribe Realtime: failed to encode outgoing message"
        case .serverError(let type, let detail):
            return "Scribe Realtime [\(type)]: \(detail)"
        }
    }
}
