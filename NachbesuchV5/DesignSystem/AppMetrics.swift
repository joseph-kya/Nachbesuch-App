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
