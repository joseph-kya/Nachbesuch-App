import SwiftUI

/// One of the four result choices.
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

/// The "Später" control — deliberately a single wide row under the 2×2 grid of
/// results rather than a fifth tile in it.
///
/// Two reasons. It is not a result: the door stays open, it is only moved to a
/// later time, and grouping it with "Dabei" would say otherwise. And a five-tile
/// grid leaves an odd gap that reads as a missing option.
struct LaterButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isSelected: Bool
    /// The time already booked, shown in place of the explanation.
    let bookedAt: Date?
    let action: () -> Void

    private var outcome: VisitOutcome { .later }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.snug) {
                Text(outcome.emoji)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.title)
                        .font(.subheadline.weight(.semibold))
                    Text(bookedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: AppTouch.minimum, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
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
        .accessibilityValue(bookedText)
        .accessibilityHint("Fragt nach einer Uhrzeit")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var bookedText: String {
        guard isSelected, let bookedAt else { return outcome.explanation }
        return "Gebucht für \(RevisitPlanner.clockFormatter.string(from: bookedAt))"
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
