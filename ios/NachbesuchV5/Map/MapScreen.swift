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
    /// Measured heights of the floating chrome, so the map's legal attribution can be
    /// kept clear of it at any text size. See `chromeInsets`.
    @State private var topChromeHeight: CGFloat = 132
    @State private var bottomChromeHeight: CGFloat = 96

    // Presentation — one route, one sheet. Six independent `isPresented` flags on a
    // single view is how the importer→confirmation race got in.
    @State private var sheetRoute: MapRoute?
    @State private var confirmation: MapConfirmation?
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

    var body: some View {
        // The chrome anchors to `Color.clear`, which respects the safe area, rather
        // than to the map stack, which does not. `MapHost` bleeds to the screen
        // edges, and a bottom overlay on the stack it lives in therefore aligns to
        // the *screen* bottom — under the tab bar. That was invisible on iOS 26,
        // where the tab bar is a floating pill the map is meant to show through, and
        // covered the Liste and Archiv items on iOS 18, where it is an opaque strip.
        // Anchoring to the safe area puts "bottom" at the top of the tab bar on both.
        Color.clear
            .overlay {
                mapStack
            }
            .overlay(alignment: .top) { topChrome }
            .overlay(alignment: .bottom) { bottomChrome }
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
                onTapHouse: openHouse,
                onStackedPins: { ids in
                    sheetRoute = .stackedPins(ids)
                },
                onDropConsumed: { id in
                    if dropHouseID == id { dropHouseID = nil }
                },
                menuProvider: contextMenu(for:),
                previewProvider: contextPreview(for:)
            )
            .ignoresSafeArea()

            if mode != .browsing {
                PlacementReticle(kind: mode == .placingHouse ? .house : .boundaryPoint)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .sheet(item: $sheetRoute, content: sheet(for:))
        .alert(item: $confirmation, content: alert(for:))
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
        !hasSeenGuide && houses.isEmpty && mode == .browsing && gebiet != nil
    }

    private var showsTerritoryButton: Bool {
        mode == .browsing && !isSelecting && isAwayFromTerritory
    }

    /// Insets handed to MapKit so its legal attribution, scale and compass are never
    /// covered. The HIG requires 7 pt at the sides and 10 pt above/below the Apple
    /// logo and legal link — obscuring them is an App Review rejection.
    ///
    /// **Measured, not assumed.** These were hardcoded at 132/108, which is only
    /// correct at the default text size. In normal browsing, the location button
    /// sits on the right and must not push the left-aligned Apple attribution up by
    /// its full height. MapKit adds the tab bar's safe-area clearance on top of the
    /// margin, so a 96 pt lane places the attribution directly above the full-width
    /// action bar. At accessibility sizes the summary card is several times taller
    /// and the action bar wraps, so MapKit went on positioning the attribution as
    /// though the chrome were 132 pt tall and the "Rechtl. Informationen" link ended
    /// up underneath the floating buttons — the exact rejection this comment warns
    /// about. The fallbacks are the old constants, used only for the frames before
    /// the chrome has been measured.
    private var chromeInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: max(topChromeHeight, 132),
            left: 7,
            bottom: max(bottomChromeHeight, 96),
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
        .safeAreaPadding(.top, AppSpacing.tight)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            topChromeHeight = height
        }
        // The summary bar and the selection bar share a glass id, so switching modes
        // reshapes one panel rather than dissolving two unrelated ones.
        .compatGlassTransition(.matchedGeometry, reduceMotion: reduceMotion)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: topChromeLayout)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            bottomChromeHeight = height
        }
        .compatGlassTransition(.matchedGeometry, reduceMotion: reduceMotion)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: bottomChromeLayout)
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
            isAwayFromTerritory = away
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
        mode = .browsing
        draftBoundary = []
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
        // Answering a door settles it, so any reminder it still carries is stale.
        let houseID = house.id
        let doorID = door.id
        Task { await ReminderService.cancelRevisit(house: houseID, door: doorID, day: day) }
        scheduleSave()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Books a return time for a single-door pin, from the long-press menu.
    private func setRevisitTime(_ date: Date, for id: UUID) {
        guard let house = housesByID[id], let door = house.units.first else { return }
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func markOpenDoors(for id: UUID) {
        guard let house = housesByID[id] else { return }
        guard house.setOutcomeForOpenDoors(.notHome, day: writeDay(for: house)) > 0 else { return }
        scheduleSave()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func scheduleSave() {
        pendingSave.schedule(in: modelContext, reporting: notices)
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

        case .revisitTime(let id, let address):
            RevisitTimeSheet(
                subject: address,
                existing: housesByID[id]?.summary(for: scope).nextRevisitAt
            ) { date in
                setRevisitTime(date, for: id)
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

        case .stackedPins(let ids):
            // Pins drawn on top of each other cannot be aimed at separately, so the
            // tap opens a list instead of guessing which one was meant.
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
    case stackedPins([UUID])
    /// Booking a return time for a single-door pin, from its long-press menu.
    case revisitTime(houseID: UUID, address: String)

    var id: String {
        switch self {
        case .houseDetail(let id): "house-\(id)"
        case .addHouse(let coordinate, _): "add-\(coordinate.latitude)-\(coordinate.longitude)"
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
