import Foundation

/// Which campaign day the UI is currently looking at.
///
/// This used to be a bare `Int` threaded through twenty call sites as 0/1/2, which
/// is how the read/write asymmetry bugs got in: code read with one meaning and
/// wrote with another. Making it a type forces every site to say what it means.
nonisolated enum DayScope: Int, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    /// Everything that happened, day 1 and day 2 combined.
    case combined = 0
    case day1 = 1
    case day2 = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .combined: "Gesamt"
        case .day1: "Tag 1"
        case .day2: "Tag 2"
        }
    }

    /// The day a new result should be written to when the user records something
    /// while this scope is active.
    var writeTargetDay: Int {
        self == .day2 ? 2 : 1
    }
}
