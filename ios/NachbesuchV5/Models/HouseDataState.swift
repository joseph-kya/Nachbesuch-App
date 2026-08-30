import Foundation

/// The only interpretation of a house's encoded door payload.
///
/// Empty and damaged are deliberately different states. Turning an unreadable blob
/// into an empty array makes every downstream surface lie in a slightly different
/// way, and is especially dangerous in exports and statistics.
nonisolated enum HouseDataState: Sendable, Equatable {
    case empty
    case readable([DoorResult])
    case damaged

    var doors: [DoorResult]? {
        switch self {
        case .empty: []
        case .readable(let doors): doors
        case .damaged: nil
        }
    }

    var isDamaged: Bool {
        if case .damaged = self { return true }
        return false
    }

    static func decode(_ data: Data, decoder: JSONDecoder = AppCoders.unitsDecoder()) -> HouseDataState {
        guard !data.isEmpty else { return .empty }
        guard let doors = try? decoder.decode([DoorResult].self, from: data) else { return .damaged }
        return doors.isEmpty ? .empty : .readable(doors)
    }
}

nonisolated struct ValidatedHouseSnapshot: Sendable, Equatable {
    let address: String
    let doors: [DoorResult]

    enum ValidationError: LocalizedError, Equatable {
        case damaged(address: String)

        var errorDescription: String? {
            switch self {
            case .damaged(let address):
                "Daten beschädigt bei „\(address)“. Export und Auswertung wurden sicherheitshalber nicht ausgeführt."
            }
        }
    }

    static func validate(
        address: String,
        unitsData: Data,
        decoder: JSONDecoder = AppCoders.unitsDecoder()
    ) throws -> ValidatedHouseSnapshot {
        switch HouseDataState.decode(unitsData, decoder: decoder) {
        case .empty:
            return ValidatedHouseSnapshot(address: address, doors: [])
        case .readable(let doors):
            return ValidatedHouseSnapshot(address: address, doors: doors)
        case .damaged:
            throw ValidationError.damaged(address: address)
        }
    }
}
