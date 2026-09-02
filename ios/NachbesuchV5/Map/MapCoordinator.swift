import MapKit
import UIKit

/// Owns everything that happens inside `MKMapView`.
///
/// Design rules this class exists to enforce:
/// * Annotations are created once per house and never touched by a gesture.
/// * Content updates patch only the houses that actually changed, and only
///   reconfigure views that are actually on screen.
/// * **There is no clustering and no collision mode.** One house is one pin, from
///   the widest overview to the closest street zoom. Nothing merges, nothing
///   splits, nothing is hidden — so there is no mode for a fast pinch to catch
///   half-applied, and the map looks the same however you arrived at a zoom level.
/// * The only thing zoom changes is how big a pin is drawn, and that is a pure
///   function of the camera: same zoom, same size, always.
@MainActor
final class MapCoordinator: NSObject, MKMapViewDelegate {
    weak var mapView: MKMapView?

    var onCameraIdle: ((MKCoordinateRegion) -> Void)?
    var onCameraMoved: ((MKCoordinateRegion) -> Void)?
    var onTrackingModeChanged: ((Bool) -> Void)?
    var onTapHouse: ((UUID) -> Void)?
    /// Raised when the tapped pin has others stacked underneath it, so the UI can
    /// offer a list instead of opening whichever one happened to win the touch.
    var onStackedPins: (([UUID]) -> Void)?
    var onDropConsumed: ((UUID) -> Void)?
    /// The 1-based number of the tapped draft vertex while drawing, so the UI can
    /// offer moving that one point instead of undoing everything after it.
    var onTapDraftPoint: ((Int) -> Void)?
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
    private var draftAnnotations: [DraftPointAnnotation] = []

    private var lastCommandID: UUID?
    private var pendingDropHouseID: UUID?
    private var consumedDropIDs: [UUID] = []

    private var appliedConfiguration: ConfigurationKey?
    private var appliedChromeInsets: UIEdgeInsets?
    private(set) var pinScale: PinScale = .full
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

    func syncDraftPoints(_ mapView: MKMapView, points: [CLLocationCoordinate2D], selectedNumber: Int?) {
        selectedDraftNumber = selectedNumber
        if draftAnnotations.count != points.count {
            UIView.performWithoutAnimation {
                if !draftAnnotations.isEmpty { mapView.removeAnnotations(draftAnnotations) }
                draftAnnotations = points.enumerated().map {
                    DraftPointAnnotation(number: $0.offset + 1, coordinate: $0.element)
                }
                if !draftAnnotations.isEmpty { mapView.addAnnotations(draftAnnotations) }
            }
            applyDraftSelection(mapView)
            return
        }
        for (index, annotation) in draftAnnotations.enumerated() where
            annotation.coordinate.latitude != points[index].latitude
            || annotation.coordinate.longitude != points[index].longitude {
            annotation.coordinate = points[index]
        }
        applyDraftSelection(mapView)
    }

    /// A tap on a draft vertex while drawing. Deselects the annotation so MapKit
    /// holds no callout selection, then hands the number to the UI.
    func draftPointTapped(_ annotation: DraftPointAnnotation) {
        mapView?.deselectAnnotation(annotation, animated: false)
        UISelectionFeedbackGenerator().selectionChanged()
        onTapDraftPoint?(annotation.number)
    }

    /// The edit selection is SwiftUI state, but the discs are UIKit views that
    /// outlive any single body evaluation — including recycled ones dequeued for
    /// a different vertex. So the flag is pushed here, on every sync, rather
    /// than carried by the annotation.
    private var selectedDraftNumber: Int?

