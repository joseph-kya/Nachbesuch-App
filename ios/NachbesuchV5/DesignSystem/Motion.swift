import SwiftUI

/// Zentrale Bewegungs-Definition — einzige Wahrheit für Dauer und Feder.
///
/// **Ein Charakter, nicht fünf.** Jede Kurve hier ist eine kritisch gedämpfte
/// (oder fast gedämpfte) Feder: sie startet mit dem Schwung der Geste, kommt
/// weich an und schwingt nicht nach. Das ist der Unterschied zwischen „modern
/// und ruhig" und „hüpfend": Überschwingen liest sich auf Glas als Wackeln,
/// weil die Lichtkante jede Bewegung doppelt zeigt.
///
/// Regel-Tabelle (bitte EINHALTEN, keine Roh-Dauern an Call-Sites):
/// - Drücken/Loslassen → `.appPress` (0.26, ohne Bounce). Nur ButtonStyles.
/// - Auswahl, Chips, Zähler, Chrome ein/aus → `.appFeedback` (smooth 0.32).
/// - Auf-/Zuklappen (Straßen, Blöcke in Karten) → `.appExpand` (smooth 0.40).
/// - Layout/Kamera/Scroll/Inhaltswechsel → `.appSettle` (smooth 0.48).
/// - Echte Abschluss-Momente NUR → `.appCelebrate` (spring 0.55, bounce 0.15).
/// - Reduce Motion: alles wird zu einer kurzen Überblendung (easeInOut 0.2),
///   Transitions zu reinem Fade — Scale/Translation entfallen dort komplett.
///
/// Follows Apple's duration+bounce spring model and the HIG's Reduce Motion
/// obligations: remove bounce, and replace positional transitions with fades
/// rather than merely shortening them.
extension Animation {
    /// Press-in / press-out of a control. Short enough to track the finger,
    /// damped so a quick tap never wobbles.
    static func appPress(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.26, bounce: 0)
    }

    /// Everyday UI feedback: selection, chips, counters, chrome appearing.
    static func appFeedback(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.32)
    }

    /// Expanding and collapsing a block inside a surface that stays put. A touch
    /// longer than feedback: the eye follows a height change, not a colour change.
    static func appExpand(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4)
    }

    /// Larger settling motion: camera, scroll, content replaced wholesale.
    static func appSettle(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.22) : .smooth(duration: 0.48)
    }

    /// Reserved for genuine moments of completion, never for routine interaction.
    /// A small, single overshoot — enough to feel like an arrival, not a bounce.
    static func appCelebrate(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.22) : .spring(duration: 0.55, bounce: 0.15)
    }
}

extension AnyTransition {
    /// A floating chrome panel entering or leaving — anything that is not
    /// backed by a `glassEffectID`.
    ///
    /// Scale is deliberately shallow (0.96): these panels are wide, and a deep
    /// scale on a wide panel reads as a zoom rather than as an appearance. The
    /// anchor is the edge the panel is attached to, so it grows out of its dock.
    static func appChrome(reduceMotion: Bool, anchor: UnitPoint = .bottom) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96, anchor: anchor))
    }

    /// A block that comes and goes *inside* a card that stays put.
    ///
    /// A fade with a very shallow top-anchored scale reads as the card growing a
    /// new section; anything deeper competes with the height change around it.
    static func blockSwap(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }

    /// A banner arriving from an edge — the notice banner and the undo banner.
    ///
    /// A short glide (18 pt), not a full `move(edge:)`: travelling the banner's
    /// whole height made it race across the screen and arrive late, which is the
    /// opposite of what a confirmation should feel like.
    static func appBanner(edge: Edge, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = edge == .top ? -18 : 18
        return .offset(y: distance)
            .combined(with: .scale(scale: 0.97, anchor: edge == .top ? .top : .bottom))
            .combined(with: .opacity)
    }

    /// Strenge Innen-Zeilen (z. B. Adress-Zeilen im Container): NUR Fade, nie Scale/Move.
    ///
    /// Scale würde die Zeile aus dem Container reißen (siehe `GroupedRowStyle`).
    static func opacityOnly(reduceMotion _: Bool) -> AnyTransition {
        .opacity
    }
}

extension View {
    /// How a Liquid Glass panel that has **no morph partner** should enter and leave.
    ///
    /// Both map chrome containers set `.matchedGeometry` as the default for their
    /// descendants, which is right for the two pairs that genuinely reshape into one
    /// another (summary ⇄ selection bar, add ⇄ move). For a panel with a unique
    /// `glassEffectID` there is nothing on the other side of the transition to match
    /// against, so it needs `materialize` instead.
    func standaloneGlassTransition(reduceMotion: Bool) -> some View {
        compatGlassTransition(.materialize, reduceMotion: reduceMotion)
    }
}

// MARK: - Press styles

/// Press feedback for free-floating tappable surfaces (tiles, floating cards).
///
/// Scale 0.97 plus a slight dim, on the damped `.appPress` spring. Never inside a
/// continuous grouped container — see `GroupedRowStyle` for that case.
struct PressableRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.appPress(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

// MARK: - Progress

/// A progress fill that animates its *width*, not a scale.
///
/// Replaces the `GeometryReader` + `frame(width:)` bars: a reader per bar is a
/// measuring pass per bar per layout, and on the archive that was one per card.
/// A shape gets its rect for free, keeps round caps at every width, and
/// interpolates `progress` itself, so the fill glides instead of re-laying out.
nonisolated struct ProgressFillShape: Shape {
    var progress: Double
    /// The rounded stub shown as soon as there is any progress at all.
    var minimumWidth: CGFloat = 5

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return Path() }
        let width = max(min(minimumWidth, rect.width), rect.width * clamped)
        let bar = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        return Capsule(style: .continuous).path(in: bar)
    }
}

/// Track plus fill. Height is the caller's; the default matches every bar in the app.
struct ProgressTrack<Fill: ShapeStyle>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: Double
    let fill: Fill
    var height: CGFloat = 5

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(.quaternary)
            ProgressFillShape(progress: progress)
                .fill(fill)
        }
        .frame(height: height)
        .animation(.appSettle(reduceMotion: reduceMotion), value: progress)
        .accessibilityHidden(true)
    }
}

// MARK: - Haptik-Leitfaden (nur Doku, kein Verhalten)

/// Welches `sensoryFeedback` wohin gehört — zentrale Regel, damit Haptik nicht driftet.
///
/// - `.selection`: Toggles, Chips, Tabs, Filter, Segmentwechsel (leicht, reversibel).
/// - `.success`: Fertig/Teilen/Speichern — abgeschlossene Handlung.
/// - `.warning`: ungültige Eingabe (noch nicht versendet, korrigierbar).
/// - `.error`: Fehlschlag (versendet und gescheitert).
enum SensoryGuide {
    case selection
    case success
    case warning
    case error
}

// MARK: - Scale-Leitfaden (nur Doku, kein Verhalten)

/// Wann Skalierung erlaubt ist.
///
/// - `.freeFloatingChrome`: ERLAUBT — frei schwebende Flächen (`appChrome` 0.96,
///   `PressableRowStyle` 0.97, Glas-Knöpfe). Nichts grenzt an, nichts kann wellen.
/// - `.groupedRowsNever`: VERBOTEN — gruppierte Zeilen im durchgehenden Container.
///   Dort nur Highlight (`PressHighlight`).
enum ScaleGuide {
    case freeFloatingChrome
    case groupedRowsNever
}
