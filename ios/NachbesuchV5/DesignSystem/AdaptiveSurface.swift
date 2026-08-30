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
            content.compatGlass(interactive: isInteractive, in: shape, legacyShadowRadius: 8)
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
                .compatGlass(interactive: isInteractive, in: shape)
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
            // Liquid Glass is a lens. A lens over a flat field shows a flat field —
            // which is why the grouped list read as slabs of grey no matter what
            // material was under it: `systemGroupedBackground` plus a 10 % wash is
            // very nearly one colour, and there was nothing for the glass to bend.
            //
            // These two soft fields are what the surfaces above actually refract.
            // They are deliberately far apart and very low contrast: enough
            // luminance variation for an edge to catch and for a highlight to travel
            // as the list scrolls, not enough to read as decoration in their own
            // right.
            GeometryReader { proxy in
                let side = max(proxy.size.width, proxy.size.height)
                ZStack {
                    field(accent, opacity: colorScheme == .dark ? 0.52 : 0.22)
                        .frame(width: side * 0.95, height: side * 0.95)
                        .offset(x: -side * 0.28, y: -side * 0.20)
                    field(.blue, opacity: colorScheme == .dark ? 0.36 : 0.14)
                        .frame(width: side * 0.85, height: side * 0.85)
                        .offset(x: side * 0.34, y: side * 0.30)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .blur(radius: 60)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private func field(_ tint: Color, opacity: Double) -> some View {
        Circle().fill(
            RadialGradient(
                colors: [tint.opacity(opacity), tint.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 320
            )
        )
    }
}

// MARK: - Grouped section surface

/// One street and its addresses, drawn as a single container.
///
/// Apple's guidance for iOS 26 is explicit that Liquid Glass belongs to the
/// navigation layer — toolbars, tab bars, floating controls — and never to content;
/// a glass effect on every list row is called out by name as the way to overuse it.
/// The comment at the top of this file said the same thing already, and then
/// `contentCard` put glass on all 268 address rows anyway.
///
/// A material, and **not** `glassEffect` — tried, photographed, reverted.
///
/// A `listRowBackground` is per row, so "one glass surface per street" is not what
/// that spelling buys: it is one glass element per *row*, and a dozen of them
/// sampling and re-blurring inside the list's `GlassEffectContainer` compounds into
/// a muddy wash that leaves the house numbers barely legible. That is the "super
/// weird interface" Apple's guidance describes, and it looks exactly as bad as the
/// guidance says.
///
/// The reason this surface read as flat grey before was never the material. It was
/// the backdrop: a material is a lens, and `AppBackdrop` was very nearly one colour,
/// so there was nothing to bring into focus. The fields now behind it are what make
/// this read as glass, and they cost one blurred gradient for the whole screen
/// instead of a sample per row.
struct SectionSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Rounds the top — the street header.
    let isFirst: Bool
    /// Rounds the bottom — the last address, or a collapsed header.
    let isLast: Bool
    /// Air above the section. Carried by the background rather than by a spacer row
    /// so the gap between two streets cannot drift from the corner that sits in it.
    var topGap: CGFloat = 0

    /// One key for both ends, because two stacked `.animation(_:value:)` modifiers do
    /// not compose — the second silently overrides the first for the whole subtree.
    private struct Ends: Equatable {
        let first: Bool
        let last: Bool
    }

    private var prefersOpaque: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NACHBESUCH_REDUCE_TRANSPARENCY"] != nil {
            return true
        }
        #endif
        return reduceTransparency || colorSchemeContrast == .increased
    }

    /// What separates glass from frost.
    ///
    /// A material on its own is only the blur half: it diffuses what is behind it and
    /// stops there, which is frosted bathroom glass. Real Liquid Glass is blur *plus*
    /// specular — a lit edge and a sheen that say the surface has a front face
    /// catching a light. `glassEffect` supplies both, but it cannot be used here: as a
    /// `listRowBackground` it is one glass element per row, and a dozen of them
    /// sampling and re-blurring each other renders the house numbers illegible.
    /// Photographed, then reverted. So the specular is drawn by hand.
    ///
    /// Every piece of it is built to **tile vertically without a seam**, because this
    /// surface is one segment of a taller section and a horizontal edge anywhere
    /// except the section's real ends would draw a bright line across every row
    /// boundary:
    ///   - the sheen runs leading→trailing, so each segment paints an identical
    ///     gradient and the column reads as continuous;
    ///   - the rim is two vertical hairlines, which butt onto the next segment's
    ///     exactly;
    ///   - the rounded cap is stroked only on the segment that actually owns that
    ///     end, and masked to the corner band so its straight side never shows.
    @ViewBuilder
    private func gloss(_ shape: UnevenRoundedRectangle) -> some View {
        let rim = Color.white.opacity(colorScheme == .dark ? 0.32 : 0.68)
        ZStack {
            // Two stops, not one ramp: a bright band that falls off fast reads as a
            // light source glancing off a front face. A slow even ramp reads as a
            // tinted panel.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(colorScheme == .dark ? 0.19 : 0.32), location: 0),
                    .init(color: .white.opacity(colorScheme == .dark ? 0.05 : 0.10), location: 0.28),
                    .init(color: .white.opacity(0), location: 0.75)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .clipShape(shape)

            HStack(spacing: 0) {
                Rectangle().fill(rim).frame(width: 0.66)
                Spacer(minLength: 0)
                Rectangle().fill(rim).frame(width: 0.66)
            }
            .clipShape(shape)

            if isFirst {
                shape.strokeBorder(rim, lineWidth: 0.66)
                    .mask(alignment: .top) {
                        Rectangle().frame(height: AppRadius.card)
                    }
            }
            if isLast {
                shape.strokeBorder(rim.opacity(0.5), lineWidth: 0.66)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: AppRadius.card)
                    }
            }
        }
        .allowsHitTesting(false)
    }

    var body: some View {
        let shape = sectionShape(isFirst: isFirst, isLast: isLast)
        Group {
            if prefersOpaque {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
            } else {
                // `.ultraThin`, not `.regular`. This is the surface that has to read
                // as glass, and the thinner grade lets more of `AppBackdrop`'s colour
                // fields through — which is the whole difference between "translucent"
                // and "grey".
                // The material is held back from full strength on purpose. At 100 %
                // even `.ultraThin` is opaque enough to hide the backdrop's colour
                // fields, which are the only reason this surface reads as glass and
                // not as a grey box. Letting it sit at ~three-quarters lets the field
                // behind a street tint the street.
                shape.fill(.ultraThinMaterial)
                    .opacity(colorScheme == .dark ? 0.74 : 0.88)
                    .overlay { gloss(shape) }
            }
        }
        // The corners have to *travel*, and this is the modifier that makes them.
        //
        // `isLast` flips the instant a street is collapsed, so the header snapped to
        // a rounded bottom while its addresses were still fading out underneath it —
        // a hard-cut square edge sitting over ghost rows, with the next street sliding
        // up through the gap. `UnevenRoundedRectangle` animates its `RectangleCornerRadii`,
        // but only inside a transaction, and a `listRowBackground` does not inherit the
        // one the row's own removal is running in. Keying it here puts the rounding on
        // the same clock as the fold.
        .animation(.appFeedback(reduceMotion: reduceMotion), value: Ends(first: isFirst, last: isLast))
        .padding(.top, topGap)
        .padding(.horizontal, AppSpacing.regular)
    }
}

