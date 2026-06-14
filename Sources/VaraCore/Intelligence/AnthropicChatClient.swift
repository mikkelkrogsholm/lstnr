import Foundation

/// Chat client for the Anthropic Messages API (Claude).
public struct AnthropicChatClient: ChatClient {
    public let id: String
    public let baseURL: URL
    public let apiKey: String
    public let model: String
    public let maxTokens: Int
    public let temperature: Double
    let transport: HTTPTransport

    public init(
        id: String = "anthropic",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiKey: String,
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
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                maxTokens: maxTokens,
                temperature: temperature,
                system: system,
                messages: [Message(role: "user", content: user)]
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
        // A "max_tokens" stop means the model ran out of room mid-reply: the
        // text is a partial completion, so treat it as a failure and let the
        // caller fall back to the raw transcript rather than paste half a
        // sentence.
        if decoded.stopReason == "max_tokens" {
            throw ChatClientError.truncated
        }
        let text = decoded.content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined()
        guard !text.isEmpty else {
            throw ChatClientError.emptyCompletion
        }
        return text
    }

    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let temperature: Double
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case temperature
            case system
            case messages
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct ResponseBody: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }

        let content: [ContentBlock]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }
}
