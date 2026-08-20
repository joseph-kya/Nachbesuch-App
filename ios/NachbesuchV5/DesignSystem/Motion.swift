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
    /// Floating chrome entering or leaving. Under Reduce Motion this is a pure
    /// fade — no scale, no translation.
    static func appChrome(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.97, anchor: .center))
    }
}
