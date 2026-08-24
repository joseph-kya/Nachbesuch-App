import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Memory and accounting: the balance for the active territory, then every
/// territory grouped by campaign day.
struct ArchiveScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices

    @Query(sort: \Gebiet.day1Date, order: .reverse) private var gebiete: [Gebiet]
    /// Only the columns the index needs. The old query materialised every house in
    /// the database, blobs included, on every visit to this tab.
    @Query private var houses: [House]

    @Binding var selectedGebietID: UUID?
    @Binding var scope: DayScope
    let isActive: Bool

    @State private var index = ArchiveIndex.empty
    @State private var results: [ArchiveSearchResult] = []
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var filter: ArchiveFilter = .all
    @State private var route: ArchiveRoute?
    @State private var confirmation: ArchiveConfirmation?
    @State private var backupURL: URL?
    @State private var showsImporter = false
    @State private var isWorking = false

    enum ArchiveFilter: String, CaseIterable, Identifiable {
        case all, open
        var id: String { rawValue }
        var title: String { self == .all ? "Alle" : "Offen" }
        var systemImage: String { self == .all ? "square.stack" : "arrow.clockwise" }
    }

    /// One route, one sheet. Six independent presentation flags on a single view is
    /// how the importer→confirmation race got in.
    enum ArchiveRoute: Identifiable {
        case create
        case edit(UUID)
        case export(UUID)
        case share(URL)
        case settings

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let id): "edit-\(id)"
            case .export(let id): "export-\(id)"
            case .share(let url): "share-\(url.lastPathComponent)"
            case .settings: "settings"
            }
        }
    }

    enum ArchiveConfirmation: Identifiable {
        case delete(UUID, String)
        case restore(AppBackup)

        var id: String {
            switch self {
            case .delete(let id, _): "delete-\(id)"
            case .restore: "restore"
            }
        }
    }

    private struct IndexKey: Hashable {
        let gebietCount: Int
        let houseCount: Int
        let newestHouse: Date?
        let newestGebiet: Date?
    }

    private var indexKey: IndexKey {
        IndexKey(
            gebietCount: gebiete.count,
            houseCount: houses.count,
            newestHouse: houses.max(by: { $0.updatedAt < $1.updatedAt })?.updatedAt,
            newestGebiet: gebiete.max(by: { $0.updatedAt < $1.updatedAt })?.updatedAt
        )
    }

    private var activeGebiet: Gebiet? {
        gebiete.first { $0.id == selectedGebietID } ?? gebiete.first
    }

    var body: some View {
        NavigationStack {
            archiveScroll
                .background { AppBackdrop() }
                .navigationTitle("Archiv")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarMenu }
                .sensoryFeedback(.selection, trigger: selectedGebietID)
                .overlay { if isWorking { ProgressView().controlSize(.large) } }
                .sheet(item: $route, content: sheet(for:))
                .alert(item: $confirmation, content: alert(for:))
                .fileImporter(
                    isPresented: $showsImporter,
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false,
                    onCompletion: handleImportSelection
                )
        }
        .task(id: indexKey) {
            guard isActive || index.isEmpty else { return }
            await rebuildIndex()
        }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedQuery = searchText
        }
        .onChange(of: debouncedQuery) { _, _ in recomputeResults() }
    }

    /// A native `List` combines UIKit cell reuse, elastic section headers, searchable
    /// navigation chrome and SwiftUI glass. During a fast fling to offset zero all
    /// four tried to settle in different frames. This deliberately has one owner for
    /// vertical geometry: a plain ScrollView with lazy SwiftUI content.
    private var archiveScroll: some View {
        ScrollView {
            GlassEffectContainer(spacing: 2) {
                LazyVStack(alignment: .leading, spacing: AppSpacing.regular) {
                    ArchiveSearchField(text: $searchText)
                        .padding(.horizontal, AppSpacing.regular)

                    FilterBar(
                        chips: archiveFilterChips,
                        contextLabel: "Archiv",
                        onSelect: { id in
                            guard let value = ArchiveFilter(rawValue: id) else { return }
                            applyFilter(value)
                        }
                    )

                    if let activeGebiet, debouncedQuery.isEmpty, filter == .all {
                        ArchiveSectionLabel(
                            title: activeGebiet.displayName,
                            systemImage: "checkmark.circle.fill",
                            tint: .green,
                            trailing: "Aktiv"
                        )
                        .padding(.horizontal, AppSpacing.regular)

                    BalanceSection(
                        gebiet: activeGebiet,
                        entry: index.entry(for: activeGebiet.id),
                        scope: $scope
                    )
                    .padding(.horizontal, AppSpacing.regular)
                    }

                    ForEach(daySections) { section in
                        LazyVStack(alignment: .leading, spacing: AppSpacing.snug) {
                            ArchiveSectionLabel(title: section.title)
                            ForEach(section.items) { item in
                                gebietCard(item)
                            }
                        }
                        .padding(.horizontal, AppSpacing.regular)
                    }

                    if daySections.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: 260)
                            .padding(AppSpacing.regular)
                            .contentCard(cornerRadius: AppRadius.card)
                            .padding(.horizontal, AppSpacing.regular)
                    }
                }
                .padding(.top, AppSpacing.tight)
                // `.loose` alone left the last territory card under the floating
                // tab bar with no way to scroll it clear.
                .padding(.bottom, AppSpacing.loose + AppChrome.tabBarClearance)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { route = .create } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Neues Gebiet")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button { route = .settings } label: {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                }
                Section("Sicherung") {
                    Button { Task { await createBackup() } } label: {
                        Label("Backup erstellen", systemImage: "arrow.down.doc")
                    }
                    Button { showsImporter = true } label: {
                        Label("Backup importieren", systemImage: "arrow.up.doc")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Archivoptionen")
        }
    }

    private var archiveFilterChips: [FilterChip] {
        let openCount = gebiete.reduce(into: 0) { total, gebiet in
            if (index.entry(for: gebiet.id)?.overall.open ?? 0) > 0 { total += 1 }
        }
        return ArchiveFilter.allCases.map { value in
            FilterChip(
                id: value.rawValue,
                title: value.title,
                systemImage: value.systemImage,
                tint: value == .all ? accent : .red,
                count: value == .all ? gebiete.count : openCount,
                isSelected: filter == value
            )
        }
    }

    // MARK: Sections

    private struct DaySection: Identifiable {
        let id: String
        let title: String
        let items: [ArchiveSearchResult]
    }

    private var daySections: [DaySection] {
        guard debouncedQuery.isEmpty else {
            guard !results.isEmpty else { return [] }
            return [DaySection(id: "results", title: "Beste Treffer", items: results)]
        }

        var order: [Date] = []
        var grouped: [Date: [ArchiveSearchResult]] = [:]
        for result in results {
            guard let gebiet = gebiete.first(where: { $0.id == result.gebietID }) else { continue }
            for date in gebiet.assignedDates {
                if grouped[date] == nil { order.append(date) }
                grouped[date, default: []].append(result)
            }
        }
        return order.sorted(by: >).map { date in
            DaySection(
                id: "day-\(date.timeIntervalSince1970)",
                title: dayTitle(for: date),
                items: grouped[date] ?? []
            )
        }
    }

    private func dayTitle(for date: Date) -> String {
        let calendar = Gebiet.campaignCalendar
        if calendar.isDateInToday(date) { return "Heute" }
        if calendar.isDateInYesterday(date) { return "Gestern" }
        if calendar.isDateInTomorrow(date) { return "Morgen" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    // MARK: Row

    @ViewBuilder
    private func gebietCard(_ item: ArchiveSearchResult) -> some View {
        if let gebiet = gebiete.first(where: { $0.id == item.gebietID }) {
            let entry = index.entry(for: gebiet.id)
            ZStack(alignment: .topTrailing) {
                Button {
                    selectGebiet(gebiet.id)
                } label: {
                    GebietRow(
                        model: GebietRowModel(
                            id: gebiet.id,
                            name: gebiet.displayName,
                            place: gebiet.districtOrCity,
                            dateRange: gebiet.formattedDateRange,
                            isTwoDay: gebiet.isTwoDay,
                            isActive: gebiet.id == activeGebiet?.id,
                            houseCount: entry?.houseCount ?? 0,
                            completed: entry?.overall.completed ?? 0,
                            total: entry?.overall.unitCount ?? 0,
                            open: entry?.overall.open ?? 0,
                            joined: entry?.overall.joined ?? 0
                        )
                    )
                    .equatable()
                    // Reserve the top-right hit area for the visible action menu.
                    .padding(.trailing, 42)
                    .padding(.leading, 16)
                    .padding(.vertical, 13)
                    .contentCard(cornerRadius: AppRadius.card)
                    .overlay {
                        if gebiet.id == activeGebiet?.id {
                            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                                .fill(accent.opacity(0.08))
                                .allowsHitTesting(false)
                        }
                    }
                }
                .buttonStyle(PressableRowStyle())

                Menu {
                    Button {
                        route = .export(gebiet.id)
                    } label: {
                        Label("Exportieren", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        route = .edit(gebiet.id)
                    } label: {
                        Label("Bearbeiten", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmation = .delete(gebiet.id, gebiet.displayName)
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
                label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(10)
                .accessibilityLabel("Aktionen für \(gebiet.displayName)")
            }
            // VoiceOver equivalents: the swipe actions were previously reachable
            // only by swiping.
            .accessibilityAction(named: "Bearbeiten") { route = .edit(gebiet.id) }
            .accessibilityAction(named: "Exportieren") { route = .export(gebiet.id) }
            .accessibilityAction(named: "Löschen") {
                confirmation = .delete(gebiet.id, gebiet.displayName)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !debouncedQuery.isEmpty {
            ContentUnavailableView.search(text: debouncedQuery)
        } else {
            ContentUnavailableView {
                Label("Noch keine Gebiete", systemImage: "archivebox")
            } description: {
                Text("Lege ein Gebiet an, um mit dem Erfassen zu beginnen.")
            } actions: {
                Button("Neues Gebiet") { route = .create }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Index

    private func rebuildIndex() async {
        let gebietSeeds = gebiete.map {
            ArchiveIndexBuilder.GebietSeed(
                id: $0.id,
                name: $0.name,
                districtOrCity: $0.districtOrCity,
                notes: $0.notes,
                day1Date: $0.day1Date,
                day2Date: $0.day2Date,
                isTwoDay: $0.isTwoDay
            )
        }
        let houseSeeds = houses.map {
            ArchiveIndexBuilder.HouseSeed(
                gebietID: $0.territoryID,
                address: $0.address,
                note: $0.note,
                unitsData: $0.unitsData
            )
        }
        let built = await Task.detached(priority: .userInitiated) {
            ArchiveIndexBuilder.build(gebiete: gebietSeeds, houses: houseSeeds)
        }.value
        guard !Task.isCancelled else { return }
        index = built
        recomputeResults()
    }

    /// Memoized: the search used to run inside `body`, so it re-executed against an
    /// unchanged query on every keystroke, filter tap and notice.
    private func recomputeResults() {
        results = searchResults(filter: filter)
    }

    private func searchResults(filter: ArchiveFilter) -> [ArchiveSearchResult] {
        let order = gebiete.map(\.id)
        var found = ArchiveSearchEngine.search(query: debouncedQuery, index: index, order: order)
        if filter == .open {
            found = found.filter { (index.entry(for: $0.gebietID)?.overall.open ?? 0) > 0 }
        }
        return found
    }

    /// Balance visibility and filtered cards change atomically and without a layout
    /// animation. Animating removal of the chart's glass card leaves a compositor
    /// snapshot behind for several frames, so the balance flashes over the new list.
    private func applyFilter(_ value: ArchiveFilter) {
        guard filter != value else { return }
        let nextResults = searchResults(filter: value)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            filter = value
            results = nextResults
        }
    }

    /// Replacing the active territory swaps the complete balance subtree: chart,
    /// counters, progress and (for two-day territories) the scope picker. Treating
    /// that as one animated selection made unrelated shapes interpolate at once and
    /// left compositor snapshots behind. The row still supplies normal press and
    /// selection feedback; the data replacement itself is deliberately atomic.
    private func selectGebiet(_ id: UUID) {
        guard selectedGebietID != id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedGebietID = id
        }
    }

    // MARK: Routing

    @ViewBuilder
    private func sheet(for route: ArchiveRoute) -> some View {
        switch route {
        case .create:
            GebietEditorSheet(mode: .create) { created in
                selectedGebietID = created.id
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)

        case .edit(let id):
            if let gebiet = gebiete.first(where: { $0.id == id }) {
                GebietEditorSheet(mode: .edit(gebiet))
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }

        case .export(let id):
            if let gebiet = gebiete.first(where: { $0.id == id }) {
                ExportSheet(
                    gebiet: gebiet,
                    houses: houses.filter { $0.territoryID == id },
                    scope: .combined
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }

        case .share(let url):
            ShareSheet(url: url)
                .presentationDetents([.medium])

        case .settings:
            AppearanceSettingsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func alert(for confirmation: ArchiveConfirmation) -> Alert {
        switch confirmation {
        case .delete(let id, let name):
            return Alert(
                title: Text("„\(name)“ löschen?"),
                message: Text("Alle Häuser und Ergebnisse dieses Gebiets werden entfernt."),
                primaryButton: .destructive(Text("Löschen")) { delete(id) },
                secondaryButton: .cancel(Text("Abbrechen"))
            )
        case .restore(let backup):
            return Alert(
                title: Text("Backup importieren?"),
                message: Text("\(backup.gebiete.count) Gebiete und \(backup.houses.count) Häuser werden mit deinem Bestand zusammengeführt."),
                primaryButton: .default(Text("Importieren")) {
                    Task { await restore(backup) }
                },
                secondaryButton: .cancel(Text("Abbrechen"))
            )
        }
    }

    // MARK: Actions

    private func delete(_ id: UUID) {
        guard let gebiet = gebiete.first(where: { $0.id == id }) else { return }
        // Batch delete instead of a synchronous per-house loop on the main actor.
        try? modelContext.delete(model: House.self, where: #Predicate { $0.gebietID == id || $0.dayID == id })
        modelContext.delete(gebiet)
        guard modelContext.save(reporting: notices, context: "Gebiet konnte nicht gelöscht werden") else { return }
        // Deliberately no replacement territory. The old code fabricated one under a
        // third name whenever the last was deleted, so the user could never reach the
        // empty state they had explicitly asked for.
        if selectedGebietID == id { selectedGebietID = gebiete.first { $0.id != id }?.id }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func createBackup() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await BackupService.makeBackup(gebiete: gebiete, houses: houses)
            route = .share(url)
        } catch {
            notices.report(error, context: "Backup konnte nicht erstellt werden")
        }
    }

    private func handleImportSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let backup = try await BackupService.readBackup(at: url)
                    // Yield once so the importer has finished dismissing before the
                    // confirmation tries to present — presenting into a dismissal
                    // silently no-ops, and the user saw nothing happen.
                    try? await Task.sleep(for: .milliseconds(350))
                    confirmation = .restore(backup)
                } catch {
                    notices.report(error, context: "Backup konnte nicht gelesen werden")
                }
            }
        case .failure(let error):
            notices.report(error, context: "Datei konnte nicht geöffnet werden")
        }
    }

    private func restore(_ backup: AppBackup) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await BackupService.importBackup(backup, into: modelContext)
            notices.show(
                "\(result.importedGebiete) Gebiete und \(result.importedHouses) Häuser importiert."
                    + (result.skippedHouses > 0 ? " \(result.skippedHouses) übersprungen." : "")
            )
        } catch {
            notices.report(error, context: "Backup konnte nicht importiert werden")
        }
    }
}

// MARK: - Stable archive chrome

/// Search lives in scroll content rather than navigation chrome. Its height never
/// depends on scroll velocity, overscroll or large-title state.
private struct ArchiveSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: AppSpacing.snug) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Gebiet, Adresse, Datum", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche löschen")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: AppTouch.minimum)
        .navigationGlass(cornerRadius: AppRadius.control, interactive: true)
        .accessibilityElement(children: .contain)
    }
}

private struct ArchiveSectionLabel: View {
    let title: String
    var systemImage: String?
    var tint: Color = .secondary
    var trailing: String?

    var body: some View {
        HStack(spacing: AppSpacing.tight) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

struct GebietRowModel: Identifiable, Equatable {
    let id: UUID
    let name: String
    let place: String
    let dateRange: String
    let isTwoDay: Bool
    let isActive: Bool
    let houseCount: Int
    let completed: Int
    let total: Int
    let open: Int
    let joined: Int

    var progress: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// A real `View` struct over a flat value, so SwiftUI can skip re-rendering rows
/// that did not change. The old row was a 150-line function returning `some View`,
/// which meant every row re-rendered on every keystroke.
struct GebietRow: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    let model: GebietRowModel

    static func == (lhs: GebietRow, rhs: GebietRow) -> Bool { lhs.model == rhs.model }

    var body: some View {
        HStack(spacing: AppSpacing.snug) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(model.isActive ? accent : .clear)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: AppSpacing.tight) {
                    Text(model.name)
                        .font(.headline)
                        .lineLimit(1)
                    if model.isActive {
                        Label("Aktiv", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.doneTone)
                            .labelStyle(.titleAndIcon)
                            .fixedSize()
                            .symbolEffect(.bounce, value: reduceMotion ? false : model.isActive)
                    }
                    if model.isTwoDay {
                        Text("2 Tage")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.16), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }

                Text([model.place, model.dateRange].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: AppSpacing.snug) {
                    ProgressView(value: model.progress)
                        .tint(model.open == 0 ? .green : .red)
                        .animation(.appSettle(reduceMotion: reduceMotion), value: model.progress)
                    Text("\(model.completed)/\(model.total)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: AppSpacing.snug) {
                    statLabel(systemImage: "house.fill", value: model.houseCount, tint: .secondary)
                    statLabel(systemImage: VisitOutcome.notHome.symbolName, value: model.open, tint: .red)
                    statLabel(systemImage: VisitOutcome.joined.symbolName, value: model.joined, tint: .pink)
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.name)
        .accessibilityValue(
            "\(model.dateRange), \(model.houseCount) Häuser, \(model.completed) von \(model.total) erledigt, "
                + "\(model.open) offen, \(model.joined) dabei"
                + (model.isActive ? ", aktives Gebiet" : "")
        )
        .accessibilityAddTraits(model.isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func statLabel(systemImage: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text("\(value)").monospacedDigit()
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.regular) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.doneTone)
                Text("Backup erstellt")
                    .font(.headline)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ShareLink(item: url) {
                    Label("Teilen oder sichern", systemImage: "square.and.arrow.up")
                        .frame(minHeight: AppTouch.minimum)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}
