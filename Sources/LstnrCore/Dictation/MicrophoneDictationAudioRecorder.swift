import Foundation

public enum MicrophoneDictationAudioRecorderError: Error, CustomStringConvertible, Sendable {
    case alreadyRecording
    case notRecording

    public var description: String {
        switch self {
        case .alreadyRecording:
            return "Microphone recording is already active"
        case .notRecording:
            return "Microphone recording is not active"
        }
    }
}
public final class MicrophoneDictationAudioRecorder: DictationAudioRecorder, @unchecked Sendable {
    private var recorder: AudioRecorder?
    private var stream: AsyncStream<Data>?
    private let onLevel: (@Sendable (Double) -> Void)?
    private let onDiagnostic: (@Sendable (String) -> Void)?

    public init(
        onLevel: (@Sendable (Double) -> Void)? = nil,
        onDiagnostic: (@Sendable (String) -> Void)? = nil
    ) {
        self.onLevel = onLevel
        self.onDiagnostic = onDiagnostic
    }

    public func startRecording() async throws {
        guard recorder == nil, stream == nil else {
            throw MicrophoneDictationAudioRecorderError.alreadyRecording
        }

        let recorder = try AudioRecorder()
        // Forward non-fatal audio events (dropped buffers, input-format changes
        // on AirPods/aggregate devices) to the app log so they surface in
        // Diagnostics instead of vanishing silently.
        recorder.diagnosticLog = onDiagnostic
        let stream = try recorder.start(onLevel: onLevel)
        self.recorder = recorder
        self.stream = stream
    }

    public func stopRecording() async throws -> SpeechToTextAudio {
        guard let recorder, let stream else {
            throw MicrophoneDictationAudioRecorderError.notRecording
        }

        recorder.stop()
        self.recorder = nil
        self.stream = nil
        return .pcm16Stream(stream, sampleRate: 16_000)
    }
}
