import XCTest
@testable import VaraCore

/// Coverage for the vocabulary-biasing helpers and the OpenAI-realtime enum
/// mappings shipped this session — pure, public, silent business rules
/// (≤20-char / ≤50 keyterm caps, prompt truncation, delay omit-vs-emit).
final class SpeechToTextRequestTests: XCTestCase {
    private func request(_ vocabulary: [String]) -> SpeechToTextRequest {
        SpeechToTextRequest(audio: .file(URL(fileURLWithPath: "/tmp/x.wav")), vocabulary: vocabulary)
    }

    // MARK: - whisperPrompt (Groq / OpenAI-batch "prompt")

    func testWhisperPromptNilWhenEmptyOrWhitespace() {
        XCTAssertNil(request([]).whisperPrompt())
        XCTAssertNil(request(["", "   ", "\n"]).whisperPrompt())
    }

    func testWhisperPromptJoinsTrimsAndDropsEmpties() {
        XCTAssertEqual(request(["Vara", " Krogsholm ", ""]).whisperPrompt(), "Vara, Krogsholm")
    }

    func testWhisperPromptTruncatesToMaxCharacters() {
        let prompt = request(["abcdefghij", "klmnopqrst"]).whisperPrompt(maxCharacters: 5)
        XCTAssertEqual(prompt?.count, 5)
    }

    // MARK: - elevenLabsKeyterms (Scribe realtime query params)

    func testKeytermsDrops21CharTermKeeps20() {
        let twenty = String(repeating: "a", count: 20)
        let twentyOne = String(repeating: "b", count: 21)
        let terms = request([twenty, twentyOne]).elevenLabsKeyterms
        XCTAssertTrue(terms.contains(twenty))
        XCTAssertFalse(terms.contains(twentyOne), "ElevenLabs caps each keyterm at 20 characters")
    }

    func testKeytermsCapAt50Entries() {
        let many = (0..<60).map { "term\($0)" }
        XCTAssertEqual(request(many).elevenLabsKeyterms.count, 50)
    }

    func testKeytermsTrimAndDropEmpties() {
        XCTAssertEqual(request([" hi ", "", "  "]).elevenLabsKeyterms, ["hi"])
    }

    // MARK: - Enum → wire-value mappings

    func testMicrophoneProfileMapping() {
        XCTAssertEqual(MicrophoneProfile.nearField.openAINoiseReductionType, "near_field")
        XCTAssertEqual(MicrophoneProfile.farField.openAINoiseReductionType, "far_field")
    }

    func testTranscriptionLatencyMapping() {
        XCTAssertNil(TranscriptionLatency.auto.openAIDelay, "auto means: send no delay key")
        for latency in TranscriptionLatency.allCases where latency != .auto {
            XCTAssertEqual(latency.openAIDelay, latency.rawValue)
        }
    }

    // MARK: - Default request keeps backwards-compatible behavior

    func testDefaultRequestHasNoVocabularyAndNearFieldAutoLatency() {
        let req = SpeechToTextRequest(audio: .file(URL(fileURLWithPath: "/tmp/x.wav")), languageCode: "en")
        XCTAssertTrue(req.vocabulary.isEmpty)
        XCTAssertNil(req.whisperPrompt())
        XCTAssertEqual(req.microphoneProfile, .nearField)
        XCTAssertEqual(req.transcriptionLatency, .auto)
    }
}
