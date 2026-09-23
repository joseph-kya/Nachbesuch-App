import SwiftUI

/// The iOS 18 presentation tier.
///
/// iOS 18 has no Liquid Glass, so this file builds the closest equivalent from
/// what iOS 18 does well: system materials (a real backdrop blur) for floating
/// chrome, a blur-free frosted fill for scrolling content, and the same sheen and
/// glossy rim on every surface. One design language on both OS versions; the
/// cost is spent where it shows (a handful of floating panels), never per list row.
///
/// The rule every wrapper here keeps:
///
/// > One view owns the shape. One view owns the fill. One view owns the border.
/// > One view owns the pressed state. One view owns the hit region.
///
/// Reduce Transparency and Increase Contrast always get an opaque surface.

/// Whether to render the pre-iOS 26 chrome.
///
/// `NACHBESUCH_LEGACY_CHROME` previews this tier on a modern simulator when an
/// iOS 18 runtime is unavailable. Real iOS 18 testing remains the release check.
/// This uses the same mechanism
/// `AdaptiveSurface` uses for Reduce Transparency, and DEBUG-only for the same reason.
///
///     SIMCTL_CHILD_NACHBESUCH_LEGACY_CHROME=1 xcrun simctl launch booted at.volkshilfe.nachbesuch.v5
enum LegacyChrome {
    static let isForced: Bool = {
        #if DEBUG
        // Presence is not enough: `SIMCTL_CHILD_…=""` still puts an entry in the
        // environment, which silently forced the legacy path on runs meant to be
        // modern and made the two look identical.
        let raw = ProcessInfo.processInfo.environment["NACHBESUCH_LEGACY_CHROME"] ?? ""
        return !raw.isEmpty && raw != "0"
        #else
        return false
        #endif
    }()

    /// True on iOS 18, and on iOS 26 when the harness asks for the legacy look.
    static var isActive: Bool {
        if isForced { return true }
        if #available(iOS 26, *) { return false }
        return true
    }
}

// MARK: - Container

/// Stands in for `GlassEffectContainer`, which merges co-located glass shapes into
/// one render pass. Below iOS 26 there is nothing to merge, so this is a pass-through.
///
/// - `spacing`: IMMER ein `AppSpacing`-Token (`tight` für enge Gruppen, `snug` als
///   Standard) — keine Rohwerte, damit Abstände nicht driften.
///   (Kleine Abstände lassen Glas-Formen verschmelzen; große zerreißen sie.)
///
/// The container also does *not* forward the safe area, which is why `AppChrome`
/// reserves tab bar clearance only on iOS 26 — see `tabBarClearance`.
struct CompatGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Surfaces

/// Which backdrop a floating surface has to stay legible against.
///
/// The audit's §3.4 finding: one surface recipe was being used over a pale grouped
/// background, over an elevated sheet and over dark satellite imagery. A regular
/// material that reads correctly over the first disappears over the third. iOS 18
/// therefore picks its fill from the backdrop, not from a house style.
enum CompatSurfaceRole {
    /// Over a quiet grouped background — list and archive chrome.
    case content
    /// Over MapKit. High-frequency, arbitrarily coloured, and the one place a weak
    /// material fails outright.
    case map
    /// Sitting *on* a content card that already provides the surface. A control here
    /// needs no fill of its own — giving it one is how the archive's overflow ended
    /// up as a pale pink disc floating on a white card, which the audit calls out by
    /// name. It still needs its 44 pt region and its own press state.
    case card
}

extension View {
    /// `glassEffect(_:in:)` on iOS 26, and the closest iOS 18 equivalent below it.
    ///
    /// iOS 18 has no Liquid Glass, but it has the ingredients: a system material
    /// (a real backdrop blur, the same one iOS 18's own Maps controls float on), a
    /// specular sheen along the top edge, and the glossy rim every glass surface in
    /// this app carries. Reduce Transparency and Increase Contrast still get an
    /// opaque surface — see `LegacyGlassSurface`.
    ///
    /// Only floating chrome reaches this: content cards and list sections take the
    /// blur-free `FrostedSurface` on iOS 18, because a live blur per scrolling card
    /// is a backdrop pass per card per frame.
    @ViewBuilder
    func compatGlass(
        interactive: Bool,
        in shape: some InsettableShape,
        role: CompatSurfaceRole = .content,
        legacyShadowRadius: CGFloat = 0
    ) -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            modifier(LegacyGlassSurface(shape: shape, role: role, shadowRadius: legacyShadowRadius))
        }
    }
}

