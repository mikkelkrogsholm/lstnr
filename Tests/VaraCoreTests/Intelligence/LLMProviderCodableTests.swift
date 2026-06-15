import Foundation
import XCTest
@testable import VaraCore

final class LLMProviderCodableTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: backward compatibility — already-persisted blobs must still decode

    func testExistingOpenAIBlobStillDecodes() throws {
        // Swift's synthesized enum Codable keys each case by its NAME, so a
        // persisted `.openAI` is `{"openAI":{}}`. Adding cases is purely additive.
        let data = Data(#"{"openAI":{}}"#.utf8)
        let provider = try decoder.decode(LLMProvider.self, from: data)
        XCTAssertEqual(provider, .openAI)
    }

    func testExistingCustomEndpointBlobStillDecodes() throws {
        let id = UUID()
        let data = Data(#"{"custom":{"endpointID":"\#(id.uuidString)"}}"#.utf8)
        let provider = try decoder.decode(LLMProvider.self, from: data)
        XCTAssertEqual(provider, .custom(endpointID: id))
    }

    func testExistingLLMSelectionBlobStillDecodes() throws {
        let data = Data(#"{"provider":{"groq":{}},"model":"llama-3.3-70b-versatile"}"#.utf8)
        let selection = try decoder.decode(LLMSelection.self, from: data)
        XCTAssertEqual(selection.provider, .groq)
        XCTAssertEqual(selection.model, "llama-3.3-70b-versatile")
    }

    // MARK: round-trip for the new cases

    func testGeminiRoundTrips() throws {
        try assertRoundTrips(.gemini)
    }

    func testCLICasesRoundTrip() throws {
        try assertRoundTrips(.claudeCLI(model: "haiku"))
        try assertRoundTrips(.codexCLI(model: "gpt-5.5"))
        try assertRoundTrips(.geminiCLI(model: "gemini-2.5-flash"))
    }

    func testCLISelectionRoundTripsInsideLLMSelection() throws {
        let selection = LLMSelection(provider: .codexCLI(model: "gpt-5.5"), model: "gpt-5.5")
        let data = try encoder.encode(selection)
        let decoded = try decoder.decode(LLMSelection.self, from: data)
        XCTAssertEqual(decoded, selection)
    }

    // MARK: provider metadata for the new cases

    func testCLIProvidersReportLocalAndNoKey() {
        for provider: LLMProvider in [.claudeCLI(model: "haiku"), .codexCLI(model: "gpt-5.5"), .geminiCLI(model: "gemini-2.5-flash")] {
            XCTAssertTrue(provider.runsLocally, "\(provider) should run locally")
            XCTAssertFalse(provider.requiresAPIKey, "\(provider) should need no key")
            XCTAssertTrue(provider.isCLI)
            XCTAssertNil(provider.defaultBaseURL)
        }
    }

    func testGeminiUsesGoogleOpenAICompatBaseURL() {
        XCTAssertEqual(
            LLMProvider.gemini.defaultBaseURL?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai"
        )
        XCTAssertTrue(LLMProvider.gemini.requiresAPIKey)
        XCTAssertFalse(LLMProvider.gemini.runsLocally)
        XCTAssertFalse(LLMProvider.gemini.isCLI)
    }

    func testCLIToolMapping() {
        XCTAssertEqual(LLMProvider.claudeCLI(model: "x").cliTool, .claude)
        XCTAssertEqual(LLMProvider.codexCLI(model: "x").cliTool, .codex)
        XCTAssertEqual(LLMProvider.geminiCLI(model: "x").cliTool, .gemini)
        XCTAssertNil(LLMProvider.gemini.cliTool)
        XCTAssertNil(LLMProvider.openAI.cliTool)
    }

    private func assertRoundTrips(_ provider: LLMProvider, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try encoder.encode(provider)
        let decoded = try decoder.decode(LLMProvider.self, from: data)
        XCTAssertEqual(decoded, provider, file: file, line: line)
    }
}
