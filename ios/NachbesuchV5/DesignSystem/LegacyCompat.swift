import SwiftUI

/// The iOS 18 presentation tier.
///
/// This file used to be a set of one-line substitutions: every Liquid Glass API got
/// a "material equivalent" underneath it, and the iOS 18 build was iOS 26 with the
/// rendering engine removed. `IOS18_UI_AUDIT_AND_REMEDIATION.md` names what that
/// produced — a rounded control sitting inside a second, differently shaped box,
/// map chrome that dissolves into the map, and materials stacked on materials until
/// dark mode goes muddy.
///
/// It is now a **branch**, not a fallback. iOS 18 gets its own composition, built
/// from what iOS 18 is actually good at: semantic colours, opaque elevated
/// surfaces, system button styles, native bars, and short honest motion. Feature
/// parity is required; pixel parity is explicitly not.
///
/// The single rule the old file broke, and the one every wrapper here now keeps:
///
/// > One view owns the shape. One view owns the fill. One view owns the border.
/// > One view owns the pressed state. One view owns the hit region.

/// Whether to render the pre-iOS 26 chrome.
///
/// There is no iOS 18 simulator runtime on a machine that builds against the iOS 26
/// SDK, so the legacy path would otherwise be unreviewable. `NACHBESUCH_LEGACY_CHROME`
/// forces it on a modern system for exactly that reason — the same trick
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
    /// `glassEffect(_:in:)` with a genuine iOS 18 surface underneath it.
    ///
    /// On iOS 18 this is **opaque**, not translucent, and that is deliberate rather
    /// than a compromise. A blurred material over the map has to sample and re-blur
    /// the map every frame — which on an iPhone 11 is both the least legible option
    /// and the most expensive one. An elevated semantic background with a hairline
    /// and a soft shadow is what iOS 18 itself uses for floating chrome, reads at a
    /// glance over standard *and* satellite tiles in both appearances, and costs one
    /// fill.
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
            modifier(LegacySurface(shape: shape, role: role, shadowRadius: legacyShadowRadius))
        }
    }
}

/// The iOS 18 floating surface: one fill, one border, one shadow, one shape.
private struct LegacySurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    let role: CompatSurfaceRole
    let shadowRadius: CGFloat

    private var fill: Color {
        switch role {
        // `secondarySystemBackground` is the elevated level over a plain grouped
        // ground; over the map the surface has to win against arbitrary tile colour,
        // so it takes the base background — white in light, near-black in dark.
        case .map: Color(uiColor: .systemBackground)
        // `.card` never reaches here — a control on a card draws no surface at all —
        // but a panel asking for one gets the elevated level like any other.
        case .content, .card: Color(uiColor: .secondarySystemBackground)
        }
    }

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5) }
            .shadow(
                color: .black.opacity(shadowRadius > 0 ? (colorScheme == .dark ? 0.45 : 0.16) : 0),
                radius: shadowRadius,
                y: shadowRadius > 0 ? 2 : 0
            )
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
    /// **This is the fix for the audit's §3.1.** The old fallback put a system
    /// `.bordered` button — which owns its own shape, padding, clipping and pressed
    /// state — inside a separately applied `.regularMaterial` capsule with its own
    /// stroke. Two containers, two shapes, two boundaries, and when the parent
    /// proposed a rectangle the material took the rectangle while the control stayed
    /// round inside it. That is the "rounded button in a box" the field build shows.
    ///
    /// Each branch below now has exactly one owner of the container:
    ///
    /// - **prominent** → `.borderedProminent`. Fully system-owned; honours `.tint`
    ///   and `.buttonBorderShape`, and already carries its own press state.
    /// - **plain over content** → `.bordered`. Same deal, quieter.
    /// - **plain over the map** → `LegacyMapControlStyle`. The one case a system
    ///   style cannot serve: `.bordered` is a faint wash of the tint, and a faint
    ///   wash over map tiles is invisible. This style owns shape, fill, border,
    ///   press and hit region itself, and nothing is layered around it.
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
            buttonStyle(.borderedProminent)
        } else {
            switch role {
            case .map: buttonStyle(LegacyMapControlStyle(shape: shape))
            case .card: buttonStyle(LegacyCardControlStyle())
            case .content: buttonStyle(.bordered)
            }
        }
    }
}

/// A control on a card: the glyph, nothing behind it, and a real hit region.
///
/// `.bordered` inherits the app tint, so an ellipsis on a white card came out as a
/// red glyph on a pale red disc — a second surface on a surface, and one that reads
/// as a status colour on a screen where red already means "offen".
private struct LegacyCardControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.4))
            .frame(minWidth: AppTouch.minimum, minHeight: AppTouch.minimum)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .animation(.appFeedback(reduceMotion: reduceMotion), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// A map control on iOS 18: one opaque disc or capsule, one hairline, one press.
///
/// Deliberately not built on a system style. `.bordered` tints its fill at roughly
/// 15 % opacity, which over map tiles reads as nothing at all — and adding a
/// material behind a `.bordered` button is precisely the double container this
/// whole file exists to remove.
private struct LegacyMapControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    let shape: CompatControlShape

    private var horizontalPadding: CGFloat {
        switch shape {
        case .circle: 0
        case .capsule: controlSize == .small ? 12 : 16
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let outline = AnyInsettableShape(shape)
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, horizontalPadding)
            // 44 pt is the target and also the visible size of the circular
            // controls, so there is no separate `.tappable()` expanding a smaller
            // pill — one region, and it is the one that is drawn.
            .frame(
                minWidth: AppTouch.minimum,
                minHeight: AppTouch.minimum
            )
            .background(Color(uiColor: .systemBackground), in: outline)
            .overlay { outline.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5) }
            .overlay { outline.fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0)) }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16),
                radius: 6,
                y: 2
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.appFeedback(reduceMotion: reduceMotion), value: configuration.isPressed)
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

        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
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
