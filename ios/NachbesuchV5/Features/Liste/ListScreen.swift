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

    @Query private var houses: [House]

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

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var filter: ListFilter = .all
    /// Drives the relative half of the revisit chips ("in 25 Min"). A single tick
    /// for the whole screen: `HouseRow` compares the *rendered* glance, so a tick
    /// that changes no wording re-renders nothing.
    @State private var clock = Date.now
    @State private var selectedHouse: HouseSelection?
    @State private var showsLegend = false
    @State private var showsExport = false
    /// The row waiting for a return time, once "Später" was swiped.
    @State private var revisitTarget: HouseRowModel?
    @State private var undo: UndoEntry?
    @State private var undoTask: Task<Void, Never>?
    @State private var pendingSave = PendingSave()
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
        let territoryID = gebiet?.id
        _houses = Query(
            filter: #Predicate<House> {
                territoryID != nil && ($0.gebietID == territoryID || $0.dayID == territoryID)
            },
            sort: \House.createdAt,
            order: .reverse
        )
    }

    private struct UndoEntry: Identifiable {
        let id = UUID()
        let houseID: UUID
        let previousUnits: [DoorResult]
        let label: String
    }

    private struct CorpusKey: Hashable {
        let territoryID: UUID?
        let scope: DayScope
        let count: Int
        let newestUpdate: Date?
    }

    private var corpusKey: CorpusKey {
        CorpusKey(
            territoryID: gebiet?.id,
            scope: scope,
            count: houses.count,
            newestUpdate: houses.max(by: { $0.updatedAt < $1.updatedAt })?.updatedAt
        )
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
            // Container spacing must stay **below** the gap between the shapes it
            // holds. At 10 pt against an 8 pt row gap every row fused into one long
            // white slab — the list stopped looking like cards at all.
            GlassEffectContainer(spacing: 2) {
                List {
                    if sections.isEmpty {
                        emptyState
                            .padding(AppSpacing.regular)
                            .navigationGlass(cornerRadius: AppRadius.chrome)
                            .listRowInsets(.init(top: 20, leading: 16, bottom: 20, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        ForEach(sections) { section in
                            // A normal row instead of a native Section header: native
                            // headers hover and stack translucent street cards over
                            // the addresses while scrolling.
                            Button {
                                toggleSection(section.id)
                            } label: {
                                StreetHeader(
                                    section: section,
                                    isExpanded: !collapsedSections.contains(section.id)
                                )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                                .contentCard(cornerRadius: AppRadius.card)
                            }
                            .buttonStyle(PressableRowStyle())
                            .accessibilityLabel("Straße \(section.title)")
                            .accessibilityValue(
                                section.openCount > 0
                                    ? "\(section.houseCount) Adressen, \(section.openCount) von \(section.unitCount) Türen offen"
                                    : "\(section.houseCount) Adressen, fertig"
                            )
                            .accessibilityHint(
                                collapsedSections.contains(section.id)
                                    ? "Blendet alle Adressen dieser Straße ein"
                                    : "Blendet die Adressen dieser Straße aus"
                            )
                            .listRowInsets(.init(top: 14, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)

                            if !collapsedSections.contains(section.id) {
                                ForEach(section.rows) { row in
                                        Button { selectedHouse = HouseSelection(id: row.id) } label: {
                                            HouseRow(row: row, now: clock)
                                                .equatable()
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                // No `interactive` and no per-row
                                                // morph identity: dozens of rows each
                                                // tracking touches and negotiating a
                                                // matched-geometry transition is what
                                                // made collapsing a street stutter.
                                                // The press response comes from
                                                // `PressableRowStyle` instead.
                                                .contentCard(cornerRadius: AppRadius.row, elevated: false)
                                        }
                                    .buttonStyle(PressableRowStyle())
                                    .matchedTransitionSource(id: row.id, in: zoom)
                                    .listRowInsets(
                                        .init(top: 5, leading: 16, bottom: 5, trailing: 16)
                                    )
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            MapNavigation.openWalkingRoute(
                                                to: coordinate(of: row.id),
                                                name: row.address
                                            )
                                        } label: {
                                            Label("Route", systemImage: "figure.walk")
                                        }
                                        .tint(accent)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            applyQuickStatus(.joined, to: row)
                                        } label: {
                                            Label("Dabei", systemImage: "heart.fill")
                                        }
                                        .tint(VisitOutcome.joined.tint)

                                        Button {
                                            applyQuickStatus(.notHome, to: row)
                                        } label: {
                                            Label("Niemand da", systemImage: "arrow.clockwise")
                                        }
                                        .tint(VisitOutcome.notHome.tint)

                                        Button {
                                            revisitTarget = row
                                        } label: {
                                            Label(
                                                VisitOutcome.later.title,
                                                systemImage: VisitOutcome.later.symbolName
                                            )
                                        }
                                        .tint(VisitOutcome.later.tint)
                                    }
                                    .accessibilityAction(named: "Fußroute öffnen") {
                                        MapNavigation.openWalkingRoute(
                                            to: coordinate(of: row.id),
                                            name: row.address
                                        )
                                    }
                                    .accessibilityAction(named: "Als „Niemand da“ markieren") {
                                        applyQuickStatus(.notHome, to: row)
                                    }
                                    .accessibilityAction(named: "Auf später verschieben") {
                                        revisitTarget = row
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // `.loose` alone left the last address under the floating tab bar.
                .contentMargins(
                    .bottom,
                    AppSpacing.loose + AppChrome.tabBarClearance,
                    for: .scrollContent
                )
            }
            .background { AppBackdrop() }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $searchText, prompt: "Adresse, Notiz oder Tür")
            .searchToolbarBehavior(.minimize)
            .safeAreaBar(edge: .top, spacing: 0) {
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
            // `safeAreaInset`, not `overlay`: an overlaid banner covered the bottom
            // ~56 pt of the list, so the row the user had just changed became
            // untappable for the whole undo window.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                ZStack {
                    if let undo {
                        UndoBanner(label: undo.label) { performUndo(undo) }
                            .padding(.horizontal, AppSpacing.regular)
                            .padding(.bottom, AppSpacing.tight)
                            .transition(.appBanner(edge: .bottom, reduceMotion: reduceMotion))
                    }
                }
                .animation(.appFeedback(reduceMotion: reduceMotion), value: undo?.id)
            }
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
                        showsExport = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(gebiet == nil)
                    .accessibilityLabel("Gebiet exportieren")
                }
            }
            .sheet(item: $selectedHouse) { selection in
                if let house = houses.first(where: { $0.id == selection.id }) {
                    HouseDetailSheet(house: house, scope: scope, writeDay: writeDay)
                        // The row grows into the sheet, and dragging it back down
                        // collapses it into the same row.
                        .navigationTransition(.zoom(sourceID: selection.id, in: zoom))
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $showsExport) {
                if let gebiet {
                    ExportSheet(gebiet: gebiet, houses: houses, scope: scope)
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
                showsExport = true
            }
            #endif
        }
        .task(id: corpusKey) {
            guard isActive || rows.isEmpty else { return }
            await rebuildCorpus()
        }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedQuery = searchText
        }
        .onChange(of: debouncedQuery) { _, _ in recomputeSections() }
        .onChange(of: location.location) { _, fix in
            updateSortOrigin(fix?.coordinate)
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
            sortOrigin = location.location?.coordinate
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

    // MARK: Corpus

    private func rebuildCorpus() async {
        let seeds = houses.map {
            HouseListBuilder.Seed(
                id: $0.id,
                address: $0.address,
                note: $0.note,
                createdAt: $0.createdAt,
                unitsData: $0.unitsData,
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
        let currentScope = scope
        let built = await Task.detached(priority: .userInitiated) {
            HouseListBuilder.rows(from: seeds, scope: currentScope)
        }.value
        guard !Task.isCancelled else { return }
        rows = built
        counts = HouseListBuilder.counts(for: built)
        recomputeSections()
    }

    private func recomputeSections() {
        sections = makeSections(filter: filter)
    }

    private func makeSections(filter: ListFilter) -> [StreetSection] {
        let filtered = HouseListBuilder.filter(rows, filter: filter, query: debouncedQuery)
        if sortByDistance, let origin = sortOrigin {
            // Nearest-first is a flat ranking; grouping it back into streets would
            // throw the ordering away again.
            let ranked = HouseListBuilder.sortByDistance(filtered, from: origin)
            return [
                StreetSection(
                    id: "nearest",
                    title: "Nächste zuerst",
                    rows: ranked,
                    houseCount: ranked.count,
                    unitCount: ranked.reduce(0) { $0 + $1.unitCount },
                    completedCount: ranked.reduce(0) { $0 + $1.completedCount },
                    openCount: ranked.reduce(0) { $0 + $1.openCount }
                )
            ]
        } else if filter == .later {
            // Under this filter the question is never "which street am I on" but
            // "who is due next", so the rows arrive in one time-ordered run.
            let byTime = HouseListBuilder.sortByRevisit(filtered)
            return [
                StreetSection(
                    id: "revisit",
                    title: "Nach Uhrzeit",
                    rows: byTime,
                    houseCount: byTime.count,
                    unitCount: byTime.reduce(0) { $0 + $1.unitCount },
                    completedCount: byTime.reduce(0) { $0 + $1.completedCount },
                    openCount: byTime.reduce(0) { $0 + $1.openCount }
                )
            ]
        } else {
            return HouseListBuilder.sections(from: HouseListBuilder.sort(filtered))
        }
    }

    /// Adopts a new origin only after a real move — 25 m is far enough that the
    /// order can meaningfully change, and short enough to feel live on foot.
    private func updateSortOrigin(_ coordinate: CLLocationCoordinate2D?) {
        guard sortByDistance, let coordinate else { return }
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
        // Never animate insertion/removal of glass list rows. UIKit keeps recycled
        // row snapshots alive during that transition, which produces the stacked,
        // duplicated text seen when a street collapses. The chevron has its own
        // small local animation; the expensive list geometry changes atomically.
        if collapsedSections.contains(id) {
            collapsedSections.remove(id)
        } else {
            collapsedSections.insert(id)
        }
    }

    private func applyFilter(_ value: ListFilter) {
        guard filter != value else { return }
        let nextSections = makeSections(filter: value)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            filter = value
            sections = nextSections
        }
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

    private func coordinate(of id: UUID) -> CLLocationCoordinate2D {
        houses.first { $0.id == id }?.coordinate ?? .init()
    }

    // MARK: Status changes

    private func applyQuickStatus(_ outcome: VisitOutcome, to row: HouseRowModel, revisitAt: Date? = nil) {
        guard let house = houses.first(where: { $0.id == row.id }),
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        guard let house = houses.first(where: { $0.id == entry.houseID }) else { return }
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
        pendingSave.schedule(in: modelContext, reporting: notices)
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
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(row.markerOutcome.displayTint.opacity(0.13))
                OutcomeGlyph(outcome: row.markerOutcome, size: .title3)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.address)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            if row.openCount > 0 {
                Text("\(row.openCount)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.red.opacity(0.12), in: Capsule())
            }

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
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
        .background(tint(for: glance.urgency).opacity(0.14), in: Capsule())
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
    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let section: StreetSection
    let isExpanded: Bool

    /// A street is finished only when every door is recorded *and* nothing is left
    /// open. The old card could show a green-worthy "9/9" next to a red bar, because
    private var isDone: Bool { section.isDone }

    /// **Identity, not state.** The street icon is the row's mark — it says "this is
    /// a street", and it says it in the colour the user chose for the app. It must
    /// not also carry progress: an icon that changes colour when the last door is
    /// recorded is a second, quieter version of the answer the counter and the bar
    /// already give loudly, and it made the accent look like it meant something.
    private var identityTint: Color { accent }

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

    private var streetIcon: some View {
        // A squircle instead of a circle: it echoes the card it sits in, and the
        // soft gradient keeps the tinted field from reading as a flat blob on the
        // dark background.
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [identityTint.opacity(0.26), identityTint.opacity(0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: "road.lanes")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(identityTint)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(identityTint.opacity(0.22), lineWidth: 0.5)
            }
    }

    private var title: some View {
        Text(section.title)
            // `Color.primary`, not `.primary`. A `Section` header inherits the
            // list's secondary header style, and bare `.primary` is
            // `HierarchicalShapeStyle.primary` — the *first level of the inherited
            // style*, which here is still the grey header colour. `Color.primary`
            // is the absolute label colour and actually wins, so the street name
            // stops rendering dimmer than the addresses beneath it.
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary)
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
        if isDone {
            Label("fertig", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.doneTone)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        } else {
            Text("\(section.openCount) offen")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(stateTint)
                .contentTransition(.numericText(value: Double(section.openCount)))
                .lineLimit(1)
        }
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
            .animation(.appFeedback(reduceMotion: reduceMotion), value: isExpanded)
            .frame(width: 12)
            .accessibilityHidden(true)
    }

    // MARK: Layouts

    private func headerLayout(compact: Bool) -> some View {
        HStack(spacing: AppSpacing.snug) {
            streetIcon

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
                streetIcon
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
        GlassEffectContainer(spacing: AppSpacing.tight) {
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
                    .buttonStyle(.glassProminent)
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
                    Label("Nach rechts wischen öffnet die Fußroute", systemImage: "figure.walk")
                    Label("Nach links wischen setzt einen Schnellstatus", systemImage: "hand.draw")
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
