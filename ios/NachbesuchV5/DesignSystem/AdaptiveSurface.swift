import SwiftUI

/// Einheitliche Glanzkante für ALLE Glas-Zweige — einzige Wahrheit, kein Duplikat.
///
/// - Chrome, Karten, Sektionen und die iOS-18-Glasknöpfe nutzen alle diese
///   Funktion; keine Inline-`white.opacity(...)`-Rahmen anderswo.
/// - Opake Zweige (Transparenz reduzieren / Kontrast erhöhen) nutzen NIEMALS diese
///   Kante, sondern `separator.opacity(0.6)`, 0.5 pt.
/// - Hell braucht mehr Hub als Dunkel: Weiß auf hellem Glas säuft bei 0.34 ab,
///   darum hell 0.55→0.10, dunkel 0.34→0.04. Breite immer 0.75.
func glossyRim<S: InsettableShape>(for shape: S, colorScheme: ColorScheme) -> some View {
    let top = colorScheme == .dark ? 0.34 : 0.55
    let bottom = colorScheme == .dark ? 0.04 : 0.10
    return shape.strokeBorder(
        LinearGradient(
            colors: [.white.opacity(top), .white.opacity(bottom)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        lineWidth: 0.75
    )
    .allowsHitTesting(false)
}

/// Einheitlicher Press-Highlight-Wert für alle Stile — eine Zahl, kein Drift.
enum PressHighlight {
    /// Primär-Tönung bei gedrücktem Zustand. Absichtlich dezent: lesbar, ohne Schmutz.
    static let opacity: CGFloat = 0.08
}

// MARK: - Frosted content surface (blur-free)

/// Glass for content that scrolls — without a live blur.
///
/// A content card or list section sits on `AppBackdrop`, which never moves. A
/// backdrop blur of something that never moves is a translucent fill, so this
/// draws exactly that: the grouped card colour at partial opacity over the tinted
/// ground, the top-edge sheen and the glossy rim. It reads as frosted glass and
/// costs one fill — no backdrop sample per card per frame, which is what a real
/// material costs on a scrolling list on an iPhone 11.
///
/// Used on iOS 18 for cards and sections. iOS 26 uses real Liquid Glass.
struct FrostedSurface<S: InsettableShape>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S

    var body: some View {
        if GlassPreference.prefersOpaque(reduceTransparency: reduceTransparency, contrast: contrast) {
            shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay { shape.strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5) }
        } else {
            shape.fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.62 : 0.68))
                .overlay { GlassSheen(shape: shape) }
                .overlay { glossyRim(for: shape, colorScheme: colorScheme) }
        }
    }
}

// MARK: - Floating chrome

/// Floating panels share continuous corners and the one rim above. The rim is
/// static while the glass underneath stays interactive, which keeps co-located
/// panels reading as one material instead of drifting apart.
struct MapChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let isInteractive: Bool
    /// Which backdrop this panel has to stay legible against — see `CompatSurfaceRole`.
    let role: CompatSurfaceRole

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if LegacyChrome.isActive {
            // iOS 18: material glass, sheen, rim, one shadow on the shape. The
            // surface itself falls back to opaque under Reduce Transparency.
            content.compatGlass(
                interactive: isInteractive,
                in: shape,
                role: role,
                legacyShadowRadius: 12
            )
        } else {
            // iOS 26: the system glass already carries depth and adapts to
            // Reduce Transparency / Increase Contrast by itself. No manual shadow:
            // a second shadow under Liquid Glass doubles its edge.
            content
                .compatGlass(interactive: isInteractive, in: shape, role: role)
                .overlay { glossyRim(for: shape, colorScheme: colorScheme) }
        }
    }
}

extension View {
    /// A custom control surface in the app's navigation layer (list and archive).
    func navigationGlass(
        cornerRadius: CGFloat = AppRadius.chrome,
        interactive: Bool = false
    ) -> some View {
        modifier(MapChromeModifier(cornerRadius: cornerRadius, isInteractive: interactive, role: .content))
    }

    /// A floating panel over the map.
    ///
    /// Callers put co-located panels inside a single `GlassEffectContainer` so the
    /// shapes can merge and render in one pass.
    func mapChrome(
        cornerRadius: CGFloat = AppRadius.chrome,
        interactive: Bool = false
    ) -> some View {
        modifier(MapChromeModifier(cornerRadius: cornerRadius, isInteractive: interactive, role: .map))
    }
}

// MARK: - Content cards

/// One glass surface per card.
///
/// Schatten-Regel:
/// - `elevated: true` NUR wo die Karte schwebt — Banner, Hero-Karten.
/// - `elevated: false` für Zeilen und alles in scrollenden Stapeln.
/// - Der Schatten liegt immer auf der Form, nie auf dem Inhalt: ein Schatten auf
///   der ganzen View ist ein Offscreen-Pass über jeden Buchstaben darin.
/// - iOS 26 Glas bekommt keinen Zusatzschatten — es bringt seine Tiefe mit.
struct ContentCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let isInteractive: Bool
    let isElevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if LegacyChrome.isActive {
            content.background {
                FrostedSurface(shape: shape)
                    .shadow(
                        color: .black.opacity(isElevated ? (colorScheme == .dark ? 0.28 : 0.08) : 0),
                        radius: isElevated ? 10 : 0,
                        y: isElevated ? 3 : 0
                    )
            }
        } else {
            content
                .compatGlass(interactive: isInteractive, in: shape)
                .overlay { glossyRim(for: shape, colorScheme: colorScheme) }
        }
    }
}

extension View {
    func contentCard(
        cornerRadius: CGFloat = AppRadius.card,
        interactive: Bool = false,
        elevated: Bool = true
    ) -> some View {
        modifier(ContentCardModifier(cornerRadius: cornerRadius, isInteractive: interactive, isElevated: elevated))
    }

