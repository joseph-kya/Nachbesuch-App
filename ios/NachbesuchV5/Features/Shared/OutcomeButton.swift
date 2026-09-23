import SwiftUI

/// Shared status symbols, labels, and selection treatment for every result editor.
struct OutcomeButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let outcome: VisitOutcome
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: outcome.symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(outcome.tint)
                    .accessibilityHidden(true)
                Text(outcome.title)
                    .font(.subheadline.weight(.semibold))
                    .modifier(OutcomeTextLayout(reserveSpace: false))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                Text(outcome.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .modifier(OutcomeTextLayout())
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .contentPanel(cornerRadius: AppRadius.control)
            .selectionRing(isSelected, tint: outcome.tint)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        }
        // Not `.plain`: `.plain` applies no styling at all to a custom label, so
        // these tiles had no pressed state — the only feedback was the model write
        // landing, which on a slow save is well after the thumb has left the glass.
        // `PressableRowStyle` is the app's one definition of that feedback, and it
        // owns the press while the label owns the shape and the fill.
        .buttonStyle(PressableRowStyle())
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isSelected: Bool
    /// A booked appointment replaces the unscheduled control with its time and urgency.
    let bookedAt: Date?
    let action: () -> Void

    private var outcome: VisitOutcome { .later }

    var body: some View {
        if isSelected, let bookedAt {
            BookedTimeGlance(bookedAt: bookedAt, action: action)
        } else {
            unbookedButton
        }
    }

    private var unbookedButton: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.snug) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: outcome.symbolName)
                        .font(.title3)
                        .foregroundStyle(outcome.tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.title)
                        .font(.subheadline.weight(.semibold))
                    Text("Uhrzeit wählen")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: AppTouch.minimum, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentPanel(cornerRadius: AppRadius.control)
            .selectionRing(isSelected, tint: outcome.tint)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        }
        // Not `.plain`: `.plain` applies no styling at all to a custom label, so
        // these tiles had no pressed state — the only feedback was the model write
        // landing, which on a slow save is well after the thumb has left the glass.
        // `PressableRowStyle` is the app's one definition of that feedback, and it
        // owns the press while the label owns the shape and the fill.
        .buttonStyle(PressableRowStyle())
        .animation(.appFeedback(reduceMotion: reduceMotion), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(outcome.title)
        .accessibilityValue(outcome.explanation)
        .accessibilityHint("Fragt nach einer Uhrzeit")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Compact status glyph for list rows — shape plus colour, never colour alone.
///
/// The glyph owns its own animation rather than relying on the caller. It is the
/// single place in the app where a door's result becomes visible, and it is shown in
/// list rows, apartment rows and the map callout — all of which change it by writing
/// to the model, which is not an animated transaction anywhere. `.replace` makes the
/// old symbol hand over to the new one instead of the row blinking.
struct OutcomeGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let outcome: VisitOutcome?
    var size: Font = .body

    var body: some View {
        Image(systemName: outcome?.symbolName ?? "circle.dashed")
            .font(size)
            .foregroundStyle(outcome.displayTint)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.downUp))
            .animation(.appFeedback(reduceMotion: reduceMotion), value: outcome)
            .accessibilityHidden(true)
    }
}

/// Equal-height tiles at standard sizes; unrestricted wrapping at accessibility sizes.
private struct OutcomeTextLayout: ViewModifier {
    var reserveSpace = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            content.lineLimit(nil)
        } else {
            content.lineLimit(2, reservesSpace: reserveSpace)
        }
    }
}
