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
    /// Which backdrop this panel has to stay legible against. On iOS 26 glass adapts
    /// on its own; on iOS 18 a surface over MapKit needs a stronger fill than one
    /// over a grouped background — see `CompatSurfaceRole`.
    let role: CompatSurfaceRole

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
                .overlay { shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        } else {
            content.compatGlass(
                interactive: isInteractive,
                in: shape,
                role: role,
                legacyShadowRadius: 8
            )
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
        modifier(
            MapChromeModifier(
                cornerRadius: cornerRadius,
                isInteractive: interactive,
                role: .content
            )
        )
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
        modifier(
            MapChromeModifier(
                cornerRadius: cornerRadius,
                isInteractive: interactive,
                role: .map
            )
        )
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
        if prefersOpaque || LegacyChrome.isActive {
            // iOS 18 takes the same path Reduce Transparency does, and for the same
            // two reasons rather than as a concession. Legibility: a card is content,
            // and a translucent content card over a tinted backdrop is the "muddy
            // dark mode" and the "bright white stroke around every card" the audit
            // reports. Cost: a material is a backdrop sample per card, and a long
            // list on an iPhone 11 pays that per card per frame.
            content
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                .overlay { shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5) }
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

/// The ground these screens stand on.
///
/// **Two grounds, because there are two designs.**
///
/// On iOS 26 the wash exists so the glass has something to refract; without it the
/// cards read as plain white rectangles. That is its entire job — it is not a design
/// surface, which is why it stays monochrome and very faint.
///
/// On iOS 18 there is no glass, so there is nothing for the wash to serve, and it
/// stops being free. It was a full-screen `GeometryReader` drawing two radial
/// gradients into a `blur(radius: 60)` — an offscreen render pass the size of the
/// screen, recomposited behind a scrolling list, on a phone whose GPU is six years
/// old. It also produced the "large translucent red field" the audit flags in dark
/// mode, because a red accent at 18 % over black is a red field.
///
/// iOS 18 therefore gets what iOS 18 uses: the semantic grouped background, one
/// fill, no blur, no accent.
struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccent) private var accent

    var body: some View {
        if LegacyChrome.isActive {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
        } else {
            glassGround
        }
    }

    private var glassGround: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: [accent.opacity(colorScheme == .dark ? 0.10 : 0.055), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Two soft fields in the selected accent give glass something subtle to
            // refract. Keeping both fields monochrome avoids the accidental red/blue
            // split that made the app feel like two unrelated themes, while the low
            // contrast keeps the backdrop quiet behind field data.
            GeometryReader { proxy in
                let side = max(proxy.size.width, proxy.size.height)
                ZStack {
                    field(accent, opacity: colorScheme == .dark ? 0.18 : 0.08)
                        .frame(width: side * 0.95, height: side * 0.95)
                        .offset(x: -side * 0.28, y: -side * 0.20)
                    field(accent, opacity: colorScheme == .dark ? 0.10 : 0.045)
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
    @Environment(\.colorScheme) private var colorScheme

    /// Rounds the top — the street header.
    let isFirst: Bool
    /// Rounds the bottom — the last address, or a collapsed header.
    let isLast: Bool
    /// Air above the section. Carried by the background rather than by a spacer row
    /// so the gap between two streets cannot drift from the corner that sits in it.
    var topGap: CGFloat = 0

    private var prefersOpaque: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NACHBESUCH_REDUCE_TRANSPARENCY"] != nil {
            return true
        }
        #endif
        return reduceTransparency || colorSchemeContrast == .increased
    }

    var body: some View {
        let shape = sectionShape(isFirst: isFirst, isLast: isLast)
        Group {
            if prefersOpaque || LegacyChrome.isActive {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
            } else {
                // Match Archive's regular material grade, but keep it strictly in
                // the background. `glassEffect` is safe on Archive's card content;
                // as a List row background it becomes an effect layer over the row
                // and blurs the address text behind it.
                Color.clear
                    .background(.regularMaterial, in: shape)
                    .overlay {
                        shape.strokeBorder(
                            .white.opacity(colorScheme == .dark ? 0.10 : 0.55),
                            lineWidth: 0.66
                        )
                    }
            }
        }
        // Structural list updates are intentionally atomic. Animating these radii
        // independently from UIKit's row removal creates a transient pill or a clipped
        // bottom edge while the old rows are being recycled. The chevron and progress
        // controls still provide motion; the container shape simply resolves to the
        // correct geometry for its current state.
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
