import Foundation

/// What happened at one door. Persisted by `rawValue` inside `House.unitsData`,
/// so these strings are part of the storage format — never rename a case without a
/// migration.
///
/// Deliberately free of SwiftUI: this type is decoded inside detached tasks by the
/// map, archive and export pipelines, and dragging `Color` in made the whole model
/// layer MainActor-isolated. Presentation lives in `VisitOutcome+UI`.
nonisolated enum VisitOutcome: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case notHome
    case earlyNo
    case lateNo
    case joined
    /// Nobody answered *now*, but a concrete return time was agreed or chosen. The
    /// time itself lives on the door (`DoorResult.revisitAt`), not here — an enum
    /// case with an associated value would change the storage format.
    case later

    /// The four results that end a visit, in the order the pickers show them.
    ///
    /// `allCases` deliberately still contains `.later` so tallies, legends and
    /// exports cannot forget it; this is only the grid layout. Adding `.later` to
    /// the 2×2 grid would have made the primary choices smaller on every screen,
    /// and `.later` is not a result — it is a postponement.
    nonisolated static let primary: [VisitOutcome] = [.notHome, .earlyNo, .lateNo, .joined]

    nonisolated var id: String { rawValue }

    nonisolated var emoji: String {
        switch self {
        case .notHome: "🔴"
        case .earlyNo: "🚫"
        case .lateNo: "❌"
        case .joined: "❤️‍🔥"
        case .later: "⏰"
        }
    }

    nonisolated var title: String {
        switch self {
        case .notHome: "Niemand da"
        case .earlyNo: "Frühes Nein"
        case .lateNo: "Spätes Nein"
        case .joined: "Dabei"
        case .later: "Später"
        }
    }

    nonisolated var explanation: String {
        switch self {
        case .notHome: "Noch einmal hingehen"
        case .earlyNo: "Vor dem Formular abgelehnt"
        case .lateNo: "Beim Formular abgelehnt"
        case .joined: "Langfristig aufgenommen"
        case .later: "Zu einer bestimmten Zeit wiederkommen"
        }
    }

    /// A shape cue that is independent of hue, so the outcomes stay
    /// distinguishable for colour-blind users and in greyscale.
    nonisolated var symbolName: String {
        switch self {
        case .notHome: "arrow.clockwise.circle.fill"
        case .earlyNo: "hand.raised.slash.fill"
        case .lateNo: "xmark.circle.fill"
        case .joined: "heart.fill"
        case .later: "clock.fill"
        }
    }

    /// True when this door still needs another visit.
    nonisolated var isOpenWork: Bool { self == .notHome || self == .later }

    /// True when recording this outcome asks the user for a return time.
    nonisolated var needsRevisitTime: Bool { self == .later }

    /// "Später · 18:00" for a booked door, plain `title` for everything else.
    ///
    /// Lives here rather than in the UI extension because the export pipeline needs
    /// it from a detached task, and that file imports SwiftUI.
    nonisolated func label(revisitAt: Date?) -> String {
        guard self == .later, let revisitAt else { return title }
        return "\(title) · \(RevisitPlanner.clockFormatter.string(from: revisitAt))"
    }
}
