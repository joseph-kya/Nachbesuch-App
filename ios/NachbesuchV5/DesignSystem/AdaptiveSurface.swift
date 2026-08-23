import SwiftUI

/// Floating surfaces over the map — the navigation layer.
///
/// The HIG puts Liquid Glass in the navigation layer and standard materials in the
/// content layer, so panels that float over the map get glass and cards inside a
/// scrolling list deliberately do not.
///
/// Liquid Glass adapts to Reduce Transparency and Increase Contrast on its own for
/// system controls, but a custom panel has to opt in — and on a map already busy
/// compositing thousands of pins, the opaque path is also the cheaper one.
struct MapChromeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let cornerRadius: CGFloat
    let isInteractive: Bool

    /// `accessibilityReduceTransparency` is read-only and the simulator cannot
    /// toggle it, so the harness forces the opaque path to verify it renders.
    private var prefersOpaque: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NACHBESUCH_REDUCE_TRANSPARENCY"] != nil {
            return true
        }
        #endif
        return reduceTransparency || colorSchemeContrast == .increased
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if prefersOpaque {
            content
                .background(Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay { shape.strokeBorder(.separator.opacity(0.4), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        } else {
            content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        }
    }
}

extension View {
    /// A custom control surface in the app's navigation layer.
    ///
    /// The semantic name keeps list and archive chrome from depending on a map-
    /// specific implementation detail. `mapChrome` remains as a compatibility
    /// spelling for the existing map controls.
    func navigationGlass(
        cornerRadius: CGFloat = AppRadius.chrome,
        interactive: Bool = false
    ) -> some View {
        modifier(MapChromeModifier(cornerRadius: cornerRadius, isInteractive: interactive))
    }

    /// A floating panel over the map.
    ///
    /// Callers put co-located panels inside a single `GlassEffectContainer` so the
    /// shapes can merge and render in one pass — Apple warns that many separate
    /// effect containers degrade performance.
    func mapChrome(
        cornerRadius: CGFloat = AppRadius.chrome,
        interactive: Bool = false
    ) -> some View {
        navigationGlass(cornerRadius: cornerRadius, interactive: interactive)
    }
}

/// Content-layer card.
///
/// Glass, but a quieter grade than the floating chrome: a card sits *in* the scroll
/// view rather than over it, so it gets the material plus a hairline edge and a soft
/// shadow to lift it off the backdrop. Flat `secondarySystemGroupedBackground` panels
/// read as white boxes against the tinted backdrop these screens use.
struct ContentCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let isInteractive: Bool
    /// Whether the card casts a shadow. Off for list rows: a soft shadow per row is
    /// an offscreen pass per row, and it is what makes a long list scroll unevenly.
    let isElevated: Bool

    private var prefersOpaque: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NACHBESUCH_REDUCE_TRANSPARENCY"] != nil {
            return true
        }
        #endif
        return reduceTransparency || colorSchemeContrast == .increased
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if prefersOpaque {
            content
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                .overlay { shape.strokeBorder(.separator.opacity(0.35), lineWidth: 0.5) }
        } else {
            content
                .glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
                // The rim is what makes a glass card read as an object rather than a
                // lighter patch of background.
                .overlay {
                    shape.strokeBorder(
                        .white.opacity(colorScheme == .dark ? 0.10 : 0.55),
                        lineWidth: 0.66
                    )
                }
                .shadow(
                    color: .black.opacity(isElevated ? (colorScheme == .dark ? 0.30 : 0.07) : 0),
                    radius: isElevated ? 10 : 0,
                    y: isElevated ? 4 : 0
                )
        }
    }
}

extension View {
    func contentCard(
        cornerRadius: CGFloat = AppRadius.card,
        interactive: Bool = false,
        elevated: Bool = true
    ) -> some View {
        modifier(
            ContentCardModifier(
                cornerRadius: cornerRadius,
                isInteractive: interactive,
                isElevated: elevated
            )
        )
    }
}

extension View {
    /// A panel *inside* a card. Glass on glass reads as mud, so an inner block gets
    /// a plain tinted fill and lets the card around it carry the material.
    func contentPanel(cornerRadius: CGFloat = AppRadius.control) -> some View {
        background(
            Color(uiColor: .tertiarySystemFill).opacity(0.5),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

/// The tinted ground these screens put their glass on.
///
/// Glass has nothing to refract over a flat system background, which is why the
/// cards used to read as plain white rectangles. That refraction is the backdrop's
/// entire job — it is not a design surface.
///
/// So: **one** gradient, in the accent alone. It used to be three layers — a linear
/// wash that ran accent→clear→*blue*, plus a radial glow in the corner. The blue was
/// a second colour nobody had chosen and the app never used elsewhere; the radial
/// was a highlight over a scroll view whose content slides straight through it. Two
/// of the three answered no question at all, and the cards look the same without
/// them. Deliberately faint: the first attempt at 0.16 turned the whole screen pink,
/// because an opacity that reads as subtle on a neutral accent does not on red.
struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccent) private var accent

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: [accent.opacity(colorScheme == .dark ? 0.10 : 0.055), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}
