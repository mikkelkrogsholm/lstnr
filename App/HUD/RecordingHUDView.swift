import SwiftUI

/// The floating dictation HUD — Vara's face. Always dark glass, anchored near
/// the text insertion point. Shows a live waveform while recording, a gold
/// shimmer while "forging" (transcription + LLM cleanup), and the outcome.
struct RecordingHUDView: View {
    let state: RecordingHUDState

    static let size = CGSize(width: 312, height: 96)

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            titleRow
            middleRow
            bottomRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(.regularMaterial, in: shape)
        .background(HUDPalette.backdrop.opacity(0.6), in: shape)
        .overlay {
            shape.strokeBorder(borderTint)
        }
        .environment(\.colorScheme, .dark)
        .emberGlow(active: state.phase == .recording)
        .animation(.spring(duration: 0.32), value: state.phase)
    }

    private var borderTint: Color {
        switch state.phase {
        case .recording, .forging: HUDPalette.ember.opacity(0.45)
        default: HUDPalette.teal.opacity(0.4)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var titleRow: some View {
        HStack(spacing: 8) {
            statusGlyph

            Text(title)
                .font(BSTheme.display(13, weight: .semibold))
                .foregroundStyle(HUDPalette.text)
                .lineLimit(1)

            Spacer(minLength: 4)

            if state.phase == .recording, let startedAt = state.recordingStartedAt {
                TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                    Text(elapsedText(from: startedAt, to: context.date))
                        .font(BSTheme.mono(11, weight: .medium))
                        .foregroundStyle(HUDPalette.muted)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private var middleRow: some View {
        switch state.phase {
        case .recording:
            WaveformView(levels: state.levels, tint: HUDPalette.emberGlow)
                .frame(height: 24)
        case .forging:
            WaveformView(levels: state.levels, tint: HUDPalette.ember.opacity(0.45))
                .frame(height: 24)
                .overlay { ForgeShimmer() }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .inserted, .heardNothing, .cancelled:
            Text(state.transcriptPreview.isEmpty ? subtitle : state.transcriptPreview)
                .font(.system(size: 11))
                .foregroundStyle(HUDPalette.muted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .error(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(HUDPalette.muted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .hidden:
            Color.clear
        }
    }

    @ViewBuilder
    private var bottomRow: some View {
        HStack(spacing: 8) {
            if showsModeChip {
                HStack(spacing: 4) {
                    Image(systemName: state.modeSymbol)
                        .font(.system(size: 9, weight: .semibold))
                    Text(state.modeTitle)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(HUDPalette.tealLight)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(HUDPalette.teal.opacity(0.18), in: Capsule())
            }

            Spacer(minLength: 4)

            if state.phase == .recording {
                Text("Release · Esc · 1–9", comment: "HUD hint: release key to insert, Esc cancels, digits switch mode")
                    .font(.system(size: 10))
                    .foregroundStyle(HUDPalette.muted)
            }
        }
    }

    private var showsModeChip: Bool {
        switch state.phase {
        case .recording, .forging, .inserted: !state.modeTitle.isEmpty
        default: false
        }
    }

    // MARK: Copy

    private var title: String {
        switch state.phase {
        case .hidden: ""
        case .recording: String(localized: "Vara is listening …", comment: "HUD title while recording")
        case .forging: String(localized: "Vara is forging the text …", comment: "HUD title while transcribing/cleaning")
        case .inserted(let words): String(localized: "\(words) words inserted", comment: "HUD title after insertion")
        case .heardNothing: String(localized: "Vara heard nothing", comment: "HUD title for empty transcript")
        case .cancelled: String(localized: "Cancelled", comment: "HUD title after Esc cancel")
        case .error: String(localized: "Vara hit a snag", comment: "HUD title on error")
        }
    }

    private var subtitle: String {
        switch state.phase {
        case .heardNothing:
            String(localized: "Hold the key while you speak, then let go.", comment: "HUD hint for empty transcript")
        case .cancelled:
            String(localized: "Nothing was inserted.", comment: "HUD hint after cancel")
        default: ""
        }
    }

    private var statusGlyph: some View {
        ZStack {
            switch state.phase {
            case .recording:
                PulsingDot(color: HUDPalette.emberGlow)
            case .forging:
                Image(systemName: "hammer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HUDPalette.emberGlow)
                    .symbolEffect(.pulse, options: .repeating)
            case .inserted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HUDPalette.tealLight)
            case .heardNothing, .cancelled:
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HUDPalette.muted)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HUDPalette.amber)
            case .hidden:
                EmptyView()
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private func elapsedText(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// HUD-only palette: the HUD is always dark regardless of system appearance.
private enum HUDPalette {
    static let backdrop = Color(hex: 0x0A0A0F)
    static let text = Color(hex: 0xF0F0F5)
    static let muted = Color(hex: 0x9696A6)
    static let teal = Color(hex: 0x406E76)
    static let tealLight = Color(hex: 0x5A9AA5)
    static let ember = Color(hex: 0xCA8A04)
    static let emberGlow = Color(hex: 0xEAB308)
    static let amber = Color(hex: 0xE8A33D)
}

/// Scrolling level bars; newest sample on the right. Levels are linear RMS,
/// shaped here with a square-root curve so quiet speech still moves the bars.
private struct WaveformView: View {
    let levels: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let capacity = RecordingHUDState.levelCapacity
            let slot = size.width / CGFloat(capacity)
            let barWidth = max(2, slot - 2)
            let midY = size.height / 2

            for (index, level) in levels.enumerated() {
                let shaped = min(1, pow(level, 0.5) * 1.9)
                let barHeight = max(2.5, CGFloat(shaped) * size.height)
                let x = size.width - CGFloat(levels.count - index) * slot
                let rect = CGRect(
                    x: x,
                    y: midY - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                )
                let alpha = 0.35 + 0.65 * Double(index + 1) / Double(levels.count)
                context.fill(
                    Capsule().path(in: rect),
                    with: .color(tint.opacity(alpha))
                )
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .scaleEffect(pulsing ? 1.0 : 0.72)
            .opacity(pulsing ? 1.0 : 0.65)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

/// Gold sweep across the frozen waveform while the LLM works.
private struct ForgeShimmer: View {
    @State private var offset: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, HUDPalette.emberGlow.opacity(0.5), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: proxy.size.width * 0.45)
            .offset(x: offset * proxy.size.width)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    offset = 1.1
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("HUD phases") {
    let recording = RecordingHUDState()
    let forging = RecordingHUDState()
    let inserted = RecordingHUDState()
    let error = RecordingHUDState()

    return VStack(spacing: 16) {
        RecordingHUDView(state: configured(recording) { state in
            state.beginRecording(startedAt: Date(timeIntervalSinceNow: -7))
            state.modeTitle = "Ren tekst"
            state.modeSymbol = "sparkles"
            for index in 0..<48 {
                state.pushLevel(0.04 + 0.16 * abs(sin(Double(index) * 0.4)))
            }
        })
        RecordingHUDView(state: configured(forging) { state in
            state.phase = .forging
            state.modeTitle = "Ren tekst"
            state.modeSymbol = "sparkles"
            for index in 0..<48 {
                state.pushLevel(0.04 + 0.16 * abs(sin(Double(index) * 0.4)))
            }
        })
        RecordingHUDView(state: configured(inserted) { state in
            state.phase = .inserted(words: 23)
            state.modeTitle = "Ren tekst"
            state.modeSymbol = "sparkles"
            state.transcriptPreview = "Hej, jeg ville lige følge op på vores møde i går …"
        })
        RecordingHUDView(state: configured(error) { state in
            state.phase = .error(message: "Mikrofonadgang mangler. Åbn Systemindstillinger → Mikrofon.")
        })
    }
    .padding(32)
    .background(Color(hex: 0x1A1A24))
}

@MainActor
private func configured(
    _ state: RecordingHUDState,
    apply: (RecordingHUDState) -> Void
) -> RecordingHUDState {
    apply(state)
    return state
}
