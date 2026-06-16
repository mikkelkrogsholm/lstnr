import Foundation

public struct OpenAIAudioTranscriptionBackend: ASRBackend, SpeechToTextBackend {
    public let name: String
    public let apiKey: String
    public let baseURL: URL
    public let modelID: String
    public let displayName: String

    static let sampleRate = 16_000

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        modelID: String,
        displayName: String
    ) {
        self.name = "openai-\(modelID)"
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelID = modelID
        self.displayName = displayName
    }

    public var id: String { name }

    public var capabilities: SpeechToTextBackendCapabilities {
        SpeechToTextBackendCapabilities(
            supportsFileTranscription: true,
            supportsStreamingTranscription: false,
            supportsLanguageHints: true,
            supportsTimestamps: false,
            runsLocally: false,
            requiresNetwork: true,
            requiredCredentialKeys: ["OPENAI_API_KEY"],
            supportedSampleRates: [Self.sampleRate]
        )
    }

    public func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult {
        switch request.audio {
        case .file(let url):
            return try await transcribe(audio: url, language: request.languageCode, prompt: request.whisperPrompt())
        case .pcm16Stream(let stream, let sampleRate):
            guard sampleRate == Self.sampleRate else {
                throw SpeechToTextBackendError.unsupportedAudio(
                    backendID: id,
                    reason: "OpenAI transcription expects PCM s16le mono at \(Self.sampleRate) Hz; received \(sampleRate) Hz."
                )
            }
            let audioFile = try await materializePCM16WAV(stream: stream, sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: audioFile.url) }
            let result = try await transcribe(audio: audioFile.url, language: request.languageCode, prompt: request.whisperPrompt())
            return TranscriptionResult(
                text: result.text,
                detectedLanguage: result.detectedLanguage,
                languageConfidence: result.languageConfidence,
                audioDurationSeconds: audioFile.durationSeconds,
                elapsedSeconds: result.elapsedSeconds,
                backend: result.backend,
                rawJSON: result.rawJSON
            )
        }
    }

    // ASRBackend witness (CLI path): no vocabulary biasing.
    public func transcribe(audio: URL, language: String?) async throws -> TranscriptionResult {
        try await transcribe(audio: audio, language: language, prompt: nil)
    }

    public func transcribe(audio: URL, language: String?, prompt: String?) async throws -> TranscriptionResult {
        let endpoint = baseURL.appendingPathComponent("v1/audio/transcriptions")
        let boundary = "----vara-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: audio)
        let filename = audio.lastPathComponent.isEmpty ? "audio.wav" : audio.lastPathComponent
        let mimeType = MimeType.infer(from: audio)

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        field("model", modelID)
        field("response_format", "json")
        if let language { field("language", language) }
        // Vocabulary biasing: gpt-4o-transcribe / -mini accept a free-text `prompt`
        // to steer spelling of names/jargon. (NOT supported on the realtime
        // gpt-realtime-whisper path — intentionally not sent there.)
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw OpenAITranscriptionError.httpError(status: http.statusCode, body: bodyStr)
        }

        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return TranscriptionResult(
            text: decoded.text,
            detectedLanguage: decoded.language,
            languageConfidence: nil,
            audioDurationSeconds: decoded.duration,
            elapsedSeconds: elapsed,
            backend: name,
            rawJSON: data
        )
    }
}

public struct OpenAIRealtimeWhisperBackend: ASRBackend, SpeechToTextBackend {
    public let name = "openai-gpt-realtime-whisper"
    public let apiKey: String
    public let baseURL: URL
    public let modelID: String
    public let chunkMilliseconds: Int
    public let diagnosticLog: (@Sendable (String) async -> Void)?

