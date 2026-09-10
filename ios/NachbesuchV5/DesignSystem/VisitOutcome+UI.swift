import SwiftUI
import UIKit

/// Präsentation für `VisitOutcome` — FIXE Statusfarben, NIEMALS Accent.
///
/// - Statusfarben sind fest: Rot offen, Grün erledigt (`doneTone`), Orange unbeantwortet,
///   Indigo später, Pink beigetreten, Grau/Schiefer Sonderfälle (siehe unten).
///   Sie werden NICHT mit `appAccent` (Volkshilfe Rot/Orange/Blau/Lila) getönt —
///   sonst liest „offen" plötzlich wie das gewählte Accent-Thema.
/// - Accent-Washes (`AppBackdrop`) nutzen umgekehrt NUR `appAccent`, nie hartes Rot.
///   Ein Fix pro Welt: Status fest, Grundierung Accent — nie umgekehrt.
///
/// Kept out of the model so the persisted enum stays free of SwiftUI — it is
/// decoded inside detached tasks by the map, archive and export pipelines, and
/// importing SwiftUI there dragged the whole model layer onto the main actor.
extension VisitOutcome {
    var tint: Color {
        switch self {
        case .notHome: .red
        case .earlyNo: .orange
        case .lateNo: Color(uiColor: .systemGray)
        case .joined: .pink
        // Indigo, not blue: blue is already the "noch kein Status" tone, and a
        // booked return time must not read as an unanswered door.
        case .later: .indigo
        }
    }

    /// Text VoiceOver should read instead of the emoji. Without this, the four
    /// statuses are announced as "large red circle", "prohibited sign", "cross mark"
    /// and "heart on fire" — Unicode names, in English, inside a German app.
    var accessibilityDescription: String { title }
}

extension Color {
    /// „Erledigt" — nothing left to do here, and the affirmative half of every
    /// confirmation. Deliberately outside the accent: no `VisitOutcome` is green,
    /// so green can only ever mean *done*, whichever accent the user picked.
    static let doneTone = Color.green
}

extension Optional where Wrapped == VisitOutcome {
    var displayEmoji: String { self?.emoji ?? "•" }
    var displayTitle: String { self?.title ?? "Noch kein Status" }
    /// "Nothing recorded here yet" is the quietest state on the screen, not the
    /// loudest. `systemBlue` gave the one outcome that carries no information the
    /// most saturated colour in the palette, so a fresh territory — where *every*
    /// door is untouched — rendered as a column of shouting blue circles. It also
    /// collided twice: with the user's own location puck, which is systemBlue
    /// everywhere on the map, and with the pin cache, which had always drawn this
    /// state as the muted slate below.
    ///
    /// The light value is `PinArtCache.fillColor(for:)`'s exactly, so a house reads
    /// the same on the map and in the list. Dark mode lifts it: that pin sits on a
    /// white ring over a map, while the list glyph sits bare on a near-black
    /// background, where the same slate is quiet to the point of being unreadable.
    /// Quiet is the intent; invisible is not.
    ///
    /// Distinct from `VisitOutcome.lateNo`, which is `systemGray`, by hue and — the
    /// part that survives colour blindness — by symbol: a dashed open ring against a
    /// filled `xmark.circle`.
    var displayTint: Color {
        if let self { return self.tint }
        return Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.56, green: 0.61, blue: 0.71, alpha: 1)
                : UIColor(red: 0.42, green: 0.47, blue: 0.56, alpha: 1)
        })
    }
}

// MARK: - Status chips

/// The fill behind a small tinted status chip — KANONISCH.
///
/// Eine Definition: Open-Count-Badge, Revisit-Chip und Zwei-Tage-Marker nutzten
/// früher je eigene Werte und waren bereits gedriftet. Wer einen Chip malt, nimmt
/// `StatusChipFill(tint)` — kein eigenes Opacity-Gemisch.
/// Die `tint` kommt IMMER aus der fixen Statusfarbe (`outcome.tint`, `.red`, `.orange`
/// …), NIEMALS aus `appAccent` (siehe Datei-Kopf).
///
/// A chip that draws its label and its fill from the same hue needs the two far
/// enough apart to stay legible, and how far apart is not one number: over a white
/// card a 12 % wash is a clear field behind a saturated glyph, while over a dark
/// card the same wash lands within a couple of steps of the text on top of it. The
/// audit's dark-mode requirement — "pale red selected backgrounds must not become
/// brown/gray against dark surfaces" — is exactly this case. Dark mode takes a
/// heavier fill so the separation survives.
///
/// One definition, because the open-count badge, the revisit chip and the two-day
/// marker were each carrying their own number and had already drifted apart.
nonisolated struct StatusChipFill: ShapeStyle {
    let tint: Color

    init(_ tint: Color) { self.tint = tint }

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        tint.opacity(environment.colorScheme == .dark ? 0.26 : 0.12)
    }
}
