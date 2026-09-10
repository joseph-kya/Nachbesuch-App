import SwiftUI

/// Shape and spacing tokens.
///
/// Split out of the old `AdaptiveGlass.swift`, which held corner radii that had
/// nothing to do with glass, and where two of five tokens carried the same value —
/// a distinction that conveyed nothing and was guaranteed to drift.
/// The content layer draws **one** radius.
///
/// It used to draw four on a single screen — a 32 pt street card, a 24 pt address
/// card, an 11 pt icon squircle and a circle — stacked directly on top of each
/// other. Nested corners only read as deliberate when they are concentric, and
/// these shared no centre and no scale, so the list read as a pile of unrelated
/// rounded things. A street and its addresses are now one container with one
/// radius, and the shapes inside it are gone.
///
/// **Two scales, because there are two designs.** The values below are iOS 26's:
/// Liquid Glass is a thick, lensing material and a generous radius is what keeps it
/// from looking like a sheet of plastic. iOS 18 draws the same shapes as flat opaque
/// fills, and a 32 pt radius on a full-width flat card is not calm, it is a blob —
/// it stops reading as a card and starts reading as a lozenge with text in it. Every
/// iOS 18 radius here is the corresponding system value: 10 for controls, 16 for
/// grouped cards, matching what `insetGrouped` and iOS 18 sheets draw for themselves.
enum AppRadius {
    /// Chips, badges, inline pills.
    static var small: CGFloat { LegacyChrome.isActive ? 8 : 12 }
    /// Buttons and segmented controls.
    static var control: CGFloat { LegacyChrome.isActive ? 10 : 18 }
    /// Cards and grouped sections in the content layer.
    static var card: CGFloat { LegacyChrome.isActive ? 16 : 32 }
    /// Floating panels over the map.
    static var chrome: CGFloat { LegacyChrome.isActive ? 16 : 32 }
}

/// The leading columns a grouped list shares.
///
/// A street header and the addresses under it are one object, so they get one set
/// of edges. Before this, the header card began at 16, the address cards at 30 and
/// the header's icon at 20 — three left edges within 14 pt of one another, which
/// reads as three failed attempts at the same alignment rather than as a hierarchy.
enum AppLayout {
    /// Card edge to content.
    static let rowInset: CGFloat = 16
    /// The status glyph's column. The street header has nothing here, so its title
    /// starts at `rowInset` and the addresses are indented past it by exactly this
    /// column — one deliberate step instead of three near-misses.
    static let glyphColumn: CGFloat = 28
    static let glyphGap: CGFloat = 12
    /// Where every address's text — and every separator — begins, measured from the
    /// **card edge**, so it includes `rowInset`. `rowSeparator` is applied to a view
    /// that has already taken its own `rowInset` padding, which means it measures
    /// from the card edge too; leaving that term out put the hairlines 16 pt to the
    /// left of the text they are supposed to start under.
    static var textInset: CGFloat { rowInset + glyphColumn + glyphGap }
    /// Air between two street sections. The surface and the header content both
    /// reserve it: `listRowBackground` is laid out independently of the row's own
    /// content, so a gap added to only one of them puts the street name outside the
    /// container it belongs to.
    static let sectionGap: CGFloat = 14
}

enum AppSpacing {
    /// Enge Gruppe (z. B. `CompatGlassContainer` für verschmelzende Chips).
    static let tight: CGFloat = 6
    /// Standard-Abstand co-located Panels / Container-Spacing.
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
    /// Garantiert 44 pt Trefferfläche, ohne die Optik zu ändern.
    ///
    /// - Mindestmaß für JEDE tippbare Fläche (HIG); visuell kleine Glyph-Buttons
    ///   (z. B. Ellipse auf Karte, `LegacyCardControlStyle`) bekommen so trotzdem
    ///   ein verlässliches Ziel — auch unter Dynamic Type / AX-Größen.
    /// - Form mitgeben, wenn die Trefferfläche der sichtbaren Form folgen soll
    ///   (Kreis für runde Controls), sonst Rechteck.
    func tappable(_ shape: some Shape = Rectangle()) -> some View {
        frame(minWidth: AppTouch.minimum, minHeight: AppTouch.minimum)
            .contentShape(shape)
    }
}