    static let inputSampleRate = 16_000
    static let realtimeSampleRate = 24_000

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "wss://api.openai.com")!,
        modelID: String = "gpt-realtime-whisper",
        chunkMilliseconds: Int = 200,
        diagnosticLog: (@Sendable (String) async -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelID = modelID
        self.chunkMilliseconds = chunkMilliseconds
        self.diagnosticLog = diagnosticLog
    }

    public var id: String { name }

    public var displayName: String { "OpenAI GPT Realtime Whisper" }

    public var capabilities: SpeechToTextBackendCapabilities {
        SpeechToTextBackendCapabilities(
            supportsFileTranscription: true,
            supportsStreamingTranscription: true,
            supportsLanguageHints: true,
            supportsTimestamps: false,
            runsLocally: false,
            requiresNetwork: true,
            requiredCredentialKeys: ["OPENAI_API_KEY"],
            supportedSampleRates: [Self.inputSampleRate]
        )
    }

    public func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult {
        switch request.audio {
        case .file(let url):
            return try await transcribe(audio: url, language: request.languageCode)
        case .pcm16Stream(let stream, let sampleRate):
            guard sampleRate == Self.inputSampleRate else {
                throw SpeechToTextBackendError.unsupportedAudio(
                    backendID: id,
                    reason: "OpenAI realtime transcription expects PCM s16le mono at \(Self.inputSampleRate) Hz; received \(sampleRate) Hz."
                )
            }
            return try await transcribe(pcmChunks: stream, language: request.languageCode)
        }
    }

    public func transcribe(audio: URL, language: String?) async throws -> TranscriptionResult {
        let pcm = try AudioReader.readPCM16(url: audio, targetSampleRate: Double(Self.inputSampleRate))
        let durationSeconds = Double(pcm.count / 2) / Double(Self.inputSampleRate)
        let bytesPerChunk = max(320, Self.inputSampleRate * 2 * chunkMilliseconds / 1000)
        let (stream, continuation) = AsyncStream<Data>.makeStream()

        Task.detached {
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + bytesPerChunk, pcm.count)
                continuation.yield(pcm.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
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

    public func transcribe(
        pcmChunks: AsyncStream<Data>,
        language: String?
    ) async throws -> TranscriptionResult {
        let (task, socketObserver) = openSocket()
        defer { socketObserver.finish() }
        let start = Date()

        do {
            await diagnosticLog?("OpenAI Realtime Whisper websocket opened. language=\(language ?? "automatic")")
            try await sendSessionUpdate(task: task, language: language)
            async let reader = readUntilCompleted(task: task)

            var totalInputBytes = 0
            var pendingInput = Data()
            for await chunk in pcmChunks {
                totalInputBytes += chunk.count
                pendingInput.append(chunk)

                let resampled = Self.resamplePCM16(pendingInput, from: Self.inputSampleRate, to: Self.realtimeSampleRate)
                pendingInput.removeAll(keepingCapacity: true)
                if !resampled.isEmpty {
                    try await sendAppend(task: task, pcm24k: resampled)
                }
            }

            let minCommitInputBytes = Self.inputSampleRate * 2 * 400 / 1000
            if totalInputBytes < minCommitInputBytes {
                let silence = Data(count: minCommitInputBytes - totalInputBytes)
                let resampled = Self.resamplePCM16(silence, from: Self.inputSampleRate, to: Self.realtimeSampleRate)
                try await sendAppend(task: task, pcm24k: resampled)
            }

            await diagnosticLog?("OpenAI Realtime Whisper committing. inputBytes=\(totalInputBytes)")
            try await sendCommit(task: task)

            let transcript = try await reader
            task.cancel(with: .normalClosure, reason: nil)
            await diagnosticLog?("OpenAI Realtime Whisper completed. textLength=\(transcript.count)")

            let duration = Double(totalInputBytes / 2) / Double(Self.inputSampleRate)
            return TranscriptionResult(
                text: transcript,
                detectedLanguage: language,
                languageConfidence: nil,
                audioDurationSeconds: duration,
                elapsedSeconds: Date().timeIntervalSince(start),
                backend: name,
                rawJSON: nil
            )
        } catch {
            task.cancel(with: .abnormalClosure, reason: nil)
            // A rejected WebSocket UPGRADE surfaces here only as errno 57
            // "Socket is not connected" on the first send — the real HTTP
            // status/close reason is captured by the delegate. Promote it to a
            // diagnosable error so the failure isn't an opaque ENOTCONN.
            if let rejection = socketObserver.rejection {
                throw OpenAITranscriptionError.realtimeConnectionRejected(
                    modelID: modelID,
                    status: rejection.status,
                    closeReason: rejection.reason
                )
            }
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
                throw OpenAITranscriptionError.realtimeConnectionRejected(
                    modelID: modelID,
                    status: nil,
                    closeReason: nil
                )
            }
            throw error
        }
    }
}

