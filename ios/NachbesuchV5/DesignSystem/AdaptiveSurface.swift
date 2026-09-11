import SwiftUI

/// Einheitliche Glanzkante für ALLE Glas-Zweige — einzige Wahrheit, kein Duplikat.
///
/// - `MapChromeModifier`, `ContentCardModifier`, `SectionSurface` nutzen alle diese
///   Funktion; keine Inline-`white.opacity(...)`-Rahmen anderswo (auch nicht 0.10/0.22/0.55).
/// - Opake Zweige nutzen NIEMALS diese Kante, sondern `separator.opacity(0.6)`, 0.5 pt.
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

/// Content stays opaque so text and status colors remain stable while scrolling.
struct ContentCardModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let isInteractive: Bool
    let isElevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                }
            }
            .shadow(
                color: .black.opacity(isElevated ? (colorScheme == .dark ? 0.20 : 0.05) : 0),
                radius: isElevated ? 8 : 0,
                y: isElevated ? 2 : 0
            )
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

/// A neutral ground keeps the chosen accent on controls and status on content.
struct AppBackdrop: View {
    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// Street rows share the same opaque content surface as archive cards.
struct SectionSurface: View {
    let isFirst: Bool
    let isLast: Bool
    var topGap: CGFloat = 0

    var body: some View {
        sectionShape(isFirst: isFirst, isLast: isLast)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
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
