import Foundation

public protocol DictationAudioRecorder: Sendable {
    func startRecording() async throws
    func stopRecording() async throws -> SpeechToTextAudio
}

public struct ClosureDictationAudioRecorder: DictationAudioRecorder {
    private let start: @Sendable () async throws -> Void
    private let stop: @Sendable () async throws -> SpeechToTextAudio

    public init(
        start: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async throws -> SpeechToTextAudio
    ) {
        self.start = start
        self.stop = stop
    }

    public func startRecording() async throws {
        try await start()
    }

    public func stopRecording() async throws -> SpeechToTextAudio {
        try await stop()
    }
}

public enum DictationSessionCommandResult: Equatable, Sendable {
    case startedRecording
    case ignored
    case completed(insertedText: String?)
    case failed(message: String)
}

public actor DictationSession {
    public typealias Transcribe = @Sendable (SpeechToTextRequest) async throws -> TranscriptionResult
    public typealias TextSink = @Sendable (String) async throws -> Void

    public private(set) var state: DictationSessionState

    private let mode: DictationInteractionMode
    private let recorder: any DictationAudioRecorder
    private let transcribe: Transcribe
    private let textSink: TextSink
    private let languageCode: String?
    private let now: @Sendable () -> Date

    public init(
        mode: DictationInteractionMode,
        recorder: any DictationAudioRecorder,
        languageCode: String? = nil,
        initialState: DictationSessionState = .idle,
        now: @escaping @Sendable () -> Date = Date.init,
        transcribe: @escaping Transcribe,
        textSink: @escaping TextSink
    ) {
        self.mode = mode
        self.recorder = recorder
        self.languageCode = languageCode
        self.state = initialState
        self.now = now
        self.transcribe = transcribe
        self.textSink = textSink
    }

    @discardableResult
    public func beginInteraction() async -> DictationSessionCommandResult {
        switch mode {
        case .pushToTalk:
            return await startRecording()
        case .toggle:
            return await toggleRecording()
        }
    }

    @discardableResult
    public func endInteraction() async -> DictationSessionCommandResult {
        switch mode {
        case .pushToTalk:
            return await stopRecordingAndTranscribe()
        case .toggle:
            return .ignored
        }
    }

    @discardableResult
    public func startRecording() async -> DictationSessionCommandResult {
        guard !state.isBusy else {
            return .ignored
        }

        state = .recording(startedAt: now())

        do {
            try await recorder.startRecording()
            return .startedRecording
        } catch {
            return fail(with: error)
        }
    }

    @discardableResult
    public func stopRecordingAndTranscribe() async -> DictationSessionCommandResult {
        guard case .recording = state else {
            return .ignored
        }

        state = .transcribing

        do {
            let audio = try await recorder.stopRecording()
            let result = try await transcribe(SpeechToTextRequest(audio: audio, languageCode: languageCode))
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                state = .idle
                return .completed(insertedText: nil)
            }

            state = .inserting
            try await textSink(text)
            state = .idle
            return .completed(insertedText: text)
        } catch {
            return fail(with: error)
        }
    }

    private func toggleRecording() async -> DictationSessionCommandResult {
        switch state {
        case .idle, .failed:
            return await startRecording()
        case .recording:
            return await stopRecordingAndTranscribe()
        case .transcribing, .inserting:
            return .ignored
        }
    }

    private func fail(with error: any Error) -> DictationSessionCommandResult {
        let message = String(describing: error)
        state = .failed(message: message)
        return .failed(message: message)
    }
}
