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

    @State private var structuralVersion = 0
    @State private var contentVersion = 0
    @State private var changedHouseIDs: Set<UUID> = []
    /// The newest `updatedAt` the pins were built from, so the next refresh can ask
    /// for just the houses touched since instead of the whole territory.
    @State private var pinsWatermark: Date?
    @State private var appliedRefreshKey: RefreshKey?
    @State private var hasLoadedPins = false
    /// Bumped by a real SwiftData commit. This is the signal `pipelineKey` used to
    /// hunt for by reading the query's count and newest timestamp inside `body`.
    @State private var dataVersion = 0

    // Interaction
    @State private var mode: MapMode = .browsing
    @State private var draftBoundary: [CLLocationCoordinate2D] = []
    /// Index of the draft vertex being re-aimed. Points used to be
    /// append-only, so fixing point 2 of 10 meant undoing 8 points;
    /// now any single vertex moves to the reticle on demand.
    @State private var selectedDraftIndex: Int? = nil
    /// Street encounters of the territory. Dozens, never thousands, so plain
    /// live models on the main actor — no watermark pipeline like houses.
    @State private var passanten: [Passant] = []
    @State private var selectedHouseIDs: Set<UUID>?
    @State private var cameraCommand: MapCameraCommand?
    @State private var dropHouseID: UUID?
    @State private var isFollowingUser = false
    @State private var isAwayFromTerritory = false
    /// Measured heights of the floating chrome, so the map's legal attribution can be
    /// kept clear of it at any text size. See `chromeInsets`.
    @State private var topChromeHeight: CGFloat = 132
    @State private var bottomChromeHeight: CGFloat = 96

    // Presentation — one route, one sheet. Six independent `isPresented` flags on a
    // single view is how the importer→confirmation race got in.
    @State private var sheetRoute: MapRoute?
    @State private var confirmation: MapConfirmation?
    @State private var showsAccuracyAlert = false
    @State private var isLocating = false
    @State private var pendingSave = PendingSave()
    @State private var namingTask: Task<Void, Never>?
    /// One namespace for every floating glass control, so they can morph into one
    /// another instead of cross-fading.
    @Namespace private var glass

    init(gebiet: Gebiet?, scope: Binding<DayScope>, isActive: Bool) {
        self.gebiet = gebiet
        _scope = scope
        self.isActive = isActive
        _camera = State(initialValue: MapCameraStore(territoryID: gebiet?.id))
    }

    private var poiPreset: POIPreset {
        POIPreset(rawValue: poiPresetRaw) ?? .orientation
    }

    private var boundary: [CLLocationCoordinate2D] {
        mode == .drawingArea ? draftBoundary : (gebiet?.boundaryCoordinates ?? [])
    }

    private var isSelecting: Bool { selectedHouseIDs != nil }

    var body: some View {
        // The chrome must anchor to the **safe area** while `MapHost` bleeds to the
        // screen edges: a bottom-aligned control that anchors to the screen sits
        // under the tab bar, which was invisible on iOS 26 (a floating pill the map
        // is meant to show through) and covered Liste and Archiv on iOS 18, where
        // the bar is an opaque strip.
        //
        // This used to be spelled `Color.clear.overlay { mapStack }` plus two more
        // overlays, and that spelling is what froze the app on iOS 18. An `.overlay`
        // is sized from its base, so a base that respects the safe area with a child
        // that ignores it leaves SwiftUI reconciling two different safe-area regions
        // for one box; each `.safeAreaPadding` on the chrome added another. The
        // resulting `InsetViewLayout` negotiation probes each child several times per
        // level, so the cost multiplies with depth — and after a tab transition, when
        // the proposals shift, one pass stops converging at all. The main thread then
        // never returns from that single layout pass, which is the freeze: no crash,
        // no runaway body, just a screen that stops.
        //
        // A `ZStack` is the idiom that expresses the same thing without the
        // negotiation. It sizes to the proposal — the safe area — so the chrome
        // stacked inside it lands exactly where the overlays used to, while
        // `MapHost`'s own `ignoresSafeArea` still lets the tiles bleed past it. One
        // region, one pass.
        ZStack {
            mapStack

            VStack(spacing: 0) {
                topChrome
                Spacer(minLength: 0)
                bottomChrome
            }
        }
    }

    private var mapStack: some View {
        ZStack {
            MapHost(
                startupRegion: camera.startupRegion,
                pins: prepared,
                structuralVersion: structuralVersion,
                contentVersion: contentVersion,
                changedHouseIDs: changedHouseIDs,
                boundary: boundary,
                draftPoints: mode == .drawingArea ? draftBoundary : [],
                selectedDraftIndex: mode == .drawingArea ? selectedDraftIndex : nil,
                passantPins: passanten.map {
                    PassantPin(id: $0.id, coordinate: $0.coordinate, outcome: $0.outcome, note: $0.note)
                },
                selectedHouseIDs: selectedHouseIDs,
                isActive: isActive,
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
                onTapHouse: openHouse,
                onStackedPins: { ids in
                    sheetRoute = .stackedPins(ids)
                },
                onTapDraftPoint: toggleDraftPoint,
                onTapPassant: { id in sheetRoute = .passantDetail(id) },
                onTapBoundary: mode == .drawingArea
                    ? { index, coordinate in insertBoundaryPoint(at: coordinate, index: index) }
                    : nil,
                onDropConsumed: { id in
                    if dropHouseID == id { dropHouseID = nil }
                },
                menuProvider: contextMenu(for:),
                previewProvider: contextPreview(for:)
            )
            .ignoresSafeArea()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                location.refreshHeadingOrientation()
            }

            if mode != .browsing {
                PlacementReticle(
                    kind: mode == .placingHouse ? .house
                        : mode == .placingPassant ? .passant : .boundaryPoint
                )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .sheet(item: $sheetRoute, content: sheet(for:))
        .alert(item: $confirmation, content: alert(for:))
        .alert(
            "Ungenauer Standort",
            isPresented: $showsAccuracyAlert,
            actions: {
                Button("Einstellungen öffnen") { location.openLocationSettings() }
                Button("Später", role: .cancel) { location.accuracyExplainerHandled() }
            },
            message: {
                Text("„Ungefährer Standort“ reicht für diese App nicht: Entfernungen lägen um Kilometer daneben. Bitte erlaube den genauen Standort in den Einstellungen.")
            }
        )
        .onChange(of: location.needsAccuracyExplainer) { _, needs in
            if needs { showsAccuracyAlert = true }
        }
        .task(id: isActive) {
            if isActive {
                location.beginUsing()
                // Precision follows the visible map (T4), resolved together with
                // the camera lock inside the service — never set from here.
                location.setMapVisible(true)
                if location.needsAccuracyExplainer { showsAccuracyAlert = true }
            } else {
                location.setMapVisible(false)
                location.endUsing()
                camera.flush()
                // A queued command must not replay against a later coordinator.
                cameraCommand = nil
            }
        }
        .task(id: RefreshTaskKey(refresh: refreshKey, isActive: isActive)) {
            guard isActive, appliedRefreshKey != refreshKey else { return }
            // A tab the user is only passing through must not start a 5,000-row read.
            // Flicking across the bar cancels this dwell before any work begins, which
            // is what stops rapid switching from queueing overlapping fetches.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, isActive else { return }
            await refreshPins()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            dataVersion &+= 1
        }
        .onChange(of: location.location) { _, newLocation in
            performInitialLocateIfNeeded(newLocation)
        }
        .onChange(of: gebiet?.id) { _, _ in
            resetForNewTerritory()
        }
        .onChange(of: scenePhase) { _, phase in
            // Pocketing the phone mid-street is a teardown like any other: the
            // debounce must not outlive the foreground.
            if phase != .active { flushPendingSave() }
        }
        .onDisappear {
            camera.flush()
            // Cancelling alone lost every status set within the debounce window of
            // leaving the tab. The list has flushed here all along; the map did not.
            flushPendingSave()
            namingTask?.cancel()
        }
    }

    // MARK: - Chrome

    /// Everything that decides **which** panels the top chrome shows.
    ///
    /// One key, one `.animation`. The previous shape stacked two `.animation(_:value:)`
    /// modifiers on this container, and `.animation(_:value:)` does not merely animate
    /// when its value changes — it sets the animation for its whole subtree, applying
    /// `nil` when the value is unchanged. Two of them therefore both fired when one
    /// action changed both values, and any change *not* named by either was stripped
    /// of the ambient `withAnimation` transaction coming from the call site.
    private struct TopChromeLayout: Equatable {
        let isSelecting: Bool
        let showsGuide: Bool
    }

    private var topChromeLayout: TopChromeLayout {
        TopChromeLayout(isSelecting: isSelecting, showsGuide: showsGuide)
    }

    /// The same for the bottom chrome — and this is where the bug actually bit:
    /// the old key did not name `isAwayFromTerritory`, so the territory button was
    /// silently stripped of animation despite both the call site and the view being
    /// written as if it animated.
    private struct BottomChromeLayout: Equatable {
        let mode: MapMode
        let isSelecting: Bool
        let showsTerritoryButton: Bool
    }

    private var bottomChromeLayout: BottomChromeLayout {
        BottomChromeLayout(
            mode: mode,
            isSelecting: isSelecting,
            showsTerritoryButton: showsTerritoryButton
        )
    }

    private var showsGuide: Bool {
        // Deliberately the loaded snapshot, not a query. Reading a bulk `@Query` here
        // put a full territory materialisation inside chrome evaluation.
        hasLoadedPins && !hasSeenGuide && prepared.pinsByID.isEmpty
            && mode == .browsing && gebiet != nil
    }

    private var showsTerritoryButton: Bool {
        mode == .browsing && !isSelecting && isAwayFromTerritory
    }

    /// Insets handed to MapKit so its legal attribution, scale and compass are never
    /// covered. The HIG requires 7 pt at the sides and 10 pt above/below the Apple
    /// logo and legal link — obscuring them is an App Review rejection.
    ///
    /// Bottom was `max(bottomChromeHeight+6)` → logo far above chrome (124pt
    /// high), then `10` → logo under the `…`/`Haus hinzufügen` pills. Chrome has
    /// 16pt horizontal padding, so logo at x=7 sits beside the glass. Keep it
    /// just above the pills/tab-bar with a tight gap, not floating high nor
    /// hidden.
    private var chromeInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: max(topChromeHeight + 6, 24),
            left: 7,
            bottom: 70,
            right: 7
        )
    }

    /// Co-located glass lives in ONE container: Apple warns that many separate
    /// effect containers degrade performance, and only siblings inside a shared
    /// container can merge as they move.
    @ViewBuilder
    private var topChrome: some View {
        CompatGlassContainer(spacing: AppSpacing.snug) {
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

                if showsGuide {
                    MapGuideCard(
                        namespace: glass,
                        onAddHouse: { setMode(.placingHouse) },
                        onDismiss: { hasSeenGuide = true }
                    )
                    // Standalone: `map.guide` has no partner to morph into, so the
                    // container's `.matchedGeometry` default does not apply here.
                    .standaloneGlassTransition(reduceMotion: reduceMotion)
                }
            }
        }
        .padding(.horizontal, AppSpacing.regular)
        .padding(.top, AppSpacing.tight)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            topChromeHeight = height
        }
        // The summary bar and the selection bar share a glass id, so switching modes
        // reshapes one panel rather than dissolving two unrelated ones.
        .compatGlassTransition(.matchedGeometry, reduceMotion: reduceMotion)
        .animation(.smooth(duration: 0.32, extraBounce: 0).speed(reduceMotion ? 1.8 : 1), value: topChromeLayout)
    }

    @ViewBuilder
    private var bottomChrome: some View {
        CompatGlassContainer(spacing: AppSpacing.snug) {
            VStack(alignment: .trailing, spacing: AppSpacing.snug) {
                if showsTerritoryButton {
                    TerritoryButton(namespace: glass, action: showTerritory)
                        .standaloneGlassTransition(reduceMotion: reduceMotion)
                }

                if mode == .browsing, !isSelecting {
                    LocateButton(
                        isFollowing: isFollowingUser,
                        isBusy: isLocating,
                        isDenied: location.isDenied,
                        namespace: glass,
                        action: toggleFollow
                    )
                    .standaloneGlassTransition(reduceMotion: reduceMotion)
                }

                switch mode {
                case .drawingArea:
                    BoundaryDrawingBar(
                        pointCount: draftBoundary.count,
                        selectedPointNumber: selectedDraftIndex.map { $0 + 1 },
                        namespace: glass,
                        onCancel: cancelDrawing,
                        onUndo: undoBoundaryPoint,
                        onAddPoint: addBoundaryPoint,
                        onMoveSelected: moveSelectedDraftPoint,
                        onSave: saveBoundary
                    )
                case .placingHouse, .placingPassant, .browsing:
                    if !isSelecting {
                        MapActionBar(
                            placement: mode == .placingHouse ? .house
                                : mode == .placingPassant ? .passant : nil,
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
        .padding(.bottom, AppSpacing.snug)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            bottomChromeHeight = height
        }
        .compatGlassTransition(.matchedGeometry, reduceMotion: reduceMotion)
        .animation(.smooth(duration: 0.32, extraBounce: 0).speed(reduceMotion ? 1.8 : 1), value: bottomChromeLayout)
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
                setMode(.placingPassant)
            } label: {
                Label(
                    MapPlacement.passant.idleTitle,
                    systemImage: MapPlacement.passant.idleSystemImage
                )
            }
            .disabled(gebiet == nil)
        }

        Section {
            // A `Picker` inside a `Menu` becomes a submenu that shows its current
            // value on the parent row — two rows instead of five, and you can see
            // what is selected without opening anything.
            Picker("Kartenstil", selection: $isSatellite) {
                Label("Standard", systemImage: "map").tag(false)
                Label("Satellit", systemImage: "globe.europe.africa.fill").tag(true)
            }
            .sensoryFeedback(.selection, trigger: isSatellite)

            Picker("Orte", selection: $poiPresetRaw) {
                ForEach(POIPreset.allCases) { preset in
                    Label(preset.title, systemImage: preset.systemImage).tag(preset.rawValue)
                }
            }
            .sensoryFeedback(.selection, trigger: poiPresetRaw)
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
            isAwayFromTerritory = away
        }
    }

    /// Flies to a picked search result. Nearby streets glide; far places cut:
    /// a fast swoosh across the city blasts tiles past the render server while
    /// every glass surface swings through the passing landscape — which reads
    /// as flicker, not motion.
    private func flyToSearchResult(_ coordinate: CLLocationCoordinate2D) {
        cameraCommand = .region(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008),
            animated: !Self.isFarFlight(from: camera.region.center, to: coordinate)
                && !reduceMotion
        )
    }

    /// Whether a search flight crosses enough map to swoosh. Pure so the rule
    /// carries a unit test instead of only eyeballing.
    nonisolated static func isFarFlight(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Bool {
        let latitudeScale = 111_320.0
        let longitudeScale = 111_320.0 * cos(from.latitude * .pi / 180)
        let dLat = (to.latitude - from.latitude) * latitudeScale
        let dLon = (to.longitude - from.longitude) * longitudeScale
        return (dLat * dLat + dLon * dLon).squareRoot() > 2_000
    }

    // MARK: - Pin pipeline

    /// What the pins are built from, expressed so that deciding whether to rebuild
    /// costs nothing.
    ///
    /// The key it replaces ended in `houses.count` and `houses.first?.updatedAt`.
    /// Both are reads of a bulk `@Query`, and the key was computed inside `body` —
    /// so every redraw of this screen, including one caused merely by the tab
    /// selection changing, materialised the whole territory on the main thread
    /// before the new tab could draw. `dataVersion` is the same signal delivered by
    /// `ModelContext.didSave` instead of hunted for.
    private struct RefreshKey: Hashable {
        let territoryID: UUID?
        let scope: DayScope
        let version: Int
    }

    /// `.task(id:)` restarts on any change to its id, so the id has to carry
    /// `isActive` too — otherwise leaving and re-entering the tab cannot re-arm a
    /// refresh that was skipped while the screen was in the background.
    private struct RefreshTaskKey: Hashable {
        let refresh: RefreshKey
        let isActive: Bool
    }

    private var refreshKey: RefreshKey {
        RefreshKey(territoryID: gebiet?.id, scope: scope, version: dataVersion)
    }

    private func refreshPins() async {
        let requested = refreshKey
        let currentScope = scope

        guard let territoryID = gebiet?.id else {
            prepared = .empty
            pinsWatermark = nil
            hasLoadedPins = true
            appliedRefreshKey = requested
            return
        }

        // Street encounters travel with every refresh, full or incremental:
        // dozens of small rows, fetched plainly on the main actor.
        passanten = fetchPassanten()

        let reader = HouseReadService(modelContainer: modelContext.container)

        // Content-only change (a status was tapped): patch just the houses touched
        // since the last build instead of decoding every blob in the territory.
        // Without this a single door tap on a 5,000-house territory costs a full
        // refetch and rebuild, which is the most common action in the field.
        if let since = pinsWatermark,
           let previous = appliedRefreshKey,
           previous.territoryID == requested.territoryID,
           previous.scope == requested.scope {
            let changed: [RawMapHouse]
            do {
                changed = try await reader.mapSeeds(territoryID: territoryID, updatedAfter: since)
            } catch is CancellationError {
                return
            } catch {
                notices.report(error, context: "Karte konnte nicht gelesen werden")
                return
            }
            guard !Task.isCancelled else { return }
            if !changed.isEmpty {
                let base = prepared
                let patched = await offMainActor { MapPinSnapshotBuilder.patch(base, with: changed, scope: currentScope) }
                guard !Task.isCancelled else { return }
                prepared = patched
                changedHouseIDs = Set(changed.map(\.id))
                contentVersion &+= 1
                pinsWatermark = changed.compactMap(\.updatedAt).max() ?? since
                appliedRefreshKey = requested
                return
            }
            // Nothing actually changed. Advance the key so an identical request does
            // not queue another read, but leave the snapshot alone.
            appliedRefreshKey = requested
            return
        }

        let raw: [RawMapHouse]
        do {
            raw = try await reader.mapSeeds(territoryID: territoryID, updatedAfter: nil)
        } catch is CancellationError {
            return
        } catch {
            notices.report(error, context: "Karte konnte nicht gelesen werden")
            return
        }
        guard !Task.isCancelled else { return }
        let snapshot = await offMainActor { MapPinSnapshotBuilder.build(from: raw, scope: currentScope) }
        guard !Task.isCancelled else { return }

        prepared = snapshot
        changedHouseIDs = []
        structuralVersion &+= 1
        contentVersion &+= 1
        pinsWatermark = raw.compactMap(\.updatedAt).max()
        hasLoadedPins = true
        appliedRefreshKey = requested

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
        isAwayFromTerritory = false
        mode = .browsing
        draftBoundary = []
        selectedDraftIndex = nil
        passanten = []
        selectedHouseIDs = nil
        sheetRoute = nil
        confirmation = nil
        prepared = .empty
        pinsWatermark = nil
        hasLoadedPins = false
        appliedRefreshKey = nil
        structuralVersion &+= 1
        let restored = camera.selectTerritory(gebiet?.id)
        cameraCommand = .region(restored, animated: false)
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
            cameraCommand = .region(target, animated: !reduceMotion)
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
                animated: !reduceMotion
            )
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    // MARK: - Modes

    private func setMode(_ newMode: MapMode) {
        mode = newMode
    }

    private func primaryAction() {
        switch mode {
        case .placingHouse:
            guard let gebiet else { return }
            // The reticle's point is at the map centre by construction, so what the
            // user aimed at is what gets stored.
            sheetRoute = .addHouse(coordinate: camera.region.center, gebietID: gebiet.id)
            setMode(.browsing)
        case .placingPassant:
            guard let gebiet else { return }
            sheetRoute = .addPassant(coordinate: camera.region.center, gebietID: gebiet.id)
            setMode(.browsing)
        case .browsing:
            setMode(.placingHouse)
        case .drawingArea:
            break
        }
    }

    private func beginDrawingArea() {
        draftBoundary = gebiet?.boundaryCoordinates ?? []
        selectedDraftIndex = nil
        setMode(.drawingArea)
    }

    private func cancelDrawing() {
        mode = .browsing
        draftBoundary = []
        selectedDraftIndex = nil
    }

    private func addBoundaryPoint() {
        draftBoundary.append(camera.region.center)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Tapping a draft vertex selects it for re-aiming; tapping it again
    /// deselects. Numbers are 1-based on the map, indices 0-based here —
    /// guarded because the tap races nothing, but stale numbers must not
    /// index out of bounds.
    private func toggleDraftPoint(number: Int) {
        let index = number - 1
        guard draftBoundary.indices.contains(index) else { return }
        selectedDraftIndex = (selectedDraftIndex == index) ? nil : index
    }

    private func undoBoundaryPoint() {
        guard !draftBoundary.isEmpty else { return }
        let removed = draftBoundary.count - 1
        draftBoundary.removeLast()
        if selectedDraftIndex == removed { selectedDraftIndex = nil }
    }

    /// Moves the selected vertex to the reticle and releases the selection —
    /// a correction is a one-shot, not a mode, so appending continues directly.
    private func moveSelectedDraftPoint() {
        guard let index = selectedDraftIndex,
              draftBoundary.indices.contains(index) else { return }
        draftBoundary[index] = camera.region.center
        selectedDraftIndex = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Inserts a vertex where the boundary line was tapped: between the two
    /// neighbours, never just at the end. Any edit selection ends — inserting
    /// while one is active would stack two intentions on one gesture.
    private func insertBoundaryPoint(at coordinate: CLLocationCoordinate2D, index: Int) {
        guard mode == .drawingArea else { return }
        var points = draftBoundary
        points.insert(coordinate, at: min(max(index, 0), points.count))
        draftBoundary = points
        selectedDraftIndex = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func saveBoundary() {
        guard let gebiet, draftBoundary.count >= 3 else { return }
        gebiet.boundaryCoordinates = draftBoundary
        guard modelContext.save(reporting: notices, context: "Gebiet konnte nicht gespeichert werden")
        else { return }
        setMode(.browsing)
        selectedDraftIndex = nil
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
        selectedHouseIDs = []
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func exitSelection() {
        selectedHouseIDs = nil
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
        guard let selectedHouseIDs, !selectedHouseIDs.isEmpty else { return [] }
        // Only the selection, by id. The old shape fetched the whole territory
        // and filtered in memory — inside the sheet builder, so opening
        // "Auswahl exportieren" decoded every door blob before the first frame.
        let ids = Array(selectedHouseIDs)
        let descriptor = FetchDescriptor<House>(predicate: #Predicate { ids.contains($0.id) })
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            notices.report(error, context: "Häuser konnten nicht gelesen werden")
            return []
        }
    }

    /// Street encounters of one territory. Dozens, so a plain main-thread fetch —
    /// no background pipeline like houses.
    private func fetchPassanten() -> [Passant] {
        guard let territoryID = gebiet?.id else { return [] }
        let descriptor = FetchDescriptor<Passant>(predicate: #Predicate { $0.gebietID == territoryID })
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            notices.report(error, context: "Passanten konnten nicht gelesen werden")
            return []
        }
    }
    /// One row, by id. Interaction paths need a real model to write through; they do
    /// not need the territory resident to find it.
    private func fetchHouse(_ id: UUID) -> House? {
        var descriptor = FetchDescriptor<House>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            notices.report(error, context: "Haus konnte nicht gelesen werden")
            return nil
        }
    }

    private func deleteSelectedHouses() {
        let doomed = selectedHouses
        guard !doomed.isEmpty else { return }
        for house in doomed { modelContext.delete(house) }
        guard modelContext.save(reporting: notices, context: "Auswahl konnte nicht gelöscht werden")
        else { return }
        dropPins(Set(doomed.map(\.id)))
        Task {
            for house in doomed { await ReminderService.cancelAllRevisits(house: house.id) }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        exitSelection()
    }

    // MARK: - House interaction

    private func openHouse(_ id: UUID) {
        if isSelecting {
            toggleSelection(id)
            return
        }
        sheetRoute = .houseDetail(id)
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
        guard let house = fetchHouse(id), let door = house.units.first else { return }
        let day = writeDay(for: house)
        let current = door.result(on: day)
        house.setOutcome(current == outcome ? nil : outcome, for: door.id, day: day)
        // Answering a door settles it, so any reminder it still carries is stale.
        let houseID = house.id
        let doorID = door.id
        Task { await ReminderService.cancelRevisit(house: houseID, door: doorID, day: day) }
        scheduleSave()
    }

    /// Books a return time for a single-door pin, from the long-press menu.
    private func setRevisitTime(_ date: Date, for id: UUID) {
        guard let house = fetchHouse(id), let door = house.units.first else { return }
        let day = writeDay(for: house)
        house.setOutcome(.later, for: door.id, day: day, revisitAt: date)
        let houseID = house.id
        let doorID = door.id
        let address = house.address
        let label = door.label
        Task {
            await ReminderService.scheduleRevisit(
                house: houseID, door: doorID, day: day,
                address: address, doorLabel: label,
                isApartmentBuilding: false, at: date
            )
        }
        scheduleSave()
        notices.show("Später um \(RevisitPlanner.clockFormatter.string(from: date))")
    }

    private func markOpenDoors(for id: UUID) {
        guard let house = fetchHouse(id) else { return }
        guard house.setOutcomeForOpenDoors(.notHome, day: writeDay(for: house)) > 0 else { return }
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave.schedule(in: modelContext, reporting: notices) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func flushPendingSave() {
        pendingSave.flush(in: modelContext, reporting: notices)
    }

    private func scheduleAutoNaming(force: Bool = false) {
        guard let gebiet, force || GebietNameAllocator.isGenericName(gebiet.name) else { return }
        // One cancellable task: the old code fired an unstructured Task per
        // house-count change, queueing overlapping reverse-geocodes into Apple's
        // rate limiter.
        namingTask?.cancel()
        let coordinates = prepared.pinsByID.values.map(\.coordinate)
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
        let details = UIMenu(options: .displayInline, children: [
            UIAction(title: "Details öffnen", image: UIImage(systemName: "info.circle")) { _ in
                openHouse(id)
            }
        ])

        let status: UIMenu
        if pin.unitCount == 1 {
            var actions = VisitOutcome.primary.map { outcome in
                UIAction(title: "\(outcome.emoji)  \(outcome.title)") { _ in
                    setQuickOutcome(outcome, for: id)
                }
            }
            // The ellipsis is the promise that a time is still to be chosen — this
            // action opens the picker rather than writing a status straight away.
            let later = VisitOutcome.later
            actions.append(UIAction(title: "\(later.emoji)  \(later.title)…") { _ in
                sheetRoute = .revisitTime(houseID: id, address: pin.address)
            })
            status = UIMenu(options: .displayInline, children: actions)
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
                confirmation = .deleteHouse(id: id, address: pin.address)
            }
        ])

        return UIMenu(title: pin.address, children: [details, status, destructive])
    }

    private func contextPreview(for pin: MapPinSnapshot) -> UIViewController? {
        guard let house = fetchHouse(pin.id), house.isApartmentBuilding else { return nil }
        return UIHostingController(
            rootView: ApartmentStatusPreview(address: house.address, units: house.units, scope: scope)
        )
    }

    // MARK: - Routing

    @ViewBuilder
    private func sheet(for route: MapRoute) -> some View {
        switch route {
        case .houseDetail(let id):
            if let house = fetchHouse(id) {
                HouseDetailSheet(house: house, scope: scope, writeDay: writeDay(for: house)) { deletedID in
                    dropPins([deletedID])
                }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }

        case .revisitTime(let id, let address):
            RevisitTimeSheet(
                subject: address,
                existing: fetchHouse(id)?.summary(for: scope).nextRevisitAt
            ) { date in
                setRevisitTime(date, for: id)
            }

        case .addHouse(let coordinate, let gebietID):
            AddHouseSheet(
                coordinate: coordinate,
                gebietID: gebietID,
                writeDay: gebiet.map { $0.writeScope().writeTargetDay } ?? 1
            ) { house in
                insertCreatedHouse(house)
            } onOpenExisting: { house in
                sheetRoute = .houseDetail(house.id)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .addPassant(let coordinate, let gebietID):
            PassantSheet(coordinate: coordinate, gebietID: gebietID) { passant in
                insertCreatedPassant(passant)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .passantDetail(let id):
            if let passant = passanten.first(where: { $0.id == id }) {
                PassantDetailSheet(passant: passant) { deletedID in
                    dropPassanten([deletedID])
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }

        case .search:
            MapSearchSheet(region: camera.region) { coordinate in
                flyToSearchResult(coordinate)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .importArea:
            if let gebiet {
                AreaHouseImportSheet(
                    boundary: gebiet.boundaryCoordinates,
                    gebietID: gebiet.id
                ) {
                    scheduleAutoNaming(force: true)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }

        case .exportSelection:
            if let gebiet {
                ExportSheet(gebiet: gebiet, houses: selectedHouses, passanten: [], scope: scope, isPreselected: true)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }

        case .stackedPins(let ids):
            // Pins drawn on top of each other cannot be aimed at separately, so the
            // tap opens a list instead of guessing which one was meant.
            StackedPinsSheet(
                houses: ids.compactMap(fetchHouse),
                scope: scope
            ) { id in
                self.sheetRoute = .houseDetail(id)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    /// Makes a committed house visible in the same presentation turn that closes
    /// the add sheet. Waiting for the save notification plus the refresh dwell made
    /// freshly placed houses appear missing, and the drop animation was consumed
    /// before an annotation existed to animate.
    private func insertCreatedHouse(_ house: House) {
        let raw = RawMapHouse(house)
        prepared = MapPinSnapshotBuilder.patch(prepared, with: [raw], scope: scope)
        changedHouseIDs = [house.id]
        structuralVersion &+= 1
        contentVersion &+= 1
        hasLoadedPins = true
        if let updatedAt = raw.updatedAt {
            pinsWatermark = max(pinsWatermark ?? .distantPast, updatedAt)
        }
        dropHouseID = house.id
        updateTerritoryProximity(camera.region)
        scheduleAutoNaming()
    }

    /// Makes a recorded encounter visible in the same presentation turn that
    /// closes the add sheet — same immediacy as `insertCreatedHouse`, without
    /// a pin pipeline: encounters sync as a whole set on the next pass anyway.
    private func insertCreatedPassant(_ passant: Passant) {
        passanten.append(passant)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Removes deleted houses in the same presentation turn that commits the
    /// delete. The watermark refresh only ever sees *updated* rows, so without
    /// this the pin lingered until the next full rebuild. Mirror of
    /// `insertCreatedHouse`.
    private func dropPins(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        prepared = MapPinSnapshotBuilder.removing(prepared, ids: ids)
        changedHouseIDs.subtract(ids)
        if var selection = selectedHouseIDs {
            selection.subtract(ids)
            selectedHouseIDs = selection
        }
        structuralVersion &+= 1
        contentVersion &+= 1
    }

    /// Removes deleted street encounters immediately. They live outside the
    /// watermark pipeline, so this is just the array — the coordinator syncs
    /// the small set on the next pass and the disc is gone.
    private func dropPassanten(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        passanten.removeAll { ids.contains($0.id) }
    }

    private func alert(for confirmation: MapConfirmation) -> Alert {
        switch confirmation {
        case .deleteHouse(let id, let address):
            return Alert(
                title: Text("Haus löschen?"),
                message: Text("„\(address)“ und alle Tür-Status werden aus diesem Gebiet gelöscht."),
                primaryButton: .destructive(Text("Löschen")) {
                    guard let house = fetchHouse(id) else { return }
                    modelContext.delete(house)
                    if modelContext.save(reporting: notices, context: "Haus konnte nicht gelöscht werden") {
                        dropPins([id])
                        Task { await ReminderService.cancelAllRevisits(house: id) }
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
    case placingPassant
    case drawingArea
}

enum MapRoute: Identifiable {
    case houseDetail(UUID)
    case addHouse(coordinate: CLLocationCoordinate2D, gebietID: UUID)
    case addPassant(coordinate: CLLocationCoordinate2D, gebietID: UUID)
    case passantDetail(UUID)
    case search
    case importArea
    case exportSelection
    case stackedPins([UUID])
    /// Booking a return time for a single-door pin, from its long-press menu.
    case revisitTime(houseID: UUID, address: String)

    var id: String {
        switch self {
        case .houseDetail(let id): "house-\(id)"
        case .addHouse(let coordinate, _): "add-\(coordinate.latitude)-\(coordinate.longitude)"
        case .addPassant(let coordinate, _): "add-passant-\(coordinate.latitude)-\(coordinate.longitude)"
        case .passantDetail(let id): "passant-\(id)"
        case .search: "search"
        case .importArea: "import"
        case .exportSelection: "export"
        case .stackedPins(let ids): "stacked-\(ids.count)-\(ids.first?.uuidString ?? "")"
        case .revisitTime(let id, _): "revisit-\(id)"
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