    private func applyDraftSelection(_ mapView: MKMapView) {
        for annotation in draftAnnotations {
            guard let view = mapView.view(for: annotation) as? DraftPointView else { continue }
            view.editSelected = (annotation.number == selectedDraftNumber)
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
        onStackedPins = nil
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

    /// The visible rect plus a margin, so a pin that is one gesture away from
    /// coming on screen is already drawn at the right size when it arrives.
    private func paddedVisibleRect(_ mapView: MKMapView) -> MKMapRect {
        mapView.visibleMapRect.insetBy(
            dx: -mapView.visibleMapRect.width * 0.25,
            dy: -mapView.visibleMapRect.height * 0.25
        )
    }

    // MARK: - Pin scale

    /// How big the pins are drawn at the current zoom.
    ///
    /// **A pure function of the camera** — it reads no previous tier and keeps no
    /// state. That is the whole fix for sizes that used to depend on how you got
    /// somewhere: the old version was a transition table with overlapping
    /// hysteresis bands, so the same zoom produced a different size depending on
    /// the direction and speed of the gesture, and a fast pinch that skipped a band
    /// left the pins a tier behind until the camera moved again.
    ///
    /// Hysteresis is unnecessary here because a tier change is *only* a bitmap
    /// swap: same canvas, same anchor, no layout and no animation. Flapping across
    /// a threshold costs one cache lookup and is invisible.
    static func scale(forMetersAcross meters: Double) -> PinScale {
        switch meters {
        case ..<1_400: .full
        case ..<3_000: .compact
        default: .dot
        }
    }

    /// Cheap enough to run on every frame of a gesture, so the size tracks the
    /// pinch instead of snapping once the camera stops. Early-outs on the common
    /// frame, where the tier has not changed at all.
    private func updatePinScale(_ mapView: MKMapView) {
        let metersAcross = mapView.region.span.latitudeDelta * 111_320
        let next = Self.scale(forMetersAcross: metersAcross)
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

        case is HouseAnnotation:
            guard let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: HousePinView.reuseIdentifier,
                for: annotation
            ) as? HousePinView else { return nil }
            view.coordinator = self
            view.configure()
            return view

        case let draft as DraftPointAnnotation:
            guard let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: DraftPointView.reuseIdentifier,
                for: draft
            ) as? DraftPointView else { return nil }
            view.coordinator = self
            view.editSelected = (draft.number == selectedDraftNumber)
            return view

        default:
            return nil
        }
    }

    /// Only job: land the drop animation for a house that was just placed.
    ///
    /// Pins deliberately do **not** fade in as they scroll into view. A per-view
    /// alpha animation on every pan is both the largest avoidable cost here and the
    /// only way a recycled pin can come back half transparent — and a pin appearing
    /// as you pan is not an event that needs announcing.
    func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
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
    private var lastDirectTapByHouse: [UUID: Date] = [:]

    func houseTappedFromGesture(_ houseID: UUID) {
        let now = Date()
        if let last = lastTapByHouse[houseID], now.timeIntervalSince(last) < 0.35 { return }
        lastDirectTapByHouse[houseID] = now
        executeHouseTap(houseID, at: now)
    }

    func houseTapped(_ houseID: UUID) {
        let now = Date()
        if let last = lastTapByHouse[houseID], now.timeIntervalSince(last) < 0.35 { return }
        executeHouseTap(houseID, at: now)
    }

    private func executeHouseTap(_ houseID: UUID, at now: Date) {
        lastTapByHouse[houseID] = now
        if lastTapByHouse.count > 64 {
            let cutoff = now.addingTimeInterval(-2)
            lastTapByHouse = lastTapByHouse.filter { $0.value > cutoff }
        }
        if lastDirectTapByHouse.count > 64 {
            let cutoff = now.addingTimeInterval(-2)
            lastDirectTapByHouse = lastDirectTapByHouse.filter { $0.value > cutoff }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let stacked = stackedHouseIDs(around: houseID)
        if stacked.count > 1 {
            onStackedPins?(stacked)
        } else {
            onTapHouse?(houseID)
        }
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        switch view.annotation {
        case let house as HouseAnnotation:
            deselect(mapView, view.annotation)
            let now = Date()
            if let lastDirect = lastDirectTapByHouse[house.houseID], now.timeIntervalSince(lastDirect) < 1.0 {
                // Already processed by the direct pin gesture recognizer; ignore MapKit's delayed echo.
                return
            }
            houseTapped(house.houseID)
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

    /// House IDs sitting essentially on top of the tapped one, tapped house first.
    ///
    /// With nothing ever merged or hidden, houses at the same spot render as one
    /// visible pin and a tap can only reach whichever view is on top. This finds the
    /// ones underneath so the UI can offer them.
    ///
    /// The radius is deliberately **small**. Merely adjacent pins overlap at street
    /// zoom, but each still exposes enough of itself to be hit directly — MapKit
    /// hit-tests the topmost view under the finger, so a partly covered pin is a
    /// perfectly good target. Only a pin whose centre is under another pin's head is
    /// genuinely unreachable, and that is the case worth a list.
    ///
    /// Costs one spatial-index query against a rect a few points wide, on tap only.
    private func stackedHouseIDs(around houseID: UUID) -> [UUID] {
        guard let mapView, let tapped = annotationsByHouseID[houseID] else { return [houseID] }

        // MapKit points per screen point, so a screen-space radius can be expressed
        // as a map rect without leaving the projection.
        let mapPointsPerScreenPoint = mapView.visibleMapRect.width / max(mapView.bounds.width, 1)
        let radius = pinScale.headDiameter * 0.3 * mapPointsPerScreenPoint
        let origin = MKMapPoint(tapped.coordinate)
        let rect = MKMapRect(
            x: origin.x - radius, y: origin.y - radius,
            width: radius * 2, height: radius * 2
        )

        var ids = [houseID]
        for case let house as HouseAnnotation in mapView.annotations(in: rect)
        where house.houseID != houseID {
            // The query is rectangular; the pin heads are round.
            let point = MKMapPoint(house.coordinate)
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            if dx * dx + dy * dy <= radius * radius { ids.append(house.houseID) }
        }
        return ids
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
