import CoreLocation
import Observation
import UIKit

/// Location precision is a function of two independent conditions, resolved in
/// one place. The previous shape let `setFollowing(false)` overwrite an
/// unrelated caller's request — two writers, one property, last one wins.
/// Internal so the resolution rules carry unit tests.
nonisolated struct AccuracyProfile: Equatable, Sendable {
    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance

    /// - Following wins: the camera is locked to the user, every metre shows.
    /// - The visible map gets full precision: at a door, ten-metre accuracy is
    ///   three houses wide, and the screen costs more than the GPS duty cycle.
    /// - Everything else (list distance sorting, background waits) stays coarse.
    static func resolve(mapVisible: Bool, following: Bool) -> AccuracyProfile {
        if following {
            return AccuracyProfile(desiredAccuracy: kCLLocationAccuracyBest, distanceFilter: 1)
        }
        if mapVisible {
            return AccuracyProfile(desiredAccuracy: kCLLocationAccuracyBest, distanceFilter: 2)
        }
        return AccuracyProfile(
            desiredAccuracy: kCLLocationAccuracyNearestTenMeters,
            distanceFilter: 3
        )
    }
}

/// How much the drawn position can be trusted.
///
/// Hysteresis on purpose: a fix hovering at the threshold would flicker the
/// puck between states, which reads as a bug rather than as information.
/// Internal so the bands carry unit tests.
nonisolated enum PuckConfidence: Sendable, Equatable {
    case trusted
    case uncertain

    static func from(horizontalAccuracy: Double, current: PuckConfidence) -> PuckConfidence {
        switch current {
        case .trusted: return horizontalAccuracy > 25 ? .uncertain : .trusted
        case .uncertain: return horizontalAccuracy <= 18 ? .trusted : .uncertain
        }
    }
}

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
    /// "Ungefährer Standort": the fix is kilometres off and every distance, the
    /// puck and the sort order would be nonsense. Distances hide and the puck
    /// goes uncertain while this holds (B6).
    private(set) var isReducedAccuracy = false
    /// One-time explainer state for the reduced-accuracy grant. The UI shows it
    /// once and routes to Settings; the flag survives so it never nags twice.
    private(set) var needsAccuracyExplainer = false

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
    /// Throttles compass-driven SwiftUI invalidation: the sensor still smooths
    /// at full rate, but the published value only moves when it matters.
    private var lastPublishedHeading: Double?
    private var lastPublishedHeadingAt: Date = .distantPast
    // Filter vor dem Main-Hop: Glätten + Band + Drossel laufen nonisolated bei
    // 20–50 Hz, nur echte Änderungen (≥3°/Band/0,25 s) hüpfen auf Main.
    private let headingFilter = HeadingFilter()
    /// The two independent precision conditions, resolved through
    /// `AccuracyProfile` so neither caller stamps on the other.
    private var mapVisible = false
    private var following = false
    /// Completions waiting for the next usable fix (supermarket search, recenter).
    private var freshFixWaiters: [(CLLocation?) -> Void] = []
    private var freshFixTimeout: Task<Void, Never>?

    #if DEBUG
    /// Fix counter and accuracy aggregates for the hidden diagnostics view
    /// (B4). Present in debug builds only; nothing leaves the device.
    private(set) var debugFixCount = 0
    private(set) var debugAccuracySum = 0.0
    private(set) var debugUncertainFixes = 0
    #endif

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
        refreshReducedAccuracy()
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
        lastPublishedHeading = nil
        lastPublishedHeadingAt = .distantPast
        headingFilter.reset()
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        // Resolve with nil: the waiter’s screen is gone (tab left), and firing
        // a stale fix into a sheet/search/fly-to on the wrong screen is worse
        // than reporting “no fix”.
        resolveFreshFixWaiters(with: nil)
    }

    private func beginUpdates() {
        guard users > 0, !isStreaming else { return }
        isStreaming = true
        manager.startUpdatingLocation()
        // Heading needs a magnetometer, which the Simulator does not have —
        // and only the map draws the cone. The list’s distance sort must not
        // power the magnetometer with no visible cone.
        if mapVisible, CLLocationManager.headingAvailable() {
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
    /// Resolved against map visibility in one place — see `AccuracyProfile`.
    func setFollowing(_ following: Bool) {
        self.following = following
        applyAccuracyProfile()
    }

    /// Full precision follows the visible map, not the camera lock: this app
    /// deliberately does not follow, so gating precision on following left the
    /// normal state permanently at ten metres — three houses at a door.
    /// The list intentionally does NOT call this: distance sorting wants a
    /// position, not metre precision, and often runs with the phone pocketed.
    func setMapVisible(_ visible: Bool) {
        mapVisible = visible
        applyAccuracyProfile()
        // Gate the magnetometer on the cone being visible. Starting/stopping
        // heading here keeps the list’s held-open GPS stream from powering a
        // sensor nobody is looking at.
        if visible {
            if isStreaming, !wantsHeading, CLLocationManager.headingAvailable() {
                wantsHeading = true
                manager.startUpdatingHeading()
            }
        } else if wantsHeading {
            wantsHeading = false
            manager.stopUpdatingHeading()
        }
    }

    private func applyAccuracyProfile() {
        let profile = AccuracyProfile.resolve(mapVisible: mapVisible, following: following)
        // Skip the `CLLocationManager` write when nothing resolved differently:
        // re-setting accuracy restarts the fix cycle for no reason.
        guard manager.desiredAccuracy != profile.desiredAccuracy
            || manager.distanceFilter != profile.distanceFilter else { return }
        manager.desiredAccuracy = profile.desiredAccuracy
        manager.distanceFilter = profile.distanceFilter
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

    // MARK: - Reduced accuracy (B6)

    nonisolated static func shouldExplainReducedAccuracy(
        authorization: CLAuthorizationStatus,
        accuracy: CLAccuracyAuthorization
    ) -> Bool {
        (authorization == .authorizedWhenInUse || authorization == .authorizedAlways)
            && accuracy == .reducedAccuracy
    }

    private static let reducedExplainerKey = "location.reducedExplainerShown"

    private func refreshReducedAccuracy() {
        let reduced: Bool
        if #available(iOS 14, *) {
            reduced = Self.shouldExplainReducedAccuracy(
                authorization: manager.authorizationStatus,
                accuracy: manager.accuracyAuthorization
            )
        } else {
            reduced = false
        }
        isReducedAccuracy = reduced
        needsAccuracyExplainer = reduced
            && !UserDefaults.standard.bool(forKey: Self.reducedExplainerKey)
    }

    /// The one-time explainer was shown (or dismissed) — never ask twice.
    func accuracyExplainerHandled() {
        UserDefaults.standard.set(true, forKey: Self.reducedExplainerKey)
        needsAccuracyExplainer = false
    }

    /// Opens Settings so the grant can be switched to a precise position.
    /// A generated Info.plist cannot carry the temporary-authorization
    /// dictionary, so the durable fix (Settings) replaces the per-session one.
    func openLocationSettings() {
        accuracyExplainerHandled()
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    #if DEBUG
    /// One block for the hidden diagnostics view (B4): fix count, mean
    /// accuracy, share of fixes above the puck's uncertainty threshold.
    var debugDiagnostics: String {
        let mean = debugFixCount > 0 ? debugAccuracySum / Double(debugFixCount) : 0
        let share = debugFixCount > 0
            ? Double(debugUncertainFixes) / Double(debugFixCount) * 100 : 0
        return String(format: "Fixes: %d · mittlere Genauigkeit: %.0f m · ungenau: %.0f %%",
                      debugFixCount, mean, share)
    }
    #endif
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let reduced: Bool
        if #available(iOS 14, *) {
            reduced = Self.shouldExplainReducedAccuracy(
                authorization: manager.authorizationStatus,
                accuracy: manager.accuracyAuthorization
            )
        } else {
            reduced = false
        }
        Task { @MainActor in
            self.authorization = status
            self.isReducedAccuracy = reduced
            self.needsAccuracyExplainer = reduced
                && !UserDefaults.standard.bool(forKey: Self.reducedExplainerKey)
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
        #if DEBUG
        // One Instruments event per fix (B4): intervals cannot span the hop onto
        // the main actor, events mark the stream without that.
        if PerformanceTrace.signposter.isEnabled {
            PerformanceTrace.signposter.emitEvent("location-fix")
        }
        #endif
        Task { @MainActor in
            // Reject readings that are stale or wildly imprecise; a 2 km "fix" would
            // otherwise teleport the dot across the city.
            guard newest.horizontalAccuracy >= 0, newest.horizontalAccuracy < 500 else { return }
            self.location = newest
            #if DEBUG
            self.debugFixCount += 1
            self.debugAccuracySum += newest.horizontalAccuracy
            if newest.horizontalAccuracy > 25 { self.debugUncertainFixes += 1 }
            #endif
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
        // Nonisolated filtern: Nur bei ≥3°/Bandwechsel/0,25 s auf Main hüpfen,
        // sonst baut jedes Sample HeadingAwareMapHost + updateUIView neu.
        let now = Date()
        guard let smoothedValue = headingFilter.shouldPublish(raw: raw, accuracy: accuracy, now: now) else { return }
        Task { @MainActor in
            self.lastPublishedHeading = smoothedValue
            self.lastPublishedHeadingAt = now
            self.headingDegrees = smoothedValue
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

    /// Accuracy band the cone width is derived from — mirrors the thresholds in
    /// `UserLocationPuckView.apply(headingDegrees:accuracy:mapHeadingDegrees:)`
    /// closely enough to detect a visible width change without importing UIKit.
    private nonisolated static func headingBand(_ accuracy: Double) -> Int {
        if accuracy < 15 { return 0 }
        if accuracy < 30 { return 1 }
        return 2
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

// MARK: - Kompass-Filter (nonisolated, vor dem Main-Hop)

/// Glättet und drosselt Kompass-Samples abseits vom Main-Thread (20–50 Hz).
/// Nur bei ≥3° Änderung, Bandwechsel oder 0,25 s vergeht ein Wert — sonst würde
/// jedes Sample SwiftUI + MapKit neu aufbauen, ohne sichtbar etwas zu ändern.
private nonisolated final class HeadingFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: Double?
    private var lastPublished: Double?
    private var lastAccuracy: Double?
    private var lastAt: Date = .distantPast

    nonisolated func shouldPublish(raw: Double, accuracy: Double, now: Date) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        // Kreisförmiger Tiefpass: 359° und 1° liegen 1° auseinander.
        let smoothed: Double
        if let prev = previous {
            var delta = raw - prev
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            let alpha = accuracy < 15 ? 0.35 : (accuracy < 30 ? 0.18 : 0.08)
            var next = (prev + alpha * delta).truncatingRemainder(dividingBy: 360)
            if next < 0 { next += 360 }
            smoothed = next
        } else {
            smoothed = raw
        }
        previous = smoothed
        if let last = lastPublished {
            var delta = abs(smoothed - last)
            if delta > 180 { delta = 360 - delta }
            let bandChanged = Self.band(accuracy) != Self.band(lastAccuracy ?? accuracy)
            let elapsed = now.timeIntervalSince(lastAt)
            guard delta >= 3 || bandChanged || elapsed >= 0.25 else { return nil }
        }
        lastPublished = smoothed
        lastAccuracy = accuracy
        lastAt = now
        return smoothed
    }

    nonisolated func reset() {
        lock.lock()
        defer { lock.unlock() }
        previous = nil
        lastPublished = nil
        lastAccuracy = nil
        lastAt = .distantPast
    }

    private nonisolated static func band(_ accuracy: Double) -> Int {
        if accuracy < 15 { return 0 }
        if accuracy < 30 { return 1 }
        return 2
    }
}
