import Foundation

/// Every JSON coder in the app, in one place, with the compatibility constraints
/// written down.
///
/// The old code scattered `JSONDecoder()` across five files — some as shared
/// `static let`s used from `Task.detached`, which is a data race because
/// `JSONDecoder` is a non-`Sendable` class with mutable configuration. Coders are
/// cheap; these factory methods hand out a fresh one per use site instead.
nonisolated enum AppCoders {
    /// Door results inside `House.unitsData`.
    ///
    /// **Storage format.** Dates use the default `.deferredToDate` strategy. Every
    /// blob ever written by every shipped version used that default, so changing it
    /// would silently reinterpret every existing timestamp.
    nonisolated static func unitsEncoder() -> JSONEncoder { JSONEncoder() }
    nonisolated static func unitsDecoder() -> JSONDecoder { JSONDecoder() }

    /// Territory boundaries inside `Gebiet.boundaryData` — same constraint.
    nonisolated static func boundaryEncoder() -> JSONEncoder { JSONEncoder() }
    nonisolated static func boundaryDecoder() -> JSONDecoder { JSONDecoder() }

    /// The backup envelope, which is a user-facing file and therefore uses a
    /// readable, unambiguous date format.
    nonisolated static func backupEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    nonisolated static func backupDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
