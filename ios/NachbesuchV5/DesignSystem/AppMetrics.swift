import SwiftUI

/// Shape and spacing tokens.
///
/// Split out of the old `AdaptiveGlass.swift`, which held corner radii that had
/// nothing to do with glass, and where two of five tokens carried the same value —
/// a distinction that conveyed nothing and was guaranteed to drift.
enum AppRadius {
    /// Chips, badges, inline pills.
    static let small: CGFloat = 12
    /// Buttons and segmented controls.
    static let control: CGFloat = 18
    /// Rows inside a list. Concentric with `card`, one step tighter.
    static let row: CGFloat = 24
    /// Cards inside a scroll view.
    static let card: CGFloat = 32
    /// Floating panels over the map.
    static let chrome: CGFloat = 32
}

enum AppSpacing {
    static let tight: CGFloat = 6
    static let snug: CGFloat = 10
    static let regular: CGFloat = 16
    static let loose: CGFloat = 24
}

/// Room a scrolling screen has to leave under itself for the **floating** tab bar.
///
/// The iOS 26 tab bar is a pill that hovers over the content rather than sitting in
/// a reserved strip, and `tabBarMinimizeBehavior(.onScrollDown)` means it is *meant*
/// to be scrolled under. What it is not meant to do is swallow the last row: at the
/// bottom of the list the final address sat half-behind the glass with no way to
/// bring it out. The system safe area does not cover this on its own here — both
/// scroll views sit inside a `GlassEffectContainer`, which does not forward it.
///
/// Measured on an iPhone 17 Pro: the pill clears the home indicator by roughly
/// 45 pt, plus a gap so the last card does not touch it.
enum AppChrome {
    static var tabBarClearance: CGFloat {
        // Only iOS 26 has the floating pill. The iOS 18 tab bar sits in a reserved
        // strip the system already accounts for, and there is no
        // `GlassEffectContainer` there to swallow the safe area, so reserving the
        // extra 58 pt would just leave a gap under the last row.
        // Deliberately real availability, not `LegacyChrome.isActive`: the tab bar
        // is drawn by the system, so the DEBUG override cannot turn the pill back
        // into a strip. Tying the clearance to the override would only put content
        // under a pill that is still there.
        if #available(iOS 26, *) { return 58 }
        return 0
    }
}

/// The minimum comfortable hit target. Applied via `.tappable()` so a control can
/// stay visually small while remaining reliably hittable — the old chrome had ten
/// controls between 20 and 36 pt using `.buttonStyle(.plain)`, which does not
/// expand the hit region past the label.
enum AppTouch {
    static let minimum: CGFloat = 44
}

extension View {
    /// Guarantees a 44 pt hit target without changing how the control looks.
    func tappable(_ shape: some Shape = Rectangle()) -> some View {
        frame(minWidth: AppTouch.minimum, minHeight: AppTouch.minimum)
            .contentShape(shape)
    }
}
