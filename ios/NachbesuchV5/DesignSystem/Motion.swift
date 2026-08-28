import SwiftUI

/// One definition of the app's motion, instead of the five near-identical
/// `feedbackAnimation` properties that used to live in five different views.
///
/// Follows Apple's duration+bounce spring model and the HIG's Reduce Motion
/// obligations: tighten springs to remove bounce, and replace positional
/// transitions with fades rather than merely shortening them.
extension Animation {
    /// Everyday UI feedback: selection, chips, chrome appearing.
    static func appFeedback(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.24, extraBounce: 0.03)
    }

    /// Larger settling motion: sheets, camera, layout changes.
    static func appSettle(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .smooth(duration: 0.34)
    }

    /// Reserved for genuine moments of completion, never for routine interaction.
    static func appCelebrate(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(duration: 0.45, bounce: 0.35)
    }
}

extension AnyTransition {
    /// A floating chrome panel entering or leaving — the route cards, and anything
    /// else that is not backed by a `glassEffectID`.
    ///
    /// Scale is deliberately shallow (0.94, not 0.7): these panels are wide, and a
    /// deep scale on a wide panel reads as a zoom rather than as an appearance. Under
    /// Reduce Motion this is a pure fade — no scale, no translation.
    static func appChrome(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
    }

    /// A banner sliding in from an edge — the notice banner and the undo banner.
    static func appBanner(edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: edge).combined(with: .opacity)
    }
}

extension View {
    /// How a Liquid Glass panel that has **no morph partner** should enter and leave.
    ///
    /// Both map chrome containers set `.matchedGeometry` as the default for their
    /// descendants, which is right for the two pairs that genuinely reshape into one
    /// another (summary ⇄ selection bar, menu ⇄ cancel). For a panel with a unique
    /// `glassEffectID` there is nothing on the other side of the transition to match
    /// against, so it needs `materialize` instead — otherwise the glass shape is
    /// being asked to morph from a geometry that does not exist.
    func standaloneGlassTransition(reduceMotion: Bool) -> some View {
        compatGlassTransition(.materialize, reduceMotion: reduceMotion)
    }
}
