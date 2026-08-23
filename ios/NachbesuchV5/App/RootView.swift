import SwiftData
import SwiftUI

enum AppTab: Hashable {
    case map, list, archive
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppNoticeCenter.self) private var notices

    @Query(sort: \Gebiet.day1Date, order: .reverse) private var gebiete: [Gebiet]
    @Query(sort: \CampaignDay.date, order: .reverse) private var legacyDays: [CampaignDay]

    @AppStorage("migration.legacyDaysToGebiete.v3") private var didMigrateLegacyDays = false
    /// Distinguishes "brand new install" from "the user deliberately deleted
    /// everything". Only the first justifies creating a territory unasked.
    @AppStorage("didCreateFirstGebiet") private var didCreateFirstGebiet = false

    /// Persisted: the territory you were working in is part of "where I left off",
    /// exactly like the map camera. Keeping it in view state meant every relaunch
    /// silently reset it to whichever territory happened to sort first.
    @AppStorage("selectedGebietID") private var selectedGebietIDString = ""
    @AppStorage("appearance.mode") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("appearance.accent") private var accentRaw = AppAccent.volkshilfe.rawValue

    private var selectedGebietID: UUID? {
        get { UUID(uuidString: selectedGebietIDString) }
        nonmutating set { selectedGebietIDString = newValue?.uuidString ?? "" }
    }

    private var selectedGebietBinding: Binding<UUID?> {
        Binding(get: { selectedGebietID }, set: { selectedGebietID = $0 })
    }
    @State private var scope: DayScope = .combined
    /// One instance for the whole app: the map and the list both need position,
    /// and two services would mean two GPS sessions.
    @State private var location = LocationService()

    @State private var tab: AppTab = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["NACHBESUCH_TAB"] {
        case "list": return .list
        case "archive": return .archive
        default: return .map
        }
        #else
        return .map
        #endif
    }()

    private var accentColor: Color {
        (AppAccent(rawValue: accentRaw) ?? .volkshilfe).color
    }

    private var selectedGebiet: Gebiet? {
        gebiete.first { $0.id == selectedGebietID } ?? gebiete.first
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Karte", systemImage: "map.fill", value: AppTab.map) {
                MapScreen(
                    gebiet: selectedGebiet,
                    scope: $scope,
                    isActive: tab == .map && scenePhase == .active
                )
            }

            // All three tabs stay mounted. Replacing the inactive ones with
            // `Color.clear` destroyed their identity on every switch, discarding
            // scroll position, search text, filters and collapsed sections — and
            // forcing the archive to rebuild its whole index on every visit.
            Tab("Liste", systemImage: "list.bullet.clipboard.fill", value: AppTab.list) {
                ListScreen(
                    gebiet: selectedGebiet,
                    scope: $scope,
                    isActive: tab == .list
                )
            }

            Tab("Archiv", systemImage: "archivebox.fill", value: AppTab.archive) {
                ArchiveScreen(
                    selectedGebietID: selectedGebietBinding,
                    scope: $scope,
                    isActive: tab == .archive
                )
            }
        }
        .environment(location)
        // Both, always together: `.tint` drives the controls SwiftUI colours for us,
        // `appAccent` drives everything we tint by hand. Setting only one is what let
        // the two reds drift apart.
        .tint(accentColor)
        .environment(\.appAccent, accentColor)
        .preferredColorScheme(
            (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
        )
        .tabBarMinimizeBehavior(.onScrollDown)
        // `safeAreaBar` rather than `overlay`: an overlaid banner swallows taps in
        // the navigation bar behind it, and the bar variant additionally extends the
        // scroll edge effect of any scroll view it insets.
        .safeAreaBar(edge: .top, spacing: 0) {
            AppNoticeBanner()
        }
        .task {
            await migrateLegacyDaysIfNeeded()
            createFirstGebietIfNeeded()
            #if DEBUG
            if let count = DebugSeed.requestedCount,
               let seeded = DebugSeed.populate(modelContext, count: count) {
                selectedGebietID = seeded
            }
            #endif
            ensureSelection()
        }
        .onChange(of: gebiete.count) { _, _ in
            ensureSelection()
        }
        .onChange(of: selectedGebietIDString) { _, _ in
            // A one-day territory has no Tag-2 picker, so a scope left at .day2 would
            // be unreachable — and every status tap would write to a day that does
            // not exist, invisible to the statistics and the export.
            if selectedGebiet?.isTwoDay != true, scope == .day2 {
                scope = .combined
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                modelContext.save(reporting: notices)
            }
        }
    }

    /// Gives a brand-new install something to work with.
    ///
    /// Runs exactly once per install. Deleting the last territory later leaves the
    /// user in the empty state they asked for — the old build had three separate code
    /// paths inventing replacement territories under three different names.
    private func createFirstGebietIfNeeded() {
        guard !didCreateFirstGebiet, gebiete.isEmpty else {
            didCreateFirstGebiet = true
            return
        }
        let today = Gebiet.campaignCalendar.startOfDay(for: .now)
        modelContext.insert(Gebiet(name: "", date: today))
        guard modelContext.save(reporting: notices, context: "Erstes Gebiet konnte nicht angelegt werden")
        else { return }
        didCreateFirstGebiet = true
    }

    /// Picks a territory only when there isn't a valid one already.
    ///
    /// The old version reassigned the selection unconditionally on launch and again
    /// on every day rollover, so a territory the user had deliberately opened in the
    /// archive was silently swapped out from under them.
    private func ensureSelection() {
        if let selectedGebietID, gebiete.contains(where: { $0.id == selectedGebietID }) {
            return
        }
        let today = Gebiet.campaignCalendar.startOfDay(for: .now)
        let todays = gebiete.first { $0.dayIndex(on: today) != nil }
        selectedGebietID = (todays ?? gebiete.first)?.id
    }

    /// Moves any surviving `CampaignDay` rows into `Gebiet`.
    ///
    /// The flag is written **after** a confirmed save. Setting it first — as both
    /// legacy migrations used to — meant a failed save or a kill mid-migration
    /// stranded the data permanently, with missing territories as the only symptom.
    private func migrateLegacyDaysIfNeeded() async {
        guard !didMigrateLegacyDays else { return }
        guard !legacyDays.isEmpty else {
            didMigrateLegacyDays = true
            return
        }

        var didChange = false
        for day in legacyDays where !gebiete.contains(where: { $0.id == day.id }) {
            let formatted = day.date.formatted(.dateTime.day().month().year())
            let migrated = Gebiet(name: "Gebiet vom \(formatted)", date: day.date)
            migrated.id = day.id
            migrated.createdAt = day.createdAt
            migrated.boundaryData = day.boundaryData
            modelContext.insert(migrated)
            didChange = true
        }

        // Houses written before territories existed carry only the legacy key.
        let orphans = (try? modelContext.fetch(
            FetchDescriptor<House>(predicate: #Predicate { $0.gebietID == nil })
        )) ?? []
        for house in orphans where house.dayID != nil {
            house.gebietID = house.dayID
            didChange = true
        }

        guard didChange else {
            didMigrateLegacyDays = true
            return
        }
        if modelContext.save(reporting: notices, context: "Alte Tagesrunden konnten nicht übernommen werden") {
            didMigrateLegacyDays = true
        }
    }
}
