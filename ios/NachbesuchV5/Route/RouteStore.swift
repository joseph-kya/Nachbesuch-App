import CoreLocation
import Foundation

/// The active recommended route, per territory.
///
/// Persisted so a route survives closing the app: a round takes hours, and having
/// to re-plan after every interruption would make the feature useless in the field.
@MainActor
final class RouteStore {
    private struct Stored: Codable {
        let startLatitude: Double
        let startLongitude: Double
        let houseIDs: [UUID]
        let distance: Double
        /// The drawn path, so a restored route still follows streets without
        /// hitting the network again.
        var path: [StoredCoordinate] = []
        var followsStreets = false
        /// Houses pushed to the back of the queue, newest last.
        var skipped: [UUID] = []
        /// Per-stop legs and coordinates, aligned with `houseIDs`. Defaulted so a
        /// route stored by an older build still restores — it simply loses the
        /// per-leg drawing until the next plan.
        var legs: [[StoredCoordinate]] = []
        var stops: [StoredCoordinate] = []
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for gebietID: UUID) -> String {
        "route.\(gebietID.uuidString)"
    }

    struct Restored {
        let start: CLLocationCoordinate2D
        let houseIDs: [UUID]
        let distance: Double
        let path: [CLLocationCoordinate2D]
        let followsStreets: Bool
        let skipped: [UUID]
        let legs: [[CLLocationCoordinate2D]]
        let stops: [CLLocationCoordinate2D]
    }

    func load(for gebietID: UUID) -> Restored? {
        guard let data = defaults.data(forKey: key(for: gebietID)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.houseIDs.isEmpty
        else { return nil }
        return Restored(
            start: CLLocationCoordinate2D(
                latitude: stored.startLatitude,
                longitude: stored.startLongitude
            ),
            houseIDs: stored.houseIDs,
            distance: stored.distance,
            path: stored.path.map(\.coordinate),
            followsStreets: stored.followsStreets,
            skipped: stored.skipped,
            legs: stored.legs.map { $0.map(\.coordinate) },
            stops: stored.stops.map(\.coordinate)
        )
    }

    func save(_ route: PlannedRoute, skipped: [UUID], for gebietID: UUID) {
        let stored = Stored(
            startLatitude: route.start.latitude,
            startLongitude: route.start.longitude,
            houseIDs: route.houseIDs,
            distance: route.distance,
            path: route.path.map(StoredCoordinate.init),
            followsStreets: route.followsStreets,
            skipped: skipped,
            legs: route.legs.map { $0.map(StoredCoordinate.init) },
            stops: route.stops.map { StoredCoordinate(($0.coordinate)) }
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key(for: gebietID))
    }

    /// Rewrites just the skip list of an already-saved route.
    func saveSkipped(_ skipped: [UUID], for gebietID: UUID) {
        guard let data = defaults.data(forKey: key(for: gebietID)),
              var stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        stored.skipped = skipped
        guard let encoded = try? JSONEncoder().encode(stored) else { return }
        defaults.set(encoded, forKey: key(for: gebietID))
    }

    func clear(for gebietID: UUID) {
        defaults.removeObject(forKey: key(for: gebietID))
    }
}
