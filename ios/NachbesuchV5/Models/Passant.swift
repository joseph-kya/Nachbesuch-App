import CoreLocation
import Foundation
import SwiftData

/// A person talked to on the street — recorded instead of a house, when there
/// is no address to pin the conversation to.
///
/// Deliberately door-less: one encounter, one outcome, one optional return
/// time. Anything a house can do that a person cannot (units, apartment
/// conversion, duplicate-by-address) stays on `House`; the two share only the
/// outcome vocabulary and the reminder plumbing, both keyed by UUID.
@Model
final class Passant {
    @Attribute(.unique) var id: UUID
    /// What was talked about — same free-text role as a house note, same care.
    var note: String
    var latitude: Double
    var longitude: Double
    var outcome: VisitOutcome?
    /// Booked return time for a `.later` outcome. `nil` for every other outcome.
    var revisitAt: Date?
    var gebietID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(note: String, latitude: Double, longitude: Double, gebietID: UUID) {
        id = UUID()
        self.note = note
        self.latitude = latitude
        self.longitude = longitude
        self.gebietID = gebietID
        createdAt = .now
        updatedAt = .now
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Marks the record changed. Same monotonic rule as `House.touch`: the map
    /// watermark and the archive index key off `updatedAt`.
    func touch() {
        let now = Date.now
        updatedAt = now > updatedAt ? now : updatedAt.addingTimeInterval(0.001)
    }
}