/// Whether a custom surface must fall back to an opaque fill.
///
/// `accessibilityReduceTransparency` is read-only and the simulator cannot toggle
/// it, so the harness forces the opaque path with `NACHBESUCH_REDUCE_TRANSPARENCY`.
/// Cached: the environment lookup must not run per surface per frame.
enum GlassPreference {
    static let debugForceOpaque: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["NACHBESUCH_REDUCE_TRANSPARENCY"] != nil
        #else
        return false
        #endif
    }()

    static func prefersOpaque(reduceTransparency: Bool, contrast: ColorSchemeContrast) -> Bool {
        debugForceOpaque || reduceTransparency || contrast == .increased
    }
}

/// The light that makes a flat fill read as a pane of glass: a soft white sheen
/// falling off from the top edge. Static and cheap — one gradient fill, no blur.
struct GlassSheen<S: Shape>: View {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S

    var body: some View {
        shape.fill(
            LinearGradient(
                colors: [.white.opacity(colorScheme == .dark ? 0.10 : 0.38), .white.opacity(0)],
                startPoint: .top,
                endPoint: .center
            )
        )
        .allowsHitTesting(false)
    }
}

/// The iOS 18 floating glass: material, sheen, rim, one shadow on the shape.
private struct LegacyGlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S
    let role: CompatSurfaceRole
    let shadowRadius: CGFloat

    private var opaqueFill: Color {
        switch role {
        case .map: Color(uiColor: .systemBackground)
        case .content, .card: Color(uiColor: .secondarySystemBackground)
        }
    }

    /// Over MapKit the surface has to win against arbitrary tile colour, so it
    /// takes the thicker material; over the quiet app ground the regular one.
    private var material: Material {
        role == .map ? .regularMaterial : .thinMaterial
    }

    private func shadowOpacity(opaque: Bool) -> Double {
        switch (opaque, colorScheme == .dark) {
        case (true, true): 0.32
        case (true, false): 0.12
        case (false, true): 0.24
        case (false, false): 0.07
        }
    }

    func body(content: Content) -> some View {
        let opaque = GlassPreference.prefersOpaque(reduceTransparency: reduceTransparency, contrast: contrast)
        content
            .background {
                // The shadow belongs to the shape, never to the label: a shadow on
                // the whole view is an offscreen pass over its text as well.
                Group {
                    if opaque {
                        shape.fill(opaqueFill)
                    } else {
                        shape.fill(material)
                            .overlay { GlassSheen(shape: shape) }
                    }
                }
                // Lighter under glass than under an opaque fill: a material is
                // translucent, and a heavy shadow shows through it as a smudge.
                .shadow(
                    color: .black.opacity(shadowRadius > 0 ? shadowOpacity(opaque: opaque) : 0),
                    radius: shadowRadius,
                    y: shadowRadius > 0 ? shadowRadius / 3 : 0
                )
            }
            .overlay {
                if opaque {
                    shape.strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5)
                } else {
                    glossyRim(for: shape, colorScheme: colorScheme)
                }
            }
    }
}

// MARK: - Morph identity and transitions

/// Which glass transition a panel wants, expressed so the choice survives on a
/// system that has no glass. See `Motion.swift` for why the distinction matters.
enum CompatGlassTransition {
    /// Two panels that genuinely reshape into one another.
    case matchedGeometry
    /// A panel with a unique ID and no morph partner on the other side.
    case materialize
}

extension View {
    /// `glassEffectID(_:in:)` — inert below iOS 26, where nothing morphs.
    @ViewBuilder
    func compatGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// `glassEffectTransition(_:)` — inert below iOS 26. The ordinary SwiftUI
    /// `.transition` on these panels still runs there.
    @ViewBuilder
    func compatGlassTransition(_ kind: CompatGlassTransition, reduceMotion: Bool) -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            switch kind {
            case .matchedGeometry:
                glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            case .materialize:
                glassEffectTransition(reduceMotion ? .identity : .materialize)
            }
        } else {
            self
        }
    }
}

// MARK: - Buttons

/// The outline an iOS 18 control draws.
///
/// `buttonBorderShape` is a system-style input: a custom `ButtonStyle` cannot read
/// it, which is exactly how the icon-only map controls ended up as rectangles inside
/// circles. Where iOS 18 needs a custom style, the shape is therefore passed in.
enum CompatControlShape {
    case capsule
    case circle
}

