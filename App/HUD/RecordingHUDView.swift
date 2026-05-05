import SwiftUI

struct RecordingHUDView: View {
    let model: RecordingHUDModel

    var body: some View {
        HStack(spacing: 10) {
            statusGlyph

            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(model.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if model.phase == .recording {
                AudioLevelMeter(level: model.level)
                    .frame(width: 48, height: 16)
                    .accessibilityLabel("Input level")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 208)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
    }

    private var statusGlyph: some View {
        ZStack {
            Circle()
                .fill(model.phase.tint.opacity(0.14))
                .frame(width: 28, height: 28)

            Image(systemName: model.phase.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.phase.tint)
        }
        .accessibilityHidden(true)
    }
}

struct RecordingHUDModel: Hashable {
    var phase: RecordingHUDPhase
    var level: Double
    var transcriptPreview: String

    var title: String {
        switch phase {
        case .idle: "Ready to dictate"
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .inserted: "Inserted"
        case .error: "Needs attention"
        }
    }

    var subtitle: String {
        if !transcriptPreview.isEmpty {
            return transcriptPreview
        }

        return switch phase {
        case .idle: "Hold Right Option to start"
        case .recording: "Release to finish"
        case .transcribing: "Preparing text"
        case .inserted: "Saved to history"
        case .error: "Check microphone and permissions"
        }
    }

    static let previewRecording = RecordingHUDModel(
        phase: .recording,
        level: 0.66,
        transcriptPreview: "Drafting the follow-up email..."
    )
}

enum RecordingHUDPhase: Hashable {
    case idle
    case recording
    case transcribing
    case inserted
    case error

    var systemImage: String {
        switch self {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing: "text.bubble"
        case .inserted: "checkmark"
        case .error: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .secondary
        case .recording: .red
        case .transcribing: .blue
        case .inserted: .green
        case .error: .orange
        }
    }
}

private struct AudioLevelMeter: View {
    let level: Double

    private var clampedLevel: Double {
        min(max(level, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let barWidth = proxy.size.width / 9
            let activeBars = Int((clampedLevel * 8).rounded(.up))

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<8, id: \.self) { index in
                    Capsule()
                        .fill(index < activeBars ? Color.red : Color.secondary.opacity(0.24))
                        .frame(width: max(3, barWidth - 3), height: barHeight(for: index))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [6, 10, 14, 18, 16, 12, 9, 6]
        return heights[index]
    }
}

#Preview("Recording HUD") {
    VStack(spacing: 18) {
        RecordingHUDView(model: .previewRecording)
        RecordingHUDView(model: RecordingHUDModel(phase: .transcribing, level: 0, transcriptPreview: ""))
        RecordingHUDView(model: RecordingHUDModel(phase: .error, level: 0, transcriptPreview: "Missing microphone permission"))
    }
    .padding(40)
}
