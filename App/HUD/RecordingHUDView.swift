import SwiftUI

/// The floating dictation HUD — Vara's face. Always light glass (cool mist,
/// matching vara.dk + the app's light theme), anchored near the text insertion
/// point. Shows a live waveform while recording, a gold shimmer while "forging"
/// (transcription + LLM cleanup), and the outcome.
struct RecordingHUDView: View {
    let state: RecordingHUDState
    /// Invoked when the user clicks the HUD's close (X) control. Wired to
    /// `cancelDictation()` on the MainActor by the window controller.
    var onCancel: (() -> Void)?

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
        .background(HUDPalette.backdrop.opacity(0.72), in: shape)
        .overlay {
            shape.strokeBorder(borderTint)
        }
        .environment(\.colorScheme, .light)
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

            if showsCloseButton {
                closeButton
            }
        }
    }

    /// Small close (X) that cancels the dictation. Shown while recording and
    /// forging so the user always has a visible way out — Esc is the keyboard
    /// twin. The host panel is a `.nonactivatingPanel` with `canBecomeKey=false`
    /// and does NOT set `ignoresMouseEvents`, so this click is delivered to the
    /// button WITHOUT pulling key focus away from the frontmost app (the paste
    /// target). `.plain` button style keeps it from drawing a focus ring.
    @ViewBuilder
    private var closeButton: some View {
        Button {
            onCancel?()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(HUDPalette.muted)
                .frame(width: 16, height: 16)
                .background(HUDPalette.muted.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Cancel", comment: "HUD close button cancels the dictation"))
    }

    private var showsCloseButton: Bool {
        switch state.phase {
        case .recording, .forging: true
        default: false
        }
    }

    @ViewBuilder
    private var middleRow: some View {
        switch state.phase {
        case .recording:
            WaveformView(levels: state.levels, tint: HUDPalette.emberGlow, animated: true)
                .frame(height: 24)
        case .forging:
            // Frozen waveform (no animation — levels are static now) plus one
            // lightweight indeterminate spinner. This replaces the old
            // ForgeShimmer + repeating symbol pulse, whose unbounded
            // `repeatForever` redraw loops pegged a CPU core in the floating panel.
            HStack(spacing: 8) {
                WaveformView(levels: state.levels, tint: HUDPalette.ember.opacity(0.35), animated: false)
                    .frame(height: 24)
                ProgressView()
                    .controlSize(.small)
                    .tint(HUDPalette.ember)
            }
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
        HStack(spacing: 6) {
            if showsModeChip { modeChip }
            if showsEngineChip { engineChip }

            Spacer(minLength: 4)

            if state.phase == .recording {
                hintLabel(Text("Release · Esc · 1–9", comment: "HUD hint: release key to insert, Esc cancels, digits switch mode"))
            } else if state.phase == .forging {
                // Forging is now escapable — surface the Esc hint so the user
                // isn't trapped if the backend hangs.
                hintLabel(Text("Esc · cancel", comment: "HUD hint while forging: Esc cancels"))
            }
        }
    }

    /// Teal chip naming the active dictation mode (e.g. "Ren tekst").
    private var modeChip: some View {
        chip(symbol: state.modeSymbol, text: state.modeTitle, tint: HUDPalette.teal)
    }

    /// Muted chip naming the active speech engine, with a cloud/laptop glyph that
    /// shows at a glance whether transcription runs in the cloud or on-device —
    /// answers "which engine is running?" on every dictation.
    private var engineChip: some View {
        chip(
            symbol: state.engineRunsLocally ? "laptopcomputer" : "cloud",
            text: state.engineName,
            tint: HUDPalette.muted,
            maxTextWidth: 116
        )
    }

    private func chip(symbol: String, text: String, tint: Color, maxTextWidth: CGFloat? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxTextWidth)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.16), in: Capsule())
    }

    /// The keyboard hint, deprioritized so it compresses before the chips when
    /// the HUD is narrow.
    private func hintLabel(_ text: Text) -> some View {
        text
            .font(.system(size: 10))
            .foregroundStyle(HUDPalette.muted)
            .lineLimit(1)
            .layoutPriority(-1)
    }

    private var showsModeChip: Bool {
        switch state.phase {
        case .recording, .forging, .inserted: !state.modeTitle.isEmpty
        default: false
        }
    }

    private var showsEngineChip: Bool {
        switch state.phase {
        case .recording, .forging, .inserted: !state.engineName.isEmpty
        default: false
        }
    }

    // MARK: Copy

    private var title: String {
        switch state.phase {
        case .hidden: ""
        case .recording: String(localized: "Vara is listening …", comment: "HUD title while recording")
        // WHY: while WhisperKit specializes the CoreML model on first run, the
        // forge legitimately blocks on that one-time compile — say so instead of
        // the normal "forging" copy. Only the title changes; the .forging glyph,
        // spinner, border tint and Esc/X cancel hint stay keyed on `case .forging`.
        case .forging:
            state.forgePreparingModel
                ? String(localized: "Preparing the model (one-time) …", comment: "HUD title while WhisperKit specializes the CoreML model on first run")
                : String(localized: "Vara is forging the text …", comment: "HUD title while transcribing/cleaning")
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
                // Static glyph — the old `.symbolEffect(.pulse, options:
                // .repeating)` ran an unbounded redraw loop; the forging spinner
                // in the middle row now carries the "working" motion instead.
                Image(systemName: "hammer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HUDPalette.emberGlow)
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

/// HUD-only palette: the HUD is always LIGHT regardless of system appearance,
/// matching vara.dk and the app's light theme (cool mist surface, ink text, teal
/// + ember-forge accents).
private enum HUDPalette {
    static let backdrop = Color(hex: 0xF5F7F9)   // vara.dk --bg, cool mist
    static let text = Color(hex: 0x0A1E27)        // ink
    static let muted = Color(hex: 0x5F6E76)
    static let teal = Color(hex: 0x36636B)        // vara.dk --teal
    static let tealLight = Color(hex: 0x5A9AA5)   // vara.dk --teal-light
    static let ember = Color(hex: 0xCA8A04)       // forge gold (recording/forging)
    static let emberGlow = Color(hex: 0xEAB308)
    static let amber = Color(hex: 0xCA7A12)       // error glyph, darkened for light bg
}

/// Scrolling level bars; newest sample on the right. Levels are linear RMS,
/// shaped here with a square-root curve so quiet speech still moves the bars.
private struct WaveformView: View {
    let levels: [Double]
    let tint: Color
    /// Drives the per-sample slide animation only while recording. During forging
    /// the levels are frozen, so animating them would needlessly redraw the panel.
    var animated: Bool = true

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
        .animation(animated ? .linear(duration: 0.08) : nil, value: levels)
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
            state.engineName = "ElevenLabs Scribe"
            state.engineRunsLocally = false
            for index in 0..<48 {
                state.pushLevel(0.04 + 0.16 * abs(sin(Double(index) * 0.4)))
            }
        })
        RecordingHUDView(state: configured(forging) { state in
            state.phase = .forging
            state.modeTitle = "Ren tekst"
            state.modeSymbol = "sparkles"
            state.engineName = "Hviske"
            state.engineRunsLocally = true
            for index in 0..<48 {
                state.pushLevel(0.04 + 0.16 * abs(sin(Double(index) * 0.4)))
            }
        })
        RecordingHUDView(state: configured(inserted) { state in
            state.phase = .inserted(words: 23)
            state.modeTitle = "Ren tekst"
            state.modeSymbol = "sparkles"
            state.engineName = "OpenAI Realtime"
            state.engineRunsLocally = false
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
