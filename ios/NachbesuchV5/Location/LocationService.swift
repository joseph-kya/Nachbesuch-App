import CoreLocation
import Observation
import UIKit

/// Continuous, foreground-only location + heading for the map.
///
/// The previous implementation was one-shot (`requestLocation()` followed by an
/// immediate `stopUpdatingLocation()`, plus a 180 s "fresh enough" short circuit),
/// which is why the blue dot only ever moved a handful of times per session. This
/// service streams updates for as long as the map is on screen and stops the moment
/// it isn't, so the dot glides while walking without costing battery in other tabs.
@MainActor
@Observable
final class LocationService: NSObject {

    // MARK: Published state

    private(set) var location: CLLocation?
    /// Screen-space direction the device is pointing, in degrees clockwise from true
    /// north. `nil` while the compass has no usable reading.
    private(set) var headingDegrees: Double?
    private(set) var headingAccuracy: Double?
    private(set) var authorization: CLAuthorizationStatus
    /// True once the user has denied or restricted access — the UI stops offering
    /// location actions that cannot succeed.
    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }
    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    // MARK: Internals

    private let manager = CLLocationManager()
    private var isStreaming = false
    /// How many screens currently want live updates.
    ///
    /// The map and the list can both ask independently, and whoever leaves last
    /// turns the GPS off — without this, one screen stopping would cut the other
    /// screen's updates.
    private var users = 0
    /// Only true while a view that draws the direction cone is visible.
    private var wantsHeading = false
    private var precisionRequests = 0
    /// Completions waiting for the next usable fix (supermarket search, recenter).
    private var freshFixWaiters: [(CLLocation?) -> Void] = []
    private var freshFixTimeout: Task<Void, Never>?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Apple's guidance for a pedestrian app: ten-metre accuracy plus a small
        // distance filter. `Best`/`BestForNavigation` pin the GPS at full duty cycle,
        // which matters when the phone has to survive a whole canvassing shift. The
        // old settings were the opposite mistake — 100 m accuracy with a 50 m filter,
        // so the dot only moved once per half block.
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 3
        // iOS pauses updates for a "stationary" user and — critically — never
        // resumes on its own without the deferred-updates dance. For a canvasser
        // standing at a door for two minutes that reads as a frozen dot.
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.headingFilter = 2
        manager.headingOrientation = .portrait
    }

    // MARK: Lifecycle

    /// Registers a screen that wants live updates.
    func beginUsing() {
        users += 1
        refreshHeadingOrientation()
        startStreaming()
    }

    /// Balances `beginUsing()`. Streaming stops once nobody is left.
    func endUsing() {
        users = max(0, users - 1)
        if users == 0 { stopStreaming() }
    }

    /// Idempotent.
    func startStreaming() {
        guard !isStreaming else { return }
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    /// Called when nothing needs location any more.
    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        wantsHeading = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        resolveFreshFixWaiters(with: location)
    }

    private func beginUpdates() {
        guard users > 0, !isStreaming else { return }
        isStreaming = true
        manager.startUpdatingLocation()
        // Heading needs a magnetometer, which the Simulator does not have.
        if CLLocationManager.headingAvailable() {
            wantsHeading = true
            manager.startUpdatingHeading()
        }
    }

    /// Whether a direction indicator can be shown at all on this device.
    var isHeadingAvailable: Bool { CLLocationManager.headingAvailable() }

    /// Core Location reports headings relative to the physical top of the device;
    /// keep that reference aligned with the active window in landscape and iPad
    /// multitasking instead of assuming portrait forever.
    func refreshHeadingOrientation() {
        guard let orientation = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation else { return }
        switch orientation {
        case .portrait: manager.headingOrientation = .portrait
        case .portraitUpsideDown: manager.headingOrientation = .portraitUpsideDown
        case .landscapeLeft: manager.headingOrientation = .landscapeLeft
        case .landscapeRight: manager.headingOrientation = .landscapeRight
        default: break
        }
    }

    /// Temporarily raises accuracy while the user is actively being followed.
    func setFollowing(_ following: Bool) {
        // Tighten up only while the camera is locked to the user, where the extra
        // precision is actually visible.
        manager.desiredAccuracy = following
            ? kCLLocationAccuracyBest
            : kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = following ? 1 : 3
    }

    // MARK: One-off precise fix

    /// Resolves with a usable fix for actions that need a real position right now
    /// (recenter, nearby-supermarket search). A stationary fix does not become
    /// useless after a few seconds: Core Location may intentionally emit nothing
    /// while the phone has not moved. Accepting a good fix for five minutes avoids
    /// making a recenter tap look frozen while still rejecting genuinely stale data.
    func requestFreshFix(_ completion: @escaping (CLLocation?) -> Void) {
        if let location,
           location.timestamp.timeIntervalSinceNow > -300,
           location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= 100 {
            completion(location)
            return
        }

        guard !isDenied else {
            completion(nil)
            return
        }

        freshFixWaiters.append(completion)
        startStreaming()
        if authorization == .notDetermined { return }

        freshFixTimeout?.cancel()
        freshFixTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.resolveFreshFixWaiters(with: self?.location)
        }
    }

    private func resolveFreshFixWaiters(with location: CLLocation?) {
        guard !freshFixWaiters.isEmpty else { return }
        freshFixTimeout?.cancel()
        freshFixTimeout = nil
        let waiters = freshFixWaiters
        freshFixWaiters = []
        for waiter in waiters { waiter(location) }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.beginUpdates()
            case .denied, .restricted:
                self.stopStreaming()
                self.resolveFreshFixWaiters(with: nil)
            default:
                break
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let newest = locations.last else { return }
        Task { @MainActor in
            // Reject readings that are stale or wildly imprecise; a 2 km "fix" would
            // otherwise teleport the dot across the city.
            guard newest.horizontalAccuracy >= 0, newest.horizontalAccuracy < 500 else { return }
            self.location = newest
            if newest.horizontalAccuracy <= 65 {
                self.resolveFreshFixWaiters(with: newest)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Negative accuracy means the compass reading is unusable.
        guard newHeading.headingAccuracy >= 0 else { return }
        // `trueHeading` is only valid while location updates are also running, which
        // they are; it falls back to magnetic north otherwise.
        let raw = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy
        Task { @MainActor in
            self.headingDegrees = self.smoothed(raw, accuracy: accuracy)
            self.headingAccuracy = accuracy
        }
    }

    /// Circular low-pass filter.
    ///
    /// Compass readings jitter by 10–20° indoors, and degrees cannot be averaged
    /// directly because 359° and 1° are one degree apart. This tracks the shortest
    /// arc and weights new readings by how much the compass trusts itself.
    private func smoothed(_ newValue: Double, accuracy: Double) -> Double {
        guard let previous = headingDegrees else { return newValue }
        var delta = newValue - previous
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        // A confident compass tracks quickly; a poor one is averaged harder.
        let alpha = accuracy < 15 ? 0.35 : (accuracy < 30 ? 0.18 : 0.08)
        let next = (previous + alpha * delta).truncatingRemainder(dividingBy: 360)
        return next < 0 ? next + 360 : next
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // `kCLErrorLocationUnknown` is transient — CoreLocation keeps trying, so the
        // stream must stay open. Anything else ends the wait so the UI can move on.
        if (error as? CLError)?.code == .locationUnknown { return }
        Task { @MainActor in
            self.resolveFreshFixWaiters(with: nil)
        }
    }

    /// The figure-8 calibration alert covers the whole window until it completes, so
    /// it is only ever offered while a heading indicator is actually on screen.
    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        MainActor.assumeIsolated { isStreaming && wantsHeading }
    }
}
