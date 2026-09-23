import SwiftUI
import UIKit

/// One filter chip.
struct FilterChip: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let count: Int?
    let isSelected: Bool
}

/// The app's filter bar — a single implementation.
///
/// There used to be two near-identical copies (`QuickFilterBar` and
/// `ListFilterBar`), ~90 duplicated lines whose differences were all accidental:
/// 34 vs 36 pt chips, one firing a haptic the other didn't, and one using a
/// hardcoded `.black` badge that was invisible in dark mode.
/// The app's filter bar — a single implementation.
///
/// There used to be two near-identical copies (`QuickFilterBar` and `ListFilterBar`),
/// ~90 duplicated lines whose differences were all accidental.
///
/// Every chip is one glass capsule; the selected one's glass takes the chip's
/// tint, so the selection travels as a colour change and nothing in the row moves.
struct FilterBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    let chips: [FilterChip]
    /// Named so VoiceOver says which filter list this is.
    var contextLabel: String
    var onSelect: (String) -> Void
    var onHelp: (() -> Void)?
    /// Suche läuft (Rohtext ≠ Debounce): zeigt einen 6-pt-Punkt am Zeilenende.
    /// Immer im Layout, nur die Deckkraft wechselt — kein Layoutsprung.
    var isSearching = false

    private var selectedID: String? { chips.first(where: \.isSelected)?.id }

    var body: some View {
        // Help is pinned beside the chips on iOS 18 and rides along inside them on
        // iOS 26, and that split is not cosmetic.
        //
        // It was the last item *inside* the scroll view, which made it two things it
        // is not: a filter, and optional — with five chips it scrolled off the right
        // edge and stopped existing for anyone who did not think to swipe a row of
        // filters. That is the audit's §6.16, and pinning it fixes it.
        //
        // iOS 26 keeps it inside. There the chips and the help button share one
        // `GlassEffectContainer` so the shapes merge and render in one pass, and the
        // row carries its own scroll edge effect; lifting one member out of the
        // container leaves the effect's boundary drawn as a visible rectangle beside
        // it. The row is also one chip shorter of overflowing there, because the
        // minimised search bar does not take a line of its own.
        Group {
            if LegacyChrome.isActive {
                HStack(spacing: AppSpacing.tight) {
                    chipScroller
                    helpButton
                        .padding(.trailing, AppSpacing.regular)
                }
            } else {
                chipScroller
            }
        }
        .compatGlassTransition(.matchedGeometry, reduceMotion: reduceMotion)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: selectedID)
        // One haptic per selection. Attaching the trigger to every chip produced
        // two taps (old selection off, new selection on).
        .sensoryFeedback(.selection, trigger: selectedID)
    }

    private var chipScroller: some View {
        ScrollView(.horizontal) {
            // Container spacing matches the stack's, so the chips stay distinct at
            // rest and only blend while the selection moves between them.
            CompatGlassContainer(spacing: AppSpacing.tight) {
                HStack(spacing: AppSpacing.tight) {
                    ForEach(chips) { chip in
                        chipButton(chip)
                    }
                    if !LegacyChrome.isActive {
                        helpButton
                    }
                    searchingDot
                }
                .padding(.horizontal, 2)
                // Liquid Glass grows a few points while pressed. Reserve that
                // space so a long press never crops the top or bottom edge.
                .padding(.vertical, 6)
            }
        }
        .scrollIndicators(.hidden)
        // Only on iOS 26, and only because Liquid Glass grows past its own bounds
        // under a press. On iOS 18 nothing grows, and leaving clipping off there let
        // the last chip paint straight over the pinned help button.
        .scrollClipDisabled(!LegacyChrome.isActive)
        .contentMargins(.leading, AppSpacing.regular, for: .scrollContent)
        .contentMargins(.trailing, AppSpacing.tight, for: .scrollContent)
        .modifier(ChipScrollEdge())
    }

    @ViewBuilder
    private var helpButton: some View {
        if let onHelp {
            Button(action: onHelp) {
                Image(systemName: "questionmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 20, height: 20)
            }
            .compatGlassButton(shape: .circle)
            .buttonBorderShape(.circle)
            // The same neutral tint the unselected chips take. Left on the app accent
            // it came out as a pink disc beside them — which on this bar reads as a
            // sixth, permanently-highlighted filter rather than as the one control
            // here that is not a filter at all.
            .tint(.primary)
            .compatGlassID("filter.help", in: glass)
            .accessibilityLabel("Erklärung der Status-Symbole")
        }
    }

    /// One button per chip, always — selection changes its *surface*, never its
    /// identity.
    ///
    /// This used to be `if selected { prominent button } else { plain button }`.
    /// Two branches are two views, so every tap removed one chip and inserted
    /// another; for the length of the animation both sat in the `HStack`, and the
    /// chips beside them jumped sideways and back. Now the selected chip's glass
    /// takes the tint and the rest of the row does not move.
    private func chipButton(_ chip: FilterChip) -> some View {
        Button { onSelect(chip.id) } label: {
            HStack(spacing: 5) {
                // Only the icon carries the status colour when not selected — a
                // row of fully tinted chips all shouting at once reads as noise.
                Image(systemName: chip.systemImage)
                    .imageScale(.small)
                    .foregroundStyle(chip.isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(chip.tint))
                Text(chip.title)
                    .fixedSize(horizontal: true, vertical: false)
                if let count = chip.count {
                    ChipCount(count: count)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(chip.isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(FilterChipStyle(isSelected: chip.isSelected, tint: chip.tint))
        .accessibilityLabel("\(contextLabel): \(chip.title)")
        .accessibilityValue(chip.count.map { "\($0)" } ?? "")
        .accessibilityAddTraits(chip.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Sucht-Punkt: reserviert immer 6 pt, blendet nur die Deckkraft — still,
    /// kein Spinner, kein Schieben der Chips wenn die Debounce einholt.
    private var searchingDot: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 6, height: 6)
            .opacity(isSearching ? 1 : 0)
            .animation(.appFeedback(reduceMotion: reduceMotion), value: isSearching)
            .accessibilityHidden(true)
    }
}

/// A filter chip: capsule, glass surface, damped press.
///
/// iOS 26: Liquid Glass, tinted when selected — the tint crossfades inside the
/// same glass shape. iOS 18: the blur-free chip surface below. Both scale to
/// 0.96 under the finger on the `.appPress` spring.
private struct FilterChipStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background { ChipSurface(isSelected: isSelected, tint: tint, isPressed: configuration.isPressed) }
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.appPress(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

private struct ChipSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let isSelected: Bool
    let tint: Color
    let isPressed: Bool

    var body: some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26, *), !LegacyChrome.isForced {
            Color.clear
                .glassEffect(isSelected ? Glass.regular.tint(tint) : Glass.regular, in: shape)
        } else {
            // iOS 18: no blur. The chip bar floats over scrolling rows, so the
            // unselected fill is dense enough to stay legible over them.
            let opaque = GlassPreference.prefersOpaque(reduceTransparency: reduceTransparency, contrast: contrast)
            shape
                .fill(isSelected
                      ? AnyShapeStyle(tint)
                      : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground).opacity(opaque ? 1 : 0.92)))
                .overlay { if !opaque { GlassSheen(shape: shape) } }
                .overlay { shape.fill(Color.primary.opacity(isPressed ? PressHighlight.opacity : 0)) }
                .overlay {
                    if opaque {
                        shape.strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5)
                    } else {
                        glossyRim(for: shape, colorScheme: colorScheme)
                    }
                }
        }
    }
}

/// Zähler im Chip: the digits roll to the new value, nothing else moves.
///
/// The old scale "pop" on top of the rolling digits was two motions for one
/// change, and it fired on every chip whose count moved — several at once.
private struct ChipCount: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let count: Int

    var body: some View {
        Text("\(count)")
            .monospacedDigit()
            .font(.caption.weight(.bold))
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
            .animation(.appFeedback(reduceMotion: reduceMotion), value: count)
            .accessibilityHidden(true)
    }
}

/// Tells the eye there is more to the right.
///
/// iOS 26 gets this from the scroll edge effect. iOS 18 has none, so a chip was
/// simply chopped off at the boundary with no way to tell a clipped label from the
/// end of the row; below iOS 26 the trailing edge fades instead of cutting.
/// Applied only where it is missing.
///
/// This used to be a gradient **mask** over the whole scroller. A mask is an
/// offscreen pass over the scrolling content, recomposited on every scroll frame
/// and every selection change — on an iPhone 11, for a static cue. A fixed fade
/// strip pinned to the trailing edge says the same thing for one small static
/// composite that never moves with the content.
private struct ChipScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if LegacyChrome.isActive {
            content.overlay(alignment: .trailing) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color(uiColor: .systemGroupedBackground), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 28)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}