    /// Ein Panel *innerhalb* einer Karte — die EINZIGE Innenflächen-Füllung.
    ///
    /// Glas auf Glas wird matschig, darum bekommt ein innerer Block eine flache
    /// getönte Füllung und die Karte außen trägt das Material.
    func contentPanel(cornerRadius: CGFloat = AppRadius.control) -> some View {
        background(
            Color(uiColor: .tertiarySystemFill).opacity(0.5),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

// MARK: - Forms and sheets

/// Row background for grouped forms and lists inside sheets: a translucent pane.
///
/// Opaque grouped cells are the one solid slab left in a glass sheet. This keeps
/// the grouped geometry (the list still rounds the section corners) and lets the
/// sheet's glass — or iOS 18's material — show through, at a density that keeps
/// text and controls fully legible. Opaque under Reduce Transparency.
struct GlassRowFill: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if GlassPreference.prefersOpaque(reduceTransparency: reduceTransparency, contrast: contrast) {
            Color(uiColor: .secondarySystemGroupedBackground)
        } else {
            Color(uiColor: .secondarySystemGroupedBackground)
                .opacity(colorScheme == .dark ? 0.55 : 0.62)
        }
    }
}

extension View {
    /// Applied to a `Section` (or row): translucent glass rows.
    func glassRows() -> some View {
        listRowBackground(GlassRowFill())
    }

    /// A `Form` / `List` that lets its sheet's glass through.
    ///
    /// iOS 26 sheets are Liquid Glass at partial heights; an opaque grouped
    /// background painted over them hid it completely. iOS 18 sheets get a
    /// system material instead of the flat sheet colour.
    func glassForm() -> some View {
        scrollContentBackground(.hidden)
            .compatSheetGlass()
    }

    /// The sheet's own background: system glass on iOS 26 (nothing to do), a
    /// thick material on iOS 18, the default opaque sheet under Reduce Transparency.
    @ViewBuilder
    func compatSheetGlass() -> some View {
        if LegacyChrome.isActive {
            modifier(LegacySheetGlass())
        } else {
            self
        }
    }
}

private struct LegacySheetGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if GlassPreference.prefersOpaque(reduceTransparency: reduceTransparency, contrast: contrast) {
            content.presentationBackground(Color(uiColor: .systemGroupedBackground))
        } else {
            content.presentationBackground(.thickMaterial)
        }
    }
}

// MARK: - Selection ring

/// Keep selection inside the glass edge. Both the inset and its reduced radius
/// use the same geometry, so the ring stays concentric at every corner.
struct SelectionRing: ViewModifier {
    let isSelected: Bool
    let tint: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .inset(by: 3)
                .strokeBorder(tint.opacity(isSelected ? 1 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func selectionRing(_ isSelected: Bool, tint: Color,
                       cornerRadius: CGFloat = AppRadius.control) -> some View {
        modifier(SelectionRing(isSelected: isSelected, tint: tint, cornerRadius: cornerRadius))
    }
}

// MARK: - Ground

/// The ground every screen stands on — the thing the glass refracts.
///
/// Without it the cards read as plain white rectangles. It stays monochrome in the
/// accent and very faint: its only job is to give the glass something to bend.
///
/// Static by construction: two linear gradients rasterised once
/// (`drawingGroup`), no `GeometryReader`, no blur. The earlier ground drew radial
/// fields through a full-screen blur — an offscreen pass the size of the screen
/// recomposited behind a scrolling list. This one is one texture, on every OS.
struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccent) private var accent

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: [accent.opacity(colorScheme == .dark ? 0.10 : 0.06), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [.clear, accent.opacity(colorScheme == .dark ? 0.06 : 0.035)],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .drawingGroup()
    }
}

// MARK: - Grouped section surface

/// One glass container per street, collapsed or expanded.
///
/// iOS 26: real glass. iOS 18: the blur-free frosted surface — a list row scrolls,
/// and a live blur per row is exactly the cost this app must not pay there.
struct SectionSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Rounds the top — the street header.
    let isFirst: Bool
    /// Rounds the bottom — the last address, or a collapsed header.
    let isLast: Bool
    /// Air above the section, carried by the background so the gap between two
    /// streets cannot drift from the corner that sits in it.
    var topGap: CGFloat = 0

    var body: some View {
        let shape = sectionShape(isFirst: isFirst, isLast: isLast)
        Group {
            if LegacyChrome.isActive {
                FrostedSurface(shape: shape)
            } else {
                Color.clear
                    .compatGlass(interactive: false, in: shape)
                    .overlay { glossyRim(for: shape, colorScheme: colorScheme) }
            }
        }
        .padding(.top, topGap)
    }
}

/// The container's outline at a given row position — rounded where the section
/// starts and ends, square where its rows meet.
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
/// Highlight only, never scale: scaling tears the row out of the continuous
/// container. `PressableRowStyle` (Motion.swift) is the free-floating counterpart.
struct GroupedRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isFirst = false
    var isLast = false
    var topGap: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                sectionShape(isFirst: isFirst, isLast: isLast)
                    .fill(.primary.opacity(configuration.isPressed ? PressHighlight.opacity : 0))
                    .padding(.top, topGap)
                    .padding(.horizontal, AppSpacing.regular)
                    .allowsHitTesting(false)
            }
            .animation(.appPress(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    /// Die Haarlinie zwischen zwei Zeilen einer Sektion — KANONISCH.
    @ViewBuilder
    func rowSeparator(_ isVisible: Bool, leading: CGFloat = AppLayout.textInset) -> some View {
        overlay(alignment: .bottom) {
            if isVisible {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 0.5)
                    .padding(.leading, leading)
            }
        }
    }
}
