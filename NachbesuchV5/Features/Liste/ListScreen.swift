import CoreLocation
import SwiftData
import SwiftUI
import UIKit

/// The working list: every address in the territory, open work first, grouped by
/// street.
struct ListScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
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
    @State private var selectedHouseID: UUID?
    @State private var showsLegend = false
    @State private var showsExport = false
    @State private var undo: UndoEntry?
    @State private var undoTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
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
                            // One animation owner only. The previous conditional
                            // insertion plus parent and glass animations rendered
                            // old and new row snapshots on top of each other.
                            Section(isExpanded: expansionBinding(for: section.id)) {
                                ForEach(section.rows) { row in
                                        Button { selectedHouseID = row.id } label: {
                                            HouseRow(row: row)
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
                                        .tint(.blue)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            applyQuickStatus(.joined, to: row)
                                        } label: {
                                            Label("Dabei", systemImage: "heart.fill")
                                        }
                                        .tint(.pink)

                                        Button {
                                            applyQuickStatus(.notHome, to: row)
                                        } label: {
                                            Label("Niemand da", systemImage: "arrow.clockwise")
                                        }
                                        .tint(.red)
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
                                }
                            } header: {
                                StreetHeader(section: section)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                                .navigationGlass(
                                    cornerRadius: AppRadius.card,
                                    interactive: true
                                )
                                .accessibilityLabel("Straße \(section.title)")
                                .accessibilityValue(
                                    "\(section.houseCount) Adressen, \(section.completedCount) von \(section.unitCount) Türen erledigt"
                                )
                                .accessibilityHint(
                                    collapsedSections.contains(section.id)
                                        ? "Blendet alle Adressen dieser Straße ein"
                                        : "Blendet die Adressen dieser Straße aus"
                                )
                                .listRowInsets(
                                    .init(top: 14, leading: 16, bottom: 6, trailing: 16)
                                )
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, AppSpacing.loose, for: .scrollContent)
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
                        withAnimation(.appFeedback(reduceMotion: reduceMotion)) { filter = value }
                    },
                    onHelp: { showsLegend = true }
                )
                .padding(.vertical, 6)
            }
            // `safeAreaInset`, not `overlay`: an overlaid banner covered the bottom
            // ~56 pt of the list, so the row the user had just changed became
            // untappable for the whole undo window.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if let undo {
                    UndoBanner(label: undo.label) { performUndo(undo) }
                        .padding(.horizontal, AppSpacing.regular)
                        .padding(.bottom, AppSpacing.tight)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.appFeedback(reduceMotion: reduceMotion), value: undo?.id)
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
            .sheet(item: $selectedHouseID) { id in
                if let house = houses.first(where: { $0.id == id }) {
                    HouseDetailSheet(house: house, scope: scope, writeDay: writeDay)
                        // The row grows into the sheet, and dragging it back down
                        // collapses it into the same row.
                        .navigationTransition(.zoom(sourceID: id, in: zoom))
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
        .onChange(of: filter) { _, _ in recomputeSections() }
        .onChange(of: location.location) { _, fix in
            updateSortOrigin(fix?.coordinate)
        }
        // The GPS only runs while this ordering is actually on screen and in use.
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
        .onDisappear {
            undoTask?.cancel()
            saveTask?.cancel()
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
        let filtered = HouseListBuilder.filter(rows, filter: filter, query: debouncedQuery)
        if sortByDistance, let origin = sortOrigin {
            // Nearest-first is a flat ranking; grouping it back into streets would
            // throw the ordering away again.
            let ranked = HouseListBuilder.sortByDistance(filtered, from: origin)
            sections = [
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
        } else {
            sections = HouseListBuilder.sections(from: HouseListBuilder.sort(filtered))
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

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(id) },
            set: { expanded in
                if expanded {
                    collapsedSections.remove(id)
                } else {
                    collapsedSections.insert(id)
                }
            }
        )
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
        case .all: .accentColor
        case .open: .red
        case .unanswered: .orange
        case .joined: .pink
        }
    }

    private func coordinate(of id: UUID) -> CLLocationCoordinate2D {
        houses.first { $0.id == id }?.coordinate ?? .init()
    }

    // MARK: Status changes

    private func applyQuickStatus(_ outcome: VisitOutcome, to row: HouseRowModel) {
        guard let house = houses.first(where: { $0.id == row.id }),
              let previous = house.decodedUnits() else { return }

        if house.isApartmentBuilding {
            guard house.setOutcomeForOpenDoors(outcome, day: writeDay) > 0 else { return }
        } else {
            guard let door = previous.first else { return }
            house.setOutcome(outcome, for: door.id, day: writeDay)
        }

        offerUndo(
            UndoEntry(
                houseID: row.id,
                previousUnits: previous,
                // Concrete, so the user knows exactly what they are undoing after the
                // list has re-sorted and the row has moved.
                label: "\(row.address) → \(outcome.title)"
            )
        )
        scheduleSave()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        scheduleSave()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            modelContext.save(reporting: notices, context: "Status konnte nicht gespeichert werden")
        }
    }

    /// The pending save must land even if the view goes away first — the old code
    /// fired the mutation from an unstored `Task` after teardown, so the change was
    /// lost until something unrelated happened to save.
    private func flushPendingSave() {
        modelContext.save(reporting: notices, context: "Status konnte nicht gespeichert werden")
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

    static func == (lhs: HouseRow, rhs: HouseRow) -> Bool { lhs.row == rhs.row }

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
            row.formattedDistance.map { "\(row.accessibilityValue), \($0) entfernt" }
                ?? row.accessibilityValue
        )
        .accessibilityHint("Öffnet die Details")
    }
}

// MARK: - Street header

private struct StreetHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let section: StreetSection

    var body: some View {
        ViewThatFits(in: .horizontal) {
            headerLayout(compact: true)
            headerLayout(compact: false)
        }
        .contentShape(.rect)
    }

    private func headerLayout(compact: Bool) -> some View {
        HStack(alignment: compact ? .center : .firstTextBaseline, spacing: AppSpacing.snug) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.13))
                Image(systemName: "road.lanes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(compact ? 1 : 2)
                Text("\(section.houseCount) \(section.houseCount == 1 ? "Adresse" : "Adressen")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(section.completedCount)/\(section.unitCount)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(section.completedCount)))
                ProgressView(value: section.progress)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 44 : 58)
                    .tint(section.openCount == 0 ? .green : .red)
            }
            .animation(.appSettle(reduceMotion: reduceMotion), value: section.progress)

        }
    }
}

/// A quiet coloured field gives the transparent cards something useful to refract
/// in both appearances without fighting the status colours inside them.
// MARK: - Undo banner

private struct UndoBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let action: () -> Void

    var body: some View {
        // Two sibling glass shapes in one container. Nesting the button inside a
        // glass panel prevents Liquid Glass from sampling the content correctly.
        GlassEffectContainer(spacing: AppSpacing.tight) {
            HStack(spacing: AppSpacing.tight) {
                HStack(spacing: AppSpacing.snug) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
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
                    .tint(.blue)
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

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