extension View {
    /// Replaces `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`.
    ///
    /// Each branch has exactly one owner of shape, fill, border, press and hit
    /// region — no system button nested inside a separately drawn capsule, which is
    /// what produced the "rounded button in a box" on iOS 18 before.
    ///
    /// - iOS 26: the system glass styles.
    /// - iOS 18 prominent → `LegacyGlassProminentStyle`: a tinted glass drop with a
    ///   sheen, a rim and a soft coloured shadow.
    /// - iOS 18 plain → `LegacyGlassControlStyle`: material, sheen and rim, the
    ///   label in the tint (or primary over the map).
    /// - iOS 18 on a card → `LegacyCardControlStyle`: the glyph only — the card
    ///   already is the surface.
    @ViewBuilder
    func compatGlassButton(
        prominent: Bool = false,
        shape: CompatControlShape = .capsule,
        role: CompatSurfaceRole = .content
    ) -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(LegacyGlassProminentStyle(shape: shape))
        } else {
            switch role {
            case .map: buttonStyle(LegacyGlassControlStyle(shape: shape, role: .map))
            case .card: buttonStyle(LegacyCardControlStyle())
            case .content: buttonStyle(LegacyGlassControlStyle(shape: shape, role: .content))
            }
        }
    }
}

/// Label padding per control size, close to what the system bordered styles give,
/// so swapping styles never meaningfully changes a button's footprint.
private func legacyControlPadding(_ size: ControlSize, shape: CompatControlShape) -> EdgeInsets {
    if shape == .circle {
        let inset: CGFloat = switch size {
        case .mini, .small: 6
        case .large, .extraLarge: 10
        default: 8
        }
        return EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
    }
    switch size {
    case .mini, .small: return EdgeInsets(top: 5, leading: 11, bottom: 5, trailing: 11)
    // Large lands a 26 pt label exactly on the 44 pt target, level with the
    // circular map controls beside it.
    case .large, .extraLarge: return EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 20)
    default: return EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
    }
}

/// A control on a card: the glyph, nothing behind it, and a real hit region.
private struct LegacyCardControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.4))
            .frame(minWidth: AppTouch.minimum, minHeight: AppTouch.minimum)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? PressHighlight.opacity : 0))
            )
            .animation(.appPress(reduceMotion: reduceMotion), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// iOS 18 glass control: material disc or capsule with sheen and rim.
///
/// Over the map the label stays primary — a faint tinted glyph over map tiles
/// reads as nothing. Over content it takes the tint, as `.bordered` did.
private struct LegacyGlassControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let shape: CompatControlShape
    let role: CompatSurfaceRole

    func makeBody(configuration: Configuration) -> some View {
        let outline = AnyInsettableShape(shape)
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(role == .map ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tint))
            .padding(legacyControlPadding(controlSize, shape: shape))
            .frame(minWidth: shape == .circle ? AppTouch.minimum : nil,
                   minHeight: role == .map || controlSize == .large ? AppTouch.minimum : nil)
            .compatGlass(interactive: false, in: outline, role: role,
                         legacyShadowRadius: role == .map ? 6 : 0)
            .overlay { outline.fill(Color.primary.opacity(configuration.isPressed ? PressHighlight.opacity : 0)) }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.appPress(reduceMotion: reduceMotion), value: configuration.isPressed)
            .contentShape(outline)
    }
}

/// iOS 18 prominent glass: the tint as a lit, rounded drop.
///
/// Fill is the environment tint (`.tint`), so every `.tint(…)` at a call site
/// still decides the colour. The sheen and rim are what make it glass rather
/// than a flat pill; the coloured shadow is on the shape only.
private struct LegacyGlassProminentStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let shape: CompatControlShape

    func makeBody(configuration: Configuration) -> some View {
        let outline = AnyInsettableShape(shape)
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(legacyControlPadding(controlSize, shape: shape))
            .frame(minWidth: shape == .circle ? AppTouch.minimum : nil,
                   minHeight: controlSize == .large ? AppTouch.minimum : nil)
            .background {
                // Disabled drains the colour in the fill itself rather than via a
                // saturation filter over the whole button (an extra render pass).
                outline.fill(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(uiColor: .systemGray3)))
                    .overlay {
                        if !reduceTransparency {
                            outline.fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.30), .white.opacity(0)],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                        }
                    }
                    .shadow(color: .black.opacity(isEnabled ? 0.18 : 0), radius: 6, y: 3)
            }
            .overlay {
                outline.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.45), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
            .overlay { outline.fill(Color.black.opacity(configuration.isPressed ? 0.10 : 0)) }
            .opacity(isEnabled ? 1 : 0.7)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.appPress(reduceMotion: reduceMotion), value: configuration.isPressed)
            .contentShape(outline)
    }
}

