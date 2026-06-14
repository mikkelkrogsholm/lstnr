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
    public let temperature: Double
    let transport: HTTPTransport

    public init(
        id: String,
        baseURL: URL,
        apiKey: String?,
        model: String,
        temperature: Double = 0.3,
        transport: @escaping HTTPTransport = liveHTTPTransport
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
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
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw ChatClientError.emptyCompletion
        }
        return text
    }

    private struct RequestBody: Encodable {
        let model: String
        let temperature: Double
        let messages: [Message]
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            let message: Message
        }

        let choices: [Choice]
    }
}
