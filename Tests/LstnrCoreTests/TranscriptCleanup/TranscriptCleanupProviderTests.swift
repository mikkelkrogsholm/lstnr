import XCTest
@testable import LstnrCore

final class TranscriptCleanupProviderTests: XCTestCase {
    func testRawProviderReturnsOriginalTextForRawMode() async throws {
        let provider = RawTranscriptCleanupProvider()
        let originalText = "  Keep   this text exactly , please.\n\n\n"

        let result = try await provider.cleanup(TranscriptCleanupRequest(rawText: originalText, mode: .raw))

        XCTAssertEqual(result.rawText, originalText)
        XCTAssertEqual(result.cleanedText, originalText)
        XCTAssertEqual(result.mode, .raw)
        XCTAssertEqual(result.providerID, "raw")
    }

    func testBasicProviderCleansWhitespaceAndSpacingBeforePunctuation() async throws {
        let provider = BasicTranscriptCleanupProvider()
        let originalText = "  Hello   world  !\n\n\nThis\t\tis   clean  ,  right ?  "

        let result = try await provider.cleanup(TranscriptCleanupRequest(rawText: originalText, mode: .clean))

        XCTAssertEqual(result.rawText, originalText)
        XCTAssertEqual(result.cleanedText, "Hello world!\n\nThis is clean, right?")
        XCTAssertEqual(result.mode, .clean)
        XCTAssertEqual(result.providerID, "basic-clean")
    }

    func testBasicCleanNormalizesCarriageReturnsAndSpacesAroundNewlines() {
        let cleanedText = BasicTranscriptCleanupProvider.cleanText(" A  line \r\n  then\r another   line . ")

        XCTAssertEqual(cleanedText, "A line\nthen\nanother line.")
    }

    func testProvidersRejectUnsupportedModes() async {
        let rawProvider = RawTranscriptCleanupProvider()
        let basicProvider = BasicTranscriptCleanupProvider()

        await XCTAssertThrowsErrorAsync(
            try await rawProvider.cleanup(TranscriptCleanupRequest(rawText: "text", mode: .clean))
        ) { error in
            XCTAssertEqual(
                error as? TranscriptCleanupProviderError,
                .unsupportedMode(providerID: "raw", mode: .clean)
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await basicProvider.cleanup(TranscriptCleanupRequest(rawText: "text", mode: .raw))
        ) { error in
            XCTAssertEqual(
                error as? TranscriptCleanupProviderError,
                .unsupportedMode(providerID: "basic-clean", mode: .raw)
            )
        }
    }

    func testCleanupRequestDoesNotCarrySpeechToTextBackendSelection() {
        let request = TranscriptCleanupRequest(rawText: "Text", mode: .clean)

        XCTAssertEqual(request.rawText, "Text")
        XCTAssertEqual(request.mode, .clean)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
