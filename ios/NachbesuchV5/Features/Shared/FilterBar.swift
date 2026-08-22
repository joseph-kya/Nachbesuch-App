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
/// The selected chip is a prominent glass button and the rest are plain glass, so
/// the selection travels as a material change inside one container. That replaced a
/// hand-rolled `matchedGeometryEffect` capsule — and with it the namespace, the
/// Reduce Motion special case and the dark-mode-broken badge colour.
struct FilterBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    let chips: [FilterChip]
    /// Named so VoiceOver says which filter list this is.
    var contextLabel: String
    var onSelect: (String) -> Void
    var onHelp: (() -> Void)?

    private var selectedID: String? { chips.first(where: \.isSelected)?.id }

    var body: some View {
        ScrollView(.horizontal) {
            // Container spacing matches the stack's, so the chips stay distinct at
            // rest and only blend while the selection moves between them.
            GlassEffectContainer(spacing: AppSpacing.tight) {
                HStack(spacing: AppSpacing.tight) {
                    ForEach(chips) { chip in
                        chipButton(chip)
                    }
                    if let onHelp {
                        Button(action: onHelp) {
                            Image(systemName: "questionmark")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .glassEffectID("filter.help", in: glass)
                        .accessibilityLabel("Erklärung der Status-Symbole")
                    }
                }
                .padding(.horizontal, 2)
                // Liquid Glass grows a few points while pressed. Reserve that
                // space so a long press never crops the top or bottom edge.
                .padding(.vertical, 6)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .contentMargins(.horizontal, AppSpacing.regular, for: .scrollContent)
        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: selectedID)
        // One haptic per selection. Attaching the trigger to every chip produced
        // two taps (old selection off, new selection on).
        .sensoryFeedback(.selection, trigger: selectedID)
    }

    @ViewBuilder
    private func chipButton(_ chip: FilterChip) -> some View {
        // Only the glyph carries the status colour when unselected — tinting the
        // whole row of chips made every filter shout at once.
        let label = HStack(spacing: 5) {
            Image(systemName: chip.systemImage)
                .imageScale(.small)
                .foregroundStyle(chip.isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(chip.tint))
            Text(chip.title)
            if let count = chip.count {
                Text("\(count)")
                    .monospacedDigit()
                    .font(.caption.weight(.bold))
                    .contentTransition(.numericText(value: Double(count)))
            }
        }
        .font(.subheadline.weight(.semibold))

        // Prominent fills with the tint; plain glass only tints its *content*, so a
        // selected chip styled as plain glass with white text rendered invisible.
        Group {
            if chip.isSelected {
                Button { onSelect(chip.id) } label: { label }
                    .buttonStyle(.glassProminent)
                    .tint(chip.tint)
            } else {
                Button { onSelect(chip.id) } label: { label }
                    .buttonStyle(.glass)
                    .tint(.primary)
            }
        }
            .glassEffectID("filter.\(chip.id)", in: glass)
            .accessibilityLabel("\(contextLabel): \(chip.title)")
            .accessibilityValue(chip.count.map { "\($0)" } ?? "")
            .accessibilityAddTraits(chip.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Press feedback for card-style rows. One definition, previously copied verbatim
/// into two different views.
struct PressableRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.appFeedback(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
