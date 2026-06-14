import Foundation

/// Chat client for any OpenAI-compatible `/chat/completions` endpoint:
/// OpenAI, Groq, Ollama, LM Studio, vLLM and other self-hosted servers.
/// `baseURL` points at the API root including version, e.g.
/// `https://api.openai.com/v1`, `https://api.groq.com/openai/v1`,
/// `http://localhost:11434/v1`.
public struct OpenAICompatibleChatClient: ChatClient {
    public let id: String
    public let baseURL: URL
    public let apiKey: String?
    public let model: String
    public let maxTokens: Int
    public let temperature: Double
    let transport: HTTPTransport

    public init(
        id: String,
        baseURL: URL,
        apiKey: String?,
        model: String,
        maxTokens: Int = 4096,
        temperature: Double = 0.3,
        transport: @escaping HTTPTransport = timeoutHTTPTransport()
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.transport = transport
    }

    public func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                maxTokens: maxTokens,
                temperature: temperature,
                messages: [
                    Message(role: "system", content: system),
                    Message(role: "user", content: user),
                ]
            )
        )

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw ChatClientError.httpError(status: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let choice = decoded.choices.first else {
            throw ChatClientError.emptyCompletion
        }
        // A "length" finish means the model hit `max_tokens` mid-reply: the text
        // is a partial completion, so treat it as a failure and let the caller
        // fall back to the raw transcript rather than paste half a sentence.
        if choice.finishReason == "length" {
            throw ChatClientError.truncated
        }
        let text = choice.message.content
        guard !text.isEmpty else {
            throw ChatClientError.emptyCompletion
        }
        return text
    }

    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let temperature: Double
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case temperature
            case messages
        }
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            let message: Message
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }

        let choices: [Choice]
    }
}
