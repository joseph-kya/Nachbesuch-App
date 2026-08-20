import MapKit
import UIKit

/// Owns everything that happens inside `MKMapView`.
///
/// Design rules this class exists to enforce:
/// * Annotations are created once per house and never touched by a gesture.
/// * Content updates patch only the houses that actually changed, and only
///   reconfigure views that are actually on screen.
/// * Clustering is left entirely to MapKit's screen-space collision engine, which
///   merges pins exactly when they would otherwise overlap — the latest possible
///   moment — and splits them again on zoom-in without any work from us.
@MainActor
final class MapCoordinator: NSObject, MKMapViewDelegate {
    weak var mapView: MKMapView?

    var onCameraIdle: ((MKCoordinateRegion) -> Void)?
    var onCameraMoved: ((MKCoordinateRegion) -> Void)?
    var onTrackingModeChanged: ((Bool) -> Void)?
    var onTapHouse: ((UUID) -> Void)?
    /// Set from the host on every update.
    var picksRouteStart = false
    /// Raised when a cluster cannot be zoomed apart (its members share a coordinate)
    /// so the UI can offer a disambiguation list instead of a tap that does nothing.
    var onClusterNeedsDisambiguation: (([UUID]) -> Void)?
    var onDropConsumed: ((UUID) -> Void)?
    var menuProvider: ((MapPinSnapshot) -> UIMenu)?
    var previewProvider: ((MapPinSnapshot) -> UIViewController?)?
    var reduceMotionEnabled = false

    private var annotationsByHouseID: [UUID: HouseAnnotation] = [:]
    private var pins: PreparedMapSnapshot = .empty
    private var lastStructuralVersion = -1
    private var lastContentVersion = -1
    private var lastSelection: Set<UUID>?

    private var boundaryOverlay: MKOverlay?
    private var boundaryHash: Int?
    private var routeOverlay: RoutePolyline?
    private var routeHash: Int?
    private var draftAnnotations: [DraftPointAnnotation] = []
    private var nextStopAnnotation: NextStopAnnotation?

    private var lastCommandID: UUID?
    private var pendingDropHouseID: UUID?
    private var consumedDropIDs: [UUID] = []

    private var appliedConfiguration: ConfigurationKey?
    private var appliedChromeInsets: UIEdgeInsets?
    private(set) var pinScale: PinScale = .full
    private var clusteringEnabled = false
    private var lastHeading: Double?
    private var lastHeadingAccuracy: Double?

    private struct ConfigurationKey: Equatable {
        let satellite: Bool
        let poi: POIPreset
    }

    // MARK: - Map configuration

