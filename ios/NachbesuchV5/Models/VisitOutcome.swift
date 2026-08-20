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

    nonisolated var id: String { rawValue }

    nonisolated var emoji: String {
        switch self {
        case .notHome: "🔴"
        case .earlyNo: "🚫"
        case .lateNo: "❌"
        case .joined: "❤️‍🔥"
        }
    }

    nonisolated var title: String {
        switch self {
        case .notHome: "Niemand da"
        case .earlyNo: "Frühes Nein"
        case .lateNo: "Spätes Nein"
        case .joined: "Dabei"
        }
    }

    nonisolated var explanation: String {
        switch self {
        case .notHome: "Noch einmal hingehen"
        case .earlyNo: "Vor dem Formular abgelehnt"
        case .lateNo: "Beim Formular abgelehnt"
        case .joined: "Langfristig aufgenommen"
        }
    }

    /// A shape cue that is independent of hue, so the four outcomes stay
    /// distinguishable for colour-blind users and in greyscale.
    nonisolated var symbolName: String {
        switch self {
        case .notHome: "arrow.clockwise.circle.fill"
        case .earlyNo: "hand.raised.slash.fill"
        case .lateNo: "xmark.circle.fill"
        case .joined: "heart.fill"
        }
    }

    /// True when this door still needs another visit.
    nonisolated var isOpenWork: Bool { self == .notHome }
}
