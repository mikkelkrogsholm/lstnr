import Foundation
import Observation

/// Observable model behind the floating HUD. Owned by AppState; the HUD view
/// observes it directly so level pushes and phase changes render live.
@MainActor
@Observable
final class RecordingHUDState {
    enum Phase: Equatable {
        case hidden
        case recording
        /// Transcribing and/or LLM cleanup — "Vara is forging the text".
        case forging
        case inserted(words: Int)
        case heardNothing
        case cancelled
        case error(message: String)
    }

    static let levelCapacity = 48

    var phase: Phase = .hidden
    /// Rolling RMS levels, oldest first. Capacity `levelCapacity`.
    private(set) var levels: [Double] = []
    var recordingStartedAt: Date?
    var modeTitle: String = ""
    var modeSymbol: String = "waveform"
    var transcriptPreview: String = ""

    func pushLevel(_ level: Double) {
        levels.append(level)
        if levels.count > Self.levelCapacity {
            levels.removeFirst(levels.count - Self.levelCapacity)
        }
    }

    func beginRecording(startedAt: Date) {
        levels.removeAll()
        transcriptPreview = ""
        recordingStartedAt = startedAt
        phase = .recording
    }
}
