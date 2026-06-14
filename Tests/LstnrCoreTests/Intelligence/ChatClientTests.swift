import Foundation
import XCTest
@testable import LstnrCore

final class ChatClientTests: XCTestCase {
    // MARK: OpenAI-compatible

    func testOpenAICompatibleBuildsRequestAndParsesContent() async throws {
        let probe = TransportProbe(
            status: 200,
            body: #"{"choices":[{"message":{"role":"assistant","content":"Renset."}}]}"#
        )
        let client = OpenAICompatibleChatClient(
            id: "groq",
            baseURL: URL(string: "https://api.groq.com/openai/v1")!,
            apiKey: "secret-key",
            model: "llama-3.3-70b-versatile",
            transport: probe.transport
        )

        let text = try await client.complete(system: "SYS", user: "USER")

        XCTAssertEqual(text, "Renset.")
        let request = probe.lastRequest!
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "llama-3.3-70b-versatile")
        let messages = body["messages"] as! [[String: String]]
        XCTAssertEqual(messages[0], ["role": "system", "content": "SYS"])
        XCTAssertEqual(messages[1], ["role": "user", "content": "USER"])
    }

    func testOpenAICompatibleOmitsAuthorizationWithoutKey() async throws {
        let probe = TransportProbe(
            status: 200,
            body: #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#
        )
        let client = OpenAICompatibleChatClient(
            id: "ollama",
            baseURL: URL(string: "http://localhost:11434/v1")!,
            apiKey: nil,
            model: "gemma3",
            transport: probe.transport
        )

        _ = try await client.complete(system: "s", user: "u")

        XCTAssertNil(probe.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testOpenAICompatibleThrowsOnHTTPError() async {
        let probe = TransportProbe(status: 401, body: #"{"error":"bad key"}"#)
        let client = OpenAICompatibleChatClient(
            id: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "k",
            model: "gpt-4o-mini",
            transport: probe.transport
        )

        do {
            _ = try await client.complete(system: "s", user: "u")
            XCTFail("Expected error")
        } catch let error as ChatClientError {
            guard case .httpError(let status, let body) = error else {
                return XCTFail("Expected httpError, got \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("bad key"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: Anthropic

    func testAnthropicBuildsRequestAndParsesContent() async throws {
        let probe = TransportProbe(
            status: 200,
            body: #"{"content":[{"type":"text","text":"Svar fra Claude."}]}"#
        )
        let client = AnthropicChatClient(
            apiKey: "anthropic-key",
            model: "claude-haiku-4-5-20251001",
            transport: probe.transport
        )

        let text = try await client.complete(system: "SYS", user: "USER")

        XCTAssertEqual(text, "Svar fra Claude.")
        let request = probe.lastRequest!
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["system"] as? String, "SYS")
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5-20251001")
        XCTAssertNotNil(body["max_tokens"])
        let messages = body["messages"] as! [[String: String]]
        XCTAssertEqual(messages, [["role": "user", "content": "USER"]])
    }

    func testAnthropicJoinsMultipleTextBlocksAndSkipsOtherTypes() async throws {
        let probe = TransportProbe(
            status: 200,
            body: #"{"content":[{"type":"thinking","text":"hm"},{"type":"text","text":"To "},{"type":"text","text":"dele."}]}"#
        )
        let client = AnthropicChatClient(apiKey: "k", model: "m", transport: probe.transport)

        let text = try await client.complete(system: "s", user: "u")

        XCTAssertEqual(text, "To dele.")
    }

    func testAnthropicThrowsOnEmptyContent() async {
        let probe = TransportProbe(status: 200, body: #"{"content":[]}"#)
        let client = AnthropicChatClient(apiKey: "k", model: "m", transport: probe.transport)

        do {
            _ = try await client.complete(system: "s", user: "u")
            XCTFail("Expected error")
        } catch let error as ChatClientError {
            guard case .emptyCompletion = error else {
                return XCTFail("Expected emptyCompletion, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

private final class TransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let body: String
    private(set) var lastRequest: URLRequest?

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        lastRequest = request
        lock.unlock()
    }

    var transport: HTTPTransport {
        { [self] request in
            record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }
}
