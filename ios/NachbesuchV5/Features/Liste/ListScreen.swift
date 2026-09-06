import CoreLocation
import SwiftData
import SwiftUI
import UIKit

/// The working list: every address in the territory, open work first, grouped by
/// street.
struct ListScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppNoticeCenter.self) private var notices
    @Environment(LocationService.self) private var location

    let gebiet: Gebiet?
    @Binding var scope: DayScope
    let isActive: Bool

    /// The corpus, built once per data change rather than per keystroke.
    ///
    /// This is the single biggest change in this screen. `body` used to rebuild every
    /// row model — including a Unicode folding pass over each house's address, note
    /// and every door label — on every body evaluation. `searchText` is `@State`, so
    /// that ran on every character typed, every filter tap and every scroll-triggered
    /// invalidation.
    @State private var rows: [HouseRowModel] = []
    @State private var sections: [StreetSection] = []
    @State private var counts: [ListFilter: Int] = [:]
    @State private var collapsedSections: Set<String> = []
    /// The territory the collapse state was defaulted for. Data saves rebuild
    /// the corpus constantly and must never clobber manual toggles — only a
    /// territory switch re-seeds the defaults.
    @State private var collapseDefaultsTerritory: UUID?

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var filter: ListFilter = .all
    /// Drives the relative half of the revisit chips ("in 25 Min"). A single tick
    /// for the whole screen: `HouseRow` compares the *rendered* glance, so a tick
    /// that changes no wording re-renders nothing.
    @State private var clock = Date.now
    /// The address whose sheet is open, held **by id**.
    ///
    /// A live `House` in `@State` looks convenient and costs a great deal: `@Model`
    /// is observable, so the open row's every property change re-evaluates this
    /// screen's whole body, and the object stays registered in the view's context
    /// for as long as the state does — including after the sheet closes. The id is
    /// resolved to a model once, when the sheet is built.
    @State private var selectedHouse: HouseSelection?
    @State private var showsLegend = false
    @State private var showsExport = false
    /// The territory's houses, alive only while the export sheet is.
    ///
    /// `ExportSheet` needs real models. Holding them in `@State` past the sheet would
    /// pin the whole territory in memory for the rest of the session — the exact leak
    /// this screen's queries were taken out to stop — so `showsExport` clears it.
    @State private var exportHouses: [House] = []
    /// Street encounters for the same export. Cleared with the houses above.
    @State private var exportPassanten: [Passant] = []
    /// The row waiting for a return time, once "Später" was swiped.
    @State private var revisitTarget: HouseRowModel?
    @State private var undo: UndoEntry?
    @State private var undoTask: Task<Void, Never>?
    @State private var pendingSave = PendingSave()
    /// Bumped whenever SwiftData commits, so the corpus can be rebuilt on a real
    /// change without `body` paying to look for one.
    ///
    /// The key this replaces ended in `houses.max(by: { $0.updatedAt < $1.updatedAt })`.
    /// That is an O(n) scan that faults `updatedAt` on **every** house in the
    /// territory, and because it was computed inside `body` — as the `id` of a
    /// `.task` — it ran again on every single body evaluation. Tapping a row sets
    /// `selectedHouse`, which re-evaluates `body`, which paid for a full scan of
    /// 1000+ models before the sheet could even begin presenting. That is the tap
    /// that lands seconds late, and the inconsistency is faulting: the scan is cheap
    /// once the objects are in memory and expensive when they are not.
    @State private var dataVersion = 0
    @State private var builtCorpusKey: CorpusKey?
    @State private var rowCache = HouseListCache()
    @State private var presentationVersion = 0

    private struct PresentationTaskKey: Hashable {
        let version: Int
        let isActive: Bool
    }

    @Namespace private var zoom

    /// Nearest-first ordering, using the live position.
    ///
    /// This is what you actually want standing on a street: not "which house did I
    /// add first", but "what is still open within thirty metres of me".
    @AppStorage("list.sortByDistance") private var sortByDistance = false
    /// Only updated once the user has genuinely moved, so a jittering GPS fix does
    /// not reshuffle the list under their thumb.
    @State private var sortOrigin: CLLocationCoordinate2D?

    init(gebiet: Gebiet?, scope: Binding<DayScope>, isActive: Bool) {
        self.gebiet = gebiet
        _scope = scope
        self.isActive = isActive
    }

    private struct UndoEntry: Identifiable {
        let id = UUID()
        let houseID: UUID
        let previousUnits: [DoorResult]
        let label: String
    }

    private struct UndoInsetModifier: ViewModifier {
        let undo: UndoEntry?
        let reduceMotion: Bool
        let onUndo: (UndoEntry) -> Void

        @ViewBuilder
        func body(content: Content) -> some View {
            // An empty safeAreaInset is not inert on iOS 18: after repeated TabView
            // transitions it can keep renegotiating layout forever. No undo means no
            // inset in the hierarchy at all.
            if let undo {
                content.compatSafeAreaBar(edge: .bottom, spacing: 0) {
                    UndoBanner(label: undo.label) { onUndo(undo) }
                        .padding(.horizontal, AppSpacing.regular)
                        .padding(.bottom, AppSpacing.tight)
                        .transition(.appBanner(edge: .bottom, reduceMotion: reduceMotion))
                }
            } else {
                content
            }
        }
    }

    private struct CorpusKey: Hashable {
        let territoryID: UUID?
        let scope: DayScope
        let version: Int
    }

    /// Cheap by construction: identifiers and an explicit save counter only. The
    /// former `houses.count` looked harmless but forced iOS 18 SwiftData to
    /// materialise the entire query during every tab-selection body update.
    private var corpusKey: CorpusKey {
        CorpusKey(
            territoryID: gebiet?.id,
            scope: scope,
            version: dataVersion
        )
    }

    private struct CorpusTaskKey: Hashable {
        let corpus: CorpusKey
        let isActive: Bool
    }

    private var writeDay: Int {
        switch scope {
        case .day1: 1
        case .day2: 2
        case .combined: gebiet?.writeScope().writeTargetDay ?? 1
        }
    }

    var body: some View {
        NavigationStack {
            listSurface
            .scrollDismissesKeyboard(.interactively)
            .compatSoftScrollEdges()
            .background { AppBackdrop() }
            .searchable(text: $searchText, prompt: "Adresse, Notiz oder Tür")
            .compatMinimizedSearch()
            .compatSafeAreaBar(edge: .top, spacing: 0) {
                FilterBar(
                    chips: filterChips,
                    contextLabel: "Liste",
                    onSelect: { id in
                        guard let value = ListFilter(rawValue: id) else { return }
                        applyFilter(value)
                    },
                    onHelp: { showsLegend = true }
                )
                .padding(.vertical, 6)
            }
            .modifier(
                UndoInsetModifier(
                    undo: undo,
                    reduceMotion: reduceMotion,
                    onUndo: performUndo
                )
            )
            .sensoryFeedback(.selection, trigger: collapsedSections)
            .navigationTitle("Nachbesuche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if gebiet?.isTwoDay == true {
                    ToolbarItem(placement: .principal) {
                        DayScopePicker(scope: $scope)
                            .frame(maxWidth: 240)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Reihenfolge", selection: $sortByDistance) {
                            Label("Offene zuerst", systemImage: "arrow.up.arrow.down").tag(false)
                            Label("Nächste zuerst", systemImage: "location").tag(true)
                        }
                        Divider()
                        Button {
                            setAllStreets(expanded: true)
                        } label: {
                            Label("Alle Straßen öffnen", systemImage: "chevron.down.2")
                        }
                        .disabled(collapsedSections.isEmpty)

                        Button {
                            setAllStreets(expanded: false)
                        } label: {
                            Label("Alle Straßen schließen", systemImage: "chevron.up.2")
                        }
                        .disabled(
                            sections.isEmpty
                                || sections.allSatisfy { collapsedSections.contains($0.id) }
                        )
                    } label: {
                        Image(systemName: sortByDistance ? "location" : "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Reihenfolge")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        prepareExport()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(gebiet == nil)
                    .accessibilityLabel("Gebiet exportieren")
                }
            }
            .sheet(item: $selectedHouse) { selection in
                if let house = fetchHouse(selection.id) {
                    HouseDetailSheet(house: house, scope: scope, writeDay: writeDay)
                        // The row grows into the sheet, and dragging it back down
                        // collapses it into the same row.
                        .navigationTransition(.zoom(sourceID: selection.id, in: zoom))
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $showsExport, onDismiss: { exportHouses = []; exportPassanten = [] }) {
                if let gebiet {
                    ExportSheet(gebiet: gebiet, houses: exportHouses, passanten: exportPassanten, scope: scope)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $showsLegend) {
                StatusLegendSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $revisitTarget) { row in
                RevisitTimeSheet(
                    subject: row.address,
                    existing: row.nextRevisitAt
                ) { date in
                    applyQuickStatus(.later, to: row, revisitAt: date)
                }
            }
        }
        .task {
            #if DEBUG
            // Lets the test harness open the export sheet without a tap.
            if ProcessInfo.processInfo.environment["NACHBESUCH_SHEET"] == "export" {
                prepareExport()
            }
            #endif
        }
        #if DEBUG
        // Collapsing a street needs a tap, and a screenshot harness has no thumb —
        // so the one layout that only exists while a street is closed (a section
        // whose header is also its last row, and therefore rounded on all four
        // corners) could not be reviewed at all. Same opt-in convention as
        // `NACHBESUCH_SEED` and `NACHBESUCH_SHEET`.
        //
        //     SIMCTL_CHILD_NACHBESUCH_COLLAPSED=all xcrun simctl launch booted at.volkshilfe.nachbesuch.v5
        .onChange(of: sections.isEmpty) { _, isEmpty in
            guard !isEmpty,
                  ProcessInfo.processInfo.environment["NACHBESUCH_COLLAPSED"] == "all"
            else { return }
            setAllStreets(expanded: false)
        }
        #endif
        .task(id: CorpusTaskKey(corpus: corpusKey, isActive: isActive)) {
            guard isActive, builtCorpusKey != corpusKey else { return }
            // First display and scope switches should not wait behind a save debounce.
            if builtCorpusKey?.territoryID == corpusKey.territoryID,
               builtCorpusKey?.scope == corpusKey.scope {
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard !Task.isCancelled, isActive else { return }
            await rebuildCorpus()
        }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedQuery = searchText
        }
        .onChange(of: debouncedQuery) { _, _ in recomputeSections() }
        .onChange(of: sortByDistance) { _, _ in recomputeSections() }
        .task(id: PresentationTaskKey(version: presentationVersion, isActive: isActive)) {
            guard isActive else { return }
            await rebuildSections()
        }
        // The signal the scan was standing in for, delivered instead of hunted for.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            dataVersion &+= 1
        }
        .onChange(of: location.location) { _, fix in
            updateSortOrigin(fix?.coordinate)
        }
        .onChange(of: location.isReducedAccuracy) { _, reduced in
            // "Ungefährer Standort" is kilometres off: kilometre-grade
            // distances would sort doors into a meaningless order, so the
            // ranking and its per-row figures go away until the grant returns.
            guard reduced else { return }
            sortOrigin = nil
            recomputeSections()
        }
        // The GPS only runs while this ordering is actually on screen and in use.
        .task(id: isActive) {
            // Half a minute, not a full one: the chip rounds to the nearest minute,
            // so a 60 s tick could leave "in 1 Min" standing for two.
            while isActive, !Task.isCancelled {
                clock = .now
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task(id: sortByDistance && isActive) {
            guard sortByDistance, isActive else { return }
            location.beginUsing()
            sortOrigin = location.isReducedAccuracy ? nil : location.location?.coordinate
            recomputeSections()
            defer { location.endUsing() }
            // Held open for as long as the task lives, which is exactly as long as
            // the ordering stays selected and the tab visible.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Pocketing the phone mid-street is a teardown like any other: the
            // debounce must not outlive the foreground.
            if phase != .active { flushPendingSave() }
        }
        .onDisappear {
            undoTask?.cancel()
            flushPendingSave()
        }
    }

    /// Native row reuse keeps even a territory-wide nearest/time ranking lazy.
    /// Each house is a List row; an expanded street no longer builds all of its
    /// buttons before the first visible address can be drawn.
    private var listSurface: some View {
        List {
            if sections.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ForEach(sections) { section in
                    Section {
                        Button { toggleSection(section.id) } label: {
                            StreetHeader(section: section, isExpanded: !collapsedSections.contains(section.id))
                                .padding(.vertical, 4)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Straße \(section.title)")
                        .accessibilityValue("\(section.houseCount) Adressen, \(section.openCount) Türen offen")
                        .accessibilityHint(collapsedSections.contains(section.id)
                            ? "Blendet die Adressen ein" : "Blendet die Adressen aus")

                        if !collapsedSections.contains(section.id) {
                            ForEach(section.rows) { row in
                                Button { openHouse(row.id) } label: {
                                    HouseRow(row: row, now: clock)
                                        .equatable()
                                        .frame(minHeight: AppTouch.minimum)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .matchedTransitionSource(id: row.id, in: zoom)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 11, leading: AppLayout.rowInset,
                                              bottom: 11, trailing: AppLayout.rowInset))
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(AppSpacing.regular)
        .scrollContentBackground(.hidden)
    }

    // MARK: Corpus

    private func rebuildCorpus() async {
        let key = corpusKey
        guard let territoryID = gebiet?.id else {
            rows = []
            sections = []
            counts = [:]
            collapseDefaultsTerritory = nil
            rowCache = HouseListCache()
            recomputeSections()
            builtCorpusKey = key
            return
        }
        let reader = HouseReadService(modelContainer: modelContext.container)
        let seeds: [HouseListBuilder.Seed]
        do {
            seeds = try await reader.listSeeds(territoryID: territoryID)
        } catch is CancellationError {
            return
        } catch {
            notices.report(error, context: "Liste konnte nicht gelesen werden")
            return
        }
        guard !Task.isCancelled else { return }
        let currentScope = scope
        let previousCache = rowCache
        let needsCollapseDefaults = collapseDefaultsTerritory != territoryID
        let buildTask = Task.detached(priority: .userInitiated) {
            var cache = previousCache
            let built = try cache.update(seeds, scope: currentScope)
            let counts = HouseListBuilder.counts(for: built)
            let collapsed = needsCollapseDefaults
                ? HouseListBuilder.initiallyCollapsedSectionIDs(rows: built) : nil
            return (cache, built, counts, collapsed)
        }
        do {
            let (cache, built, newCounts, collapsed) = try await withTaskCancellationHandler {
                try await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }
            guard !Task.isCancelled, key == corpusKey else { return }
            rowCache = cache
            rows = built
            counts = newCounts
            if let collapsed {
                collapsedSections = collapsed
                collapseDefaultsTerritory = territoryID
            }
            recomputeSections()
        } catch is CancellationError {
            return
        } catch {
            notices.report(error, context: "Liste konnte nicht aufgebaut werden")
            return
        }
        builtCorpusKey = key
    }

    private func fetchHouse(_ id: UUID) -> House? {
        var descriptor = FetchDescriptor<House>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            notices.report(error, context: "Haus konnte nicht geöffnet werden")
            return nil
        }
    }

    private func openHouse(_ id: UUID) {
        selectedHouse = HouseSelection(id: id)
    }

    private func prepareExport() {
        guard let territoryID = gebiet?.id else { return }
        let descriptor = FetchDescriptor<House>(predicate: #Predicate {
            $0.gebietID == territoryID || $0.dayID == territoryID
        })
        do {
            exportHouses = try modelContext.fetch(descriptor)
            exportPassanten = try modelContext.fetch(
                FetchDescriptor<Passant>(predicate: #Predicate { $0.gebietID == territoryID })
            )
            showsExport = true
        } catch {
            notices.report(error, context: "Export konnte nicht vorbereitet werden")
        }
    }

    private func recomputeSections() {
        presentationVersion &+= 1
    }

    private func rebuildSections() async {
        let version = presentationVersion
        let currentRows = rows
        let currentFilter = filter
        let query = debouncedQuery
        let origin = sortByDistance ? sortOrigin : nil
        let built = await offMainActor {
            HouseListBuilder.presentedSections(rows: currentRows, filter: currentFilter,
                                               query: query, origin: origin)
        }
        guard !Task.isCancelled, version == presentationVersion else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { sections = built }
    }

    /// Adopts a new origin only after a real move — 25 m is far enough that the
    /// order can meaningfully change, and short enough to feel live on foot.
    /// Never from a reduced-accuracy fix: it would re-sort the street by noise.
    private func updateSortOrigin(_ coordinate: CLLocationCoordinate2D?) {
        guard isActive, sortByDistance, let coordinate, !location.isReducedAccuracy else { return }
        if let sortOrigin {
            let latitudeScale = 110_540.0
            let longitudeScale = 111_320.0 * cos(coordinate.latitude * .pi / 180)
            let dLat = (coordinate.latitude - sortOrigin.latitude) * latitudeScale
            let dLon = (coordinate.longitude - sortOrigin.longitude) * longitudeScale
            guard (dLat * dLat + dLon * dLon).squareRoot() > 25 else { return }
        }
        sortOrigin = coordinate
        recomputeSections()
    }

    private func toggleSection(_ id: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            if collapsedSections.contains(id) { collapsedSections.remove(id) }
            else { collapsedSections.insert(id) }
        }
    }

    private func applyFilter(_ value: ListFilter) {
        guard filter != value else { return }
        filter = value
        recomputeSections()
    }

    private func setAllStreets(expanded: Bool) {
        if expanded {
            collapsedSections.removeAll()
        } else {
            collapsedSections.formUnion(sections.map(\.id))
        }
    }

    private var filterChips: [FilterChip] {
        ListFilter.allCases.map { value in
            FilterChip(
                id: value.rawValue,
                title: value.title,
                systemImage: value.systemImage,
                tint: tint(for: value),
                count: counts[value],
                isSelected: filter == value
            )
        }
    }

    private func tint(for filter: ListFilter) -> Color {
        switch filter {
        case .all: accent
        case .open: .red
        case .later: .indigo
        case .unanswered: .orange
        case .joined: .pink
        }
    }

    // MARK: Status changes

    private func applyQuickStatus(_ outcome: VisitOutcome, to row: HouseRowModel, revisitAt: Date? = nil) {
        guard let house = fetchHouse(row.id),
              let previous = house.decodedUnits() else { return }

        // The doors the write is about to touch, captured before it happens: after
        // the write they are no longer "open" and cannot be found again.
        let affected: [DoorResult]
        if house.isApartmentBuilding {
            affected = previous.filter { $0.isOpen(in: writeDay == 2 ? .day2 : .day1) }
            guard house.setOutcomeForOpenDoors(outcome, day: writeDay, revisitAt: revisitAt) > 0 else { return }
        } else {
            guard let door = previous.first else { return }
            affected = [door]
            house.setOutcome(outcome, for: door.id, day: writeDay, revisitAt: revisitAt)
        }

        syncReminders(for: house, doors: affected, outcome: outcome, at: revisitAt)

        offerUndo(
            UndoEntry(
                houseID: row.id,
                previousUnits: previous,
                // Concrete, so the user knows exactly what they are undoing after the
                // list has re-sorted and the row has moved.
                label: "\(row.address) → \(outcome.label(revisitAt: revisitAt))"
            )
        )
        scheduleSave()
    }

    /// Books or drops the reminders belonging to a quick status write.
    private func syncReminders(
        for house: House,
        doors: [DoorResult],
        outcome: VisitOutcome,
        at date: Date?
    ) {
        let houseID = house.id
        let address = house.address
        let isApartment = house.isApartmentBuilding
        let day = writeDay
        let entries = doors.map { (id: $0.id, label: $0.label) }
        Task {
            for entry in entries {
                if outcome == .later, let date {
                    await ReminderService.scheduleRevisit(
                        house: houseID, door: entry.id, day: day,
                        address: address, doorLabel: entry.label,
                        isApartmentBuilding: isApartment, at: date
                    )
                } else {
                    await ReminderService.cancelRevisit(house: houseID, door: entry.id, day: day)
                }
            }
        }
    }

    private func offerUndo(_ entry: UndoEntry) {
        undoTask?.cancel()
        undo = entry
        undoTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            undo = nil
        }
    }

    private func performUndo(_ entry: UndoEntry) {
        undoTask?.cancel()
        undo = nil
        guard let house = fetchHouse(entry.houseID) else { return }
        house.restore(units: entry.previousUnits)
        // Undoing a "Später" must take the reminder with it, and re-book any time
        // the undone write had overwritten. Rebuilding the house's whole set is
        // simpler and safer than reasoning about which direction the undo went.
        rebuildReminders(for: house)
        scheduleSave()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Re-derives every reminder of one house from its stored doors.
    private func rebuildReminders(for house: House) {
        let houseID = house.id
        let address = house.address
        let isApartment = house.isApartmentBuilding
        let day = writeDay
        let doors = house.units
        Task {
            await ReminderService.cancelAllRevisits(house: houseID)
            for door in doors {
                guard door.result(on: day) == .later, let date = door.revisitTime(on: day) else { continue }
                await ReminderService.scheduleRevisit(
                    house: houseID, door: door.id, day: day,
                    address: address, doorLabel: door.label,
                    isApartmentBuilding: isApartment, at: date
                )
            }
        }
    }

    private func scheduleSave() {
        pendingSave.schedule(in: modelContext, reporting: notices) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func flushPendingSave() {
        pendingSave.flush(in: modelContext, reporting: notices)
    }

    @ViewBuilder
    private var emptyState: some View {
        // Driven by the debounced query, so the message and the list can never
        // disagree about what was searched for.
        if !debouncedQuery.isEmpty {
            ContentUnavailableView.search(text: debouncedQuery)
        } else {
            ContentUnavailableView {
                Label(filter.emptyTitle, systemImage: filter.systemImage)
            } description: {
                Text(filter.emptyMessage)
            }
        }
    }
}

// MARK: - Row

private struct HouseRow: View, Equatable {
    let row: HouseRowModel
    /// Only ever read through `glance`. Compared by its *effect*, never directly —
    /// see `==`.
    let now: Date

    private var glance: RevisitGlance? {
        RevisitGlance.make(at: row.nextRevisitAt, laterDoors: row.laterCount, now: now)
    }

    /// Two rows are the same row when they would draw the same thing. Comparing
    /// `now` itself would invalidate every row on the screen twice a minute, which
    /// is precisely what the value-typed row model exists to avoid; comparing the
    /// glance means only a row whose chip actually changed its wording redraws.
    static func == (lhs: HouseRow, rhs: HouseRow) -> Bool {
        lhs.row == rhs.row && lhs.glance == rhs.glance
    }

    var body: some View {
        HStack(spacing: AppLayout.glyphGap) {
            // A bare symbol in the shared column, not a symbol on a tinted disc. The
            // disc was a third circle competing with two rounded rectangles for the
            // same 40 pt, and on an untouched territory it drew 232 identical ones.
            // The glyph is already shape-coded and colour-coded; the ring around it
            // added neither.
            OutcomeGlyph(outcome: row.markerOutcome, size: .body)
                .frame(width: AppLayout.glyphColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    // Not larger than the street name above it. The house number is
                    // the scannable part, but it is *inside* a street, and setting it
                    // at 20 pt under a 15 pt header inverted the hierarchy.
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let glance {
                    revisitChip(glance)
                }
                if !row.note.isEmpty {
                    Label(row.note, systemImage: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let distance = row.formattedDistance {
                Text(distance)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // Multi-door houses only. On a single-door house "1 offen" is the third
            // copy of one fact — the glyph beside it is already the red "come back"
            // mark, and for one door there is nothing the count can add that the mark
            // does not already say. It made every row of a fresh territory carry an
            // identical red badge, which is a decoration, not a signal.
            if !row.isSingleDoor, row.openCount > 0 {
                Text("\(row.openCount)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StatusChipFill(.red), in: Capsule())
            }

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        // The row draws the number; VoiceOver still gets the whole address, because
        // "6" on its own is not an address to someone who cannot see the street
        // header above it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.address)
        .accessibilityValue(
            [
                row.accessibilityValue,
                glance?.voiceOver,
                row.formattedDistance.map { "\($0) entfernt" }
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
        .accessibilityHint("Öffnet die Details")
    }

    /// The return time, close to the address it belongs to rather than out in the
    /// trailing column with the distance and the open count — those answer "where"
    /// and "how much", this one answers "when", and it is the only one of the three
    /// that can be late.
    private func revisitChip(_ glance: RevisitGlance) -> some View {
        HStack(spacing: 4) {
            Image(systemName: glance.systemImage)
            Text(glance.label)
                .monospacedDigit()
            if glance.extraDoors > 0 {
                Text("+\(glance.extraDoors)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint(for: glance.urgency))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(StatusChipFill(tint(for: glance.urgency)), in: Capsule())
        .padding(.top, 2)
    }

    private func tint(for urgency: RevisitGlance.Urgency) -> Color {
        switch urgency {
        case .overdue: .red
        case .imminent: .orange
        case .upcoming: .indigo
        }
    }
}

// MARK: - Street header

private struct StreetHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let section: StreetSection
    let isExpanded: Bool

    /// A street is finished only when every door is recorded *and* nothing is left
    /// open. The old card could show a green-worthy "9/9" next to a red bar, because
    private var isDone: Bool { section.isDone }

    /// The street's mark used to be a tinted squircle holding `road.lanes`, tinted
    /// with the app accent to mean "identity, not state". That reasoning only holds
    /// while the accent is not the state colour — and the accent *is* red, the same
    /// red as "offen", the filter chip and the open glyph, so identity and state were
    /// indistinguishable and the screen had one colour. The street name is the
    /// identity; it does not need a badge to say it is a street.
    ///
    /// **State.** Red while there is something to come back to, green when there is
    /// not — the same red the "Offen" filter chip and the per-row open badge use, so
    /// "offen" is one colour throughout the screen rather than three.
    private var stateTint: Color { isDone ? .green : .red }

    private var barWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 44 : 56 }

    var body: some View {
        // Both candidates used to be `HStack`s. When neither fits, `ViewThatFits`
        // takes the last one and lets it overflow — at accessibility sizes the
        // progress column was clipped off the right edge mid-digit. The stacked
        // variant is a layout that always fits, so there is a real last resort.
        ViewThatFits(in: .horizontal) {
            headerLayout(compact: true)
            headerLayout(compact: false)
            stackedLayout
        }
        .contentShape(.rect)
    }

    // MARK: Pieces

    private var title: some View {
        Text(section.title)
            // `Color.primary`, not `.primary`. A `Section` header inherits the
            // list's secondary header style, and bare `.primary` is
            // `HierarchicalShapeStyle.primary` — the *first level of the inherited
            // style*, which here is still the grey header colour. `Color.primary`
            // is the absolute label colour and actually wins, so the street name
            // stops rendering dimmer than the addresses beneath it.
            // Outranks the house numbers under it, which are `.body.weight(.semibold)`.
            .font(.headline)
            .foregroundStyle(Color.primary)
            .lineLimit(1)
    }

    /// How many addresses. What is *there* — the state belongs to the counter.
    private var subtitle: some View {
        Text("\(section.houseCount) \(section.houseCount == 1 ? "Adresse" : "Adressen")")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// **One** number, and it agrees with the bar beside it.
    ///
    /// This slot used to read "68/80" — doors *recorded* — above a bar drawn from
    /// the same fraction, while the subtitle said "40 offen". Both were true and
    /// together they were a riddle: a street can be 85 % recorded and half unfinished,
    /// because "Niemand da" and "Später" are recorded outcomes that mean come back.
    /// Now the number and the bar both count doors with nothing left to do on them,
    /// and the label says which of the two things it means.
    @ViewBuilder
    private var counter: some View {
        Group {
            if isDone {
                Label("fertig", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.doneTone)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .symbolEffect(
                        .bounce,
                        options: reduceMotion ? .nonRepeating : .default,
                        value: isDone
                    )
                    .symbolEffectsRemoved(reduceMotion)
                    .transition(.blockSwap(reduceMotion: reduceMotion))
            } else {
                Text("\(section.openCount) offen")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(stateTint)
                    .contentTransition(.numericText(value: Double(section.openCount)))
                    .lineLimit(1)
                    .transition(.blockSwap(reduceMotion: reduceMotion))
            }
        }
        // The one place on this screen `appCelebrate` is warranted. `Motion.swift`
        // reserves it for "genuine moments of completion, never routine interaction",
        // and the last open door on a street is exactly that — it happens once per
        // street per campaign, and it is the thing the user is walking around to
        // achieve. Every other count change on this screen is `appFeedback`.
        .animation(.appCelebrate(reduceMotion: reduceMotion), value: isDone)
    }

    /// A hand-drawn capsule rather than `ProgressView`: the system bar draws its
    /// track at a hairline the tinted fill dwarfs, so a nearly-empty street looked
    /// identical to one with no doors at all. Here the track is always visible and
    /// the fill keeps a rounded stub as soon as there is any progress at all.
    private func progressBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(.quaternary)
            if section.progress > 0 {
                Capsule(style: .continuous)
                    .fill(stateTint)
                    .frame(width: max(5, width * min(section.progress, 1)))
            }
        }
        .frame(width: width, height: 5)
        .animation(.appSettle(reduceMotion: reduceMotion), value: section.progress)
        .animation(.appSettle(reduceMotion: reduceMotion), value: isDone)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
            .animation(reduceMotion ? nil : .appFeedback(reduceMotion: false), value: isExpanded)
            .frame(width: 12)
            .accessibilityHidden(true)
    }

    // MARK: Layouts

    private func headerLayout(compact: Bool) -> some View {
        HStack(spacing: AppSpacing.snug) {
            VStack(alignment: .leading, spacing: 2) {
                title.lineLimit(compact ? 1 : 2)
                subtitle
            }

            Spacer(minLength: AppSpacing.snug)

            // Count over bar, right-aligned: the two read as one measurement
            // instead of two competing trailing elements.
            VStack(alignment: .trailing, spacing: 5) {
                counter
                progressBar(width: barWidth)
            }

            chevron
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: AppSpacing.snug) {
                VStack(alignment: .leading, spacing: 2) {
                    title
                    subtitle
                }
                Spacer(minLength: AppSpacing.snug)
                chevron
            }
            HStack(spacing: AppSpacing.snug) {
                counter
                GeometryReader { proxy in
                    progressBar(width: proxy.size.width)
                        .frame(height: proxy.size.height, alignment: .center)
                }
                .frame(height: 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quiet coloured field gives the transparent cards something useful to refract
/// in both appearances without fighting the status colours inside them.
// MARK: - Undo banner

private struct UndoBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    let label: String
    let action: () -> Void

    var body: some View {
        // Two sibling glass shapes in one container. Nesting the button inside a
        // glass panel prevents Liquid Glass from sampling the content correctly.
        CompatGlassContainer(spacing: AppSpacing.tight) {
            HStack(spacing: AppSpacing.tight) {
                HStack(spacing: AppSpacing.snug) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.doneTone)
                        .symbolEffect(
                            .bounce,
                            options: reduceMotion ? .nonRepeating : .default,
                            value: reduceMotion ? "" : label
                        )
                    Text(label)
                        .font(.footnote)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .navigationGlass(cornerRadius: AppRadius.card)

                Button("Rückgängig", action: action)
                    .font(.footnote.weight(.semibold))
                    .compatGlassButton(prominent: true)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(accent)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Legend

struct StatusLegendSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    ForEach(VisitOutcome.allCases) { outcome in
                        HStack(spacing: AppSpacing.snug) {
                            Text(outcome.emoji).font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(outcome.title).font(.body.weight(.medium))
                                Text(outcome.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(outcome.title)
                        .accessibilityValue(outcome.explanation)
                    }
                }
                Section("Gesten") {
                    Label("Tippen öffnet die Details", systemImage: "hand.tap")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Hilfe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}

/// The address whose sheet is open.
///
/// This used to be a bare `UUID?` plus `extension UUID: @retroactive Identifiable`
/// at the bottom of this file — a conformance on a Foundation type, declared module
/// wide, so that one `sheet(item:)` could bind to it. Wrapping instead keeps the
/// conformance where it is used, and matches the route types the other screens
/// already present with.
private struct HouseSelection: Identifiable {
    let id: UUID
}
