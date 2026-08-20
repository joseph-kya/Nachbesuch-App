import CoreLocation
import Foundation

/// A `CLLocationCoordinate2D` that can be persisted. Kept in its own file because
/// it outlived the legacy model it used to live in.
nonisolated struct StoredCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    nonisolated init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    nonisolated var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Rejects NaN and the null island, which is what a failed geocode looks like.
    nonisolated var isPlausible: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(abs(latitude) < 0.0001 && abs(longitude) < 0.0001)
    }
}
