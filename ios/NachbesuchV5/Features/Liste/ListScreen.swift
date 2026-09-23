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
    /// and every door label — on every body evaluation. The search field lives in
    /// `ListSensors`, so keystrokes never reach this body; only the debounced
    /// query rebuilds the presentation, never the corpus.
    @State private var rows: [HouseRowModel] = []
    @State private var sections: [StreetSection] = []
    @State private var counts: [ListFilter: Int] = [:]
    @State private var collapsedSections: Set<String> = []
    /// The territory the collapse state was defaulted for. Data saves rebuild
    /// the corpus constantly and must never clobber manual toggles — only a
    /// territory switch re-seeds the defaults.
    @State private var collapseDefaultsTerritory: UUID?

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
    /// While the export resolves off the main actor the button spins instead
    /// of blocking the tap on a thousand-object fault storm.
    @State private var isPreparingExport = false
    /// Street names in display order, sorted once per corpus so filtering and
    /// searching reuse it instead of re-sorting per keystroke.
    @State private var streetOrder: [String] = []
    /// Roh-Suchtext vor der Debounce: `searchText != debouncedQuery` heißt
    /// Suche läuft — trägt den Punkt in der FilterBar, sonst nichts.
    @State private var searchText = ""
    /// Faltet didSave-Bursts: nur alle 0,5 s ein Refresh, Rest verwerfen.
    /// Faul angelegt — das Gate ist Sendable (Lock), kein Isolations-Thema.
    /// Modul-intern, daher immer verfügbar, kein Fallback nötig.
    @State private var refreshGate: DidSaveRefreshGate?
    /// Letzte Voll-Seeds je Haus: Der Delta-Pfad merget Watermark-Treffer hier
    /// ein, der Cache dekodiert danach nur diese neu (Rest sind Hits).
    @State private var seedStore: [UUID: HouseListBuilder.Seed] = [:]
    /// Neuestes gesehenes `updatedAt`: Delta-Reads fragen nur danach.
    @State private var listWatermark: Date?
    /// Bumped when a filter or ordering change delivers its new sections. The
    /// list is keyed on it, so a different *set* of rows crossfades in as a whole
    /// instead of hundreds of UIKit row insertions and deletions racing each
    /// other — and it lands at the top, which is where a new filter should start.
    @State private var listGeneration = 0
    /// Set by a filter/ordering change; consumed by the next section rebuild.
    @State private var crossfadeNextSections = false
    /// Letzter Korpus-Aufbau ist fehlgeschlagen — bei leerer Liste + Gebiet +
    /// ohne Query/Filter zeigt der Empty-State einen Retry statt
    /// „Noch keine Häuser".
    @State private var corpusFailed = false

    /// Suche läuft noch (Debounce holt den Rohtext erst ein).
    private var isSearching: Bool { searchText != debouncedQuery }

    private struct PresentationTaskKey: Hashable {
        let version: Int
        let isActive: Bool
    }

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

    /// The undo banner, floating over the bottom of the list.
    ///
    /// Always installed, never `if undo { content.safeAreaBar } else { content }`:
    /// the two branches of that `if` are two different views, so every status
    /// write rebuilt the whole `List` — scroll position included — the moment the
    /// banner appeared, and again when it left. An overlay keeps the list's
    /// identity, costs no layout negotiation on iOS 18, and gives the banner a
    /// stable parent to glide in and out of.
    private struct UndoOverlayModifier: ViewModifier {
        let undo: UndoEntry?
        let reduceMotion: Bool
        let onUndo: (UndoEntry) -> Void

        func body(content: Content) -> some View {
            content.overlay(alignment: .bottom) {
                ZStack {
                    if let undo {
                        UndoBanner(label: undo.label) { onUndo(undo) }
                            .padding(.horizontal, AppSpacing.regular)
                            .padding(.bottom, AppSpacing.snug)
                            .transition(.appBanner(edge: .bottom, reduceMotion: reduceMotion))
                    }
                }
                .animation(.appSettle(reduceMotion: reduceMotion), value: undo?.id)
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
        // Filterwechsel scrollen nach oben (wie Archiv): Der Reader muss Ahn
        // aller Filter-Call-Sites sein — darum außen um den ganzen Stack.
        ScrollViewReader { proxy in
        NavigationStack {
            listContent(proxy: proxy)
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
        .onChange(of: debouncedQuery) { _, _ in recomputeSections() }
        .onChange(of: sortByDistance) { _, _ in
            crossfadeNextSections = true
            recomputeSections()
        }
        .task(id: PresentationTaskKey(version: presentationVersion, isActive: isActive)) {
            guard isActive else { return }
            await rebuildSections()
        }
        // The signal the scan was standing in for, delivered instead of hunted for.
        // Burst-Faltung per DidSaveRefreshGate: Bulk-Import speichert mehrfach
        // pro Sekunde — nur alle 0,5 s ein Refresh, Rest verwerfen.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            guard shouldRefreshList() else { return }
            dataVersion &+= 1
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

    /// Body in zwei Hälften: Basis (Suche/Bars/Titel) + Chrome (Toolbar/Sheets).
    /// Eine einzige Kette vom Surface bis zum letzten Sheet war zu komplex
    /// für den Type-Checker.
    private func listContent(proxy: ScrollViewProxy) -> some View {
        listBase(proxy: proxy)
            .toolbar {
                listToolbar(proxy: proxy)
            }
            .sheet(item: $selectedHouse) { selection in
                HouseSheetHost(id: selection.id, scope: scope, writeDay: writeDay)
            }
            .sheet(isPresented: $showsExport, onDismiss: { exportHouses = []; exportPassanten = [] }) {
                exportSheetContent
            }
            .sheet(isPresented: $showsLegend) {
                StatusLegendSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $revisitTarget) { row in
                revisitSheetContent(row: row)
            }
    }

    private func listBase(proxy: ScrollViewProxy) -> some View {
        listSurface(proxy: proxy)
            .scrollDismissesKeyboard(.interactively)
            .compatSoftScrollEdges()
            .background { AppBackdrop() }
            .background {
                // 0-pt sensors: GPS fixes and keystrokes re-evaluate this view
                // only — never the NavigationStack above it.
                ListSensors(onFix: updateSortOrigin, onQuery: { debouncedQuery = $0 }, onText: { searchText = $0 })
            }
            .compatSafeAreaBar(edge: .top, spacing: 0) {
                FilterBar(
                    chips: filterChips,
                    contextLabel: "Liste",
                    onSelect: { id in
                        guard let value = ListFilter(rawValue: id) else { return }
                        applyFilter(value, proxy: proxy)
                    },
                    isSearching: isSearching
                )
                .padding(.vertical, 6)
            }
            .modifier(
                UndoOverlayModifier(
                    undo: undo,
                    reduceMotion: reduceMotion,
                    onUndo: performUndo
                )
            )
            .navigationTitle("Nachbesuche")
            .navigationBarTitleDisplayMode(.inline)
    }

    /// One List row per street. The old version made the header row 0 and each
    /// address rows 1…n of the same Section, so every expand/collapse changed the
    /// number of UIKit rows *and* flipped the header background from rounded-all
    /// to rounded-top. Animating those two things independently is the
    /// Kantenkatastrophe: a transient pill, a clipped bottom edge, a seam across
    /// the middle while rows recycle. Now the List structure never changes —
    /// one row per street, always rounded on all four corners, always the same
    /// glossy material — and only the height of that row's inner VStack animates.
    /// Der Reader kommt vom Body: Filterwechsel scrollen darüber nach oben.
    private func listSurface(proxy: ScrollViewProxy) -> some View {
        List {
            // Ohne Fix gibt es keine Distanzen — Straßen-Gruppierung bleibt,
            // Hinweiszeile erklärt, warum keine Meter dabeistehen.
            if sortByDistance, sortOrigin == nil {
                Text("Standort wird gesucht…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityLabel("Standort wird gesucht")
            }
            if sections.isEmpty {
                emptyState(proxy: proxy)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ForEach(sections) { section in
                    let isExpanded = !collapsedSections.contains(section.id)
                    Section {
                        StreetCard(
                            section: section,
                            isExpanded: isExpanded,
                            now: clock,
                            onToggle: { toggleSection(section.id) },
                            onOpen: { openHouse($0) },
                            onJumpTop: { proxy.scrollTo(section.id, anchor: .top) }
                        )
                        .listRowBackground(
                            SectionSurface(isFirst: true, isLast: true)
                        )
                        .listRowSeparator(.hidden)
                    }
                    .listRowInsets(EdgeInsets(top: StreetCardMetrics.verticalInset, leading: AppLayout.rowInset,
                                              bottom: StreetCardMetrics.verticalInset, trailing: AppLayout.rowInset))
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(AppSpacing.regular)
        .scrollContentBackground(.hidden)
        .id(listGeneration)
        .transition(.opacity)
        // iPad/landscape: insetGrouped liefe sonst über die volle Breite —
        // Doppel-Frame engt auf 700 pt ein und zentriert (außen infinity).
        // Harmlos am iPhone (schmaler als 700), Hintergrund bleibt AppBackdrop.
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
    }

    // MARK: Corpus

    /// Faltet didSave-Bursts zu einem Refresh (0,5-s-Gate, siehe PendingSave).
    /// Faul angelegt, synchron aufrufbar — das Gate ist Lock-geschützt.
    private func shouldRefreshList(now: Date = .now) -> Bool {
        if refreshGate == nil { refreshGate = DidSaveRefreshGate() }
        return refreshGate?.shouldRefresh(now: now) ?? true
    }

    private func rebuildCorpus() async {
        let key = corpusKey
        guard let territoryID = gebiet?.id else {
            rows = []
            sections = []
            counts = [:]
            streetOrder = []
            collapseDefaultsTerritory = nil
            seedStore = [:]
            listWatermark = nil
            corpusFailed = false
            rowCache = HouseListCache()
            recomputeSections()
            builtCorpusKey = key
            return
        }
        let reader = await HouseReadService.background(container: modelContext.container)
        // Delta-Pfad: gleiches Gebiet + Scope wie der letzte Aufbau und ein
        // Watermark vorhanden → nur geänderte Häuser lesen und in den
        // Seed-Store patchen. Der Cache dekodiert danach nur diese neu, der
        // Rest sind Hits — kein Voll-Refetch pro Tür-Tap. Ehrliche Grenze:
        // Löschungen trägt kein Watermark — ein gelöschtes Haus fällt erst
        // beim nächsten Vollaufbau (Gebiets-/Scopewechsel) raus.
        if let since = listWatermark,
           let built = builtCorpusKey,
           built.territoryID == key.territoryID,
           built.scope == key.scope {
            let deltas: [HouseListDelta]
            do {
                deltas = try await reader.listSeeds(territoryID: territoryID, updatedAfter: since)
            } catch is CancellationError {
                return
            } catch {
                notices.report(error, context: "Liste konnte nicht gelesen werden")
                corpusFailed = true
                return
            }
            guard !Task.isCancelled else { return }
            guard !deltas.isEmpty else {
                // Nichts geändert: Schlüssel übernehmen, Ansicht unangetastet.
                builtCorpusKey = key
                return
            }
            let currentScope = scope
            let previousCache = rowCache
            var store = seedStore
            for delta in deltas { store[delta.seed.id] = delta.seed }
            let watermark = deltas.map(\.updatedAt).max() ?? since
            // Als Let für die sendable Build-Closure (fängt keine Var).
            let merged = store
            let buildTask = Task.detached(priority: .userInitiated) {
                var cache = previousCache
                let builtRows = try cache.update(Array(merged.values), scope: currentScope)
                let newCounts = HouseListBuilder.counts(for: builtRows)
                let order = HouseListBuilder.sortedStreetOrder(Array(Set(builtRows.map(\.street))))
                return (cache, builtRows, newCounts, order)
            }
            do {
                let (cache, builtRows, newCounts, order) = try await withTaskCancellationHandler {
                    try await buildTask.value
                } onCancel: {
                    buildTask.cancel()
                }
                guard !Task.isCancelled, key == corpusKey else { return }
                seedStore = merged
                listWatermark = watermark
                rowCache = cache
                rows = builtRows
                counts = newCounts
                streetOrder = order
                corpusFailed = false
                recomputeSections()
            } catch is CancellationError {
                return
            } catch {
                notices.report(error, context: "Liste konnte nicht aufgebaut werden")
                corpusFailed = true
                return
            }
            builtCorpusKey = key
            return
        }
        // Vollpfad (erster Aufbau, Gebiets- oder Scopewechsel): Das Watermark
        // ist der Lesestart — was danach schreibt, fängt das nächste Delta.
        let started = Date.now
        let seeds: [HouseListBuilder.Seed]
        do {
            seeds = try await reader.listSeeds(territoryID: territoryID)
        } catch is CancellationError {
            return
        } catch {
            notices.report(error, context: "Liste konnte nicht gelesen werden")
            corpusFailed = true
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
            let order = HouseListBuilder.sortedStreetOrder(Array(Set(built.map(\.street))))
            return (cache, built, counts, collapsed, order)
        }
        do {
            let (cache, built, newCounts, collapsed, order) = try await withTaskCancellationHandler {
                try await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }
            guard !Task.isCancelled, key == corpusKey else { return }
            seedStore = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, $0) })
            listWatermark = started
            rowCache = cache
            rows = built
            counts = newCounts
            streetOrder = order
            corpusFailed = false
            if let collapsed {
                collapsedSections = collapsed
                collapseDefaultsTerritory = territoryID
            }
            recomputeSections()
        } catch is CancellationError {
            return
        } catch {
            notices.report(error, context: "Liste konnte nicht aufgebaut werden")
            corpusFailed = true
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
        // Genau eine Selection-Haptik beim Öffnen, nicht via Trigger: Ein
        // `.sensoryFeedback`-Trigger auf der Selection würde auch beim Schließen
        // (→ nil) erneut feuern. Generator = nur auf, nie zu.
        UISelectionFeedbackGenerator().selectionChanged()
        selectedHouse = HouseSelection(id: id)
    }

    /// Export prep leaves the tap transaction immediately. IDs resolve off the
    /// main actor, the button spins meanwhile, and the live models the sheet
    /// needs fault in inside the Task — never synchronously on the tap.
    private func prepareExport() {
        guard let territoryID = gebiet?.id, !isPreparingExport else { return }
        isPreparingExport = true
        Task {
            let reader = await HouseReadService.background(container: modelContext.container)
            let ids: (houses: [UUID], passanten: [UUID])
            do {
                ids = try await reader.exportIDs(territoryID: territoryID)
            } catch is CancellationError {
                isPreparingExport = false
                return
            } catch {
                notices.report(error, context: "Export konnte nicht vorbereitet werden")
                isPreparingExport = false
                return
            }
            guard !Task.isCancelled else {
                isPreparingExport = false
                return
            }
            do {
                // Live models must come from this view's context — the background
                // read only decided *which* ones, so the tap never waits on the
                // fault storm itself.
                let houseIDs = ids.houses
                let passantIDs = ids.passanten
                exportHouses = houseIDs.isEmpty ? [] : try modelContext.fetch(
                    FetchDescriptor<House>(predicate: #Predicate { houseIDs.contains($0.id) })
                )
                exportPassanten = passantIDs.isEmpty ? [] : try modelContext.fetch(
                    FetchDescriptor<Passant>(predicate: #Predicate { passantIDs.contains($0.id) })
                )
                isPreparingExport = false
                showsExport = true
            } catch {
                notices.report(error, context: "Export konnte nicht vorbereitet werden")
                isPreparingExport = false
            }
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
        let order = streetOrder
        let built = await offMainActor {
            HouseListBuilder.presentedSections(rows: currentRows, filter: currentFilter,
                                               query: query, origin: origin, streetOrder: order)
        }
        guard !Task.isCancelled, version == presentationVersion else { return }
        if crossfadeNextSections {
            // A new filter or ordering: the old rows fade out as one, the new
            // ones fade in as one, starting at the top.
            crossfadeNextSections = false
            withAnimation(.appFeedback(reduceMotion: reduceMotion)) {
                listGeneration &+= 1
                sections = built
            }
        } else {
            // Data changes (a status written elsewhere, a keystroke) swap in
            // place without row animations: the rows are the same rows, and a
            // list re-sorting itself under the thumb is not something to animate.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { sections = built }
        }
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
        // Haptic on the tap itself. It used to be a `sensoryFeedback` trigger on
        // `collapsedSections`, which also buzzed when a territory loaded and
        // seeded its default collapse state — a tap the user never made.
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.appExpand(reduceMotion: reduceMotion)) {
            if collapsedSections.contains(id) { collapsedSections.remove(id) }
            else { collapsedSections.insert(id) }
        }
    }

    /// Filterwechsel: the chip moves at once (FilterBar owns that animation);
    /// the rows follow as one crossfade when the new sections are ready, and the
    /// new list starts at the top. No scroll animation racing a data swap.
    private func applyFilter(_ value: ListFilter, proxy _: ScrollViewProxy) {
        // Haptik besitzt die FilterBar (`selection` auf selectedID) — hier kein
        // zweiter Trigger, sonst brummt jeder Chipwechsel doppelt.
        guard filter != value else { return }
        filter = value
        crossfadeNextSections = true
        recomputeSections()
    }

    private func setAllStreets(expanded: Bool) {
        // One selection haptic per bulk tap, from the tap (see toggleSection).
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.appExpand(reduceMotion: reduceMotion)) {
            if expanded {
                collapsedSections.removeAll()
            } else {
                collapsedSections.formUnion(sections.map(\.id))
            }
        }
    }

    /// Toolbar-Menü zerlegt: Der einzeilige Menu-Block mit Section+ForEach+
    /// Picker+Divider+Disabled-Logik war zu komplex für den Type-Checker.
    private func listMenu(proxy: ScrollViewProxy) -> some View {
        Menu {
            listFilterMenuSection(proxy: proxy)
            Button("Statuslegende", systemImage: "questionmark.circle") { showsLegend = true }
            listOrderMenuSection
            Divider()
            listBulkMenuSection
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
    }

    /// Toggles, so the current filter gets the same leading checkmark beside its own
    /// icon that the order picker below draws. The hand-rolled buttons swapped the
    /// selected filter's icon *for* a checkmark instead, so one menu showed
    /// selection two different ways. Not a `Picker`: inside a menu that swallows
    /// the section's "Filter" header.
    private func listFilterMenuSection(proxy: ScrollViewProxy) -> some View {
        Section {
            ForEach(ListFilter.allCases) { value in
                Toggle(isOn: Binding(
                    get: { filter == value },
                    set: { isOn in if isOn { applyFilter(value, proxy: proxy) } }
                )) {
                    Label(value.title, systemImage: value.systemImage)
                }
            }
        } header: {
            Text("Filter")
        }
    }

    private var listOrderMenuSection: some View {
        Picker("Reihenfolge", selection: $sortByDistance) {
            Label("Offene zuerst", systemImage: "arrow.up.arrow.down").tag(false)
            Label("Nächste zuerst", systemImage: "location").tag(true)
        }
    }

    private var listBulkMenuSection: some View {
        Group {
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
            .disabled(listBulkCloseDisabled)
        }
    }

    private var listBulkCloseDisabled: Bool {
        sections.isEmpty || sections.allSatisfy { collapsedSections.contains($0.id) }
    }

    @ToolbarContentBuilder
    private func listToolbar(proxy: ScrollViewProxy) -> some ToolbarContent {
        if gebiet?.isTwoDay == true {
            ToolbarItem(placement: .principal) {
                DayScopePicker(scope: $scope)
                    .frame(maxWidth: 240)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            listMenu(proxy: proxy)
                .accessibilityLabel("Filter und Reihenfolge")
        }
        ToolbarItem(placement: .topBarTrailing) {
            exportToolbarButton
        }
    }

    private var exportToolbarButton: some View {
        Button {
            prepareExport()
        } label: {
            exportToolbarIcon
        }
        .disabled(gebiet == nil || isPreparingExport)
        .accessibilityLabel("Gebiet exportieren")
    }

    @ViewBuilder
    private var exportToolbarIcon: some View {
        if isPreparingExport {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "square.and.arrow.up")
        }
    }

    @ViewBuilder
    private var exportSheetContent: some View {
        if let gebiet {
            ExportSheet(gebiet: gebiet, houses: exportHouses, passanten: exportPassanten, scope: scope)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func revisitSheetContent(row: HouseRowModel) -> some View {
        RevisitTimeSheet(
            subject: row.address,
            existing: row.nextRevisitAt
        ) { date in
            applyQuickStatus(.later, to: row, revisitAt: date)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var filterChips: [FilterChip] {
        let primary: [ListFilter] = [.all, .open] + ((counts[.later] ?? 0) > 0 || filter == .later ? [.later] : [])
        let visible = primary.contains(filter) ? primary : primary + [filter]
        return visible.map { value in
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

    /// Präfix-Vorschlag bei Leer-Treffern: erste 3 gefaltete Zeichen gegen die
    /// Straßenreihenfolge — fängt Umlaut-/Tippfehler-Anfänge ("modl"→"Mödling").
    /// Nur Hinweis-Text: Tappen bräuchte das Search-Binding der Sensoren.
    private func suggestedStreet(for query: String) -> String? {
        let gefaltet = SearchText.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard gefaltet.count >= 2 else { return nil }
        let prefix = String(gefaltet.prefix(3))
        return streetOrder.first { SearchText.fold($0).hasPrefix(prefix) }
    }

    @ViewBuilder
    private func emptyState(proxy: ScrollViewProxy) -> some View {
        // Ladefehler zuerst: leere Liste trotz Gebiet, ohne Query und Filter —
        // dann erklärt kein Filter die Leere, nur ein Retry hilft.
        if corpusFailed, rows.isEmpty, gebiet != nil, debouncedQuery.isEmpty, filter == .all {
            ContentUnavailableView {
                Label("Konnte nicht laden", systemImage: "arrow.clockwise")
            } description: {
                Text("Die Liste konnte nicht gelesen werden.")
            } actions: {
                Button("Erneut versuchen") {
                    corpusFailed = false
                    // Gate zurücksetzen, sonst schluckt es den Folge-Refresh
                    // nach Retry als Burst-Rauschen.
                    refreshGate?.reset()
                    dataVersion &+= 1
                }
                .compatGlassButton(prominent: true)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Erneut versuchen")
                .accessibilityHint("Lädt die Liste neu")
            }
            .accessibilityLabel("Konnte nicht laden. Erneut versuchen.")
        // Driven by the debounced query, so the message and the list can never
        // disagree about what was searched for. Natives `.searchable` besitzt den
        // eigenen Löschknopf — kein Custom-Clear wie im Archiv nötig; Tastatur
        // schließt per `scrollDismissesKeyboard(.interactively)` am List-Surface.
        } else if !debouncedQuery.isEmpty {
            VStack(spacing: AppSpacing.snug) {
                ContentUnavailableView.search(text: debouncedQuery)
                // Präfix-Rettung bei Tippfehlern/Umlauten ("modl"→"Mödling").
                if let vorschlag = suggestedStreet(for: debouncedQuery) {
                    Text("Meintest du „\(vorschlag)“?")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Meintest du \(vorschlag)?")
                }
                // Nur wenn ein Filter die Suche zusätzlich einengt: Vorschlag, ihn
                // zu lösen, statt leer dazustehen.
                if filter != .all {
                    Button("Filter zurücksetzen") { applyFilter(.all, proxy: proxy) }
                        .compatGlassButton()
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel("Filter zurücksetzen")
                        .accessibilityHint("Zeigt wieder alle Adressen")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Keine Treffer für \(debouncedQuery)")
        } else {
            ContentUnavailableView {
                // No bounce: the list already crossfades to this state, and a
                // second motion on arrival says nothing the first did not.
                Label(filter.emptyTitle, systemImage: filter.systemImage)
            } description: {
                Text(filter.emptyMessage)
            } actions: {
                if filter != .all {
                    Button("Filter zurücksetzen") { applyFilter(.all, proxy: proxy) }
                        .compatGlassButton(prominent: true)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel("Filter zurücksetzen")
                        .accessibilityHint("Zeigt wieder alle Adressen")
                }
            }
            .accessibilityLabel("\(filter.emptyTitle). \(filter.emptyMessage)")
        }
    }
}

// MARK: - Sensors & sheet host

/// 0-pt views living inside the NavigationStack so the screen itself never
/// subscribes to high-frequency signals.
///
/// Reading `location.location` or the search field in `ListScreen.body` would
/// re-evaluate the whole NavigationStack per GPS fix and per keystroke. Here
/// only this empty view re-evaluates; the screen sees the debounced query and
/// a 25 m-gated origin through callbacks.
private struct ListSensors: View {
    @Environment(LocationService.self) private var location
    let onFix: (CLLocationCoordinate2D?) -> Void
    let onQuery: (String) -> Void
    /// Meldet jeden Rohtext sofort — der Screen vergleicht gegen die Debounce
    /// und zeigt solange den Such-Punkt in der FilterBar.
    let onText: (String) -> Void
    @State private var searchText = ""

    var body: some View {
        Color.clear
            .frame(height: 0)
            .searchable(text: $searchText, prompt: "Adresse, Notiz oder Tür")
            .compatMinimizedSearch()
            .allowsHitTesting(false)
            .onChange(of: location.location) { _, fix in onFix(fix?.coordinate) }
            .onChange(of: searchText) { _, new in onText(new) }
            .task(id: searchText) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                onQuery(searchText)
            }
    }
}

/// Resolves the tapped address after presentation, never inside its
/// transaction: the sheet starts moving on the tap, the live model faults in
/// behind it.
///
/// The spinner placeholder used to be swapped for the form mid-transition — a
/// flash of "wird geöffnet …" on every tap, for a fetch that takes a millisecond.
/// The placeholder is now empty glass that the form fades into; a spinner appears
/// only if resolving is genuinely slow.
///
/// No zoom transition out of the row: the sheet rests at the medium detent with
/// the list still in view, and a zoom source stays hidden for as long as its
/// sheet is up — the tapped address left a blank gap in its street card.
private struct HouseSheetHost: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppNoticeCenter.self) private var notices
    let id: UUID
    let scope: DayScope
    let writeDay: Int
    @State private var house: House?
    @State private var didResolve = false
    @State private var isSlow = false

    var body: some View {
        ZStack {
            if let house {
                HouseDetailSheet(house: house, scope: scope, writeDay: writeDay)
                    .transition(.opacity)
            } else if didResolve {
                ContentUnavailableView {
                    Label("Adresse nicht gefunden", systemImage: "questionmark.circle")
                } description: {
                    Text("Sie wurde möglicherweise gelöscht.")
                }
                .transition(.opacity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .overlay {
                        if isSlow {
                            ProgressView("Adresse wird geöffnet …")
                                .transition(.opacity)
                        }
                    }
                    .compatSheetGlass()
            }
        }
        .animation(.appFeedback(reduceMotion: reduceMotion), value: didResolve)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: isSlow)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: id) {
            let houseID = id
            var descriptor = FetchDescriptor<House>(predicate: #Predicate { $0.id == houseID })
            descriptor.fetchLimit = 1
            do {
                house = try modelContext.fetch(descriptor).first
            } catch {
                notices.report(error, context: "Haus konnte nicht geöffnet werden")
            }
            didResolve = true
        }
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, !didResolve else { return }
            isSlow = true
        }
    }
}

// MARK: - Row

private struct HouseRow: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                OpenCountBadge(count: row.openCount)
            }

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        // The row draws the number; VoiceOver still gets the whole address, because
        // "6" on its own is not an address to someone who cannot see the street
        // header above it.
        // Kein "Später buchen"-Action an der Zeile: Row ist reiner Wert ohne
        // House-Modell — Buchung braucht Fetch+Sheet am Screen. Öffnet-Hint bleibt.
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
            // Puls nur bei überfällig — und nur einmal beim Erscheinen: Dauerpuls
            // auf 200 Zeilen wäre Flackern, kein Signal. Ohne Reduce Motion.
            Group {
                if glance.urgency == .overdue {
                    Image(systemName: glance.systemImage)
                        .symbolEffect(.pulse, options: .nonRepeating)
                        .symbolEffectsRemoved(reduceMotion)
                } else {
                    Image(systemName: glance.systemImage)
                }
            }
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

/// Rote Offen-Badge. Static on purpose: list data swaps in place without
/// animation, so a count "pop" only ever fired on rows the user was not
/// looking at — the one moment an animation can only distract.
private struct OpenCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.red)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(StatusChipFill(.red), in: Capsule())
            .accessibilityHidden(true)
    }
}

// MARK: - Street card (one List row per street)

/// Geometry the street card and its press highlights share.
private enum StreetCardMetrics {
    /// The list row's top/bottom inset — card edge to header content.
    static let verticalInset: CGFloat = 11
    /// Header content to the hairline under it when the street is open.
    static let headerToHairline: CGFloat = 7
    /// How far an address highlight reaches past the row's content.
    static let rowOutset = CGSize(width: 8, height: 6)
}

/// Street header press: highlights the header's slice of the card, edge to edge.
///
/// Highlight only, never scale — the header shares one glass surface with its
/// addresses, and scaling would tear it away from them. The highlight used to be
/// a card-radius shape drawn on the *inset* header content, so it floated inside
/// the card as a smaller blob with corners that matched nothing. It now reaches
/// out to the card's edges (and down to the hairline when the street is open), so
/// its corners are the card's corners.
private struct StreetHeaderPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isExpanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                sectionShape(isFirst: true, isLast: !isExpanded)
                    .fill(.primary.opacity(configuration.isPressed ? PressHighlight.opacity : 0))
                    .padding(.horizontal, -AppLayout.rowInset)
                    .padding(.top, -StreetCardMetrics.verticalInset)
                    .padding(.bottom, isExpanded ? -StreetCardMetrics.headerToHairline : -StreetCardMetrics.verticalInset)
                    .allowsHitTesting(false)
            }
            .animation(.appPress(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Address press: a rounded pill a little larger than the row, concentric with
/// the card around it.
///
/// It used to be exactly the size of the row's content, so the highlight touched
/// the glyph and the chevron and read as a box drawn around the text. Behind the
/// content, not over it, so the text never greys under the finger.
private struct AddressRowPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(
                    cornerRadius: AppRadius.card - StreetCardMetrics.rowOutset.width,
                    style: .continuous
                )
                .fill(.primary.opacity(configuration.isPressed ? PressHighlight.opacity : 0))
                .padding(.horizontal, -StreetCardMetrics.rowOutset.width)
                .padding(.vertical, -StreetCardMetrics.rowOutset.height)
                .allowsHitTesting(false)
            }
            .animation(.appPress(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Press for the paging pills ("Weitere anzeigen", "Nach oben"): the highlight
/// lies over the pill's own fill, in the pill's own shape.
private struct PanelPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? PressHighlight.opacity : 0))
                    .allowsHitTesting(false)
            }
            .animation(.appPress(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Header + Adressen in einer Listenzelle hinter einer glänzenden Fläche.
/// Höhe animiert, Ecken nicht: Hintergrund bleibt rounded-all, nur das innere
/// VStack wächst — kein Frame zeigt je eine eckige Kante mid-motion.
private struct StreetCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Windowing page size. A street with 100+ addresses must not build 100+
    /// HouseRows eagerly on first layout — the scroll pays for all of them.
    private static let pageSize = 30
    let section: StreetSection
    let isExpanded: Bool
    let now: Date
    let onToggle: () -> Void
    let onOpen: (UUID) -> Void
    /// Scroll zum Sektionskopf — Closure vom Außen-Reader aus listSurface,
    /// kein eigener ScrollViewReader (der säße unter der List und fände nichts).
    let onJumpTop: () -> Void
    @State private var visibleCount = Self.pageSize

    private var clipRoom: EdgeInsets {
        let outset = StreetCardMetrics.rowOutset
        return EdgeInsets(top: 0, leading: outset.width, bottom: outset.height, trailing: outset.width)
    }

    private var clipRoomReturned: EdgeInsets {
        EdgeInsets(top: -clipRoom.top, leading: -clipRoom.leading,
                   bottom: -clipRoom.bottom, trailing: -clipRoom.trailing)
    }

    var body: some View {
        VStack(spacing: 0) {
            // VoiceOver: Button trägt Label+Value ("erweitert/reduziert")+Hint —
            // das IST die Aktion, kein Rotor nötig. Verifiziert: traits .isHeader.
            Button(action: onToggle) {
                StreetHeader(section: section, isExpanded: isExpanded)
                    // 44 pt Trefferfläche ohne Optik-Bruch: minHeight statt fix.
                    .frame(minHeight: AppTouch.minimum)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
            }
            // Not `.plain`: that has no press state. Highlight only, in the card's
            // own corners — all round when shut, top only when open.
            .buttonStyle(StreetHeaderPressStyle(isExpanded: isExpanded))
            .accessibilityLabel("Straße \(section.title)")
            // SwiftUI kennt kein .isExpanded-Trait — der Zustand wandert darum
            // ins Value: „erweitert"/„reduziert" wird mit angesagt.
            .accessibilityValue("\(section.houseCount) Adressen, \(section.openCount) Türen offen, \(isExpanded ? "erweitert" : "reduziert")")
            .accessibilityHint(isExpanded ? "Blendet die Adressen aus" : "Blendet die Adressen ein")
            .accessibilityAddTraits(.isHeader)

            if isExpanded, !section.rows.isEmpty {
                // One page over the cap, never a full enumerated copy: the rest
                // pages in on tap.
                let visible = Array(section.rows.prefix(visibleCount))
                let lastID = visible.last?.id
                VStack(spacing: 0) {
                    // Hairline between header and first address, inset to the text
                    // column like a native grouped separator — not a second
                    // container edge, so no seam can appear mid-card.
                    Rectangle()
                        .fill(.separator)
                        .frame(height: 0.5)
                        .padding(.leading, AppLayout.glyphColumn + AppLayout.glyphGap)
                        .padding(.top, StreetCardMetrics.headerToHairline)
                    ForEach(visible) { row in
                        Button { onOpen(row.id) } label: {
                            // The clock only reaches rows with a booked time:
                            // timeless rows keep a fixed date, so the 30 s tick
                            // never rebuilds them.
                            HouseRow(row: row, now: row.nextRevisitAt == nil ? .distantPast : now)
                                .equatable()
                                .frame(maxWidth: .infinity, minHeight: AppTouch.minimum, alignment: .leading)
                                .contentShape(.rect)
                        }
                        // Highlight, never scale: rows share one surface, and a
                        // scaled row would tear its edge away from its neighbours.
                        .buttonStyle(AddressRowPressStyle())
                        .padding(.top, 11)
                        .padding(.bottom, row.id == lastID ? 4 : 11)
                        .overlay(alignment: .bottom) {
                            if row.id != lastID {
                                Rectangle()
                                    .fill(.separator)
                                    .frame(height: 0.5)
                                    .padding(.leading, AppLayout.glyphColumn + AppLayout.glyphGap)
                            }
                        }
                    }
                    if section.rows.count > visible.count {
                        Button {
                            withAnimation(.appExpand(reduceMotion: reduceMotion)) {
                                visibleCount += Self.pageSize
                            }
                        } label: {
                            // Volle Breite, 44 pt, Pillen-Panel mit Chevron: fühlt
                            // sich an wie Inhalt, nicht wie System-Kleingedrucktes.
                            HStack(spacing: 6) {
                                Text("Weitere \(section.rows.count - visible.count) anzeigen")
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: AppTouch.minimum)
                            .contentPanel()
                            .contentShape(.rect)
                        }
                        .buttonStyle(PanelPressStyle())
                        .accessibilityLabel("Weitere \(section.rows.count - visible.count) Adressen anzeigen")
                        .accessibilityHint("Zeigt mehr Adressen dieser Straße")
                    }
                    // Nach 2× Paging (>60): faltet das Windowing ein und springt
                    // per Außen-Proxy zum Kopf — sonst scrollt man ewig zurück.
                    if visibleCount > Self.pageSize * 2 {
                        Button {
                            // Scroll first, then fold: folding 60+ rows while the
                            // list scrolls makes the scroll target move under it.
                            withAnimation(.appSettle(reduceMotion: reduceMotion)) {
                                onJumpTop()
                            } completion: {
                                withAnimation(.appExpand(reduceMotion: reduceMotion)) {
                                    visibleCount = Self.pageSize
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("Nach oben")
                                Image(systemName: "arrow.up")
                                    .font(.caption2.weight(.bold))
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: AppTouch.minimum)
                            .contentPanel()
                            .contentShape(.rect)
                        }
                        .buttonStyle(PanelPressStyle())
                        .accessibilityLabel("Nach oben springen")
                        .accessibilityHint("Zeigt wieder die ersten Adressen dieser Straße")
                    }
                }
                // Opacity only: a slide/move here would drag text over the rounded
                // corners mid-height-animation. Clipped so fading rows never poke
                // outside the glass while the row grows. Arriving rows fade in
                // slightly behind the height so the card opens *then* fills;
                // leaving rows fade out fast so they never outlive their room.
                .transition(
                    AnyTransition.asymmetric(
                        insertion: AnyTransition.opacity.animation(
                            .appExpand(reduceMotion: reduceMotion).delay(reduceMotion ? 0 : 0.06)
                        ),
                        removal: AnyTransition.opacity.animation(.easeOut(duration: 0.14))
                    )
                )
                // The clip is widened by the address highlight's outset (and
                // handed back as negative padding, so layout is unchanged):
                // clipped at the content edge, a pressed row's pill lost its
                // rounded ends and the last row's lost its bottom.
                .padding(clipRoom)
                .clipped()
                .padding(clipRoomReturned)
            }
        }
        .animation(.appExpand(reduceMotion: reduceMotion), value: isExpanded)
        // Ein Paging-Tap = eine Selection-Haptik. Kein zweiter Trigger auf
        // demselben Wert: withAnimation oben trägt keine Haptik.
        .sensoryFeedback(.selection, trigger: visibleCount)
    }
}

// MARK: - Street header

private struct StreetHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let section: StreetSection
    let isExpanded: Bool
    /// Feuert die Success-Haptik genau einmal pro Fertigstellung: `sensoryFeedback`
    /// auf `isDone` würde auch beim Wiederöffnen (true→false) brummen.
    @State private var celebrateToken = 0

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
        // Accessibility sizes always take the stacked layout: laying out all
        // candidates per header (ViewThatFits) costs 3x on this screen.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedLayout
                    .contentShape(.rect)
            } else {
                // Both candidates used to be `HStack`s. When neither fits, `ViewThatFits`
                // takes the last one and lets it overflow — at accessibility sizes the
                // progress column was clipped off the right edge mid-digit. The stacked
                // variant is a layout that always fits, so there is a real last resort.
                ViewThatFits(in: .horizontal) {
                    headerLayout(compact: true)
                    headerLayout(compact: false)
                }
                .contentShape(.rect)
            }
        }
        // Success nur bei false→true: Token steigt nur beim Fertigwerden, nie
        // beim Wiederöffnen. Balken selbst bleibt stumm (appSettle ohne Haptik).
        .sensoryFeedback(.success, trigger: celebrateToken)
        .onChange(of: isDone) { _, done in
            guard done else { return }
            celebrateToken &+= 1
        }
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
            } else {
                // "Türen", not a bare "offen": beside "11 Adressen" a bare
                // "18 offen" read as eighteen open out of eleven addresses.
                Text("\(section.openCount) \(section.openCount == 1 ? "Tür" : "Türen") offen")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(stateTint)
                    .lineLimit(1)
                    // AX5 schrumpft statt zu clippen; ohne ScaleFactor frisst die
                    // einzeilige Zahl den Balken daneben.
                    .minimumScaleFactor(0.7)
            }
        }
        // No animation modifiers here: sections arrive in a transaction that
        // disables animations (data swaps in place), so every morph, bounce and
        // celebrate that used to sit on this header was either dead weight per
        // row or fired on a row off screen. The completion haptic still lands.
    }

    /// A hand-drawn capsule rather than `ProgressView`: the system bar draws its
    /// track at a hairline the tinted fill dwarfs, so a nearly-empty street looked
    /// identical to one with no doors at all. Here the track is always visible and
    /// the fill keeps a rounded stub as soon as there is any progress at all.
    private func progressBar(width: CGFloat) -> some View {
        ProgressTrack(progress: section.progress, fill: stateTint)
            .frame(width: width)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            // Rotation only, on the same expand curve as the card: the chevron
            // points where the content goes, and moves exactly as far as it does.
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
            .animation(.appExpand(reduceMotion: reduceMotion), value: isExpanded)
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
            // Synthetik ("Nächste zuerst"/"Nach Uhrzeit") mischt Straßen und
            // Filter — Balken täuschte Straßen-Fortschritt vor, darum nur Zahl.
            // Untertitel mit Adresszahl bleibt immer (irreführungsfrei).
            VStack(alignment: .trailing, spacing: 5) {
                counter
                if !section.isSynthetic {
                    progressBar(width: barWidth)
                }
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
                // Fixed width, no GeometryReader: one layout pass per street
                // instead of a measuring pass each.
                // Wie oben: kein Balken in Synthetik-Sektionen.
                if !section.isSynthetic {
                    progressBar(width: barWidth)
                }
                Spacer(minLength: 0)
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
    /// Restzeit 1→0: läuft linear 5 s wie der Dismiss-Task des Parents.
    @State private var remaining: CGFloat = 1

    var body: some View {
        // Two sibling glass shapes in one container. Nesting the button inside a
        // glass panel prevents Liquid Glass from sampling the content correctly.
        CompatGlassContainer(spacing: AppSpacing.tight) {
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.tight) {
                    HStack(spacing: AppSpacing.snug) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.doneTone)
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
                // Countdown-Balken: linear 5 s auf 0. Ohne Reduce Motion schrumpft
                // die Breite, mit nur die Deckkraft — reine Optik, Dismiss bleibt
                // beim Parent-Task.
                Capsule(style: .continuous)
                    .fill(.secondary.opacity(0.5))
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .scaleEffect(x: reduceMotion ? 1 : remaining, y: 1, anchor: .leading)
                    .opacity(reduceMotion ? Double(remaining) : 1)
            }
        }
        // Glass entry to go with the banner slide the parent applies: without
        // it the panel fades its contents but never its material.
        .standaloneGlassTransition(reduceMotion: reduceMotion)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gespeichert: \(label)")
        .accessibilityAction(named: "Rückgängig") { action() }
        .onAppear { startTimer() }
        .onChange(of: label) { _, _ in startTimer() }
    }

    /// Startet die 5-s-Animation neu — auch bei neuem Undo im selben Banner.
    private func startTimer() {
        remaining = 1
        withAnimation(
            reduceMotion ? .easeOut(duration: 0.2) : .linear(duration: 5)
        ) { remaining = 0 }
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
                .glassRows()
                Section("Gesten") {
                    Label("Tippen öffnet die Details", systemImage: "hand.tap")
                }
                .glassRows()
            }
            .listStyle(.insetGrouped)
            .glassForm()
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