private extension OpenAIRealtimeWhisperBackend {
    func openSocket() -> (task: URLSessionWebSocketTask, observer: RealtimeSocketObserver) {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/realtime"),
            resolvingAgainstBaseURL: false
        )!
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http" { components.scheme = "ws" }
        // A transcription session is selected with intent=transcription. The
        // transcription model is passed in session.update under
        // audio.input.transcription.model — NOT as ?model=. Passing a
        // transcription model (e.g. gpt-realtime-whisper) as the session model is
        // rejected by the GA server with invalid_model ("is a transcription model
        // and cannot be used as the realtime session model"), which closes the
        // socket and surfaces only as errno 57 "Socket is not connected".
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // A delegate-backed session so a rejected HTTP upgrade (401/403/404)
        // is captured instead of being lost behind a bare ENOTCONN.
        let observer = RealtimeSocketObserver()
        let session = URLSession(configuration: .default, delegate: observer, delegateQueue: nil)
        observer.adopt(session: session)
        let task = session.webSocketTask(with: request)
        task.resume()
        return (task, observer)
    }

    func sendSessionUpdate(task: URLSessionWebSocketTask, language: String?) async throws {
        let event = RealtimeSessionUpdate(
            type: "session.update",
            session: RealtimeSession(
                type: "transcription",
                audio: RealtimeAudio(
                    input: RealtimeAudioInput(
                        format: RealtimeAudioFormat(type: "audio/pcm", rate: Self.realtimeSampleRate),
                        transcription: RealtimeTranscription(model: modelID, language: language),
                        turnDetection: nil
                    )
                )
            )
        )
        try await sendJSON(task: task, event)
    }

    func sendAppend(task: URLSessionWebSocketTask, pcm24k: Data) async throws {
        try await sendJSON(
            task: task,
            RealtimeAudioAppend(type: "input_audio_buffer.append", audio: pcm24k.base64EncodedString())
        )
    }

    func sendCommit(task: URLSessionWebSocketTask) async throws {
        try await sendJSON(task: task, RealtimeCommit(type: "input_audio_buffer.commit"))
    }

    func sendJSON<T: Encodable>(task: URLSessionWebSocketTask, _ value: T) async throws {
        let jsonData = try JSONEncoder().encode(value)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw OpenAITranscriptionError.encodingFailed
        }
        try await task.send(.string(jsonString))
    }

    func readUntilCompleted(task: URLSessionWebSocketTask) async throws -> String {
        var collected = ""
        let decoder = JSONDecoder()

        while true {
            let message = try await task.receive()
            switch message {
            case .string(let string):
                guard let data = string.data(using: .utf8) else { continue }
                let event = try decoder.decode(OpenAIRealtimeIncomingEvent.self, from: data)
                switch event.type {
                case "conversation.item.input_audio_transcription.delta":
                    if let delta = event.delta {
                        collected += delta
                    }
                    await diagnosticLog?("OpenAI Realtime Whisper delta. textLength=\(collected.count)")
                case "conversation.item.input_audio_transcription.completed":
                    return event.transcript ?? collected
                default:
                    if event.type.contains("error") || event.error != nil {
                        throw OpenAITranscriptionError.realtimeServerError(
                            type: event.type,
                            message: event.error?.message ?? event.error?.type ?? ""
                        )
                    }
                }
            case .data:
                continue
            @unknown default:
                continue
            }
        }
    }

    static func resamplePCM16(_ data: Data, from sourceRate: Int, to targetRate: Int) -> Data {
        guard sourceRate != targetRate else { return data }
        let sourceSamples = data.withUnsafeBytes { rawBuffer -> [Int16] in
            let buffer = rawBuffer.bindMemory(to: Int16.self)
            return Array(buffer)
        }
        guard !sourceSamples.isEmpty else { return Data() }

        let outputCount = Int((Double(sourceSamples.count) * Double(targetRate) / Double(sourceRate)).rounded())
        guard outputCount > 0 else { return Data() }

        var output = [Int16]()
        output.reserveCapacity(outputCount)

        for outputIndex in 0..<outputCount {
            let sourcePosition = Double(outputIndex) * Double(sourceRate) / Double(targetRate)
            let lower = Int(sourcePosition.rounded(.down))
            let upper = min(lower + 1, sourceSamples.count - 1)
            let fraction = sourcePosition - Double(lower)
            let lowerSample = Double(sourceSamples[min(lower, sourceSamples.count - 1)])
            let upperSample = Double(sourceSamples[upper])
            let interpolated = lowerSample + (upperSample - lowerSample) * fraction
            output.append(Int16(max(Double(Int16.min), min(Double(Int16.max), interpolated.rounded()))))
        }

        return Data(bytes: output, count: output.count * MemoryLayout<Int16>.size)
    }
}

private extension OpenAIAudioTranscriptionBackend {
    struct MaterializedAudio: Sendable {
        let url: URL
        let durationSeconds: Double
    }

