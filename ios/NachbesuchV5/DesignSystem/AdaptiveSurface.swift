import SwiftUI

/// Einheitliche Glanzkante für ALLE Glas-Zweige — einzige Wahrheit, kein Duplikat.
///
/// - `MapChromeModifier`, `ContentCardModifier`, `SectionSurface` nutzen alle diese
///   Funktion; keine Inline-`white.opacity(...)`-Rahmen anderswo (auch nicht 0.10/0.22/0.55).
/// - Opake Zweige nutzen NIEMALS diese Kante, sondern `separator.opacity(0.6)`, 0.5 pt.
/// - Hell braucht mehr Hub als Dunkel: Weiß auf hellem Glas säuft bei 0.34 ab,
///   darum hell 0.55→0.10, dunkel 0.34→0.04. Breite immer 0.75.
/// - Offene Migration (fremde Map-Datei — NICHT hier editieren): `LegacyPreviewSurface`
///   in `Map/MapChrome.swift` dupliziert das Rim noch inline mit fest 0.34→0.04
///   (nur Dunkel-Werte, Hell 0.55→0.10 fehlt). Bei nächster Map-Änderung dort auf
///   `glossyRim(for:colorScheme:)` umstellen. Helper bewusst `internal` (nicht
///   `private`), damit die Map-Datei ihn ohne Duplikat nutzen kann.
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
}

/// Einheitlicher Press-Highlight-Wert für alle Stile — eine Zahl, kein Drift.
///
/// `GroupedRowStyle`, `LegacyCardControlStyle` und `LegacyMapControlStyle` lesen
/// alle diesen Wert (0.08). Skalierung steuert jeder Stil selbst (siehe unten).
enum PressHighlight {
    /// Primär-Tönung bei gedrücktem Zustand. Absichtlich dezent: lesbar, ohne Schmutz.
    static let opacity: CGFloat = 0.08
}

/// Floating panels and content cards share continuous corners and the one rim
/// above. The rim is static while the glass underneath stays interactive, which
/// keeps co-located panels reading as one material instead of drifting apart.
struct MapChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
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
    /// Cached: the environment lookup must not run per panel per frame.
    #if DEBUG
    private static let debugForceOpaque: Bool =
        ProcessInfo.processInfo.environment["NACHBESUCH_REDUCE_TRANSPARENCY"] != nil
    #endif

    private var prefersOpaque: Bool {
        #if DEBUG
        if Self.debugForceOpaque {
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
                .overlay { shape.strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5) }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.12), radius: 12, y: 4)
        } else {
            content.compatGlass(
                interactive: isInteractive,
                in: shape,
                role: role,
                legacyShadowRadius: 12
            )
            .overlay {
                // iOS 26 glass only: on the legacy path `compatGlass` already drew
                // its separator hairline, and a white rim over an opaque surface
                // is the bright stroke the audit reports.
                // Kanonisch: alle Glas-Zweige nutzen `glossyRim(for:colorScheme:)`.
                if !LegacyChrome.isActive {
                    glossyRim(for: shape, colorScheme: colorScheme)
                }
            }
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

/// One glass surface per card, with an inexpensive opaque iOS 18 fallback.
///
/// Schatten-Regel (einheitlich 12/4 Karten, 3/1 Controls):
/// - `elevated: true` NUR wo die Karte schwebt — Banner, Chrome, Hero-Karten.
/// - `elevated: false` für Listen-Zeilen und alles in scrollenden Stapeln: ein
///   weicher Schatten pro Zeile ist ein Offscreen-Pass pro Zeile und macht langes
///   Scrollen unruhig. Opaker Zweig dimmt den Schatten ebenfalls auf 0.
struct ContentCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let isInteractive: Bool
    /// Whether the card casts a shadow. Off for list rows: a soft shadow per row is
    /// an offscreen pass per row, and it is what makes a long list scroll unevenly.
    let isElevated: Bool

    /// Cached: the environment lookup must not run per card per frame.
    #if DEBUG
    private static let debugForceOpaque: Bool =
        ProcessInfo.processInfo.environment["NACHBESUCH_REDUCE_TRANSPARENCY"] != nil
    #endif

    private var prefersOpaque: Bool {
        #if DEBUG
        if Self.debugForceOpaque {
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
                .overlay { shape.strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5) }
                .shadow(
                    color: .black.opacity(isElevated ? (colorScheme == .dark ? 0.30 : 0.12) : 0),
                    radius: isElevated ? 12 : 0,
                    y: isElevated ? 4 : 0
                )
        } else {
            // iOS 26 only: `LegacyChrome` takes the opaque branch above, so the
            // glossy rim here can never land on an opaque surface.
            // Kanonisch: selber `glossyRim` wie überall, kein Inline-Weiß.
            content
                .compatGlass(interactive: isInteractive, in: shape)
                .overlay { glossyRim(for: shape, colorScheme: colorScheme) }
                .shadow(
                    color: .black.opacity(isElevated ? (colorScheme == .dark ? 0.30 : 0.12) : 0),
                    radius: isElevated ? 12 : 0,
                    y: isElevated ? 4 : 0
                )
        }
    }
}

