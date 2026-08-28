import SwiftUI

/// Back-compatibility for iOS 18–25.
///
/// Every Liquid Glass API in this app is iOS 26-only. Rather than gate ~65 call
/// sites individually, each one goes through a `compat…` wrapper here that keeps
/// the real glass on iOS 26 and falls back to a material equivalent below it.
///
/// The fallbacks are deliberately *equivalents*, not imitations: on iOS 18 there is
/// no lensing, no shape merging, and no morph between two IDs, so the wrappers
/// degrade to a plain material with a hairline rim — the same visual language the
/// Reduce Transparency path in `AdaptiveSurface` already uses.

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
        if #available(iOS 26, *), !LegacyChrome.isForced { return false }
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

extension View {
    /// `glassEffect(_:in:)` with a material fallback.
    ///
    /// Glass carries its own edge and its own separation from the backdrop; a plain
    /// material carries neither, so the fallback draws a hairline rim, and floating
    /// chrome passes a `legacyShadowRadius` so it still reads as sitting *over* the
    /// map rather than being painted onto it. Surfaces that already cast their own
    /// shadow leave the radius at zero.
    @ViewBuilder
    func compatGlass(
        interactive: Bool,
        in shape: some InsettableShape,
        legacyShadowRadius: CGFloat = 0
    ) -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.separator.opacity(0.4), lineWidth: 0.5) }
                .shadow(
                    color: .black.opacity(legacyShadowRadius > 0 ? 0.14 : 0),
                    radius: legacyShadowRadius,
                    y: legacyShadowRadius > 0 ? 3 : 0
                )
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

extension View {
    /// Replaces `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`.
    ///
    /// The fallback is `.bordered` / `.borderedProminent` rather than a hand-rolled
    /// style. A custom `ButtonStyle` cannot see `buttonBorderShape`, and it has to
    /// re-derive its padding from `controlSize` by hand — the first attempt did
    /// neither, which turned the icon-only map controls into ovals a size too small.
    /// The system styles honour both modifiers, and they are what these controls
    /// looked like before Liquid Glass anyway.
    @ViewBuilder
    func compatGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26, *), !LegacyChrome.isForced {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            // `.bordered` fills with a faint wash of the tint. That is legible on a
            // settings screen and almost invisible over the map, where these same
            // controls sit on top of hundreds of pins — so the fallback puts a
            // material underneath it. `Capsule` covers both border shapes: the
            // circular controls are laid out square, and a capsule on a square frame
            // *is* a circle.
            buttonStyle(.bordered)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5) }
        }
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