/// Type-erases the two control outlines so one style can draw either without
/// generic parameters leaking into every call site.
struct AnyInsettableShape: InsettableShape {
    private let makePath: @Sendable (CGRect) -> Path
    private let inset: CGFloat

    init(_ shape: CompatControlShape, inset: CGFloat = 0) {
        self.inset = inset
        switch shape {
        case .capsule:
            makePath = { rect in Capsule(style: .continuous).path(in: rect) }
        case .circle:
            makePath = { rect in Circle().path(in: rect) }
        }
    }

    private init(makePath: @escaping @Sendable (CGRect) -> Path, inset: CGFloat) {
        self.makePath = makePath
        self.inset = inset
    }

    func path(in rect: CGRect) -> Path {
        makePath(rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> AnyInsettableShape {
        AnyInsettableShape(makePath: makePath, inset: inset + amount)
    }
}

// MARK: - Bars

extension View {
    /// `tabBarMinimizeBehavior(.onScrollDown)` — the iOS 18 tab bar is a fixed strip
    /// and has no minimised state, so there is nothing to ask for.
    @ViewBuilder
    func compatTabBarMinimize() -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// `searchToolbarBehavior(.minimize)` — the iOS 18 search field does not
    /// collapse into the toolbar, so there is no behaviour to select.
    @ViewBuilder
    func compatMinimizedSearch() -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            searchToolbarBehavior(.minimize)
        } else {
            self
        }
    }

    /// `safeAreaBar(edge:spacing:)` falls back to `safeAreaInset`. The difference is
    /// that a bar participates in the bar layout and an inset merely reserves space;
    /// for these banners the reserved space is the part that matters, and unlike an
    /// `overlay` an inset still does not swallow taps beneath it.
    @ViewBuilder
    func compatSafeAreaBar<Bar: View>(
        edge: VerticalEdge,
        spacing: CGFloat?,
        @ViewBuilder content: () -> Bar
    ) -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            safeAreaBar(edge: edge, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: spacing, content: content)
        }
    }
}

// MARK: - Scroll edges

extension View {
    /// `scrollEdgeEffectStyle(.soft, for:)` — the iOS 26 Liquid Glass treatment where
    /// content dissolves into the bar above it instead of sliding under a hard line.
    ///
    /// This is the glass that belongs on a list screen. The rows themselves are
    /// content and get a plain material; the *edge* where content meets the filter
    /// bar and the tab bar is navigation layer, and it is the place the effect was
    /// designed for. Inert below iOS 26, which has no scroll edge effect to style.
    @ViewBuilder
    func compatSoftScrollEdges() -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

// MARK: - System bar appearance

/// Makes the iOS 18 tab bar a surface again.
///
/// The audit's highest-priority defect: over the map the bar "visually dissolves
/// into the content", leaving three loose icons floating above the tiles, and dark
/// mode makes it worse because bar and map share values. The cause is the default
/// scroll-edge appearance, which is transparent — correct behind a scroll view whose
/// content has an edge effect, wrong behind edge-to-edge MapKit.
///
/// One opaque appearance for both states puts a real bar with a real hairline under
/// every tab, which is what iOS 18 does for itself. iOS 26 is untouched: the pill is
/// system-drawn there and already handles its own separation.
enum LegacyBarAppearance {
    static func applyIfNeeded() {
        // Deliberately a real availability check rather than `LegacyChrome.isActive`.
        // This reaches into UIKit's global appearance proxy, and the DEBUG override
        // exists to preview *our* surfaces on a modern runtime, not to restyle a
        // system bar that iOS 26 draws differently anyway.
        if #available(iOS 26, *) { return }

        // The system material, in both states. The default scroll-edge appearance
        // is fully transparent, which over edge-to-edge MapKit left three loose
        // icons floating on the tiles; an opaque strip fixed that but was the one
        // solid slab in an otherwise glass interface. The blurred default bar is
        // iOS 18's own glass and separates from the map on its own.
        let tabBar = UITabBarAppearance()
        tabBar.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        // Same reasoning one bar up: the list and archive titles sat on transparent
        // chrome over a tinted backdrop, so the title had no ground of its own.
        let navigationBar = UINavigationBarAppearance()
        navigationBar.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = navigationBar
        UINavigationBar.appearance().compactAppearance = navigationBar
        UINavigationBar.appearance().scrollEdgeAppearance = navigationBar
    }
}