/// The container's outline at a given row position — rounded where the section
/// starts and ends, square where its rows meet.
///
/// Shared by the surface and by the press highlight drawn on top of it. A plain
/// `Rectangle` for the highlight painted square corners over the rounded material on
/// the first and last row of every street.
func sectionShape(isFirst: Bool, isLast: Bool) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(
        topLeadingRadius: isFirst ? AppRadius.card : 0,
        bottomLeadingRadius: isLast ? AppRadius.card : 0,
        bottomTrailingRadius: isLast ? AppRadius.card : 0,
        topTrailingRadius: isFirst ? AppRadius.card : 0,
        style: .continuous
    )
}

/// Press feedback for a row that shares a surface with its neighbours.
///
/// `PressableRowStyle` scales its label to 0.98, which is right for a card floating
/// on its own and wrong here: a row inside a continuous container visibly tears away
/// from the rows above and below it, and the container's edge ripples where the
/// scaled row no longer reaches it. A grouped row highlights instead — what a native
/// `List` row does, and the only press feedback that leaves the geometry alone.
struct GroupedRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isFirst = false
    var isLast = false
    /// Matches the surface's own `topGap`, so the highlight stops at the container's
    /// top edge instead of painting into the air above the street.
    var topGap: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                sectionShape(isFirst: isFirst, isLast: isLast)
                    .fill(.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(.top, topGap)
                    .padding(.horizontal, AppSpacing.regular)
                    .allowsHitTesting(false)
            }
            .animation(.appFeedback(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    /// The hairline between two rows of a section, inset to the text column so it
    /// starts where the words start — the iOS convention, and the thing that makes a
    /// run of rows read as one list instead of as separate slabs.
    @ViewBuilder
    func rowSeparator(_ isVisible: Bool) -> some View {
        overlay(alignment: .bottom) {
            if isVisible {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 0.5)
                    .padding(.leading, AppLayout.textInset)
            }
        }
    }
}
