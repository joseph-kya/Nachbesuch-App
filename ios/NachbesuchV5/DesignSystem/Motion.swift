import SwiftUI

/// Zentrale Bewegungs-Definition — einzige Wahrheit für Dauer und Feder.
///
/// Regel-Tabelle (bitte EINHALTEN, keine Roh-Dauern wie `.snappy(duration: ...)`):
/// - Auf-/Zuklappen, Auswahl, Chips, Chrome ein/aus → `.appFeedback` (snappy .24,
///   extraBounce 0.03). Dafür auch der Alias `.appExpand` (gleicher Wert, klarer Name).
/// - Layout/Camera/Scroll/Sheets → `.appSettle` (smooth .34).
/// - Abschluss-Momente NUR → `.appCelebrate` (spring .45/.35). Nie für Routine!
/// - Reduce Motion: Federn werden zu `easeOut` (0.15–0.18), Transitions zu Fade.
///   Scale/Translation entfallen dort komplett — immer `reduceMotion` durchreichen.
///
/// Follows Apple's duration+bounce spring model and the HIG's Reduce Motion
/// obligations: tighten springs to remove bounce, and replace positional
/// transitions with fades rather than merely shortening them.
extension Animation {
    /// Everyday UI feedback: selection, chips, chrome appearing.
    /// AUCH für Expand/Collapse (dafür Alias `.appExpand` — selber Wert).
    static func appFeedback(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.24, extraBounce: 0.03)
    }

    /// Alias für Auf-/Zuklappen (Straßen, Blöcke in Karten). Gleicher Wert wie
    /// `.appFeedback` (.24 snappy) — der Name fängt künftige Roh-Dauern ab: wer
    /// expandiert, greift zu `appExpand`, nicht zu einer erfundenen Dauer.
    static func appExpand(reduceMotion: Bool) -> Animation {
        appFeedback(reduceMotion: reduceMotion)
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
    /// A floating chrome panel entering or leaving — anything that is not
    /// backed by a `glassEffectID`.
    ///
    /// Scale is deliberately shallow (0.94, not 0.7): these panels are wide, and a
    /// deep scale on a wide panel reads as a zoom rather than as an appearance. Under
    /// Reduce Motion this is a pure fade — no scale, no translation.
    static func appChrome(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
    }

    /// A block that comes and goes *inside* a card that stays put — the campaign-day
    /// picker, the revisit summary, the damaged-data warning, the fifth metric tile.
    ///
    /// Deliberately not `appChrome`: those are free-floating panels that arrive from
    /// nowhere, while these blocks are already inside a surface whose height is
    /// animating around them. A fade with a shallow top-anchored scale reads as the
    /// card growing a new section; anything deeper competes with the height change
    /// and produces the double motion this used to be turned off to avoid.
    static func blockSwap(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    }

    /// A banner sliding in from an edge — the notice banner and the undo banner.
    static func appBanner(edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: edge).combined(with: .opacity)
    }

    /// Strenge Innen-Zeilen (z. B. Adress-Zeilen im Container): NUR Fade, nie Scale/Move.
    ///
    /// Muster: `.transition(.opacityOnly(reduceMotion: ...))` + umgebende View `.clipped()`.
    /// Scale würde die Zeile aus dem Container reißen (siehe `GroupedRowStyle`);
    /// darum hier bewusst kein `blockSwap`/`appChrome`. Unter Reduce Motion
    /// ohnehin Fade — diese Transition ist also in beiden Modi identisch ruhig.
    static func opacityOnly(reduceMotion _: Bool) -> AnyTransition {
        .opacity
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

// MARK: - Haptik-Leitfaden (nur Doku, kein Verhalten)

/// Welches `sensoryFeedback` wohin gehört — zentrale Regel, damit Haptik nicht driftet.
///
/// - `.selection`: Toggles, Chips, Tabs, Filter, Segmentwechsel (leicht, reversibel).
/// - `.success`: Fertig/Teilen/Speichern — abgeschlossene Handlung (zuletzt: Export-Flush).
/// - `.warning`: ungültige Eingabe (noch nicht versendet, korrigierbar).
/// - `.error`: Fehlschlag (versendet und gescheitert).
///
/// Kein Code-Eingriff: Call-Sites nutzen weiterhin `.sensoryFeedback(...)` direkt;
/// dieses Enum ist der Kompass bei neuen Stellen. Kein Impact/Vibration roh streuen.
enum SensoryGuide {
    /// Umkehrbare Auswahl: Toggles, Chips, Tabs, Filter.
    case selection
    /// Abgeschlossene Handlung: fertig, teilen, speichern/flushen.
    case success
    /// Korrigierbare Fehleingabe (noch nichts versendet).
    case warning
    /// Gescheiterter Vorgang.
    case error
}

// MARK: - Scale-Leitfaden (nur Doku, kein Verhalten)

/// Wann Skalierung erlaubt ist — zentrale Regel, damit Press-Scale nicht wieder
/// in Container zurückkriecht und Kanten wellt (siehe `GroupedRowStyle`).
///
/// - `.freeFloatingChrome`: ERLAUBT — frei schwebende Flächen (Chrome-Panels per
///   `appChrome`, 0.94; freischwebende Karten-Zeilen per `PressableRowStyle`,
///   0.98). Nichts grenzt an, nichts kann wellen.
/// - `.groupedRowsNever`: VERBOTEN — gruppierte Zeilen im durchgehenden Container
///   (`GroupedRowStyle`, `opacityOnly`-Transition, `SectionSurface`). Scale reißt
///   die Zeile aus dem Container; dort nur `PressHighlight`-Highlight (0.08).
///
/// Kein Code-Eingriff: Call-Sites nutzen weiterhin `.appChrome`,
/// `.opacityOnly` bzw. die ButtonStyles direkt; dieses Enum ist der Kompass bei
/// neuen Stellen. Kein Scale unter Reduce Motion — immer `reduceMotion`
/// durchreichen.
enum ScaleGuide {
    /// Frei schwebendes Chrome / frei schwebende Karten: Scale erlaubt.
    case freeFloatingChrome
    /// Gruppierte Zeilen im Container: niemals skalieren, nur highlighten.
    case groupedRowsNever
}
