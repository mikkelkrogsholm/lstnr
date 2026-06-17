import XCTest
@testable import VaraCore

/// Regression coverage for the OpenAI realtime transcription backend — the
/// request construction that silently broke once (?model= instead of
/// ?intent=transcription) and the session.update wire shape shipped alongside it.
final class OpenAIRealtimeWhisperBackendTests: XCTestCase {
    private func makeBackend(model: String = "gpt-realtime-whisper") -> OpenAIRealtimeWhisperBackend {
        OpenAIRealtimeWhisperBackend(apiKey: "test-key", modelID: model)
    }

    // MARK: - Connection URL (the ?model= → ?intent=transcription regression)

    func testRealtimeURLUsesIntentTranscriptionNotModel() {
        let url = OpenAIRealtimeWhisperBackend.realtimeRequestURL(baseURL: URL(string: "wss://api.openai.com")!)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = components.queryItems ?? []

        XCTAssertTrue(components.path.hasSuffix("v1/realtime"), "path was \(components.path)")
        XCTAssertTrue(
            items.contains(URLQueryItem(name: "intent", value: "transcription")),
            "a transcription session must connect with ?intent=transcription"
        )
        XCTAssertFalse(
            items.contains { $0.name == "model" },
            "the transcription model must NOT go in ?model= — the GA server rejects it as invalid_model (errno 57)"
        )
    }

    func testRealtimeURLRewritesHTTPSchemesToWebSocket() {
        XCTAssertEqual(
            OpenAIRealtimeWhisperBackend.realtimeRequestURL(baseURL: URL(string: "https://api.openai.com")!).scheme,
            "wss"
        )
        XCTAssertEqual(
            OpenAIRealtimeWhisperBackend.realtimeRequestURL(baseURL: URL(string: "http://localhost:9999")!).scheme,
            "ws"
        )
    }

    // MARK: - session.update wire shape

    private func sessionUpdateInput(
        latency: TranscriptionLatency = .auto,
        mic: MicrophoneProfile = .nearField,
        language: String? = "da"
    ) throws -> [String: Any] {
        let data = try makeBackend().sessionUpdateData(language: language, microphoneProfile: mic, latency: latency)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["type"] as? String, "session.update")
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        return try XCTUnwrap(audio["input"] as? [String: Any])
    }

    func testSessionUpdateFormatUsesWireRate24kPCM() throws {
        let format = try XCTUnwrap(try sessionUpdateInput()["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        // The WIRE rate is 24000, deliberately not the 16000 Hz capture rate.
        XCTAssertEqual(format["rate"] as? Int, 24000)
    }

    func testSessionUpdateUsesSnakeCaseKeysAndNullTurnDetection() throws {
        let input = try sessionUpdateInput()
        XCTAssertNotNil(input["noise_reduction"], "key must be snake_case noise_reduction")
        XCTAssertNil(input["noiseReduction"], "must not leak the Swift camelCase property name")
        XCTAssertTrue(input.keys.contains("turn_detection"), "turn_detection must be present…")
        XCTAssertTrue(input["turn_detection"] is NSNull, "…and explicitly null (manual commit mode)")
    }

    func testSessionUpdateCarriesModelAndLanguage() throws {
        let transcription = try XCTUnwrap(try sessionUpdateInput(language: "da")["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(transcription["language"] as? String, "da")
    }

    func testMicrophoneProfileMapsToNoiseReductionType() throws {
        let near = try XCTUnwrap((try sessionUpdateInput(mic: .nearField)["noise_reduction"] as? [String: Any])?["type"] as? String)
        let far = try XCTUnwrap((try sessionUpdateInput(mic: .farField)["noise_reduction"] as? [String: Any])?["type"] as? String)
        XCTAssertEqual(near, "near_field")
        XCTAssertEqual(far, "far_field")
    }

    func testDelayOmittedWhenAutoEmittedOtherwise() throws {
        let auto = try XCTUnwrap(try sessionUpdateInput(latency: .auto)["transcription"] as? [String: Any])
        XCTAssertFalse(auto.keys.contains("delay"), "auto must OMIT delay so the server default applies")

        let high = try XCTUnwrap(try sessionUpdateInput(latency: .high)["transcription"] as? [String: Any])
        XCTAssertEqual(high["delay"] as? String, "high")
    }

    // MARK: - Rejected-connection error surfacing

    func testRealtimeConnectionRejectedDescriptionIsDiagnosable() {
        let withStatus = OpenAITranscriptionError.realtimeConnectionRejected(
            modelID: "gpt-realtime-whisper", status: 403, closeReason: "no access"
        )
        XCTAssertTrue(withStatus.description.contains("HTTP 403"))
        XCTAssertTrue(withStatus.description.contains("gpt-realtime-whisper"))

        let noStatus = OpenAITranscriptionError.realtimeConnectionRejected(
            modelID: "gpt-realtime-whisper", status: nil, closeReason: nil
        )
        XCTAssertFalse(noStatus.description.isEmpty)
        XCTAssertTrue(noStatus.description.contains("gpt-realtime-whisper"))
    }

    // MARK: - Buffered replay (the realtime → batch fallback re-streams the same audio)

    func testChunkedStreamReassemblesToOriginalLosslessly() async {
        var pcm = Data()
        for i in 0..<10_000 { pcm.append(UInt8(i & 0xFF)) }
        var rebuilt = Data()
        for await chunk in OpenAIRealtimeWhisperBackend.chunkedStream(pcm, chunkMilliseconds: 100) {
            rebuilt.append(chunk)
        }
        XCTAssertEqual(rebuilt, pcm, "replayed chunks must reconstruct the buffered audio byte-for-byte")
    }

    func testChunkedStreamProducesUniformChunksThenRemainder() async {
        let pcm = Data(repeating: 0xAB, count: 8000)
        var sizes: [Int] = []
        for await chunk in OpenAIRealtimeWhisperBackend.chunkedStream(pcm, chunkMilliseconds: 100) {
            sizes.append(chunk.count)
        }
        XCTAssertGreaterThan(sizes.count, 1, "8000 bytes should split into multiple chunks")
        let full = try! XCTUnwrap(sizes.first)
        XCTAssertTrue(sizes.dropLast().allSatisfy { $0 == full }, "all but the last chunk must be full-sized: \(sizes)")
        XCTAssertLessThanOrEqual(try! XCTUnwrap(sizes.last), full)
        XCTAssertEqual(sizes.reduce(0, +), 8000, "no bytes may be lost or duplicated across chunks")
    }

    func testChunkedStreamOfEmptyBufferEmitsNothing() async {
        var count = 0
        for await _ in OpenAIRealtimeWhisperBackend.chunkedStream(Data(), chunkMilliseconds: 100) { count += 1 }
        XCTAssertEqual(count, 0, "an empty buffer must finish the stream with no chunks")
    }

    // MARK: - HUD engine short names (must stay compact + non-truncating)

    func testRealtimeShortNameIsConcise() {
        XCTAssertEqual(makeBackend().shortName, "OpenAI Realtime")
    }

    func testOpenAIBatchShortNameDerivesFromModelID() {
        let full = OpenAIAudioTranscriptionBackend(apiKey: "k", modelID: "gpt-4o-transcribe", displayName: "OpenAI GPT-4o Transcribe")
        XCTAssertEqual(full.shortName, "OpenAI 4o")
        let mini = OpenAIAudioTranscriptionBackend(apiKey: "k", modelID: "gpt-4o-mini-transcribe", displayName: "OpenAI GPT-4o Mini Transcribe 2025-12-15")
        XCTAssertEqual(mini.shortName, "OpenAI 4o-mini")
    }
}
