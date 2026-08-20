import MapKit
import SwiftData
import SwiftUI
import UIKit

/// The canvassing surface.
///
/// Two structural rules keep this fast, and both were violated by the version this
/// replaces:
///
/// 1. **The map view is never unmounted.** It used to be wrapped in
///    `if isActive { … } else { Color.clear }`, so pulling down Control Centre or
///    answering the location permission alert dismantled `MKMapView` entirely —
///    discarding tiles, annotations and GPU resources, and forcing a full pin
///    rebuild on return. `isActive` now gates *work*, not the view's existence.
/// 2. **Gestures never invalidate this body.** The live camera lives in
///    `MapCameraStore`, a plain object outside SwiftUI's dependency graph.
struct MapScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppNoticeCenter.self) private var notices

    @Query private var houses: [House]
    @Query private var allGebiete: [Gebiet]

    @Environment(LocationService.self) private var location
    @State private var camera = MapCameraStore()

    @AppStorage("map.usesSatellite") private var isSatellite = false
    @AppStorage("map.poiPreset") private var poiPresetRaw = POIPreset.orientation.rawValue
    @AppStorage("map.hasSeenGuide") private var hasSeenGuide = false

    let gebiet: Gebiet?
    @Binding var scope: DayScope
    let isActive: Bool

    // Pin pipeline
    @State private var prepared = PreparedMapSnapshot.empty
    @State private var housesByID: [UUID: House] = [:]
    @State private var structuralVersion = 0
    @State private var contentVersion = 0
    @State private var changedHouseIDs: Set<UUID> = []
    @State private var lastPipelineKey: PipelineKey?

    // Interaction
    @State private var mode: MapMode = .browsing
    @State private var draftBoundary: [CLLocationCoordinate2D] = []
    @State private var selectedHouseIDs: Set<UUID>?
    @State private var cameraCommand: MapCameraCommand?
    @State private var dropHouseID: UUID?
    @State private var isFollowingUser = false
    @State private var isAwayFromTerritory = false

    // Presentation — one route, one sheet. Six independent `isPresented` flags on a
    // single view is how the importer→confirmation race got in.
    @State private var sheetRoute: MapRoute?
    @State private var confirmation: MapConfirmation?
    @State private var isLocating = false
    @State private var saveTask: Task<Void, Never>?
    @State private var namingTask: Task<Void, Never>?
    /// One namespace for every floating glass control, so they can morph into one
    /// another instead of cross-fading.
    @Namespace private var glass

    // Recommended route
    @State private var route = RouteSession()
    /// The in-flight planning task, so ending or re-planning actually stops it.
    @State private var planTask: Task<Void, Never>?
    @State private var routePhase: RoutePhase = .off
    /// Whether the route drawing is on the map. Persisted: the choice belongs to
    /// the user, not to the app launch.
    @AppStorage("route.overlayVisible") private var showsRouteOverlay = true

    private enum RoutePhase: Equatable {
        case off
        /// Asking where to start from.
        case choosingStart
        /// Waiting for a house to be tapped as the start.
        case pickingOnMap
        case running
    }

    init(gebiet: Gebiet?, scope: Binding<DayScope>, isActive: Bool) {
        self.gebiet = gebiet
        _scope = scope
        self.isActive = isActive
        let territoryID = gebiet?.id
        // Guard against `nil`: `gebietID == nil || dayID == nil` matched every
        // orphaned house in the store, rendering them as pins on a territory-less
        // map that "select all + delete" would then wipe.
        _houses = Query(
            filter: #Predicate<House> {
                territoryID != nil && ($0.gebietID == territoryID || $0.dayID == territoryID)
            },
            sort: \House.updatedAt,
            order: .reverse
        )
    }

    private var poiPreset: POIPreset {
        POIPreset(rawValue: poiPresetRaw) ?? .orientation
    }

    private var boundary: [CLLocationCoordinate2D] {
        mode == .drawingArea ? draftBoundary : (gebiet?.boundaryCoordinates ?? [])
    }

    private var isSelecting: Bool { selectedHouseIDs != nil }

    // MARK: - Recommended route

    /// Houses that still need a visit — the set a route is planned over, and the
    /// set that shrinks as you work.
    private var openHouseIDs: Set<UUID> {
        Set(prepared.pinsByID.values.filter(\.hasOpenWork).map(\.id))
    }

    /// The remaining path — the planned street line, trimmed to what is still
    /// ahead of you.
    private var routeCoordinates: [CLLocationCoordinate2D] {
        guard showsRouteOverlay, routePhase == .running, route.isActive else { return [] }
        return route.remainingPath(
            queue: route.remaining(openHouseIDs: openHouseIDs),
            currentLocation: location.location?.coordinate
        )
    }

    /// The coordinate to ring on the map — nil while the overlay is switched off.
    private var nextStopMarker: CLLocationCoordinate2D? {
        guard showsRouteOverlay else { return nil }
        return nextStopPin?.coordinate
    }

    private var nextStopPin: MapPinSnapshot? {
        guard routePhase == .running,
              let next = route.nextStop(openHouseIDs: openHouseIDs) else { return nil }
        return prepared.pinsByID[next]
    }

    private func beginRoute() {
        guard gebiet != nil, !openHouseIDs.isEmpty else { return }
        withAnimation(.appFeedback(reduceMotion: reduceMotion)) { routePhase = .choosingStart }
    }

    private func planRoute(from start: CLLocationCoordinate2D) {
        guard let gebiet else { return }
        let stops = prepared.pinsByID.values
            .filter(\.hasOpenWork)
            .map { RouteStop(houseID: $0.id, latitude: $0.latitude, longitude: $0.longitude) }
        guard !stops.isEmpty else { return }
        withAnimation(.appFeedback(reduceMotion: reduceMotion)) { routePhase = .running }
        let plannedFor = gebiet.id
        planTask?.cancel()
        planTask = Task {
            let succeeded = await route.plan(start: start, stops: stops, for: plannedFor)
            // A territory switch cancels this task (`resetForNewTerritory`), so a
            // result for the old territory can never land on the new one's map.
            guard succeeded, !Task.isCancelled, routePhase == .running else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Frame the whole route so you can see what you are in for.
            if let bounds = MapBounds.around(route.path.isEmpty
                ? [start] + stops.map(\.coordinate)
                : route.path) {
                cameraCommand = .region(bounds.region, animated: !reduceMotion)
            }
        }
    }

    /// Re-plans over the houses still open, starting from where you are standing.
    ///
    /// A plan decays: doors get skipped, houses get added, and after an hour the
    /// original order is no longer the shortest way through what is left.
    private func replanFromHere() {
        guard let coordinate = location.location?.coordinate else {
            notices.show("Ohne Standort lässt sich die Route nicht neu planen.")
            return
        }
        planRoute(from: coordinate)
    }

    /// Centres the map on the next house, so "where do I go now" is one tap away
    /// even when you have panned somewhere else entirely.
    private func focusNextStop() {
        guard let pin = nextStopPin else { return }
        if !showsRouteOverlay {
            withAnimation(.appFeedback(reduceMotion: reduceMotion)) { showsRouteOverlay = true }
        }
        cameraCommand = .region(
            center: pin.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.0025, longitudeDelta: 0.0025),
            animated: !reduceMotion
        )
    }

    /// Leaves the current house for later and moves on to the next one.
    private func skipNextStop() {
        guard let gebiet else { return }
        let moved = route.skipNextStop(openHouseIDs: openHouseIDs, for: gebiet.id)
        guard moved else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let pin = nextStopPin, showsRouteOverlay {
            cameraCommand = .region(
                center: pin.coordinate,
                span: camera.region.span,
                animated: !reduceMotion
            )
        }
    }

    /// Keeps a running route honest against the houses that actually exist.
    ///
    /// Only ever runs once the pin pipeline has produced a snapshot — on the first
    /// frames after launch every house looks closed, and a route would end itself
    /// before it was ever shown.
    private func auditRoute() {
        guard let gebiet, routePhase == .running, lastPipelineKey != nil,
              !prepared.pinsByID.isEmpty else { return }
        route.prune(livingHouseIDs: Set(prepared.pinsByID.keys), for: gebiet.id)
        if route.requiresReplan, !route.isPlanning {
            // Routes from builds that predate per-stop legs cannot advance their
            // line correctly. Repair them automatically rather than showing a
            // plausible-looking but stale route after relaunch.
            planRoute(from: location.location?.coordinate ?? route.start ?? camera.region.center)
            return
        }
        let unplannedOpen = openHouseIDs.subtracting(route.plannedOrder)
        if !unplannedOpen.isEmpty, !route.isPlanning {
            // Houses added after planning must never be silently omitted. Rebuild
            // from the live position when possible. During launch the first GPS fix
            // often arrives after the pins; the saved start is a safer fallback
            // than ending an otherwise valid route just because of that race.
            planRoute(from: location.location?.coordinate ?? route.start ?? camera.region.center)
            return
        }
        guard !route.plannedOrder.isEmpty else {
            endRoute()
            return
        }
        guard route.remaining(openHouseIDs: openHouseIDs).isEmpty else { return }
        finishRoute()
    }

    /// Every house on the route is done. Ends it and says so, rather than leaving a
    /// bar that reads "Route abgeschlossen" until someone taps the cross.
    private func finishRoute() {
        let houses = route.plannedOrder.count
        let metres = route.plannedDistance
        endRoute()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let walked = metres >= 950
            ? String(format: "%.1f km", metres / 1000)
            : "\(Int((metres / 10).rounded() * 10)) m"
        notices.show("Route geschafft: \(houses) Häuser, rund \(walked) Weg.")
    }

    private func endRoute() {
        guard let gebiet else { return }
        planTask?.cancel()
        planTask = nil
        route.end(for: gebiet.id)
        withAnimation(.appFeedback(reduceMotion: reduceMotion)) { routePhase = .off }
    }

    /// Distance to the next stop, but only when it is a plausible walking figure.
    ///
    /// Without a usable fix the raw number is nonsense — a stale or absent position
    /// produced readings like "12258 km", which is worse than showing nothing.
    private var distanceToNextStop: Double? {
        guard let pin = nextStopPin,
              let fix = location.location,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy < 200
        else { return nil }
        let metres = RoutePlanner.metres(fix.coordinate, pin.coordinate)
        return metres < 20_000 ? metres : nil
    }



    var body: some View {
        ZStack {
            MapHost(
                startupRegion: camera.startupRegion,
                pins: prepared,
                structuralVersion: structuralVersion,
                contentVersion: contentVersion,
                changedHouseIDs: changedHouseIDs,
                boundary: boundary,
                draftPoints: mode == .drawingArea ? draftBoundary : [],
                routeCoordinates: routeCoordinates,
                nextStopCoordinate: nextStopMarker,
                selectedHouseIDs: selectedHouseIDs,
                isSatellite: isSatellite,
                poiPreset: poiPreset,
                reduceMotion: reduceMotion,
                dropHouseID: dropHouseID,
                cameraCommand: cameraCommand,
                userHeading: location.headingDegrees,
                userHeadingAccuracy: location.headingAccuracy,
                chromeInsets: chromeInsets,
                onCameraIdle: { region in
                    camera.record(region)
                    updateTerritoryProximity(region)
                },
                onCameraMoved: { camera.updateLive($0) },
                onTrackingModeChanged: { following in
                    isFollowingUser = following
                    location.setFollowing(following)
                },
                picksRouteStart: routePhase == .pickingOnMap,
                onTapHouse: openHouse,
                onClusterNeedsDisambiguation: { ids in
                    sheetRoute = .clusterMembers(ids)
                },
                onDropConsumed: { id in
                    if dropHouseID == id { dropHouseID = nil }
                },
                menuProvider: contextMenu(for:),
                previewProvider: contextPreview(for:)
            )
            .ignoresSafeArea()

            if mode != .browsing || routePhase == .pickingOnMap {
                PlacementReticle(kind: mode == .placingHouse ? .house : .boundaryPoint)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .top) { topChrome }
        .overlay(alignment: .bottom) { bottomChrome }
        .sheet(item: $sheetRoute, content: sheet(for:))
        .alert(item: $confirmation, content: alert(for:))
        .task(id: gebiet?.id) {
            guard let gebiet else { return }
            route.restore(for: gebiet.id)
            routePhase = route.isActive ? .running : .off
        }
        // A restored route can outlive the houses in it. Pruning here — after the
        // pin pipeline has actually loaded — keeps the counter honest and lets a
        // finished round end itself instead of hanging around forever.
        .onChange(of: contentVersion) { _, _ in auditRoute() }
        .onChange(of: structuralVersion) { _, _ in auditRoute() }
        #if DEBUG
        // Test harness. `NACHBESUCH_ROUTE=pick` stops at the start-point step so the
        // crosshair and its bar can be captured; `NACHBESUCH_ROUTE=tap` runs the exact
        // branch a tap on a house takes — the one that silently did nothing because an
        // edit to `openHouse` never landed.
        .task(id: prepared.pinsByID.count) {
            let mode = ProcessInfo.processInfo.environment["NACHBESUCH_ROUTE"]
            guard let mode, routePhase == .off, gebiet != nil,
                  let first = prepared.pinsByID.values.min(by: { $0.latitude < $1.latitude })
            else { return }
            switch mode {
            case "pick":
                routePhase = .choosingStart
                try? await Task.sleep(for: .milliseconds(300))
                routePhase = .pickingOnMap
            case "tap":
                routePhase = .pickingOnMap
                try? await Task.sleep(for: .milliseconds(300))
                openHouse(first.id)
            case "skip":
                // Plans, then defers the first two houses, so the redrawn line and
                // the moved ring can be captured — the paths a tap would take.
                planRoute(from: first.coordinate)
                try? await Task.sleep(for: .seconds(20))
                skipNextStop()
                try? await Task.sleep(for: .milliseconds(700))
                skipNextStop()
            case "hidden":
                planRoute(from: first.coordinate)
                try? await Task.sleep(for: .seconds(20))
                showsRouteOverlay = false
            default:
                planRoute(from: first.coordinate)
            }
        }
        #endif
        .task(id: isActive) {
            if isActive {
                location.beginUsing()
            } else {
                location.endUsing()
                camera.flush()
                // A queued command must not replay against a later coordinator.
                cameraCommand = nil
            }
        }
        .task(id: pipelineKey) {
            await refreshPins()
        }
        .onChange(of: location.location) { _, newLocation in
            performInitialLocateIfNeeded(newLocation)
        }
        .onChange(of: gebiet?.id) { _, _ in
            resetForNewTerritory()
        }
        .onDisappear {
            camera.flush()
            saveTask?.cancel()
            namingTask?.cancel()
            planTask?.cancel()
        }
    }

    // MARK: - Chrome

    /// Insets handed to MapKit so its legal attribution, scale and compass are never
    /// covered. The HIG requires 7 pt at the sides and 10 pt above/below the Apple
    /// logo and legal link — obscuring them is an App Review rejection.
    private var chromeInsets: UIEdgeInsets {
        UIEdgeInsets(top: 132, left: 7, bottom: 108, right: 7)
    }

    /// Co-located glass lives in ONE container: Apple warns that many separate
    /// effect containers degrade performance, and only siblings inside a shared
    /// container can merge as they move.
    @ViewBuilder
    private var topChrome: some View {
        GlassEffectContainer(spacing: AppSpacing.snug) {
            VStack(spacing: AppSpacing.snug) {
                if isSelecting {
                    MapSelectionBar(
                        namespace: glass,
                        selectedCount: selectedHouseIDs?.count ?? 0,
                        totalCount: prepared.pinsByID.count,
                        onCancel: exitSelection,
                        onToggleAll: toggleSelectAll,
                        onExport: { sheetRoute = .exportSelection },
                        onDelete: {
                            confirmation = .deleteSelection(selectedHouseIDs?.count ?? 0)
                        }
                    )
                } else {
                    MapSummaryCard(
                        namespace: glass,
                        title: gebiet?.displayName ?? "Kein Gebiet",
                        subtitle: gebiet?.formattedDateRange ?? "Lege im Archiv ein Gebiet an",
                        stats: prepared.stats,
                        isTwoDay: gebiet?.isTwoDay == true,
                        scope: $scope,
                        onSearch: { sheetRoute = .search },
                        onSelect: enterSelection,
                        canSelect: !prepared.pinsByID.isEmpty
                    )
                }

                if !hasSeenGuide, houses.isEmpty, mode == .browsing, gebiet != nil {
                    MapGuideCard(
                        namespace: glass,
                        onAddHouse: { setMode(.placingHouse) },
                        onDrawArea: beginDrawingArea,
                        onDismiss: { hasSeenGuide = true }
                    )
                }
            }
        }
        .padding(.horizontal, AppSpacing.regular)
        .safeAreaPadding(.top, AppSpacing.tight)
        // The summary bar and the selection bar share a glass id, so switching modes
        // reshapes one panel rather than dissolving two unrelated ones.
        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: isSelecting)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: hasSeenGuide)
    }

    @ViewBuilder
    private var bottomChrome: some View {
        GlassEffectContainer(spacing: AppSpacing.snug) {
            VStack(alignment: .trailing, spacing: AppSpacing.snug) {
                if mode == .browsing, !isSelecting, isAwayFromTerritory {
                    TerritoryButton(namespace: glass, action: showTerritory)
                }

                if mode == .browsing, !isSelecting {
                    LocateButton(
                        isFollowing: isFollowingUser,
                        isBusy: isLocating,
                        isDenied: location.isDenied,
                        namespace: glass,
                        action: toggleFollow
                    )
                }

                switch routePhase {
                case .choosingStart:
                    RouteStartPrompt(
                        canUseLocation: location.location != nil && !location.isDenied,
                        onUseLocation: {
                            guard let coordinate = location.location?.coordinate else { return }
                            planRoute(from: coordinate)
                        },
                        onPickOnMap: {
                            withAnimation(.appFeedback(reduceMotion: reduceMotion)) {
                                routePhase = .pickingOnMap
                            }
                        },
                        onCancel: {
                            withAnimation(.appFeedback(reduceMotion: reduceMotion)) { routePhase = .off }
                        }
                    )
                case .pickingOnMap:
                    RouteStartPicker(
                        onConfirm: { planRoute(from: camera.region.center) },
                        onCancel: {
                            withAnimation(.appFeedback(reduceMotion: reduceMotion)) { routePhase = .off }
                        }
                    )
                case .running:
                    let remaining = route.remaining(openHouseIDs: openHouseIDs)
                    RouteBar(
                        remainingCount: remaining.count,
                        totalCount: max(route.plannedOrder.count, 1),
                        nextAddress: nextStopPin?.address,
                        distanceToNext: distanceToNextStop,
                        isStraightLine: route.fellBackToStraightLines,
                        isPlanning: route.isPlanning,
                        showsOverlay: showsRouteOverlay,
                        onToggleOverlay: {
                            withAnimation(.appFeedback(reduceMotion: reduceMotion)) {
                                showsRouteOverlay.toggle()
                            }
                        },
                        onFocusNext: focusNextStop,
                        canSkip: remaining.count > 1,
                        onSkip: skipNextStop,
                        onEnd: endRoute
                    )
                case .off:
                    EmptyView()
                }

                switch mode {
                case .drawingArea:
                    BoundaryDrawingBar(
                        pointCount: draftBoundary.count,
                        namespace: glass,
                        onCancel: cancelDrawing,
                        onUndo: { if !draftBoundary.isEmpty { draftBoundary.removeLast() } },
                        onAddPoint: addBoundaryPoint,
                        onSave: saveBoundary
                    )
                case .placingHouse, .browsing:
                    if !isSelecting {
                        MapActionBar(
                            isPlacing: mode == .placingHouse,
                            canAddHouse: gebiet != nil,
                            namespace: glass,
                            onCancelPlacement: { setMode(.browsing) },
                            onPrimary: primaryAction,
                            menu: { toolsMenu }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, AppSpacing.regular)
        .safeAreaPadding(.bottom, AppSpacing.snug)
        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: mode)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: isSelecting)
    }

    /// Deliberately short.
    ///
    /// "Pins auswählen" lived here *and* as a button in the summary card, and
    /// "Nächsten Nachbesuch öffnen" was a one-off navigation command sitting among
    /// map settings. A menu that lists everything is a menu nobody reads, so this
    /// one now holds two territory actions and two appearance settings — grouped,
    /// so they read as two decisions rather than eight commands.
    @ViewBuilder
    private var toolsMenu: some View {
        Section {
            Button {
                if gebiet?.hasBoundary == true {
                    confirmation = .boundaryOptions
                } else {
                    beginDrawingArea()
                }
            } label: {
                Label(
                    gebiet?.hasBoundary == true ? "Gebiet bearbeiten" : "Gebiet einzeichnen",
                    systemImage: "pentagon"
                )
            }
            .disabled(gebiet == nil)

            Button {
                sheetRoute = .importArea
            } label: {
                Label("Häuser aus Kartendaten laden", systemImage: "square.and.arrow.down")
            }
            .disabled((gebiet?.boundaryCoordinates.count ?? 0) < 3)

            Button {
                beginRoute()
            } label: {
                Label("Empfohlene Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .disabled(gebiet == nil || openHouseIDs.isEmpty || routePhase != .off)

            if routePhase == .running {
                Button {
                    replanFromHere()
                } label: {
                    Label("Route neu planen", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .disabled(route.isPlanning || openHouseIDs.isEmpty)
            }
        }

        Section {
            // A `Picker` inside a `Menu` becomes a submenu that shows its current
            // value on the parent row — two rows instead of five, and you can see
            // what is selected without opening anything.
            Picker("Kartenstil", selection: $isSatellite) {
                Label("Standard", systemImage: "map").tag(false)
                Label("Satellit", systemImage: "globe.europe.africa.fill").tag(true)
            }

            Picker("Orte", selection: $poiPresetRaw) {
                ForEach(POIPreset.allCases) { preset in
                    Label(preset.title, systemImage: preset.systemImage).tag(preset.rawValue)
                }
            }
        }
    }

    // MARK: - Territory framing

    /// Where the current territory sits — its drawn boundary if there is one, else
    /// the extent of its pins.
    private var territoryRegion: MKCoordinateRegion? {
        if let boundary = gebiet?.boundaryCoordinates, boundary.count >= 3,
           let bounds = MapBounds.around(boundary) {
            return bounds.region
        }
        return prepared.bounds?.region
    }

    /// Frames the whole territory.
    private func showTerritory() {
        guard let region = territoryRegion else { return }
        camera.record(region)
        cameraCommand = .region(region, animated: !reduceMotion)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Drives the "Zum Gebiet" button, which only exists when it has something to
    /// do — if the territory is already on screen the button would be noise.
    private func updateTerritoryProximity(_ region: MKCoordinateRegion) {
        guard let territory = territoryRegion else {
            if isAwayFromTerritory { isAwayFromTerritory = false }
            return
        }
        let latitudeReach = region.span.latitudeDelta / 2
        let longitudeReach = region.span.longitudeDelta / 2
        let away = abs(territory.center.latitude - region.center.latitude) > latitudeReach
            || abs(territory.center.longitude - region.center.longitude) > longitudeReach
        // Only touch state on a real change: this runs every time the camera settles.
        if away != isAwayFromTerritory {
            withAnimation(.appFeedback(reduceMotion: reduceMotion)) {
                isAwayFromTerritory = away
            }
        }
    }

    // MARK: - Pin pipeline

    /// Identity of the data the pins are built from. A change here — and only here —
    /// re-runs the pipeline.
    private struct PipelineKey: Hashable {
        let territoryID: UUID?
        let scope: DayScope
        let houseCount: Int
        let newestUpdate: Date?
    }

    private var pipelineKey: PipelineKey {
        PipelineKey(
            territoryID: gebiet?.id,
            scope: scope,
            houseCount: houses.count,
            newestUpdate: houses.first?.updatedAt
        )
    }

    private func refreshPins() async {
        let key = pipelineKey
        let currentScope = scope

        // Content-only change (a status was tapped): patch just those houses instead
        // of decoding every blob in the territory again.
        if let previous = lastPipelineKey,
           previous.territoryID == key.territoryID,
           previous.scope == key.scope,
           previous.houseCount == key.houseCount,
           let since = previous.newestUpdate,
           key.newestUpdate != previous.newestUpdate {
            // Sorted by updatedAt descending, so everything touched forms a prefix.
            let changed = houses.prefix { $0.updatedAt > since }.map(RawMapHouse.init)
            if !changed.isEmpty {
                let base = prepared
                let patched = await Task.detached(priority: .userInitiated) {
                    MapPinSnapshotBuilder.patch(base, with: changed, scope: currentScope)
                }.value
                guard !Task.isCancelled else { return }
                prepared = patched
                changedHouseIDs = Set(changed.map(\.id))
                contentVersion &+= 1
                lastPipelineKey = key
                return
            }
            // The prefix came back empty even though the key moved. Fall through to a
            // full rebuild rather than advancing the key on a no-op, which used to
            // leave the map permanently showing the pre-change status.
        }

        let raw = houses.map(RawMapHouse.init)
        let index = Dictionary(houses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let snapshot = await Task.detached(priority: .userInitiated) {
            MapPinSnapshotBuilder.build(from: raw, scope: currentScope)
        }.value
        guard !Task.isCancelled else { return }

        prepared = snapshot
        housesByID = index
        changedHouseIDs = []
        structuralVersion &+= 1
        contentVersion &+= 1
        lastPipelineKey = key

        if var selection = selectedHouseIDs {
            selection.formIntersection(snapshot.pinsByID.keys)
            selectedHouseIDs = selection
        }
        // The extent only becomes known here, so re-evaluate rather than waiting for
        // a camera move that may never come.
        updateTerritoryProximity(camera.region)
        scheduleAutoNaming()
    }

    private func resetForNewTerritory() {
        planTask?.cancel()
        planTask = nil
        routePhase = .off
        isAwayFromTerritory = false
        mode = .browsing
        draftBoundary = []
        selectedHouseIDs = nil
        sheetRoute = nil
        prepared = .empty
        housesByID = [:]
        lastPipelineKey = nil
        structuralVersion &+= 1
    }

    // MARK: - Camera

    /// The app's one and only automatic camera move.
    ///
    /// It happens on the first launch that produces a usable fix, and never again —
    /// the flag lives in `UserDefaults`, not in view state. Every later launch, tab
    /// switch and foreground restores exactly where the user left the map.
    private func performInitialLocateIfNeeded(_ newLocation: CLLocation?) {
        guard isActive, camera.wantsInitialLocate,
              let coordinate = newLocation?.coordinate,
              let accuracy = newLocation?.horizontalAccuracy, accuracy > 0, accuracy < 200,
              let target = camera.consumeInitialLocate(at: coordinate)
        else { return }
        // Startup should already feel centred when the first usable fix arrives;
        // a long cross-city flyover only delays the useful map.
        cameraCommand = .region(target, animated: false)
    }

    private func toggleFollow() {
        guard !location.isDenied else {
            notices.show("Standortzugriff ist deaktiviert. Du kannst ihn in den Einstellungen erlauben.")
            return
        }
        if isFollowingUser {
            cameraCommand = .follow(false)
            return
        }

        // The map screen keeps Core Location streaming, so in normal use there is
        // already a perfectly usable fix. Move on the same tap/frame instead of
        // putting the UI behind the stricter fresh-fix request and its timeout.
        if let fix = location.location,
           fix.horizontalAccuracy >= 0,
           fix.horizontalAccuracy < 200,
           fix.timestamp.timeIntervalSinceNow > -600 {
            let target = MKCoordinateRegion(center: fix.coordinate, span: MapCameraStore.recenterSpan)
            camera.record(target)
            cameraCommand = .region(target, animated: false)
            isLocating = false
            location.startStreaming()
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }

        isLocating = true
        location.startStreaming()
        location.requestFreshFix { fix in
            isLocating = false
            guard let coordinate = fix?.coordinate else {
                notices.show("Der Standort konnte nicht ermittelt werden. Die Karte lässt sich weiterhin frei bewegen.")
                return
            }
            camera.record(MKCoordinateRegion(center: coordinate, span: MapCameraStore.recenterSpan))
            cameraCommand = .region(
                center: coordinate,
                span: MapCameraStore.recenterSpan,
                animated: false
            )
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    // MARK: - Modes

    private func setMode(_ newMode: MapMode) {
        withAnimation(.appFeedback(reduceMotion: reduceMotion)) { mode = newMode }
    }

    private func primaryAction() {
        switch mode {
        case .placingHouse:
            guard let gebiet else { return }
            // The reticle's point is at the map centre by construction, so what the
            // user aimed at is what gets stored.
            sheetRoute = .addHouse(coordinate: camera.region.center, gebietID: gebiet.id)
            setMode(.browsing)
        case .browsing:
            setMode(.placingHouse)
        case .drawingArea:
            break
        }
    }

    private func beginDrawingArea() {
        draftBoundary = gebiet?.boundaryCoordinates ?? []
        setMode(.drawingArea)
    }

    private func cancelDrawing() {
        withAnimation(.appFeedback(reduceMotion: reduceMotion)) {
            mode = .browsing
            draftBoundary = []
        }
    }

    private func addBoundaryPoint() {
        draftBoundary.append(camera.region.center)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func saveBoundary() {
        guard let gebiet, draftBoundary.count >= 3 else { return }
        gebiet.boundaryCoordinates = draftBoundary
        guard modelContext.save(reporting: notices, context: "Gebiet konnte nicht gespeichert werden")
        else { return }
        setMode(.browsing)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        scheduleAutoNaming(force: true)
    }

    private func deleteBoundary() {
        guard let gebiet else { return }
        gebiet.boundaryCoordinates = []
        draftBoundary = []
        guard modelContext.save(reporting: notices, context: "Gebiet konnte nicht gelöscht werden")
        else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Selection

    private func enterSelection() {
        guard !prepared.pinsByID.isEmpty else { return }
        withAnimation(.appFeedback(reduceMotion: reduceMotion)) { selectedHouseIDs = [] }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func exitSelection() {
        withAnimation(.appFeedback(reduceMotion: reduceMotion)) { selectedHouseIDs = nil }
    }

    private func toggleSelectAll() {
        let all = Set(prepared.pinsByID.keys)
        selectedHouseIDs = (selectedHouseIDs?.count ?? 0) == all.count ? [] : all
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func toggleSelection(_ id: UUID) {
        guard var selection = selectedHouseIDs else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        selectedHouseIDs = selection
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var selectedHouses: [House] {
        guard let selectedHouseIDs else { return [] }
        return selectedHouseIDs.compactMap { housesByID[$0] }
    }

    private func deleteSelectedHouses() {
        let doomed = selectedHouses
        guard !doomed.isEmpty else { return }
        for house in doomed { modelContext.delete(house) }
        guard modelContext.save(reporting: notices, context: "Auswahl konnte nicht gelöscht werden")
        else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        exitSelection()
    }

    // MARK: - House interaction

    private func openHouse(_ id: UUID) {
        // Picking a route start wins over everything: while that prompt is up, a tap
        // on a house means "start here", not "show me this house".
        if routePhase == .pickingOnMap, let pin = prepared.pinsByID[id] {
            planRoute(from: pin.coordinate)
            return
        }
        if isSelecting {
            toggleSelection(id)
            return
        }
        // O(1): the old code ran `houses.first(where:)` on five separate interaction
        // paths, each a linear scan that could fault houses in from SwiftData.
        guard let house = housesByID[id] else { return }
        sheetRoute = .houseDetail(house.id)
    }

    /// The day a status tap should be written to.
    ///
    /// Derived from the territory's calendar when the user is looking at the combined
    /// view — reading one day's value and writing another is what made taps look dead.
    private func writeDay(for house: House) -> Int {
        switch scope {
        case .day1: return 1
        case .day2: return 2
        case .combined: return gebiet?.writeScope().writeTargetDay ?? 1
        }
    }

    private func setQuickOutcome(_ outcome: VisitOutcome, for id: UUID) {
        guard let house = housesByID[id], let door = house.units.first else { return }
        let day = writeDay(for: house)
        let current = door.result(on: day)
        house.setOutcome(current == outcome ? nil : outcome, for: door.id, day: day)
        scheduleSave()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func markOpenDoors(for id: UUID) {
        guard let house = housesByID[id] else { return }
        guard house.setOutcomeForOpenDoors(.notHome, day: writeDay(for: house)) > 0 else { return }
        scheduleSave()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Coalesces a burst of taps into one SwiftData write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            modelContext.save(reporting: notices, context: "Status konnte nicht gespeichert werden")
        }
    }

    private func scheduleAutoNaming(force: Bool = false) {
        guard let gebiet, force || GebietNameAllocator.isGenericName(gebiet.name) else { return }
        // One cancellable task: the old code fired an unstructured Task per
        // house-count change, queueing overlapping reverse-geocodes into Apple's
        // rate limiter.
        namingTask?.cancel()
        let coordinates = houses.map(\.coordinate)
        namingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await GebietAutoNamer.applyIfNeeded(
                to: gebiet,
                allGebiete: allGebiete,
                modelContext: modelContext,
                notices: notices,
                houseCoordinates: coordinates
            )
        }
    }

    // MARK: - Context menu (UIKit, built lazily on long press)

    private func contextMenu(for pin: MapPinSnapshot) -> UIMenu {
        let id = pin.id
        let navigation = UIMenu(options: .displayInline, children: [
            UIAction(title: "Details öffnen", image: UIImage(systemName: "info.circle")) { _ in
                openHouse(id)
            },
            UIAction(title: "Fußroute öffnen", image: UIImage(systemName: "figure.walk")) { _ in
                MapNavigation.openWalkingRoute(to: pin.coordinate, name: pin.address)
            }
        ])

        let status: UIMenu
        if pin.unitCount == 1 {
            status = UIMenu(options: .displayInline, children: VisitOutcome.allCases.map { outcome in
                UIAction(title: "\(outcome.emoji)  \(outcome.title)") { _ in
                    setQuickOutcome(outcome, for: id)
                }
            })
        } else {
            status = UIMenu(options: .displayInline, children: [
                UIAction(
                    title: "Offene Türen als „Niemand da“ markieren",
                    image: UIImage(systemName: "arrow.clockwise.circle")
                ) { _ in
                    markOpenDoors(for: id)
                }
            ])
        }

        let destructive = UIMenu(options: .displayInline, children: [
            UIAction(title: "Pin löschen", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                if let house = housesByID[id] {
                    confirmation = .deleteHouse(id: id, address: house.address)
                }
            }
        ])

        return UIMenu(title: pin.address, children: [navigation, status, destructive])
    }

    private func contextPreview(for pin: MapPinSnapshot) -> UIViewController? {
        guard let house = housesByID[pin.id], house.isApartmentBuilding else { return nil }
        return UIHostingController(
            rootView: ApartmentStatusPreview(address: house.address, units: house.units, scope: scope)
        )
    }

    // MARK: - Routing

    @ViewBuilder
    private func sheet(for route: MapRoute) -> some View {
        switch route {
        case .houseDetail(let id):
            if let house = housesByID[id] {
                HouseDetailSheet(house: house, scope: scope, writeDay: writeDay(for: house))
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }

        case .addHouse(let coordinate, let gebietID):
            AddHouseSheet(
                coordinate: coordinate,
                gebietID: gebietID,
                existingHouses: houses,
                writeDay: gebiet.map { $0.writeScope().writeTargetDay } ?? 1
            ) { house in
                dropHouseID = house.id
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .search:
            MapSearchSheet(region: camera.region) { coordinate in
                cameraCommand = .region(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008),
                    animated: !reduceMotion
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .importArea:
            if let gebiet {
                AreaHouseImportSheet(
                    boundary: gebiet.boundaryCoordinates,
                    gebietID: gebiet.id,
                    existingHouses: houses
                ) {
                    scheduleAutoNaming(force: true)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }

        case .exportSelection:
            if let gebiet {
                ExportSheet(gebiet: gebiet, houses: selectedHouses, scope: scope, isPreselected: true)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }

        case .clusterMembers(let ids):
            // Members sitting on the same coordinate can never be separated by
            // zooming, so the tap opens a list instead of doing nothing forever.
            StackedPinsSheet(
                houses: ids.compactMap { housesByID[$0] },
                scope: scope
            ) { id in
                self.sheetRoute = .houseDetail(id)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func alert(for confirmation: MapConfirmation) -> Alert {
        switch confirmation {
        case .deleteHouse(let id, let address):
            return Alert(
                title: Text("Haus löschen?"),
                message: Text("„\(address)“ und alle Tür-Status werden aus diesem Gebiet gelöscht."),
                primaryButton: .destructive(Text("Löschen")) {
                    guard let house = housesByID[id] else { return }
                    modelContext.delete(house)
                    if modelContext.save(reporting: notices, context: "Haus konnte nicht gelöscht werden") {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                },
                secondaryButton: .cancel(Text("Abbrechen"))
            )

        case .deleteSelection(let count):
            return Alert(
                title: Text("Auswahl löschen?"),
                message: Text("\(count) Häuser und alle dazugehörigen Tür-Status werden entfernt."),
                primaryButton: .destructive(Text("\(count) löschen")) { deleteSelectedHouses() },
                secondaryButton: .cancel(Text("Abbrechen"))
            )

        case .boundaryOptions:
            return Alert(
                title: Text("Gebietsmarkierung"),
                message: Text("Du kannst die vorhandene Grenze weiterbearbeiten oder die Markierung löschen."),
                primaryButton: .default(Text("Bearbeiten")) { beginDrawingArea() },
                secondaryButton: .destructive(Text("Löschen")) { deleteBoundary() }
            )
        }
    }
}

// MARK: - Supporting types

enum MapMode: Equatable {
    case browsing
    case placingHouse
    case drawingArea
}

enum MapRoute: Identifiable {
    case houseDetail(UUID)
    case addHouse(coordinate: CLLocationCoordinate2D, gebietID: UUID)
    case search
    case importArea
    case exportSelection
    case clusterMembers([UUID])

    var id: String {
        switch self {
        case .houseDetail(let id): "house-\(id)"
        case .addHouse(let coordinate, _): "add-\(coordinate.latitude)-\(coordinate.longitude)"
        case .search: "search"
        case .importArea: "import"
        case .exportSelection: "export"
        case .clusterMembers(let ids): "cluster-\(ids.count)-\(ids.first?.uuidString ?? "")"
        }
    }
}

enum MapConfirmation: Identifiable {
    case deleteHouse(id: UUID, address: String)
    case deleteSelection(Int)
    case boundaryOptions

    var id: String {
        switch self {
        case .deleteHouse(let id, _): "deleteHouse-\(id)"
        case .deleteSelection(let count): "deleteSelection-\(count)"
        case .boundaryOptions: "boundary"
        }
    }
}
