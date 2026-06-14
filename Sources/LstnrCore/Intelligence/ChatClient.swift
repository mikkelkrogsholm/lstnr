import Foundation

/// Injectable HTTP transport so chat clients can be tested without network.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public let liveHTTPTransport: HTTPTransport = { request in
    try await URLSession.shared.data(for: request)
}

/// Minimal chat-completion abstraction used for transcript cleanup, rewriting
/// and voice Q&A. One system prompt, one user message, one text reply.
public protocol ChatClient: Sendable {
    var id: String { get }
    func complete(system: String, user: String) async throws -> String
}

public enum ChatClientError: Error, CustomStringConvertible, Sendable {
    case invalidResponse
    case httpError(status: Int, body: String)
    case emptyCompletion

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Chat completion: non-HTTP response"
        case .httpError(let status, let body):
            return "Chat completion HTTP \(status): \(body)"
        case .emptyCompletion:
            return "Chat completion returned no text"
        }
    }
}
