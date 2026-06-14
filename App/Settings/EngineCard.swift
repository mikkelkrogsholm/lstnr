import SwiftUI

/// Selectable card for one speech-to-text engine.
struct EngineCard: View {
    enum KeyStatus {
        case notNeeded
        case present
        case missing
    }

    let backend: LstnrSpeechBackendChoice
    let isSelected: Bool
    let keyStatus: KeyStatus
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: backend.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? BSTheme.cyan : BSTheme.teal)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(BSTheme.cyan)
                    }
                }

                Text(backend.shortTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(backend.latencyHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    badge(
                        backend.isLocal
                            ? String(localized: "Local", comment: "Engine badge")
                            : String(localized: "Cloud", comment: "Engine badge"),
                        tint: backend.isLocal ? .green : BSTheme.teal
                    )

                    if let tierBadge = backend.tier.badgeTitle {
                        badge(tierBadge, tint: BSTheme.textMuted)
                    }

                    switch keyStatus {
                    case .notNeeded:
                        EmptyView()
                    case .present:
                        badge(String(localized: "Key ✓", comment: "Engine badge: key present"), tint: .green)
                    case .missing:
                        badge(String(localized: "Key missing", comment: "Engine badge: key missing"), tint: .orange)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? BSTheme.teal.opacity(0.12) : BSTheme.surface,
                in: RoundedRectangle(cornerRadius: BSTheme.smallCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BSTheme.smallCornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? BSTheme.teal : BSTheme.border, lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}
