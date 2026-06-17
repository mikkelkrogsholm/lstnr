import Foundation

public struct ScribeV2Backend: ASRBackend, SpeechToTextBackend {
    public let name: String
    public let apiKey: String
    public let baseURL: URL
    public let modelID: String
    public let noVerbatim: Bool
    public let tagAudioEvents: Bool
    public let diarize: Bool

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.elevenlabs.io")!,
        modelID: String = "scribe_v2",
        noVerbatim: Bool = false,
        tagAudioEvents: Bool = false,
        diarize: Bool = false
    ) {
        self.name = "scribe-v2"
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelID = modelID
        self.noVerbatim = noVerbatim
        self.tagAudioEvents = tagAudioEvents
        self.diarize = diarize
    }

    public var id: String { name }

    public var displayName: String { "ElevenLabs Scribe v2" }
    public var shortName: String { "ElevenLabs Scribe" }

    public var capabilities: SpeechToTextBackendCapabilities {
        SpeechToTextBackendCapabilities(
            supportsFileTranscription: true,
            supportsStreamingTranscription: false,
            supportsLanguageHints: true,
            supportsTimestamps: true,
            runsLocally: false,
            requiresNetwork: true,
            requiredCredentialKeys: ["ELEVENLABS_API_KEY"],
            supportedSampleRates: []
        )
    }

    public func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult {
        switch request.audio {
        case .file(let url):
            return try await transcribe(audio: url, language: request.languageCode)
        case .pcm16Stream:
            throw SpeechToTextBackendError.unsupportedAudio(
                backendID: id,
                reason: "Scribe v2 batch transcription accepts file audio only."
            )
        }
    }

    public func transcribe(audio: URL, language: String?) async throws -> TranscriptionResult {
        let endpoint = baseURL.appendingPathComponent("v1/speech-to-text")
        let boundary = "----vara-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: audio)
        let filename = audio.lastPathComponent
        let mimeType = MimeType.infer(from: audio)

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        field("model_id", modelID)
        if let language { field("language_code", language) }
        field("tag_audio_events", tagAudioEvents ? "true" : "false")
        field("timestamps_granularity", "word")
        if diarize { field("diarize", "true") }
        if noVerbatim { field("no_verbatim", "true") }

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
            throw ScribeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw ScribeError.httpError(status: http.statusCode, body: bodyStr)
        }

        let decoded = try JSONDecoder().decode(ScribeResponse.self, from: data)
        return TranscriptionResult(
            text: decoded.text,
            detectedLanguage: decoded.language_code,
            languageConfidence: decoded.language_probability,
            audioDurationSeconds: decoded.audio_duration_secs,
            elapsedSeconds: elapsed,
            backend: name,
            rawJSON: data
        )
    }
}

private struct ScribeResponse: Decodable {
    let text: String
    let language_code: String?
    let language_probability: Double?
    let audio_duration_secs: Double?
}

public enum ScribeError: Error, CustomStringConvertible {
    case invalidResponse
    case httpError(status: Int, body: String)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Scribe: non-HTTP response"
        case .httpError(let status, let body):
            return "Scribe HTTP \(status): \(body)"
        }
    }
}

enum MimeType {
    static func infer(from url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "webm": return "audio/webm"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
