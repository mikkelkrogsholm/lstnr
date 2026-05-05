import Foundation

public enum TranscriptCleanupMode: String, CaseIterable, Hashable, Sendable {
    case raw
    case clean

    // Future cleanup modes can be added here without changing speech-to-text backend selection.
    // Planned extension points: email, technical, translate.
}