extension View {
    /// Wann `elevated` an oder aus gehört (Schatten 12/4, dunkel 0.30 / hell 0.12):
    /// - `true`: Banner, schwebendes Chrome, Hero-Karten — alles, was über Inhalt floatet.
    /// - `false`: Listen-Zeilen, Outcome-Buttons, alles in scrollenden Stapeln (Perf).
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
    /// Ein Panel *innerhalb* einer Karte — die EINZIGE Innenflächen-Füllung.
    ///
    /// - NUR für innere Blöcke (tertiär 0.5); niemals als Kartenfüllung selbst —
    ///   Glas auf Glas wird matschig, darum trägt die Karte außen das Material.
    /// - Ecken immer `AppRadius.control` (iOS 26: 18, iOS 18: 10), Stil `.continuous`.
    /// - Kein Rim, kein Schatten: die umgebende Karte trägt beides.
    /// A panel *inside* a card. Glass on glass reads as mud, so an inner block gets
    /// a plain tinted fill and lets the card around it carry the material.
    func contentPanel(cornerRadius: CGFloat = AppRadius.control) -> some View {
        background(
            Color(uiColor: .tertiarySystemFill).opacity(0.5),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

/// Keep selection inside the glass edge. Both the inset and its reduced radius
/// use the same geometry, so the ring stays concentric at every corner.
///
/// Fest: Tint 1/0, 1.5 pt, Inset 3 — kein Glow. Ein Glow wäre ein zweiter
/// Blur-Pass pro selektierter Zeile; der Ring allein trägt die Auswahl.
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
        // Static washes only — no GeometryReader, no blur. The previous ground drew
        // two radial fields through a full-screen blur, an offscreen pass the size
        // of the screen recomposited behind the scrolling list. Flat gradients
        // rasterise once (`drawingGroup`) and stay monochrome so no accent split
        // can read as a second theme; the low contrast keeps the ground quiet.
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: [accent.opacity(colorScheme == .dark ? 0.10 : 0.055), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [.clear, accent.opacity(colorScheme == .dark ? 0.06 : 0.03)],
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

/// One glossy container per street, collapsed or expanded. iOS 18 and
/// accessibility opacity settings retain the inexpensive solid fill.
///
/// Glas-Zweig trägt denselben `glossyRim` wie Karten/Chrome (kein zweites Rim),
/// opaker Zweig dieselbe Separator-Haarlinie (0.6, 0.5 pt) wie überall.
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

    /// Cached: the environment lookup must not run per section per frame.
    #if DEBUG
    private static let debugForceOpaque: Bool =
        ProcessInfo.processInfo.environment["NACHBESUCH_REDUCE_TRANSPARENCY"] != nil
    #endif

    private var prefersOpaque: Bool {
        #if DEBUG
        if Self.debugForceOpaque {
            return true
        }
        #endif
        return reduceTransparency || colorSchemeContrast == .increased
    }

    var body: some View {
        let shape = sectionShape(isFirst: isFirst, isLast: isLast)
        Group {
            if prefersOpaque || LegacyChrome.isActive {
                // Opak: gleiche Haarlinie wie Karten/Chrome — sonst steht die
                // Sektion rahmenlos neben berandeten Karten.
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay {
                        shape.strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5)
                    }
            } else {
                // One glossy container per street, collapsed or expanded. The old
                // split (glass when shut, ultraThin when open) is what made an open
                // street go flat, and two stacked materials are what drew the seam
                // across the middle.
                // Kanonisch: selber Glanz wie Karten/Chrome, kein Inline-Weiß.
                Color.clear
                    .compatGlass(interactive: false, in: shape)
                    .overlay {
                        glossyRim(for: shape, colorScheme: colorScheme)
                    }

            }
        }
        .padding(.top, topGap)
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
/// Gegenstück zu `PressableRowStyle` (FilterBar, freischwebende Karten-Zeilen):
/// - `GroupedRowStyle`: NUR Highlight (`PressHighlight.opacity` = 0.08), KEIN Scale.
///   Skalieren reißt die Zeile aus dem durchgehenden Container (Kanten wellen sich).
///   Was eine native `List`-Zeile tut — Geometrie bleibt unangetastet.
/// - `PressableRowStyle`: Scale 0.98 + Dimmen — richtig für frei floatende Karten,
///   falsch im Container.
/// - Beide: kein Scale unter Reduce Motion, Animation immer `.appFeedback` (.24 snappy).
/// - Opazität überall 0.08 (`PressHighlight`), kein Sonderwert.
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
                    // Einheitlich 0.08 (`PressHighlight`), kein Scale — siehe Typ-Doku.
                    .fill(.primary.opacity(configuration.isPressed ? PressHighlight.opacity : 0))
                    .padding(.top, topGap)
                    .padding(.horizontal, AppSpacing.regular)
                    .allowsHitTesting(false)
            }
            .animation(.appFeedback(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    /// Die Haarlinie zwischen zwei Zeilen einer Sektion — KANONISCH.
    ///
    /// - Liegt an der Unterkante, beginnt bei `leading` (Standard `AppLayout.textInset`,
    ///   also Textspalte — iOS-Konvention: Zeilen lesen sich als eine Liste).
    /// - Gewicht immer 0.5 pt, Farbe `.separator`.
    /// - KEIN blanker `Divider` / `Rectangle` an Call-Sites: Einzug und Gewicht würden
    ///   sonst von Screen zu Screen driften. Wer eine Sektions-Trennlinie braucht,
    ///   nutzt diese Funktion (ggf. mit eigenem `leading`).
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