    func materializePCM16WAV(
        stream: AsyncStream<Data>,
        sampleRate: Int
    ) async throws -> MaterializedAudio {
        var pcm = Data()
        for await chunk in stream {
            pcm.append(chunk)
        }
        guard !pcm.isEmpty else {
            throw OpenAITranscriptionError.unsupportedAudio("recorded audio is empty")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vara-openai-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Self.writePCM16WAV(data: pcm, sampleRate: sampleRate, to: url)
        let duration = Double(pcm.count / 2) / Double(sampleRate)
        return MaterializedAudio(url: url, durationSeconds: duration)
    }

    static func writePCM16WAV(data: Data, sampleRate: Int, to url: URL) throws {
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let bitsPerSample = UInt16(16)
        let dataSize = UInt32(data.count)
        let riffSize = UInt32(36 + data.count)

        var wav = Data()
        wav.append("RIFF")
        wav.appendLittleEndian(riffSize)
        wav.append("WAVE")
        wav.append("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.append("data")
        wav.appendLittleEndian(dataSize)
        wav.append(data)
        try wav.write(to: url, options: .atomic)
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
    let language: String?
    let duration: Double?
}

private struct RealtimeSessionUpdate: Encodable {
    let type: String
    let session: RealtimeSession
}

private struct RealtimeSession: Encodable {
    let type: String
    let audio: RealtimeAudio
}

private struct RealtimeAudio: Encodable {
    let input: RealtimeAudioInput
}

private struct RealtimeAudioInput: Encodable {
    let format: RealtimeAudioFormat
    let transcription: RealtimeTranscription
    let turnDetection: String?

    enum CodingKeys: String, CodingKey {
        case format
        case transcription
        case turnDetection = "turn_detection"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(transcription, forKey: .transcription)
        if let turnDetection {
            try container.encode(turnDetection, forKey: .turnDetection)
        } else {
            try container.encodeNil(forKey: .turnDetection)
        }
    }
}

private struct RealtimeAudioFormat: Encodable {
    let type: String
    let rate: Int
}

private struct RealtimeTranscription: Encodable {
    let model: String
    let language: String?
}

private struct RealtimeAudioAppend: Encodable {
    let type: String
    let audio: String
}

private struct RealtimeCommit: Encodable {
    let type: String
}

private struct OpenAIRealtimeIncomingEvent: Decodable {
    let type: String
    let delta: String?
    let transcript: String?
    let error: OpenAIRealtimeErrorPayload?
}

private struct OpenAIRealtimeErrorPayload: Decodable {
    let type: String?
    let message: String?
}

public enum OpenAITranscriptionError: Error, CustomStringConvertible, Sendable {
    case invalidResponse
    case httpError(status: Int, body: String)
    case unsupportedAudio(String)
    case encodingFailed
    case realtimeServerError(type: String, message: String)
    case realtimeConnectionRejected(modelID: String, status: Int?, closeReason: String?)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "OpenAI transcription: non-HTTP response"
        case .httpError(let status, let body):
            return "OpenAI transcription HTTP \(status): \(body)"
        case .unsupportedAudio(let reason):
            return "OpenAI transcription cannot process this audio: \(reason)"
        case .encodingFailed:
            return "OpenAI realtime transcription failed to encode an outgoing event"
        case .realtimeServerError(let type, let message):
            return "OpenAI realtime transcription [\(type)]: \(message)"
        case .realtimeConnectionRejected(let modelID, let status, let closeReason):
            let statusText = status.map { "HTTP \($0)" } ?? "socket closed during upgrade (no HTTP status surfaced)"
            let reasonText = closeReason.map { " — \($0)" } ?? ""
            return "OpenAI rejected the realtime WebSocket for model '\(modelID)' (\(statusText))\(reasonText). The batch OpenAI transcription backends are unaffected; a rejected upgrade usually means this realtime model isn't enabled for your account/project."
        }
    }
}

/// Captures the outcome of the WebSocket UPGRADE handshake. `URLSessionWebSocketTask`
/// does not expose the HTTP response of a rejected upgrade — a 401/403/404 only
/// surfaces later as errno 57 "Socket is not connected" on the first send. This
/// delegate records the HTTP status and any close reason so a refused handshake
/// becomes a real, diagnosable error instead of an opaque ENOTCONN. It also owns
/// the delegate-backed URLSession so the session<->delegate reference is broken
/// via `finish()` once the socket is done.
final class RealtimeSocketObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var httpStatus: Int?
    private var closeReason: String?
    private var ownedSession: URLSession?

    func adopt(session: URLSession) {
        lock.lock(); ownedSession = session; lock.unlock()
    }

    /// The captured rejection, if the upgrade failed; nil if nothing was recorded.
    var rejection: (status: Int?, reason: String?)? {
        lock.lock(); defer { lock.unlock() }
        guard httpStatus != nil || closeReason != nil else { return nil }
        return (httpStatus, closeReason)
    }

    /// Tear down the delegate-backed session (breaks the retain cycle).
    func finish() {
        lock.lock(); let session = ownedSession; ownedSession = nil; lock.unlock()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let http = task.response as? HTTPURLResponse else { return }
        lock.lock(); httpStatus = http.statusCode; lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard let reason, let text = String(data: reason, encoding: .utf8), !text.isEmpty else { return }
        lock.lock(); closeReason = text; lock.unlock()
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
