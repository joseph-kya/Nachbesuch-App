import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Memory and accounting: the balance for the active territory, then every
/// territory grouped by campaign day.
struct ArchiveScreen: View {
    @Environment(\.appAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices
    #if DEBUG
    @Environment(LocationService.self) private var location
    #endif

    @Query(sort: \Gebiet.day1Date, order: .reverse) private var gebiete: [Gebiet]

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
    /// Untertitel für den Backup-Teilen-Bogen („Enthält N Häuser") — reiner
    /// Index-Stand, kein Fetch (WAVE4).
    @State private var shareSubtitle: String?
    @State private var showsImporter = false
    @State private var isWorking = false
    @State private var areaSwitchRequest: UUID?
    #if DEBUG
    @State private var showsDiagnostics = false
    #endif
    /// The newest automatic safety backup, if one exists yet. Read on appear
    /// and after every save — the launch backup may finish while this screen
    /// is already open.
    @State private var autoBackup: (date: Date, url: URL)?
    /// Bumped whenever SwiftData commits, so the index can be rebuilt on a real
    /// change without `body` paying to look for one.
    ///
    /// The key this replaces ended in `houses.max(by: { $0.updatedAt < $1.updatedAt })`.
    /// That is an O(n) scan that faults `updatedAt` on **every** house in the
    /// territory, and because it was computed inside `body` — as the `id` of a
    /// `.task` — it ran again on every single body evaluation. This screen scanned twice — houses *and* territories. Tapping a card sets
    /// `selectedGebietID`, which re-evaluates `body`, which paid for a full scan of
    /// 1000+ models before the selection could be drawn. That is the tap
    /// that lands seconds late, and the inconsistency is faulting: the scan is cheap
    /// once the objects are in memory and expensive when they are not.
    @State private var dataVersion = 0

    @State private var builtIndexKey: IndexKey?
    /// Street encounters per territory. Territories, not houses, so one cheap
    /// indexed count each; refreshed only when the archive needs it.
    @State private var passantCounts: [UUID: Int] = [:]


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
        case tutorial

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let id): "edit-\(id)"
            case .export(let id): "export-\(id)"
            case .share(let url): "share-\(url.lastPathComponent)"
            case .settings: "settings"
            case .tutorial: "tutorial"
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
        let version: Int
    }

    private var indexKey: IndexKey {
        IndexKey(
            gebietCount: gebiete.count,
            version: dataVersion
        )
    }

    private struct IndexTaskKey: Hashable {
        let index: IndexKey
        let isActive: Bool
    }

    private var activeGebiet: Gebiet? {
        gebiete.first { $0.id == selectedGebietID } ?? gebiete.first
    }

    /// Territories by id, built once per body pass.
    ///
    /// `daySections` and `gebietCard` both resolved a result back to its territory
    /// with `gebiete.first(where:)`. That is a linear scan per row, inside a computed
    /// property that runs on every body evaluation — so a keystroke in the search
    /// field cost one scan per visible card, and each scan faults the territory's
    /// properties. One dictionary answers all of them.
    private var gebietByID: [UUID: Gebiet] {
        Dictionary(gebiete.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                #if DEBUG
                .sheet(isPresented: $showsDiagnostics) { DiagnosticsSheet() }
                .onReceive(NotificationCenter.default.publisher(for: .openDiagnostics)) { _ in
                    showsDiagnostics = true
                }
                #endif
                // WAVE4: Löschen als Bestätigungsdialog mit Sicherungs-Option
                // (doppelt: Menü-Tipp + Dialog), Wiederherstellen bleibt Alert.
                .confirmationDialog(
                    Text(deleteTitle),
                    isPresented: isDeletePresented,
                    titleVisibility: .visible,
                    presenting: deleteTarget
                ) { target in
                    // Sichere Option zuerst (Standard), destruktive danach — beide
                    // mit klarer Folge, Abbrechen bricht ab.
                    Button("Sichern & löschen") { Task { await backupThenDelete(target.id) } }
                    Button("Nur löschen", role: .destructive) { Task { await delete(target.id) } }
                    Button("Abbrechen", role: .cancel) {}
                } message: { target in
                    // Sicherungs-Anstoß + Folge mit Zahl (A11y: klare Konsequenz).
                    let count = houseCount(for: target.id)
                    Text("Erst sichern? \(count == 1 ? "1 Haus" : "\(count) Häuser") und alle Ergebnisse werden vom Gerät gelöscht.")
                }
                .alert(item: restoreBinding, content: restoreAlert)
                .fileImporter(
                    isPresented: $showsImporter,
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false,
                    onCompletion: handleImportSelection
                )
        }
        .task {
            refreshPassantCounts()
            refreshAutoBackup()
        }
        .task(id: IndexTaskKey(index: indexKey, isActive: isActive)) {
            guard isActive, builtIndexKey != indexKey else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, isActive else { return }
            await rebuildIndex()
        }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedQuery = searchText
        }
        .onChange(of: debouncedQuery) { _, _ in recomputeResults() }
        .onChange(of: selectedGebietID) { _, _ in
            if isActive { refreshActivePassantCount() }
        }
        .onChange(of: isActive) { _, active in
            if !active { areaSwitchRequest = nil }
            if active {
                refreshActivePassantCount()
                refreshAutoBackup()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            dataVersion &+= 1
            if isActive {
                refreshActivePassantCount()
                refreshAutoBackup()
            }
        }
    }

    /// A native `List` combines UIKit cell reuse, elastic section headers, searchable
    /// navigation chrome and SwiftUI glass. During a fast fling to offset zero all
    /// four tried to settle in different frames. This deliberately has one owner for
    /// vertical geometry: a plain ScrollView with lazy SwiftUI content.
    private var archiveScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
            CompatGlassContainer(spacing: AppSpacing.tight) {
                LazyVStack(alignment: .leading, spacing: AppSpacing.regular) {
                    ArchiveSearchField(text: $searchText)
                        .padding(.horizontal, AppSpacing.regular)
                        .id(Self.topAnchor)

                    FilterBar(
                        chips: archiveFilterChips,
                        contextLabel: "Archiv",
                        onSelect: { id in
                            guard let value = ArchiveFilter(rawValue: id) else { return }
                            applyFilter(value, proxy: proxy)
                        }
                    )

                    // WAVE4: Sicherungsalter als reine Lese-Zeile — `autoBackup`
                    // kommt aus dem Dateisystem-Stand (kein Fetch, kein Zähler).
                    backupAgeRow
                        .padding(.horizontal, AppSpacing.regular)

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
                        scope: $scope,
                        passantCount: passantCounts[activeGebiet.id] ?? 0
                    )
                    .padding(.horizontal, AppSpacing.regular)
                    }

                    let byID = gebietByID
                    ForEach(daySections) { section in
                        LazyVStack(alignment: .leading, spacing: AppSpacing.snug) {
                            ArchiveSectionLabel(title: section.title)
                            ForEach(section.items) { item in
                                gebietCard(item, in: byID, proxy: proxy)
                            }
                        }
                        .padding(.horizontal, AppSpacing.regular)
                    }

                    if daySections.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, minHeight: 220)
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
            .compatSoftScrollEdges()
            #if DEBUG
            .task(id: isActive) {
                guard isActive,
                      let raw = ProcessInfo.processInfo.environment["NACHBESUCH_AREA_STRESS"],
                      let count = Int(raw), count > 0 else { return }
                // Exercise the same handler as a territory-row tap, from below
                // the variable-height balance, including empty/populated areas.
                for _ in 0..<100 {
                    if builtIndexKey != nil, gebiete.count > 1 { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                guard gebiete.count > 1 else { return }
                for _ in 0..<count {
                    guard let target = gebiete.first(where: { $0.id != selectedGebietID })?.id else { return }
                    proxy.scrollTo(target, anchor: .center)
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    selectGebiet(target, proxy: proxy)
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    guard selectedGebietID == target else {
                        FileHandle.standardOutput.write(Data("[AreaStress] FAILED selection\n".utf8))
                        return
                    }
                }
                FileHandle.standardOutput.write(Data("[AreaStress] completed \(count) switches\n".utf8))
            }
            #endif
        }
    }

    /// The identity the screen returns to whenever the block above the list changes
    /// height. See `selectGebiet`.
    private static let topAnchor = "archive.top"

    /// Put the balance back on screen after something replaced it.
    ///
    /// The active territory's balance sits at the top of this scroll view, and its
    /// height is genuinely variable: the campaign-day picker, the revisit summary and
    /// the fifth metric tile each exist for some territories and not others, which is
    /// up to ~190 pt of difference. Swapping it while the user is scrolled past it
    /// moved every card below by that difference — the card under their finger jumped,
    /// and when the content shrank the scroll view bounced off its new content height.
    /// Both of the symptoms this screen was reported for.
    ///
    /// Freezing the swap (which is what this screen used to do) removes the animation
    /// but not the jump. Going back to the balance does: the one thing that moves is
    /// the list, deliberately, in the direction of the thing the tap just changed —
    /// which is also the confirmation the tap was missing, since the balance was
    /// off-screen the whole time.
    private func returnToBalance(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.topAnchor, anchor: .top)
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
                    Button { route = .tutorial } label: {
                        Label("Anleitung", systemImage: "book.fill")
                    }
                }
                Section("Sicherung") {
                    Button { Task { await createBackup() } } label: {
                        Label("Backup erstellen", systemImage: "arrow.down.doc")
                    }
                    Button { showsImporter = true } label: {
                        Label("Backup importieren", systemImage: "arrow.up.doc")
                    }
                    Button { Task { await exportDiagnostics() } } label: {
                        Label("Diagnose exportieren", systemImage: "stethoscope")
                    }
                    if let autoBackup {
                        ShareLink(item: autoBackup.url) {
                            Label(
                                "Automatische Sicherung teilen",
                                systemImage: "clock.arrow.circlepath"
                            )
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    #if DEBUG
                    // Hidden diagnostics (B4): no visible entry point on purpose.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.8)
                            .onEnded { _ in showsDiagnostics = true }
                    )
                    #endif
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
        let byID = gebietByID
        for result in results {
            guard let gebiet = byID[result.gebietID] else { continue }
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
    private func gebietCard(_ item: ArchiveSearchResult, in byID: [UUID: Gebiet], proxy: ScrollViewProxy) -> some View {
        if let gebiet = byID[item.gebietID] {
            let entry = index.entry(for: gebiet.id)
            ZStack(alignment: .topTrailing) {
                Button {
                    selectGebiet(gebiet.id, proxy: proxy)
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
                    // Reserve the top-right hit area for the visible action menu —
                    // now 44 pt plus its margin, so the text cannot run under it.
                    .padding(.trailing, 52)
                    .padding(.leading, AppSpacing.regular)
                    .padding(.vertical, 13)
                    .contentCard(cornerRadius: AppRadius.card)
                    // Always present, only its opacity moves. Inserting and removing
                    // the shape made the wash pop on and off; a fill that is animatable
                    // lets the old and the new card trade the highlight in one motion.
                    // On iOS 26 the wash sits under glass and reads as a tint. On an
                    // opaque iOS 18 card it is a flat pink rectangle the size of the
                    // record — the "large translucent red field" the audit rejects,
                    // and on this screen red already means "offen". iOS 18 leans on
                    // the accent rail and the "Aktiv" label the row already draws,
                    // with the wash at a quarter strength so the card is still
                    // distinguishable in greyscale by luminance alone.
                    // Invariant: dark wash ≤0.04 — red over black goes muddy
                    // (glass dark 0.03, opaque 0.02; light stays 0.08).
                    .overlay {
                        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                            .fill(
                                accent.opacity(
                                    gebiet.id == activeGebiet?.id
                                        ? (LegacyChrome.isActive ? 0.02 : (colorScheme == .dark ? 0.03 : 0.08))
                                        : 0
                                )
                            )
                            .allowsHitTesting(false)
                    }
                }
                // WAVE2: press highlight only, scale 1.0 — a scaled card tears away
                // from the glass wash and the menu button above it. Selection haptic
                // comes from the `.sensoryFeedback(trigger: selectedGebietID)` on the
                // NavigationStack (once, not per row).
                .buttonStyle(GebietCardStyle())

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
                .compatGlassButton(shape: .circle, role: .card)
                .buttonBorderShape(.circle)
                // `.padding(10)` sat here on its own. Padding *outside* a styled
                // button is margin, not target: it moves the control inwards and
                // leaves it the size of its 32 pt glyph, under Apple's 44 pt
                // minimum, floating over a card-sized button that happily takes any
                // tap that misses. `.tappable()` is this codebase's own helper for
                // exactly that, and it was not applied here.
                .tappable()
                .padding(4)
                .accessibilityLabel("Aktionen für \(gebiet.displayName)")
            }
            .id(gebiet.id)
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
            // WAVE2: icon bounce on appear (RM-gated), prominent glass CTA +
            // secondary Tutorial link. ContentUnavailableView keeps dark/light
            // legibility via semantic styles.
            ContentUnavailableView {
                Label("Noch keine Gebiete", systemImage: "archivebox")
                    .symbolEffect(
                        .bounce,
                        options: reduceMotion ? .nonRepeating : .default,
                        value: gebiete.isEmpty
                    )
                    .symbolEffectsRemoved(reduceMotion)
            } description: {
                Text("Lege ein Gebiet an, um mit dem Erfassen zu beginnen.")
            } actions: {
                Button("Neues Gebiet") { route = .create }
                    .compatGlassButton(prominent: true)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Neues Gebiet anlegen")
                Button("Anleitung ansehen") { route = .tutorial }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Anleitung ansehen")
            }
        }
    }

    // MARK: Index

    private func rebuildIndex() async {
        let key = indexKey
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
        let houseSeeds: [ArchiveIndexBuilder.HouseSeed]
        do {
            let reader = await HouseReadService.background(container: modelContext.container)
            houseSeeds = try await reader.archiveSeeds()
        } catch is CancellationError {
            return
        } catch {
            notices.report(error, context: "Archiv konnte nicht gelesen werden")
            return
        }
        let buildTask = Task.detached(priority: .userInitiated) {
            ArchiveIndexBuilder.build(gebiete: gebietSeeds, houses: houseSeeds)
        }
        let built = await withTaskCancellationHandler {
            await buildTask.value
        } onCancel: {
            buildTask.cancel()
        }
        guard !Task.isCancelled else { return }
        index = built
        recomputeResults()
        builtIndexKey = key
    }

    /// Street encounters per territory for the balance row. One indexed count
    /// per territory; territories are few, houses are many.
    private func refreshPassantCounts() {
        var counts: [UUID: Int] = [:]
        counts.reserveCapacity(gebiete.count)
        for gebiet in gebiete {
            let id = gebiet.id
            counts[id] = (try? modelContext.fetchCount(
                FetchDescriptor<Passant>(predicate: #Predicate { $0.gebietID == id })
            )) ?? passantCounts[id] ?? 0
        }
        passantCounts = counts
    }

    /// After a save only the open territory's count can have changed — but every
    /// door tap saves. Counting all territories on every tap is N indexed
    /// fetches on Main per tap for counts nobody is looking at; the rest refresh
    /// on appear/territory switch.
    private func refreshActivePassantCount() {
        guard let id = selectedGebietID ?? gebiete.first?.id else { return }
        let count = (try? modelContext.fetchCount(
            FetchDescriptor<Passant>(predicate: #Predicate { $0.gebietID == id })
        )) ?? passantCounts[id] ?? 0
        if passantCounts[id] != count {
            passantCounts[id] = count
        }
    }

    /// Picks up a launch backup that finished after this screen appeared.
    private func refreshAutoBackup() {
        autoBackup = AutoBackupService.latest()
    }

    /// WAVE4: „Letzte Sicherung: vor X" — liest nur den gemerkten Stand aus
    /// `autoBackup` (Dateisystem, kein Store-Fetch). Orange Warnung erst nach
    /// mehr als 7 Tagen ohne Sicherung.
    private var backupAgeRow: some View {
        let (text, isStale) = backupAge()
        return Label(text, systemImage: "clock.arrow.circlepath")
            .font(.footnote.weight(.medium))
            .foregroundStyle(isStale ? .orange : .secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
    }

    private func backupAge(now: Date = .now) -> (String, Bool) {
        guard let date = autoBackup?.date else {
            return ("Letzte Sicherung: noch keine", true)
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        let relativ: String
        switch days {
        case ...0: relativ = "heute"
        case 1: relativ = "gestern"
        default: relativ = "vor \(days) Tagen"
        }
        let stale = days > 7
        return ("Letzte Sicherung: \(relativ)\(stale ? " — bitte sichern" : "")", stale)
    }

    /// The houses of one territory, fetched for the moment they are needed.
    ///
    /// Export and backup are the only things on this screen that want real houses.
    /// Both are one-shot actions, so they fetch, use and release rather than being
    /// served from a set held open for the whole session.
    private func houses(in gebietID: UUID?) -> [House] {
        let descriptor: FetchDescriptor<House>
        if let gebietID {
            descriptor = FetchDescriptor<House>(
                predicate: #Predicate { $0.gebietID == gebietID || $0.dayID == gebietID }
            )
        } else {
            descriptor = FetchDescriptor<House>()
        }
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            notices.report(error, context: "Häuser konnten nicht gelesen werden")
            return []
        }
    }

    /// Street encounters of one territory, fetched for the moment they are
    /// needed — the export sheet is the only thing on this screen that wants
    /// them, same one-shot rule as houses.
    private func passanten(in gebietID: UUID) -> [Passant] {
        do {
            return try modelContext.fetch(
                FetchDescriptor<Passant>(predicate: #Predicate { $0.gebietID == gebietID })
            )
        } catch {
            notices.report(error, context: "Passanten konnten nicht gelesen werden")
            return []
        }
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

    /// Balance visibility and the filtered cards change atomically and without a
    /// layout animation. "Offen" hides the balance card outright, and animating the
    /// *removal* of a glass card leaves a compositor snapshot behind for several
    /// frames, so the balance flashed over the new list. That is still true, so the
    /// swap itself stays frozen — but the list is returned to the top afterwards,
    /// because a filter that drops half the cards otherwise leaves the user parked at
    /// an offset that no longer refers to anything they were looking at.
    private func applyFilter(_ value: ArchiveFilter, proxy: ScrollViewProxy) {
        guard filter != value else { return }
        areaSwitchRequest = nil
        let nextResults = searchResults(filter: value)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            filter = value
            results = nextResults
        }
        // Scroll is the only animated part here — the card swap itself is frozen
        // to avoid a glass snapshot. Keep the scroll silky, not snappy.
        withAnimation(.appSettle(reduceMotion: reduceMotion)) {
            returnToBalance(proxy)
        }
    }

    /// Scroll the existing layout first. Changing the territory inside that
    /// animation also changes the balance height and makes the scroll target move.
    /// Once at the top, replace unrelated statistics without numeric/layout morphs.
    /// WAVE2: tapping the already-selected card recenters it with appSettle
    /// (no data swap, so no freeze needed). Selection haptic stays on the
    /// `.sensoryFeedback(trigger: selectedGebietID)` above — once, not per row.
    private func selectGebiet(_ id: UUID, proxy: ScrollViewProxy) {
        guard selectedGebietID != id else {
            areaSwitchRequest = nil
            withAnimation(.appSettle(reduceMotion: reduceMotion)) {
                proxy.scrollTo(id, anchor: .center)
            }
            return
        }
        let request = UUID()
        areaSwitchRequest = request
        withAnimation(.appSettle(reduceMotion: reduceMotion), completionCriteria: .removed) {
            returnToBalance(proxy)
        } completion: {
            guard areaSwitchRequest == request,
                  gebiete.contains(where: { $0.id == id }) else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if scope == .day2, gebiete.first(where: { $0.id == id })?.isTwoDay != true {
                    scope = .combined
                }
                selectedGebietID = id
                areaSwitchRequest = nil
            }
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
                    houses: houses(in: id),
                    passanten: passanten(in: id),
                    scope: .combined
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }

        case .share(let url):
            ShareSheet(url: url, subtitle: shareSubtitle)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)

        case .settings:
            AppearanceSettingsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)

        case .tutorial:
            TutorialView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Bestätigungen (WAVE4)

    /// Das Löschziel aus der Bestätigung — steuert Titel und Inhalt des Dialogs.
    private var deleteTarget: (id: UUID, name: String)? {
        if case .delete(let id, let name) = confirmation { return (id, name) }
        return nil
    }

    private var deleteTitle: String {
        if case .delete(_, let name) = confirmation { return "„\(name)“ löschen?" }
        return "Gebiet löschen?"
    }

    /// Nur der Löschen-Fall hebt den Dialog; Schließen räumt die Bestätigung weg.
    private var isDeletePresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { open in if !open { confirmation = nil } }
        )
    }

    /// Nur der Wiederherstellen-Fall steuert den Alert.
    private var restoreBinding: Binding<ArchiveConfirmation?> {
        Binding(
            get: {
                if case .restore = confirmation { return confirmation }
                return nil
            },
            set: { confirmation = $0 }
        )
    }

    /// Hauszahl ohne Fetch: reiner Index-Stand für die Folgenbeschreibung.
    private func houseCount(for id: UUID) -> Int {
        index.entry(for: id)?.houseCount ?? 0
    }

    private func restoreAlert(_ confirmation: ArchiveConfirmation) -> Alert {
        guard case .restore(let backup) = confirmation else {
            return Alert(title: Text("Hinweis"))
        }
        return Alert(
            title: Text("Backup importieren?"),
            message: Text("\(backup.gebiete.count) Gebiete und \(backup.houses.count) Häuser werden mit deinem Bestand zusammengeführt."),
            primaryButton: .default(Text("Importieren")) {
                Task { await restore(backup) }
            },
            secondaryButton: .cancel(Text("Abbrechen"))
        )
    }

    // MARK: Actions

    private func delete(_ id: UUID) async {
        guard gebiete.contains(where: { $0.id == id }) else { return }
        guard await GebietDeletion.delete(id, in: modelContext, notices: notices) else { return }
        dismissStaleReferences(to: id)
    }

    /// Räumt Blätter weg, die noch auf das gelöschte Gebiet zeigen, und wählt
    /// das nächste — sonst zeigt „Gebiet bearbeiten/löschen" auf eine tote ID.
    private func dismissStaleReferences(to id: UUID) {
        // Dismiss any stale sheet/confirmation that still points at the deleted Gebiet.
        if case .edit(let editID) = route, editID == id { route = nil }
        if case .export(let expID) = route, expID == id { route = nil }
        if case .delete(let delID, _) = confirmation, delID == id { confirmation = nil }
        // Select next Gebiet; if none remain, open the selector directly instead of
        // leaving the map's "Gebiet bearbeiten/löschen" alert pointing at a dead ID.
        let remaining = gebiete.filter { $0.id != id }
        if selectedGebietID == id {
            if let next = remaining.first?.id {
                selectedGebietID = next
            } else {
                selectedGebietID = nil
                // No Gebiete left — go straight to the selector.
                route = .create
            }
        }
    }

    private func createBackup() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await BackupService.makeBackup(in: modelContext)
            // Untertitel aus dem Index-Stand (kein Fetch): was der Teilen-Bogen
            // gerade sichert. ExportSheet zeigt dasselbe für den Export.
            shareSubtitle = backupSubtitle()
            route = .share(url)
        } catch {
            notices.report(error, context: "Backup konnte nicht erstellt werden")
        }
    }

    /// „Sichern & löschen": Erst das Backup — scheitert es, wird nichts
    /// gelöscht (die Meldung erklärt bereits). Danach löschen und den Beleg
    /// zum Teilen anbieten.
    private func backupThenDelete(_ id: UUID) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await BackupService.makeBackup(in: modelContext)
            guard await GebietDeletion.delete(id, in: modelContext, notices: notices) else { return }
            dismissStaleReferences(to: id)
            shareSubtitle = backupSubtitle()
            route = .share(url)
        } catch {
            notices.report(error, context: "Backup konnte nicht erstellt werden. Nichts wurde gelöscht")
        }
    }

    /// Zähler aus @Query + Index, nie ein Fetch im Dialog-Weg.
    private func backupSubtitle() -> String {
        let houses = gebiete.reduce(into: 0) { $0 += index.entry(for: $1.id)?.houseCount ?? 0 }
        let gebietWort = gebiete.count == 1 ? "Gebiet" : "Gebiete"
        let hausWort = houses == 1 ? "Haus" : "Häuser"
        return "Enthält \(houses) \(hausWort) in \(gebiete.count) \(gebietWort)"
    }

    /// Health report without donor data (B11): counts only, never addresses,
    /// notes, coordinates or territory names.
    private func exportDiagnostics() async {
        isWorking = true
        defer { isWorking = false }
        var doors = 0
        var recorded = 0
        for gebiet in gebiete {
            if let tally = index.entry(for: gebiet.id)?.overall {
                doors += tally.unitCount
                recorded += tally.completed
            }
        }
        let storeURL = modelContext.container.configurations.first?.url
        let storeSizeKB = storeURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
            .map { $0 / 1024 }
        let text = DiagnosticsExport.makeText(
            counts: .init(
                territories: gebiete.count,
                houses: (try? modelContext.fetchCount(FetchDescriptor<House>())) ?? 0,
                doors: doors,
                recordedDoors: recorded
            ),
            autoBackup: autoBackup.map { AutoBackupService.describe(date: $0.date) },
            storeSizeKB: storeSizeKB,
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            model: UIDevice.current.model
        )
        do {
            route = .share(try DiagnosticsExport.writeFile(text))
        } catch {
            notices.report(error, context: "Diagnose konnte nicht erstellt werden")
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
                "\(result.importedGebiete) Gebiete, \(result.importedHouses) Häuser"
                    + (result.importedPassanten > 0 ? " und \(result.importedPassanten) Passanten" : "")
                    + " importiert."
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: AppSpacing.snug) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Gebiet, Adresse, Datum", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .accessibilityLabel("Archiv durchsuchen")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .tappable()
                .transition(.blockSwap(reduceMotion: reduceMotion))
                .accessibilityLabel("Suche löschen")
            }
        }
        .animation(.appFeedback(reduceMotion: reduceMotion), value: text.isEmpty)
        .padding(.horizontal, AppSpacing.regular)
        .frame(minHeight: AppTouch.minimum)
        .navigationGlass(cornerRadius: AppRadius.control)
        // WAVE2: focused ring, accent 1.5pt via the shared helper. Filter chips
        // keep their matched-glass morph inside FilterBar (glassEffectID).
        .selectionRing(isFocused, tint: accent, cornerRadius: AppRadius.control)
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
                // The active-territory label is retitled in place when the selection
                // changes; without this the old and the new name hard-cut.
                .contentTransition(.opacity)
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
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: GebietRowModel

    static func == (lhs: GebietRow, rhs: GebietRow) -> Bool { lhs.model == rhs.model }

    var body: some View {
        HStack(spacing: AppSpacing.snug) {
            // The rail grows out of the row's centre rather than blinking on. Two
            // rows change at once when the selection moves, so this reads as the
            // marker travelling from the old territory to the new one.
            Capsule(style: .continuous)
                .fill(accent)
                .frame(width: 4)
                .scaleEffect(y: model.isActive ? 1 : 0, anchor: .center)
                .opacity(model.isActive ? 1 : 0)

            VStack(alignment: .leading, spacing: 7) {
                FlowLayout(spacing: AppSpacing.tight) {
                    Text(model.name)
                        .font(.headline)
                        .lineLimit(2)
                    if model.isActive {
                        Label("Aktiv", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.doneTone)
                            .labelStyle(.titleAndIcon)
                            .fixedSize()
                            // WAVE2: pop on change, blockSwap kept. Bounce is RM-gated.
                            .symbolEffect(
                                .bounce,
                                options: reduceMotion ? .nonRepeating : .default,
                                value: model.isActive
                            )
                            .symbolEffectsRemoved(reduceMotion)
                            .transition(.blockSwap(reduceMotion: reduceMotion))
                    }
                    if model.isTwoDay {
                        Text("2 Tage")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }
                }

                Text([model.place, model.dateRange].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: AppSpacing.snug) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(.quaternary)
                            if model.progress > 0 {
                                Capsule(style: .continuous)
                                    .fill(model.open == 0 ? .green : accent)
                                    .frame(width: max(5, proxy.size.width * min(model.progress, 1)))
                            }
                        }
                    }
                    .frame(height: 5)
                    .animation(.appSettle(reduceMotion: reduceMotion), value: model.progress)
                    Text("\(model.completed)/\(model.total)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(model.completed)))
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
        // Only the selection is animated here. Keying the whole model would make a
        // row rebuilt by a search keystroke animate its way in, which is not a state
        // change the user made and reads as the list twitching.
        // Snappy, not smooth — long smooth leaves the glass washy.
        .animation(.appFeedback(reduceMotion: reduceMotion), value: model.isActive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.name)
        .accessibilityValue(
            "\(model.dateRange), \(model.houseCount) Häuser, \(model.completed) von \(model.total) erfasst, "
                + "\(model.open) offen, \(model.joined) dabei"
                + (model.isActive ? ", aktives Gebiet" : "")
        )
        .accessibilityAddTraits(model.isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func statLabel(systemImage: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text("\(value)")
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(value)))
        }
    }
}

