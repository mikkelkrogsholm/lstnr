import XCTest
@testable import VaraCore

/// Live end-to-end proof that the OpenAI key-validation probe reaches the real
/// API and classifies the response. Uses a deliberately BOGUS key, so it needs
/// no real credential and costs nothing (auth is rejected before any billing).
/// Skipped unless VARA_LIVE_TEST=1 (needs network).
final class CredentialValidatorLiveTests: XCTestCase {
    func testBogusOpenAIKeyIsReportedAsInvalidKey() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VARA_LIVE_TEST"] == "1",
            "live test: set VARA_LIVE_TEST=1 (hits api.openai.com)"
        )
        let reason = await CredentialValidator.validate(
            provider: .openAI,
            key: "sk-thiskeyisdeliberatelyinvalid000000000000000000"
        )
        XCTAssertEqual(reason, .invalidKey, "a bogus key must classify as .invalidKey, got \(String(describing: reason))")
    }

    func testEmptyKeyShortCircuitsToInvalidKeyWithoutNetwork() async {
        let reason = await CredentialValidator.validate(provider: .openAI, key: "   ")
        XCTAssertEqual(reason, .invalidKey)
    }
}
