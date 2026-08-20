import SwiftUI

/// One of the four status choices.
///
/// Carries the emoji *and* a distinct SF Symbol so the four outcomes stay
/// distinguishable by shape — red, orange and pink are three warm hues that a
/// colour-blind user cannot reliably separate at 12 pt.
struct OutcomeButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 30

    let outcome: VisitOutcome
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(outcome.emoji)
                    .font(.system(size: glyphSize))
                    .scaleEffect(isSelected ? 1.12 : 1)
                Text(outcome.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(outcome.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    .fill(isSelected ? outcome.tint.opacity(0.18) : Color(uiColor: .tertiarySystemFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    .strokeBorder(isSelected ? outcome.tint : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(outcome.title)
        .accessibilityHint(outcome.explanation)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Compact status glyph for list rows — shape plus colour, never colour alone.
struct OutcomeGlyph: View {
    let outcome: VisitOutcome?
    var size: Font = .body

    var body: some View {
        Image(systemName: outcome?.symbolName ?? "circle.dashed")
            .font(size)
            .foregroundStyle(outcome.displayTint)
            .accessibilityHidden(true)
    }
}
