import Foundation

public struct GroqWhisperBackend: ASRBackend, SpeechToTextBackend {
    public let name: String
    public let apiKey: String
    public let baseURL: URL
    public let modelID: String
    public let temperature: Double

    static let sampleRate = 16_000

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.groq.com/openai")!,
        modelID: String = "whisper-large-v3",
        temperature: Double = 0
    ) {
        self.name = "groq-whisper-large-v3"
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelID = modelID
        self.temperature = temperature
    }

    public var id: String { name }

    public var displayName: String { "Groq Whisper Large v3" }

    public var capabilities: SpeechToTextBackendCapabilities {
        SpeechToTextBackendCapabilities(
            supportsFileTranscription: true,
            supportsStreamingTranscription: false,
            supportsLanguageHints: true,
            supportsTimestamps: true,
            runsLocally: false,
            requiresNetwork: true,
            requiredCredentialKeys: ["GROQ_API_KEY"],
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
                    reason: "Groq Whisper expects PCM s16le mono at \(Self.sampleRate) Hz; received \(sampleRate) Hz."
                )
            }
            let audioFile = try await materializePCM16WAV(stream: stream, sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: audioFile.url) }
            let result = try await transcribe(audio: audioFile.url, language: request.languageCode)
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

    public func transcribe(audio: URL, language: String?) async throws -> TranscriptionResult {
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
        field("temperature", Self.formatTemperature(temperature))
        field("response_format", "verbose_json")
        if let language { field("language", language) }

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
            throw GroqWhisperError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw GroqWhisperError.httpError(status: http.statusCode, body: bodyStr)
        }

        let decoded = try JSONDecoder().decode(GroqWhisperResponse.self, from: data)
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

private extension GroqWhisperBackend {
    struct MaterializedAudio: Sendable {
        let url: URL
        let durationSeconds: Double
    }

    static func formatTemperature(_ value: Double) -> String {
        value == floor(value) ? String(Int(value)) : String(value)
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
            throw GroqWhisperError.unsupportedAudio("recorded audio is empty")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vara-groq-\(UUID().uuidString)")
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

private struct GroqWhisperResponse: Decodable {
    let text: String
    let language: String?
    let duration: Double?
}

public enum GroqWhisperError: Error, CustomStringConvertible, Sendable {
    case invalidResponse
    case httpError(status: Int, body: String)
    case unsupportedAudio(String)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Groq Whisper: non-HTTP response"
        case .httpError(let status, let body):
            return "Groq Whisper HTTP \(status): \(body)"
        case .unsupportedAudio(let reason):
            return "Groq Whisper cannot transcribe this audio: \(reason)"
        }
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
