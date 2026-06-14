import Foundation

/// Injectable HTTP transport so chat clients can be tested without network.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public let liveHTTPTransport: HTTPTransport = { request in
    try await URLSession.shared.data(for: request)
}

/// Builds a transport backed by a `URLSession` with bounded timeouts so a hung
/// LLM endpoint (e.g. a wedged local Ollama/DGX) can never block dictation
/// forever. Used by the chat clients instead of `URLSession.shared`; AppState
/// additionally wraps the call in a task timeout (belt and suspenders).
public func timeoutHTTPTransport(
    requestTimeout: TimeInterval = 25,
    resourceTimeout: TimeInterval = 60
) -> HTTPTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    let session = URLSession(configuration: configuration)
    return { request in
        try await session.data(for: request)
    }
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
    /// The model stopped because it hit the output-token limit, so the reply is
    /// a partial completion. The caller must treat this as a failure and fall
    /// back to the raw transcript — never paste a half-finished sentence.
    case truncated

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Chat completion: non-HTTP response"
        case .httpError(let status, let body):
            return "Chat completion HTTP \(status): \(body)"
        case .emptyCompletion:
            return "Chat completion returned no text"
        case .truncated:
            return "Chat completion truncated at max output tokens"
        }
    }

    /// A description safe to log: it never includes the HTTP body, which can echo
    /// the user's transcript. Prefer this over `description` at log sites that
    /// may persist or surface the message. The full body stays available via
    /// `description` for in-memory debugging only.
    public var redactedDescription: String {
        switch self {
        case .httpError(let status, let body):
            let byteCount = Data(body.utf8).count
            return "Chat completion HTTP \(status): <\(byteCount) bytes redacted>"
        case .invalidResponse, .emptyCompletion, .truncated:
            return description
        }
    }
}