// MARK: - Share sheet

/// WAVE2: card press is highlight-only at scale 1.0. The card already carries
/// `contentCard` + accent wash; scaling it tore the wash away from the glass
/// edge and from the sibling menu button. `.primary.opacity(0.08)` matches the
/// grouped-row highlight elsewhere.
private struct GebietCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .animation(.appFeedback(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct ShareSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var checkSize: CGFloat = 46
    @State private var appeared = false
    let url: URL
    /// WAVE4: „Enthält N Häuser" — Dateigröße/Seiten wären je Exportlauf neu zu
    /// messen, der Zähler dagegen steht bereits (kein Fetch).
    var subtitle: String?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: AppSpacing.regular) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: checkSize))
                    .foregroundStyle(Color.doneTone)
                    // WAVE2: icon bounce on appear, RM-gated.
                    .symbolEffect(
                        .bounce,
                        options: reduceMotion ? .nonRepeating : .default,
                        value: appeared
                    )
                    .symbolEffectsRemoved(reduceMotion)
                    .accessibilityHidden(true)
                Text("Datei erstellt")
                    .font(.headline)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Der Untertitel nennt den Inhalt, nicht die Bytes.
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(subtitle)
                }
                ShareLink(item: url) {
                    Label("Teilen oder sichern", systemImage: "square.and.arrow.up")
                        .frame(minHeight: AppTouch.minimum)
                }
                .compatGlassButton(prominent: true)
                .buttonBorderShape(.capsule)
            }
            .padding()
            .frame(maxWidth: .infinity)
            }
            .background { AppBackdrop() }
            // WAVE2: success haptic once, on presentation (a `trigger: url`
            // sensory never fires — there is no change, only an appear).
            .onAppear {
                appeared = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}
