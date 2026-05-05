import Foundation
import XCTest
@testable import LstnrCore

final class DictationSessionTests: XCTestCase {
    func testPushToTalkRecordsTranscribesAndInsertsText() async {
        let recorder = RecordingProbe()
        let sink = TextSinkProbe()
        let transcriber = TranscriptionProbe(text: " hello world ")
        let session = DictationSession(
            mode: .pushToTalk,
            recorder: recorder,
            transcribe: transcriber.transcribe,
            textSink: sink.insert
        )

        let startResult = await session.beginInteraction()
        let recordingState = await session.state
        XCTAssertEqual(startResult, .startedRecording)
        XCTAssertRecording(recordingState)

        let stopResult = await session.endInteraction()
        let finalState = await session.state
        let startCount = await recorder.startCount
        let stopCount = await recorder.stopCount
        let requestCount = await transcriber.requestCount
        let insertedTexts = await sink.insertedTexts

        XCTAssertEqual(stopResult, .completed(insertedText: "hello world"))
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(insertedTexts, ["hello world"])
    }

    func testToggleStartsAndStopsRecording() async {
        let recorder = RecordingProbe()
        let sink = TextSinkProbe()
        let transcriber = TranscriptionProbe(text: "toggle text")
        let session = DictationSession(
            mode: .toggle,
            recorder: recorder,
            transcribe: transcriber.transcribe,
            textSink: sink.insert
        )

        let startResult = await session.beginInteraction()
        XCTAssertEqual(startResult, .startedRecording)
        let recordingState = await session.state
        XCTAssertRecording(recordingState)
        let stopResult = await session.beginInteraction()
        let endResult = await session.endInteraction()
        let finalState = await session.state
        let insertedTexts = await sink.insertedTexts

        XCTAssertEqual(stopResult, .completed(insertedText: "toggle text"))
        XCTAssertEqual(endResult, .ignored)
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(insertedTexts, ["toggle text"])
    }

    func testEmptyTranscriptDoesNotInsertText() async {
        let recorder = RecordingProbe()
        let sink = TextSinkProbe()
        let transcriber = TranscriptionProbe(text: " \n\t ")
        let session = DictationSession(
            mode: .pushToTalk,
            recorder: recorder,
            transcribe: transcriber.transcribe,
            textSink: sink.insert
        )

        let startResult = await session.beginInteraction()
        let stopResult = await session.endInteraction()
        let finalState = await session.state
        let insertedTexts = await sink.insertedTexts

        XCTAssertEqual(startResult, .startedRecording)
        XCTAssertEqual(stopResult, .completed(insertedText: nil))
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(insertedTexts, [])
    }

    func testTranscriptionFailureMovesSessionToFailed() async {
        let recorder = RecordingProbe()
        let sink = TextSinkProbe()
        let transcriber = TranscriptionProbe(error: TestError.transcriptionFailed)
        let session = DictationSession(
            mode: .pushToTalk,
            recorder: recorder,
            transcribe: transcriber.transcribe,
            textSink: sink.insert
        )

        let startResult = await session.beginInteraction()
        XCTAssertEqual(startResult, .startedRecording)
        let result = await session.endInteraction()

        guard case .failed(let message) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        let finalState = await session.state
        let insertedTexts = await sink.insertedTexts
        XCTAssertEqual(message, String(describing: TestError.transcriptionFailed))
        XCTAssertEqual(finalState, .failed(message: message))
        XCTAssertEqual(insertedTexts, [])
    }

    func testDuplicateStartWhileRecordingIsIgnored() async {
        let recorder = RecordingProbe()
        let sink = TextSinkProbe()
        let transcriber = TranscriptionProbe(text: "one")
        let session = DictationSession(
            mode: .pushToTalk,
            recorder: recorder,
            transcribe: transcriber.transcribe,
            textSink: sink.insert
        )

        let startResult = await session.beginInteraction()
        let duplicateStartResult = await session.beginInteraction()
        let startCount = await recorder.startCount

        XCTAssertEqual(startResult, .startedRecording)
        XCTAssertEqual(duplicateStartResult, .ignored)
        XCTAssertEqual(startCount, 1)

        let stopResult = await session.endInteraction()
        let finalState = await session.state
        XCTAssertEqual(stopResult, .completed(insertedText: "one"))
        XCTAssertEqual(finalState, .idle)
    }
}

private func XCTAssertRecording(
    _ state: DictationSessionState,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .recording = state else {
        return XCTFail("Expected recording state, got \(state)", file: file, line: line)
    }
}

private actor RecordingProbe: DictationAudioRecorder {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let startError: (any Error)?
    private let stopError: (any Error)?

    init(startError: (any Error)? = nil, stopError: (any Error)? = nil) {
        self.startError = startError
        self.stopError = stopError
    }

    func startRecording() async throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func stopRecording() async throws -> SpeechToTextAudio {
        stopCount += 1
        if let stopError {
            throw stopError
        }
        return .pcm16Stream(AsyncStream { continuation in
            continuation.finish()
        }, sampleRate: 16_000)
    }
}

private actor TranscriptionProbe {
    private(set) var requestCount = 0
    private let text: String
    private let error: (any Error)?

    init(text: String = "", error: (any Error)? = nil) {
        self.text = text
        self.error = error
    }

    func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult {
        requestCount += 1
        if let error {
            throw error
        }
        return TranscriptionResult(
            text: text,
            elapsedSeconds: 0.01,
            backend: "test"
        )
    }
}

private actor TextSinkProbe {
    private(set) var insertedTexts: [String] = []

    func insert(_ text: String) async throws {
        insertedTexts.append(text)
    }
}

private enum TestError: Error {
    case transcriptionFailed
}
