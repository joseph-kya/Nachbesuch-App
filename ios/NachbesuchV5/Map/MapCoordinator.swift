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
    #if DEBUG
    private var zoomBugStarted = false
    #endif
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
            #if DEBUG
            startZoomBugHarnessIfNeeded(mapView)
            #endif
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

        // Stable input order makes MapKit's screen-space cluster seed selection
        // repeatable across launches instead of depending on Dictionary iteration.
        toRemove.sort(by: Self.annotationOrder)
        toAdd.sort(by: Self.annotationOrder)

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
        let ordered = rebuilt.sorted(by: Self.annotationOrder)
        UIView.performWithoutAnimation {
            mapView.removeAnnotations(stale)
            mapView.addAnnotations(ordered)
        }
    }

    private static func annotationOrder(_ lhs: HouseAnnotation, _ rhs: HouseAnnotation) -> Bool {
        if lhs.coordinate.latitude != rhs.coordinate.latitude {
            return lhs.coordinate.latitude < rhs.coordinate.latitude
        }
        if lhs.coordinate.longitude != rhs.coordinate.longitude {
            return lhs.coordinate.longitude < rhs.coordinate.longitude
        }
        return lhs.houseID.uuidString < rhs.houseID.uuidString
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
    /// Runs only when the camera settles — never per frame.
    func updateClusteringGate(_ mapView: MKMapView) {
        let metersAcross = viewportMetersAcross(mapView)
        let visible = visibleHouseCount(
            mapView,
            stopAfter: MapPinPresentationPolicy.clusterOnVisiblePins + 1
        )
        let shouldCluster = MapPinPresentationPolicy.clusters(
            currentlyEnabled: clusteringEnabled,
            metersAcross: metersAcross,
            visiblePins: visible
        )
        guard shouldCluster != clusteringEnabled else { return }
        clusteringEnabled = shouldCluster

        // MapKit stores cluster membership on more than the currently realised
        // views. At extreme overview zoom it can collapse the complete territory
        // into one generated annotation; re-adding the SAME member objects later
        // allows their old presentation positions to survive the split. Rebuild
        // fresh annotation identities at the rare gate transition so no internal
        // cluster state can leak back into street-level pins.
        let oldAnnotations = annotationsByHouseID.values.sorted(by: Self.annotationOrder)
        guard !oldAnnotations.isEmpty else { return }
        var replacements: [HouseAnnotation] = []
        replacements.reserveCapacity(pins.pinsByID.count)
        var replacementIndex: [UUID: HouseAnnotation] = [:]
        replacementIndex.reserveCapacity(pins.pinsByID.count)
        for (houseID, pin) in pins.pinsByID {
            let annotation = HouseAnnotation(
                houseID: houseID,
                pin: pin,
                isPinSelected: lastSelection?.contains(houseID) == true
            )
            replacements.append(annotation)
            replacementIndex[houseID] = annotation
        }
        replacements.sort(by: Self.annotationOrder)
        annotationsByHouseID = replacementIndex

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mapView.removeAnnotations(oldAnnotations)
            mapView.addAnnotations(replacements)
            CATransaction.commit()
        }
    }

    // MARK: - Zoom-bug diagnostics

    #if DEBUG
    /// Drives the exact sequence that corrupts pin placement — street level, full
    /// zoom-out into a single cluster, back to street level — and measures where
    /// each realised pin view actually sits against where its own coordinate says it
    /// should. Enabled with `NACHBESUCH_ZOOMBUG=1`.
    ///
    /// Measuring rather than guessing: several plausible fixes (pin sizes, anchors,
    /// hysteresis, fresh annotation identities) have already failed on this bug, so
    /// the useful next step is a number, not another hypothesis.
    private func startZoomBugHarnessIfNeeded(_ mapView: MKMapView) {
        guard ProcessInfo.processInfo.environment["NACHBESUCH_ZOOMBUG"] != nil,
              !zoomBugStarted,
              !annotationsByHouseID.isEmpty
        else { return }
        zoomBugStarted = true
        let home = mapView.region

        let wide = MKCoordinateRegion(
            center: home.center,
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
        )
        // A real pinch is not a completed animation. The first version of this
        // harness let each `setRegion` settle, MapKit re-laid the views out at the
        // end, and nothing drifted. Interrupting the zoom mid-flight — repeatedly,
        // the way a finger does — is what the reported repro actually does.
        func step(_ delay: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        step(3) { [weak self, weak mapView] in
            guard let self, let mapView else { return }
            self.dumpPinPlacement(mapView, label: "1-BEFORE")
            mapView.setRegion(wide, animated: true)
            step(0.6) { mapView.setRegion(home, animated: true) }
            step(1.0) { mapView.setRegion(wide, animated: true) }
            step(1.5) { mapView.setRegion(home, animated: true) }
            step(1.9) { mapView.setRegion(wide, animated: true) }
            step(4.0) { self.dumpPinPlacement(mapView, label: "2-CLUSTERED") }
            step(4.2) { mapView.setRegion(home, animated: true) }
            step(4.7) { mapView.setRegion(wide, animated: true) }
            step(5.1) { mapView.setRegion(home, animated: true) }
            step(10.0) { self.dumpPinPlacement(mapView, label: "3-AFTER") }
        }
    }

    /// Continuous drift watch, so the bug can be caught during a **real** pinch
    /// rather than only in the scripted sequence. `NACHBESUCH_PINWATCH=1`.
    private func reportPinDriftIfWatching(_ mapView: MKMapView) {
        guard ProcessInfo.processInfo.environment["NACHBESUCH_PINWATCH"] != nil else { return }
        // While clustering is on, MapKit deliberately translates member views toward
        // the cluster centre — that offset is the feature, not the fault. The state
        // worth watching is individual pins, which must sit exactly on their
        // coordinates.
        guard !clusteringEnabled else { return }
        var worst: CGFloat = 0
        var worstID = ""
        var drifted = 0
        var realised = 0
        for annotation in mapView.annotations {
            guard let house = annotation as? HouseAnnotation,
                  let view = mapView.view(for: house) as? HousePinView,
                  let delta = view.tipOffsetFromCoordinate(in: mapView)
            else { continue }
            realised += 1
            let magnitude = max(abs(delta.x), abs(delta.y))
            if magnitude > 1.5 { drifted += 1 }
            if magnitude > worst {
                worst = magnitude
                worstID = String(house.houseID.uuidString.prefix(4))
            }
        }
        guard drifted > 0 else { return }
        print(String(
            format: "PINWATCH drift=%d/%d worst=%.1fpt (%@) clustering=%@ scale=%@",
            drifted, realised, worst, worstID,
            clusteringEnabled ? "on" : "off", "\(pinScale)"
        ))
    }

    private func dumpPinPlacement(_ mapView: MKMapView, label: String) {
        var lines = [
            "=== PINDUMP \(label) clustering=\(clusteringEnabled) scale=\(pinScale) "
                + "span=\(String(format: "%.4f", mapView.region.span.latitudeDelta)) ==="
        ]
        var realised = 0
        var offenders = 0
        for annotation in mapView.annotations {
            guard let house = annotation as? HouseAnnotation,
                  let view = mapView.view(for: house) as? HousePinView
            else { continue }
            realised += 1
            // The tip is what has to land on the building. Comparing `center`
            // against `converted point + view.centerOffset` — the first version of
            // this check — is close to tautological: it cancels a stale offset out
            // and reports success even when the pin is visibly wrong.
            guard let tipDelta = view.tipOffsetFromCoordinate(in: mapView) else { continue }
            let dx = tipDelta.x
            let dy = tipDelta.y
            let drifted = abs(dx) > 0.5 || abs(dy) > 0.5
            if drifted { offenders += 1 }
            guard realised <= 6 || drifted else { continue }
            lines.append(String(
                format: "%@ %@ delta=(%.1f,%.1f) center=(%.1f,%.1f) off=(%.1f,%.1f) img=%.0fx%.0f bounds=%.0fx%.0f transform=%@",
                drifted ? "DRIFT" : "  ok ",
                String(house.houseID.uuidString.prefix(4)),
                dx, dy,
                view.center.x, view.center.y,
                view.centerOffset.x, view.centerOffset.y,
                view.image?.size.width ?? 0, view.image?.size.height ?? 0,
                view.bounds.width, view.bounds.height,
                view.transform.isIdentity ? "identity" : "\(view.transform)"
            ))
        }
        lines.append("=== realised=\(realised) drifted=\(offenders) ===")
        print(lines.joined(separator: "\n"))
    }
    #endif

    private func paddedVisibleRect(_ mapView: MKMapView) -> MKMapRect {
        mapView.visibleMapRect.insetBy(
            dx: -mapView.visibleMapRect.width * 0.25,
            dy: -mapView.visibleMapRect.height * 0.25
        )
    }

    /// Counts via MapKit's own spatial index, and stops as soon as the answer can
    /// no longer change.
    private func visibleHouseCount(_ mapView: MKMapView, stopAfter limit: Int) -> Int {
        var houseIDs: Set<UUID> = []
        houseIDs.reserveCapacity(min(limit, 1_024))
        for item in mapView.annotations(in: mapView.visibleMapRect) {
            if let cluster = item as? MKClusterAnnotation {
                for case let house as HouseAnnotation in cluster.memberAnnotations {
                    houseIDs.insert(house.houseID)
                    if houseIDs.count >= limit { return houseIDs.count }
                }
            } else if let house = item as? HouseAnnotation {
                houseIDs.insert(house.houseID)
            }
            if houseIDs.count >= limit { break }
        }
        return houseIDs.count
    }

    // MARK: - Pin scale

    /// Cheap enough to run on every frame of a gesture, so the size tracks the
    /// pinch instead of snapping once the camera stops.
    private func updatePinScale(_ mapView: MKMapView) {
        let next = MapPinPresentationPolicy.scale(
            current: pinScale,
            metersAcross: viewportMetersAcross(mapView)
        )
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

    /// Actual horizontal ground width. `latitudeDelta * 111_320` measures the
    /// vertical span and made identical zooms choose different tiers on tall phones,
    /// iPads and after rotation.
    private func viewportMetersAcross(_ mapView: MKMapView) -> Double {
        let metersPerMapPoint = MKMetersPerMapPointAtLatitude(mapView.centerCoordinate.latitude)
        return MapPinPresentationPolicy.viewportMetersAcross(
            mapPointsAcross: mapView.visibleMapRect.width,
            metersPerMapPoint: metersPerMapPoint
        )
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
        // Pins entering the viewport appear immediately. Fading every newly realised
        // or re-clustered view made ordinary panning look like data was loading and
        // left recycled views translucent. New houses still use `performDrop()`.
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
        let houses = cluster.memberAnnotations.compactMap { $0 as? HouseAnnotation }
            .sorted {
                let addressOrder = $0.pin.address.localizedStandardCompare($1.pin.address)
                return addressOrder == .orderedSame
                    ? $0.houseID.uuidString < $1.houseID.uuidString
                    : addressOrder == .orderedAscending
            }
        let houseIDs = houses.map(\.houseID)
        let coordinates = cluster.memberAnnotations.map(\.coordinate)
        guard let first = coordinates.first else { return }

        var minX = MKMapPoint(first).x
        var maxX = minX
        var minY = MKMapPoint(first).y
        var maxY = minY
        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate)
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let northWest = MKMapPoint(x: minX, y: minY).coordinate
        let southEast = MKMapPoint(x: maxX, y: maxY).coordinate
        let diagonalMeters = CLLocation(latitude: northWest.latitude, longitude: northWest.longitude)
            .distance(from: CLLocation(latitude: southEast.latitude, longitude: southEast.longitude))
        // Coordinates closer than walking accuracy cannot be separated reliably.
        if diagonalMeters < 6 {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            onClusterNeedsDisambiguation?(houseIDs)
            return
        }

        // Fit MapKit map points rather than degree spans. This respects latitude,
        // phone orientation and the actual aspect ratio. A minimum 140 m target
        // avoids an abrupt jump to building-level imagery for a small cluster.
        let centerPoint = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let metersPerPoint = MKMetersPerMapPointAtLatitude(centerPoint.coordinate.latitude)
        let minimumSide = 140 / max(metersPerPoint, 0.000_001)
        let width = max((maxX - minX) * 1.7, minimumSide)
        let height = max((maxY - minY) * 1.7, minimumSide)
        let target = MKMapRect(
            x: centerPoint.x - width / 2,
            y: centerPoint.y - height / 2,
            width: width,
            height: height
        )
        let margins = mapView.layoutMargins
        let desiredPadding = UIEdgeInsets(
            top: margins.top + 20,
            left: margins.left + 20,
            bottom: margins.bottom + 20,
            right: margins.right + 20
        )
        // Large accessibility chrome can otherwise leave MapKit a negative fitting
        // area. Preserve at least a small usable viewport and scale both sides of
        // an axis equally, so the cluster does not jump away from the tap.
        let padding = Self.fittedPadding(desiredPadding, in: mapView.bounds.size)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        mapView.setVisibleMapRect(target, edgePadding: padding, animated: !isMotionReduced)
    }

    private static func fittedPadding(_ desired: UIEdgeInsets, in size: CGSize) -> UIEdgeInsets {
        let usableWidth = max(size.width - 96, 0)
        let usableHeight = max(size.height - 96, 0)
        let horizontalTotal = desired.left + desired.right
        let verticalTotal = desired.top + desired.bottom
        let horizontalScale = horizontalTotal > usableWidth && horizontalTotal > 0
            ? usableWidth / horizontalTotal : 1
        let verticalScale = verticalTotal > usableHeight && verticalTotal > 0
            ? usableHeight / verticalTotal : 1
        return UIEdgeInsets(
            top: desired.top * verticalScale,
            left: desired.left * horizontalScale,
            bottom: desired.bottom * verticalScale,
            right: desired.right * horizontalScale
        )
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
        #if DEBUG
        reportPinDriftIfWatching(mapView)
        #endif
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
