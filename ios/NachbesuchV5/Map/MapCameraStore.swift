import CoreLocation
import Foundation
import MapKit

/// Owns where the map is looking, and — more importantly — decides when the app is
/// allowed to move it on the user's behalf.
///
/// The old build re-centred on the user every time the map became active again:
/// switching tabs reset its `hasCentered` flag, and the flag itself was plain
/// `@State`, so it also reset on every cold launch. The rule now is deliberately
/// blunt: **the app centres on the user exactly once in the lifetime of the
/// install.** Every later launch, tab switch and foreground restores the last
/// camera verbatim. Any other move has to come from a button the user pressed.
@MainActor
final class MapCameraStore {
    private enum Key {
        static let latitude = "map.camera.latitude"
        static let longitude = "map.camera.longitude"
        static let latitudeDelta = "map.camera.latitudeDelta"
        static let longitudeDelta = "map.camera.longitudeDelta"
        static let didInitialLocate = "map.didEverCenterOnUser"
    }

    /// Fallback when there is nothing stored and no fix yet — Vienna city centre.
    static let fallbackRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.2082, longitude: 16.3738),
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
    )

    /// The one-time welcome zoom. ~350 m across, so the user lands on their own
    /// street with house numbers legible instead of staring at a whole district.
    static let firstLaunchSpan = MKCoordinateSpan(latitudeDelta: 0.0032, longitudeDelta: 0.0032)
    /// Zoom used when the user explicitly asks to be recentred.
    static let recenterSpan = MKCoordinateSpan(latitudeDelta: 0.0045, longitudeDelta: 0.0045)

    private let defaults: UserDefaults
    private var persistTask: Task<Void, Never>?

    /// Live camera. Deliberately a plain property, not `@Published`/`@Observable`:
    /// map gestures write it dozens of times a second and must never invalidate a
    /// SwiftUI body.
    private(set) var region: MKCoordinateRegion

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        region = Self.restore(from: defaults) ?? Self.fallbackRegion
        #if DEBUG
        // Test-harness override, so a performance run can pin the camera to a known
        // zoom without racing the store's own persistence.
        if let span = Self.debugOverrideSpan() {
            // Span only: the centre still comes from whatever the seeder parked, so
            // the harness cannot strand the camera away from the generated block.
            let environment = ProcessInfo.processInfo.environment
            let centre = CLLocationCoordinate2D(
                latitude: environment["NACHBESUCH_LAT"].flatMap(Double.init) ?? region.center.latitude,
                longitude: environment["NACHBESUCH_LON"].flatMap(Double.init) ?? region.center.longitude
            )
            region = MKCoordinateRegion(
                center: centre,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            )
        }
        #endif
    }

    #if DEBUG
    private static func debugOverrideSpan() -> Double? {
        guard let span = ProcessInfo.processInfo.environment["NACHBESUCH_SPAN"]
            .flatMap(Double.init), span > 0 else { return nil }
        return span
    }
    #endif

    /// True until the app has performed its single automatic centre-on-user.
    var wantsInitialLocate: Bool {
        !defaults.bool(forKey: Key.didInitialLocate)
    }

    /// The region the map view should mount with. Never the user's location — that
    /// is applied later as an animated command, only when `wantsInitialLocate`.
    var startupRegion: MKCoordinateRegion { region }

    /// Consumes the one-time initial locate. Returns the region to fly to, or `nil`
    /// if the app has already had its one automatic move.
    func consumeInitialLocate(at coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion? {
        guard wantsInitialLocate else { return nil }
        defaults.set(true, forKey: Key.didInitialLocate)
        let target = MKCoordinateRegion(center: coordinate, span: Self.firstLaunchSpan)
        region = target
        persistNow()
        return target
    }

    /// Tracks the camera during a gesture without scheduling any persistence.
    /// Called at frame rate, so it must stay a plain property write.
    func updateLive(_ newRegion: MKCoordinateRegion) {
        region = newRegion
    }

    /// Records a camera the user settled on. Writes are coalesced so deceleration
    /// does not hammer `UserDefaults`.
    func record(_ newRegion: MKCoordinateRegion) {
        region = newRegion
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Called when the map goes away, so the very last camera is never lost.
    func flush() {
        persistTask?.cancel()
        persistTask = nil
        persistNow()
    }

    private func persistNow() {
        guard region.isUsable else { return }
        defaults.set(region.center.latitude, forKey: Key.latitude)
        defaults.set(region.center.longitude, forKey: Key.longitude)
        defaults.set(region.span.latitudeDelta, forKey: Key.latitudeDelta)
        defaults.set(region.span.longitudeDelta, forKey: Key.longitudeDelta)
    }

    private static func restore(from defaults: UserDefaults) -> MKCoordinateRegion? {
        guard let latitude = defaults.object(forKey: Key.latitude) as? Double,
              let longitude = defaults.object(forKey: Key.longitude) as? Double,
              let latitudeDelta = defaults.object(forKey: Key.latitudeDelta) as? Double,
              let longitudeDelta = defaults.object(forKey: Key.longitudeDelta) as? Double
        else { return nil }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(
                latitudeDelta: min(latitudeDelta, 170),
                longitudeDelta: min(longitudeDelta, 350)
            )
        )
        return region.isUsable ? region : nil
    }
}

extension MKCoordinateRegion {
    /// Guards against NaN/zero spans, which put MKMapView into an unrecoverable state.
    var isUsable: Bool {
        center.latitude.isFinite && center.longitude.isFinite
            && (-90...90).contains(center.latitude)
            && (-180...180).contains(center.longitude)
            && span.latitudeDelta.isFinite && span.longitudeDelta.isFinite
            && span.latitudeDelta > 0 && span.longitudeDelta > 0
    }
}