    func applyConfiguration(_ mapView: MKMapView, satellite: Bool, poi: POIPreset) {
        let key = ConfigurationKey(satellite: satellite, poi: poi)
        guard key != appliedConfiguration else { return }
        appliedConfiguration = key

        // `preferredConfiguration` is the modern replacement for `mapType` plus the
        // deprecated `showsPointsOfInterest`, and it is the only place the POI filter
        // can be set.
        let configuration: MKMapConfiguration
        if satellite {
            let hybrid = MKHybridMapConfiguration(elevationStyle: .flat)
            hybrid.pointOfInterestFilter = poi.filter
            configuration = hybrid
        } else {
            // `.muted` desaturates the base map, which is what makes showing POIs
            // viable at all: shop and transit labels stay readable while the red
            // house pins keep visual priority.
            let standard = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: poi == .off ? .default : .muted
            )
            standard.pointOfInterestFilter = poi.filter
            configuration = standard
        }
        mapView.preferredConfiguration = configuration
        // POIs are only useful for orientation if you can tap one to see what it is.
        mapView.selectableMapFeatures = poi == .off ? [] : [.pointsOfInterest]
    }

    /// Keeps MapKit's legal attribution, scale and compass clear of the floating
    /// chrome. Covering the Apple Maps attribution is an App Review rejection, and
    /// `layoutMargins` is the supported way to move the ornaments.
    func applyChromeInsets(_ mapView: MKMapView, insets: UIEdgeInsets) {
        guard insets != appliedChromeInsets else { return }
        appliedChromeInsets = insets
        mapView.layoutMargins = insets
    }

    // MARK: - Data

    func applyData(
        _ mapView: MKMapView,
        pins newPins: PreparedMapSnapshot,
        structuralVersion: Int,
        contentVersion: Int,
        changedHouseIDs: Set<UUID>,
        selectedHouseIDs: Set<UUID>?
    ) {
        let structuralChanged = structuralVersion != lastStructuralVersion
        let contentChanged = contentVersion != lastContentVersion
        let selectionChanged = selectedHouseIDs != lastSelection
        guard structuralChanged || contentChanged || selectionChanged else { return }

        let previousSelection = lastSelection
        lastStructuralVersion = structuralVersion
        lastContentVersion = contentVersion
        lastSelection = selectedHouseIDs
        pins = newPins

        if structuralChanged {
            syncAnnotationSet(mapView)
            refresh(mapView, houseIDs: nil)
            repairIfNeeded(mapView)
            updateClusteringGate(mapView)
            return
        }

        // Only the houses that actually changed need new payloads, so entering
        // selection mode with 5000 pins on screen touches two of them.
        var dirty = changedHouseIDs
        if selectionChanged {
            let before = previousSelection ?? []
            let after = selectedHouseIDs ?? []
            dirty.formUnion(before.symmetricDifference(after))
            // Entering or leaving selection mode changes the chrome of whatever was
            // selected at the time, and nothing else.
            if previousSelection == nil || selectedHouseIDs == nil {
                dirty.formUnion(before)
                dirty.formUnion(after)
            }
        }
        refresh(mapView, houseIDs: dirty.isEmpty ? nil : dirty)
    }

    /// Add/remove/move the annotation set to match the snapshot. Bulk operations
    /// only, and never inside an animation context — SwiftUI can install a UIKit
    /// animation for the transaction and MapKit would fade views into the reuse
    /// pool, which is how recycled pins end up half transparent.
    private func syncAnnotationSet(_ mapView: MKMapView) {
        let trace = PerformanceTrace.begin("Sync annotations")
        defer { PerformanceTrace.end("Sync annotations", id: trace) }

        let newPins = pins.pinsByID
        var toRemove: [HouseAnnotation] = []
        for (houseID, annotation) in annotationsByHouseID {
            guard let pin = newPins[houseID] else {
                toRemove.append(annotation)
                continue
            }
            annotation.pin = pin
            if annotation.coordinate.latitude != pin.latitude
                || annotation.coordinate.longitude != pin.longitude {
                annotation.coordinate = pin.coordinate
            }
        }

        var toAdd: [HouseAnnotation] = []
        toAdd.reserveCapacity(max(0, newPins.count - annotationsByHouseID.count))
        for (houseID, pin) in newPins where annotationsByHouseID[houseID] == nil {
            let annotation = HouseAnnotation(
                houseID: houseID,
                pin: pin,
                isPinSelected: lastSelection?.contains(houseID) == true
            )
            annotationsByHouseID[houseID] = annotation
            toAdd.append(annotation)
        }

        for annotation in toRemove {
            annotationsByHouseID.removeValue(forKey: annotation.houseID)
        }

        UIView.performWithoutAnimation {
            if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }
            if !toAdd.isEmpty { mapView.addAnnotations(toAdd) }
        }
    }

    /// Re-render pin payloads. `houseIDs == nil` means "everything", which only
    /// happens on a structural change; otherwise this touches a handful of pins.
    ///
    /// Off-screen annotations get their model updated but no view work: MapKit
    /// configures their view from the fresh payload if and when it scrolls in.
    private func refresh(_ mapView: MKMapView, houseIDs: Set<UUID>?) {
        let pinsByID = pins.pinsByID
        let selection = lastSelection

        func apply(_ annotation: HouseAnnotation) {
            if let pin = pinsByID[annotation.houseID] {
                annotation.pin = pin
            }
            annotation.isPinSelected = selection?.contains(annotation.houseID) == true
            // `view(for:)` returns nil for anything not currently realised, so this
            // costs nothing for off-screen pins.
            if let view = mapView.view(for: annotation) as? HousePinView {
                view.configure()
            }
        }

        if let houseIDs {
            for houseID in houseIDs {
                guard let annotation = annotationsByHouseID[houseID] else { continue }
                apply(annotation)
            }
        } else {
            for annotation in annotationsByHouseID.values { apply(annotation) }
        }

        // Cluster bubbles summarise their members, so a payload change can alter a
        // bubble's accent even though no member view is realised.
        refreshVisibleClusters(mapView)
    }

    private func refreshVisibleClusters(_ mapView: MKMapView) {
        for annotation in mapView.annotations(in: mapView.visibleMapRect) {
            guard let cluster = annotation as? MKClusterAnnotation,
                  let view = mapView.view(for: cluster) as? ClusterBubbleView else { continue }
            view.invalidateArt()
            view.configure()
        }
    }

    /// Safety net for the rare case where our bookkeeping and MapKit's live set
    /// diverge. Only ever runs after a structural change, never per update pass.
    private func repairIfNeeded(_ mapView: MKMapView) {
        var liveCount = 0
        for case is HouseAnnotation in mapView.annotations { liveCount += 1 }
        guard liveCount != annotationsByHouseID.count else { return }

        let stale = mapView.annotations.compactMap { $0 as? HouseAnnotation }
        annotationsByHouseID.removeAll(keepingCapacity: true)
        let rebuilt = pins.pinsByID.map { houseID, pin -> HouseAnnotation in
            let annotation = HouseAnnotation(
                houseID: houseID,
                pin: pin,
                isPinSelected: lastSelection?.contains(houseID) == true
            )
            annotationsByHouseID[houseID] = annotation
            return annotation
        }
        UIView.performWithoutAnimation {
            mapView.removeAnnotations(stale)
            mapView.addAnnotations(rebuilt)
        }
    }

    // MARK: - Boundary & draft points

    func syncBoundary(_ mapView: MKMapView, boundary: [CLLocationCoordinate2D]) {
        // Order-sensitive: a commutative sum would treat a reordered polygon as
        // unchanged and leave a stale overlay on screen.
        var hasher = Hasher()
        hasher.combine(boundary.count)
        for coordinate in boundary {
            hasher.combine(coordinate.latitude)
            hasher.combine(coordinate.longitude)
        }
        let value = hasher.finalize()
        guard value != boundaryHash else { return }
        boundaryHash = value

        if let boundaryOverlay {
            mapView.removeOverlay(boundaryOverlay)
            self.boundaryOverlay = nil
        }
        guard boundary.count >= 2 else { return }
        let overlay: MKOverlay = boundary.count >= 3
            ? MKPolygon(coordinates: boundary, count: boundary.count)
            : MKPolyline(coordinates: boundary, count: boundary.count)
        boundaryOverlay = overlay
        mapView.addOverlay(overlay, level: .aboveRoads)
    }

    /// Draws the planned walking order. Rebuilt only when the order actually
    /// changes — recording a status shortens the remaining route, and redrawing a
    /// few-hundred-point polyline on every pin tap would be wasteful.
    func syncRoute(_ mapView: MKMapView, coordinates: [CLLocationCoordinate2D]) {
        var hasher = Hasher()
        hasher.combine(coordinates.count)
        for coordinate in coordinates {
            hasher.combine(coordinate.latitude)
            hasher.combine(coordinate.longitude)
        }
        let value = hasher.finalize()
        guard value != routeHash else { return }
        routeHash = value

        if let routeOverlay {
            mapView.removeOverlay(routeOverlay)
            self.routeOverlay = nil
        }
        guard coordinates.count >= 2 else { return }
        let line = RoutePolyline(coordinates: coordinates, count: coordinates.count)
        routeOverlay = line
        // Below the boundary so a drawn territory outline stays readable on top.
        mapView.addOverlay(line, level: .aboveRoads)
    }

    /// Places (or moves) the ring that marks the next house on the route.
    func syncNextStop(_ mapView: MKMapView, coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else {
            if let existing = nextStopAnnotation {
                mapView.removeAnnotation(existing)
                nextStopAnnotation = nil
            }
            return
        }
        if let existing = nextStopAnnotation {
            guard existing.coordinate.latitude != coordinate.latitude
                || existing.coordinate.longitude != coordinate.longitude else { return }
            existing.coordinate = coordinate
            return
        }
        let annotation = NextStopAnnotation(coordinate: coordinate)
        nextStopAnnotation = annotation
        mapView.addAnnotation(annotation)
    }

    func syncDraftPoints(_ mapView: MKMapView, points: [CLLocationCoordinate2D]) {
        if draftAnnotations.count != points.count {
            UIView.performWithoutAnimation {
                if !draftAnnotations.isEmpty { mapView.removeAnnotations(draftAnnotations) }
                draftAnnotations = points.enumerated().map {
                    DraftPointAnnotation(number: $0.offset + 1, coordinate: $0.element)
                }
                if !draftAnnotations.isEmpty { mapView.addAnnotations(draftAnnotations) }
            }
            return
        }
        for (index, annotation) in draftAnnotations.enumerated() where
            annotation.coordinate.latitude != points[index].latitude
            || annotation.coordinate.longitude != points[index].longitude {
            annotation.coordinate = points[index]
        }
    }

    // MARK: - Camera

    func applyCameraCommand(_ mapView: MKMapView, command: MapCameraCommand?) {
        guard let command, command.id != lastCommandID else { return }
        lastCommandID = command.id
        switch command.kind {
        case .region(let region, let animated):
            guard region.isUsable else { return }
            (mapView as? StartupRegionMapView)?.pendingStartupRegion = nil
            mapView.setUserTrackingMode(.none, animated: false)
            mapView.setRegion(region, animated: animated && !isMotionReduced)
        case .follow(let on):
            mapView.setUserTrackingMode(on ? .follow : .none, animated: !isMotionReduced)
        }
    }

    func requestDrop(for houseID: UUID) {
        guard !consumedDropIDs.contains(houseID) else { return }
        if let annotation = annotationsByHouseID[houseID] {
            if let view = mapView?.view(for: annotation) as? HousePinView, !isMotionReduced {
                view.performDrop()
            }
            consume(dropID: houseID)
            return
        }
        pendingDropHouseID = houseID
    }

    private func consume(dropID: UUID) {
        consumedDropIDs.append(dropID)
        if consumedDropIDs.count > 16 { consumedDropIDs.removeFirst() }
        pendingDropHouseID = nil
        // Never call back synchronously: this runs inside `updateUIView`, and the
        // handler writes SwiftUI state.
        Task { @MainActor [weak self] in
            self?.onDropConsumed?(dropID)
        }
    }

    private var isMotionReduced: Bool {
        reduceMotionEnabled || UIAccessibility.isReduceMotionEnabled
    }

    func tearDown(_ mapView: MKMapView) {
        mapView.delegate = nil
        self.mapView = nil
        // The closures capture the host struct, which transitively retains the whole
        // house snapshot. MapKit can outlive dismantle, so clear them explicitly.
        onCameraIdle = nil
        onCameraMoved = nil
        onTrackingModeChanged = nil
        onTapHouse = nil
        onClusterNeedsDisambiguation = nil
        onDropConsumed = nil
        menuProvider = nil
        previewProvider = nil
    }

    // MARK: - User location puck

    func applyUserHeading(_ heading: Double?, accuracy: Double?) {
        guard heading != lastHeading || accuracy != lastHeadingAccuracy else { return }
        lastHeading = heading
        lastHeadingAccuracy = accuracy
        refreshPuck()
    }

    private func refreshPuck() {
        guard let mapView,
              let puck = mapView.view(for: mapView.userLocation) as? UserLocationPuckView
        else { return }
        puck.apply(
            headingDegrees: lastHeading,
            accuracy: lastHeadingAccuracy,
            mapHeadingDegrees: mapView.camera.heading
        )
        if let accuracy = mapView.userLocation.location?.horizontalAccuracy, accuracy > 0 {
            puck.apply(accuracyRadiusInPoints: CGFloat(accuracy / metersPerPoint(mapView)))
        }
        puck.setPulsing(mapView.userTrackingMode != .none)
    }

    private func metersPerPoint(_ mapView: MKMapView) -> Double {
        let height = max(Double(mapView.bounds.height), 1)
        return max((mapView.region.span.latitudeDelta * 111_320) / height, 0.0001)
    }

    // MARK: - Clustering gate

    /// Clustering stays **off** for the whole range anyone actually canvasses in.
    ///
    /// Leaving the decision entirely to MapKit's collision engine sounds right —
    /// it merges exactly when two pins would overlap — but "the artwork touches"
    /// is nowhere near "I am done working with these pins". Two houses 25 m apart
    /// collide at street zoom, so the map kept collapsing into bubbles precisely
    /// when individual pins were needed most.
    ///
    /// So: pins stay individual until the camera is genuinely at overview scale,
    /// and clustering exists only as a legibility/performance backstop above that.
    /// With `collisionMode = .none` below the gate, overlapping pins stack visibly
    /// instead of silently hiding each other — nothing ever disappears.
    private static let clusterOnMeters = 3_000.0
    private static let clusterOffMeters = 2_000.0
    /// Safety valve: even at working zoom, this many simultaneous pins needs help.
    private static let clusterOnVisiblePins = 1_200
    private static let clusterOffVisiblePins = 800

    /// Runs only when the camera settles — never per frame.
    private func updateClusteringGate(_ mapView: MKMapView) {
        let metersAcross = mapView.region.span.latitudeDelta * 111_320
        let visible = visibleHouseCount(mapView, stopAfter: Self.clusterOnVisiblePins + 1)

        // Hysteresis on both signals, so a pinch that hovers on a threshold cannot
        // flap the mode back and forth.
        let shouldCluster: Bool
        if clusteringEnabled {
            shouldCluster = metersAcross > Self.clusterOffMeters
                || visible > Self.clusterOffVisiblePins
        } else {
            shouldCluster = metersAcross > Self.clusterOnMeters
                || visible > Self.clusterOnVisiblePins
        }
        guard shouldCluster != clusteringEnabled else { return }
        clusteringEnabled = shouldCluster

        // MapKit decides clustering when it builds an annotation view, so the mode
        // change only reaches views that already exist by re-declaring them.
        // Bounded to the padded viewport: everything off-screen picks the new mode
        // up from `viewFor` when it is eventually created.
        let affected = houseAnnotations(in: paddedVisibleRect(mapView), of: mapView)
        guard !affected.isEmpty else { return }
        UIView.performWithoutAnimation {
            mapView.removeAnnotations(affected)
            mapView.addAnnotations(affected)
        }
    }

    private func paddedVisibleRect(_ mapView: MKMapView) -> MKMapRect {
        mapView.visibleMapRect.insetBy(
            dx: -mapView.visibleMapRect.width * 0.25,
            dy: -mapView.visibleMapRect.height * 0.25
        )
    }

    /// House annotations in `rect`, including those currently hidden inside a
    /// cluster bubble.
    private func houseAnnotations(in rect: MKMapRect, of mapView: MKMapView) -> [HouseAnnotation] {
        var result: [HouseAnnotation] = []
        for item in mapView.annotations(in: rect) {
            if let house = item as? HouseAnnotation {
                result.append(house)
            } else if let cluster = item as? MKClusterAnnotation {
                for member in cluster.memberAnnotations {
                    if let house = member as? HouseAnnotation { result.append(house) }
                }
            }
        }
        return result
    }

    /// Counts via MapKit's own spatial index, and stops as soon as the answer can
    /// no longer change.
    private func visibleHouseCount(_ mapView: MKMapView, stopAfter limit: Int) -> Int {
        var count = 0
        for item in mapView.annotations(in: mapView.visibleMapRect) {
            if let cluster = item as? MKClusterAnnotation {
                count += cluster.memberAnnotations.count
            } else if item is HouseAnnotation {
                count += 1
            }
            if count >= limit { break }
        }
        return count
    }

    // MARK: - Pin scale

    /// How big the pins are drawn at the current zoom.
    ///
    /// Deliberately **asymmetric**: leaving the full-size tier needs a clear margin,
    /// but coming back to it happens as soon as the camera is anywhere near street
    /// level. The old symmetric band (shrink at 800 m, grow back only under 550 m)
    /// meant an ordinary working zoom could sit in the shrunken state indefinitely.
    private func scale(forMetersAcross meters: Double) -> PinScale {
        switch pinScale {
        case .full:
            return meters > 1_500 ? .compact : .full
        case .compact:
            if meters <= 1_300 { return .full }
            return meters > 3_200 ? .dot : .compact
        case .dot:
            if meters <= 1_300 { return .full }
            return meters <= 3_000 ? .compact : .dot
        }
    }

    /// Cheap enough to run on every frame of a gesture, so the size tracks the
    /// pinch instead of snapping once the camera stops.
    private func updatePinScale(_ mapView: MKMapView) {
        let metersAcross = mapView.region.span.latitudeDelta * 111_320
        let next = scale(forMetersAcross: metersAcross)
        guard next != pinScale else { return }
        pinScale = next

        // Push to what is on screen for an immediate redraw. Correctness does not
        // depend on this loop — every view re-reads the scale in `prepareForDisplay`
        // and in `configure`, so anything missed here fixes itself on redisplay.
        for annotation in mapView.annotations(in: paddedVisibleRect(mapView)) {
            guard let house = annotation as? HouseAnnotation,
                  let view = mapView.view(for: house) as? HousePinView else { continue }
            view.refreshScale()
        }
        if let next = nextStopAnnotation,
           let halo = mapView.view(for: next) as? NextStopHaloView {
            halo.refreshScale()
        }
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        switch annotation {
        case is MKUserLocation:
            guard let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: UserLocationPuckView.reuseIdentifier,
                for: annotation
            ) as? UserLocationPuckView else { return nil }
            view.apply(
                headingDegrees: lastHeading,
                accuracy: lastHeadingAccuracy,
                mapHeadingDegrees: mapView.camera.heading
            )
            return view

        case is NextStopAnnotation:
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: NextStopHaloView.reuseIdentifier,
                for: annotation
            )
            (view as? NextStopHaloView)?.coordinator = self
            (view as? NextStopHaloView)?.refreshScale()
            return view

        case is HouseAnnotation:
            guard let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: HousePinView.reuseIdentifier,
                for: annotation
            ) as? HousePinView else { return nil }
            view.coordinator = self
            if clusteringEnabled {
                view.clusteringIdentifier = HousePinView.clusteringIdentifier
                view.collisionMode = .circle
            } else {
                // No clustering AND no collision: every pin stays on screen and
                // stays tappable. Overlapping pins stack visibly rather than one
                // silently winning the spot.
                view.clusteringIdentifier = nil
                view.collisionMode = .none
            }
            view.configure()
            return view

        case is MKClusterAnnotation:
            guard let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: ClusterBubbleView.reuseIdentifier,
                for: annotation
            ) as? ClusterBubbleView else { return nil }
            view.configure()
            return view

        case is DraftPointAnnotation:
            return mapView.dequeueReusableAnnotationView(
                withIdentifier: DraftPointView.reuseIdentifier,
                for: annotation
            )

        default:
            return nil
        }
    }

    func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        // Fade only a modest batch: after a territory switch this could otherwise be
        // thousands of concurrent animations.
        if !isMotionReduced, views.count <= 60 {
            for view in views where view.annotation is HouseAnnotation || view.annotation is MKClusterAnnotation {
                view.alpha = 0
                UIView.animate(withDuration: 0.16) { view.alpha = 1 }
            }
        }

        guard let pendingDropHouseID else { return }
        for view in views {
            guard let house = view.annotation as? HouseAnnotation,
                  house.houseID == pendingDropHouseID else { continue }
            if !isMotionReduced { (view as? HousePinView)?.performDrop() }
            consume(dropID: pendingDropHouseID)
            break
        }
    }

    /// One entry point for house taps, shared by the pin's own recognizer (fast
    /// path) and `didSelect` (fallback). Debounced **per house**: a global debounce
    /// silently swallows the second tap when the user works quickly down a street.
    private var lastTapByHouse: [UUID: Date] = [:]

    func houseTapped(_ houseID: UUID) {
        let now = Date()
        if let last = lastTapByHouse[houseID], now.timeIntervalSince(last) < 0.3 { return }
        lastTapByHouse[houseID] = now
        if lastTapByHouse.count > 64 {
            let cutoff = now.addingTimeInterval(-2)
            lastTapByHouse = lastTapByHouse.filter { $0.value > cutoff }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onTapHouse?(houseID)
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        switch view.annotation {
        case let house as HouseAnnotation:
            houseTapped(house.houseID)
            deselect(mapView, view.annotation)
        case let cluster as MKClusterAnnotation:
            zoomInto(cluster, mapView: mapView)
            deselect(mapView, view.annotation)
        case is MKMapFeatureAnnotation:
            // A tapped POI: MapKit shows its own callout, nothing for us to do.
            break
        default:
            break
        }
    }

    private func deselect(_ mapView: MKMapView, _ annotation: MKAnnotation?) {
        guard let annotation else { return }
        Task { @MainActor [weak mapView] in
            mapView?.deselectAnnotation(annotation, animated: false)
        }
    }

    /// Tapping a bubble zooms until its members separate. When they share a
    /// coordinate no zoom can ever split them, so the tap hands off to a
    /// disambiguation list rather than looping forever.
    private func zoomInto(_ cluster: MKClusterAnnotation, mapView: MKMapView) {
        var minLatitude = Double.greatestFiniteMagnitude
        var maxLatitude = -Double.greatestFiniteMagnitude
        var minLongitude = Double.greatestFiniteMagnitude
        var maxLongitude = -Double.greatestFiniteMagnitude
        var houseIDs: [UUID] = []
        houseIDs.reserveCapacity(cluster.memberAnnotations.count)

        for member in cluster.memberAnnotations {
            let coordinate = member.coordinate
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
            if let house = member as? HouseAnnotation { houseIDs.append(house.houseID) }
        }
        guard minLatitude <= maxLatitude else { return }

        let latitudeExtent = maxLatitude - minLatitude
        let longitudeExtent = maxLongitude - minLongitude
        // Below roughly 8 m of spread, zooming cannot separate the members.
        let isDegenerate = latitudeExtent < 0.00008 && longitudeExtent < 0.00008
        if isDegenerate {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            onClusterNeedsDisambiguation?(houseIDs)
            return
        }

        // Centre on the bounding box, not the centroid: an asymmetric cluster would
        // otherwise push members off screen.
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(latitudeExtent * 1.8, 0.0006),
                longitudeDelta: max(longitudeExtent * 1.8, 0.0006)
            )
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        mapView.setRegion(region, animated: !isMotionReduced)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let route = overlay as? RoutePolyline {
            let renderer = MKPolylineRenderer(polyline: route)
            renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85)
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
        if let polygon = overlay as? MKPolygon {
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.fillColor = UIColor.systemRed.withAlphaComponent(0.13)
            renderer.strokeColor = UIColor.systemRed.withAlphaComponent(0.9)
            renderer.lineWidth = 2.5
            renderer.lineJoin = .round
            return renderer
        }
        if let line = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = UIColor.systemRed.withAlphaComponent(0.9)
            renderer.lineWidth = 2.5
            renderer.lineDashPattern = [8, 6]
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    /// Fires continuously during gestures — the supported hook for camera-tracking
    /// chrome (`MKMapView.region` is not documented as KVO-compliant). Must stay
    /// allocation-free.
    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        updatePinScale(mapView)
        refreshPuck()
        onCameraMoved?(mapView.region)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        updateClusteringGate(mapView)
        updatePinScale(mapView)
        refreshPuck()
        onCameraIdle?(mapView.region)
    }

    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        refreshPuck()
    }

    func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
        onTrackingModeChanged?(mode != .none)
        refreshPuck()
    }
}
