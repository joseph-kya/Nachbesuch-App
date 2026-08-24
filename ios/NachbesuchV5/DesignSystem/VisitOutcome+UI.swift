import SwiftUI

/// Presentation for `VisitOutcome`.
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
    var displayTint: Color { self?.tint ?? Color(uiColor: .systemBlue) }
}
