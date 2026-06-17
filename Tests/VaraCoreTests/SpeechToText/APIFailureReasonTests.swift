import XCTest
@testable import VaraCore

/// The classifier behind both the actionable dictation errors and the key
/// validation status — so "no credit" never reads as "wrong key", etc.
final class APIFailureReasonTests: XCTestCase {
    // MARK: classify(status:body:)

    func testStatusCodeMapping() {
        XCTAssertEqual(APIFailureReason.classify(status: 401, body: ""), .invalidKey)
        XCTAssertEqual(APIFailureReason.classify(status: 402, body: ""), .insufficientQuota)
        XCTAssertEqual(APIFailureReason.classify(status: 403, body: ""), .noAccess)
        XCTAssertEqual(APIFailureReason.classify(status: 500, body: ""), .server)
        XCTAssertEqual(APIFailureReason.classify(status: 503, body: ""), .server)
    }

    func test429SeparatesNoCreditFromRateLimit() {
        let quota = APIFailureReason.classify(
            status: 429,
            body: #"{"error":{"type":"insufficient_quota","message":"You exceeded your current quota"}}"#
        )
        XCTAssertEqual(quota, .insufficientQuota, "insufficient_quota must read as 'no credit', not a transient rate limit")

        let rate = APIFailureReason.classify(
            status: 429,
            body: #"{"error":{"type":"rate_limit_exceeded","message":"Rate limit reached"}}"#
        )
        XCTAssertEqual(rate, .rateLimited)
    }

    func testModelNotFoundIsNoAccess() {
        XCTAssertEqual(
            APIFailureReason.classify(status: 404, body: #"{"error":{"message":"The model 'x' does not exist or you do not have access"}}"#),
            .noAccess
        )
    }

    func test403CarryingQuotaReadsAsNoCreditNotNoAccess() {
        XCTAssertEqual(
            APIFailureReason.classify(status: 403, body: #"{"error":{"type":"insufficient_quota","message":"You have insufficient credit"}}"#),
            .insufficientQuota,
            "a 403 that's really a billing problem must say 'add credit', not 'pick another engine'"
        )
        XCTAssertEqual(
            APIFailureReason.classify(status: 403, body: #"{"error":{"message":"You don't have access to this model"}}"#),
            .noAccess
        )
    }

    func test400WithInvalidKeyCodeIsInvalidKey() {
        XCTAssertEqual(
            APIFailureReason.classify(status: 400, body: #"{"error":{"code":"invalid_api_key","message":"Incorrect API key provided"}}"#),
            .invalidKey
        )
    }

    // MARK: reason(for:)

    func testOpenAIHTTPErrorIsClassified() {
        XCTAssertEqual(APIFailureReason.reason(for: OpenAITranscriptionError.httpError(status: 401, body: "")), .invalidKey)
        XCTAssertEqual(
            APIFailureReason.reason(for: OpenAITranscriptionError.httpError(status: 429, body: "insufficient_quota")),
            .insufficientQuota
        )
    }

    func testRealtimeRejectionUsesStatusElseNoAccess() {
        XCTAssertEqual(
            APIFailureReason.reason(for: OpenAITranscriptionError.realtimeConnectionRejected(modelID: "m", status: 403, closeReason: nil)),
            .noAccess
        )
        XCTAssertEqual(
            APIFailureReason.reason(for: OpenAITranscriptionError.realtimeConnectionRejected(modelID: "m", status: nil, closeReason: nil)),
            .noAccess
        )
    }

    func testGroqHTTPErrorIsClassified() {
        XCTAssertEqual(APIFailureReason.reason(for: GroqWhisperError.httpError(status: 401, body: "")), .invalidKey)
    }

    func testURLErrorMapsToNetwork() {
        XCTAssertEqual(APIFailureReason.reason(for: URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(APIFailureReason.reason(for: URLError(.timedOut)), .network)
    }

    func testUnrecognizedAndLocalErrorsReturnNil() {
        struct Bespoke: Error {}
        XCTAssertNil(APIFailureReason.reason(for: Bespoke()), "an unknown error must fall through to the generic message")
        XCTAssertNil(APIFailureReason.reason(for: OpenAITranscriptionError.encodingFailed), "a local encoding bug is not a cloud failure")
    }

    // MARK: silent WAV probe audio

    func testSilentWAVIsWellFormedAndSized() throws {
        let url = try CredentialValidator.writeSilentWAV(seconds: 1.0, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 16_000 * 2, "44-byte WAV header + 1s of 16kHz mono s16le silence")
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(data.subdata(in: 8..<12), Data("WAVE".utf8))
    }
}
