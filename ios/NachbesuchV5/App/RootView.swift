import SwiftData
import SwiftUI
import UIKit

enum AppTab: Hashable {
    case map, list, archive

    func isActive(selectedTab: AppTab, scenePhase: ScenePhase) -> Bool {
        self == selectedTab && scenePhase == .active
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppNoticeCenter.self) private var notices

    @Query(sort: \Gebiet.day1Date, order: .reverse) private var gebiete: [Gebiet]
    @Query(sort: \CampaignDay.date, order: .reverse) private var legacyDays: [CampaignDay]

    /// Counts a commit rather than watching the houses.
    ///
    /// This used to be `@Query(sort: \House.updatedAt) private var allHouses: [House]`
    /// — every house in the database, materialised as live `@Model` objects, held for
    /// the entire lifetime of the app because `RootView` never goes away. It existed
    /// for two things: a revision string, and one pass over the doors when reminders
    /// are reconciled.
    ///
    /// Neither needs the objects to be resident. `ArchiveScreen` and `ListScreen` each
    /// held a set of their own on top of this one, so a territory of 1500 addresses
    /// was resident three times over. On an iPhone 11 that is the jetsam that reads to
    /// the user as "the app closes when I open the Liste or Archiv tab" — and it does
    /// not reproduce in a simulator, which has no jetsam limit and borrows the Mac's
    /// memory. The reconciliation now fetches what it needs, uses it, and lets it go.
    @State private var saveRevision = 0
    @State private var initializationComplete = false

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
    @AppStorage(ReminderSettings.unscheduledCountKey) private var unscheduledRevisits = 0

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

    #if DEBUG
    /// Einmalig cachen: Environment-Dict pro Body wäre Dauer-Overhead.
    private static let debugInitialTab: AppTab = {
        switch ProcessInfo.processInfo.environment["NACHBESUCH_TAB"] {
        case "list": return .list
        case "archive": return .archive
        default: return .map
        }
    }()
    private static let debugTabStressCount: Int? = {
        guard let raw = ProcessInfo.processInfo.environment["NACHBESUCH_TAB_STRESS"],
              let switches = Int(raw), switches > 0 else { return nil }
        return switches
    }()
    private static let debugTabStressInterval: Int = {
        ProcessInfo.processInfo.environment["NACHBESUCH_TAB_STRESS_MS"]
            .flatMap(Int.init) ?? 350
    }()
    #endif

    @State private var tab: AppTab = {
        #if DEBUG
        return Self.debugInitialTab
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
                    isActive: AppTab.map.isActive(selectedTab: tab, scenePhase: scenePhase)
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
                    isActive: AppTab.list.isActive(selectedTab: tab, scenePhase: scenePhase)
                )
            }

            Tab("Archiv", systemImage: "archivebox.fill", value: AppTab.archive) {
                ArchiveScreen(
                    selectedGebietID: selectedGebietBinding,
                    scope: $scope,
                    isActive: AppTab.archive.isActive(selectedTab: tab, scenePhase: scenePhase)
                )
            }
        }
        .sensoryFeedback(.selection, trigger: tab)
        .environment(location)
        // Both, always together: `.tint` drives the controls SwiftUI colours for us,
        // `appAccent` drives everything we tint by hand. Setting only one is what let
        // the two reds drift apart.
        .tint(accentColor)
        .environment(\.appAccent, accentColor)
        .preferredColorScheme(
            (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
        )
        .compatTabBarMinimize()
        // On iOS 18 an empty `safeAreaInset` around a TabView can enter a perpetual
        // inset/layout negotiation after tab selection. Install the inset only while
        // it has actual banner content.
        .modifier(RootBannerModifier(unscheduledRevisits: unscheduledRevisits))
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
            initializationComplete = true
        }
        .task(id: initializationComplete, priority: .background) {
            guard initializationComplete else { return }
            // Sicherung erst 5 s nach dem ersten Karten-Refresh: Der Pin-Aufbau
            // gewinnt die CPU, die Sicherung läuft danach im Hintergrund.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            let container = modelContext.container
            let backup = Task.detached(priority: .background) {
                await AutoBackupService(modelContainer: container).runIfNeeded()
            }
            await withTaskCancellationHandler {
                await backup.value
            } onCancel: {
                backup.cancel()
            }
            guard !Task.isCancelled else { return }
            // Repair notifications only after initialization and backup finish.
            await reconcileReminders()
        }
        #if DEBUG
        // The regression harness for the iOS 18 freeze.
        //
        // Switching tabs by hand is exactly the gesture that used to lock the app up,
        // and it is the one thing a screenshot run cannot do. This drives the tab bar
        // instead, so the failure has a number attached to it: before the fix, one
        // single switch away from a built map tab pinned the CPU at ~90 % and grew
        // RSS by ~2.7 MB/s **for as long as the app was left running**. After it, 120
        // switches settle back to 0 % with flat memory.
        //
        //     SIMCTL_CHILD_NACHBESUCH_TAB_STRESS=120 \
        //     SIMCTL_CHILD_NACHBESUCH_TAB_STRESS_MS=350 \
        //     xcrun simctl launch booted at.volkshilfe.nachbesuch.v5
        //
        // Then watch `ps -o %cpu=,rss= -p <pid>`: it has to fall to zero once the run
        // ends. A freeze shows up as CPU that never comes down.
        .task {
            guard let switches = Self.debugTabStressCount
            else { return }
            let interval = Self.debugTabStressInterval
            let sequence: [AppTab] = [.list, .archive, .map]
            for index in 0..<switches {
                try? await Task.sleep(for: .milliseconds(interval))
                guard !Task.isCancelled else { return }
                tab = sequence[index % sequence.count]
            }
            FileHandle.standardOutput.write(Data("[TabStress] completed \(switches) switches\n".utf8))
        }
        #endif
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
            } else {
                Task { await reconcileReminders() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            saveRevision &+= 1
        }
        // The 260-entry pin bitmap cache never shrank (purge had zero callers).
        // Reclaim it under pressure instead of dying with tiles + export alive.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            PinArtCache.shared.purge()
        }
        .task(id: saveRevision, priority: .utility) {
            guard scenePhase == .active, saveRevision > 0 else { return }
            // Coalesce a burst of writes — a bulk import commits many times in a
            // row, and reconciling after each one re-reads the whole store.
            // 2.5 s, utility: the tapped door's own scheduleRevisit is instant;
            // this is only repair for overflow/capacity, so it must not win CPU
            // over the next tap or scroll.
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            await reconcileReminders()
        }
    }

    /// Rebuilds the promised reminders from the stored doors.
    ///
    /// Off the main actor, and that is the point. This used to be a `@Query` over
    /// every house held for the app's whole lifetime; then a batched scratch-context
    /// walk, which fixed the memory but left the work on the main thread — so a
    /// single door tap in the field still bought a full decode of the store 600 ms
    /// later, on the thread that draws. `HouseReadService` is a `@ModelActor`, so the
    /// walk happens on its own executor and only the finished value array comes back.
    private func reconcileReminders() async {
        let candidates: [RevisitReminderCandidate]
        do {
            let reader = await HouseReadService.background(container: modelContext.container)
            candidates = try await reader.revisitCandidates()
        } catch is CancellationError {
            return
        } catch {
            notices.report(error, context: "Erinnerungen konnten nicht abgeglichen werden")
            return
        }
        let result = await ReminderService.reconcile(candidates)
        unscheduledRevisits = result.unscheduled + result.failed
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

        // Häuser ohne Gebiet_key: Nur IDs im Hintergrund sammeln, Zuordnung
        // und Save bleiben auf Main — der Scan blockiert sonst den Start.
        let container = modelContext.container
        let orphanLinks: [(houseID: UUID, dayID: UUID)] = await Task.detached(priority: .utility) {
            let backgroundContext = ModelContext(container)
            let descriptor = FetchDescriptor<House>(predicate: #Predicate { $0.gebietID == nil })
            guard let houses = try? backgroundContext.fetch(descriptor) else { return [] }
            var links: [(UUID, UUID)] = []
            links.reserveCapacity(houses.count)
            for house in houses {
                if let dayID = house.dayID {
                    links.append((house.id, dayID))
                }
            }
            return links
        }.value
        guard !Task.isCancelled else { return }
        if !orphanLinks.isEmpty {
            // Gebündelt nach IDs statt Vollscan auf Main — wenige Zeilen, indexiert.
            let ids = orphanLinks.map(\.houseID)
            do {
                let descriptor = FetchDescriptor<House>(predicate: #Predicate { ids.contains($0.id) })
                let orphans = try modelContext.fetch(descriptor)
                let dayByHouse = Dictionary(uniqueKeysWithValues: orphanLinks.map { ($0.houseID, $0.dayID) })
                for house in orphans {
                    if let dayID = dayByHouse[house.id] {
                        house.gebietID = dayID
                        didChange = true
                    }
                }
            } catch {
                notices.report(error, context: "Alte Hauszuordnungen konnten nicht geprüft werden")
                return
            }
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

/// Transient and standing banners over every tab.
///
/// An overlay, always installed, never a conditional wrapper. The previous shape
/// was `if banner { content.safeAreaBar { … } } else { content }` — two branches
/// of an `if` are two different views to SwiftUI, so every notice appearing or
/// leaving tore down and rebuilt the entire `TabView`: the map, the list with its
/// scroll position, the archive index. That was the jolt behind every banner, and
/// it also meant the banner's own transition never ran, because it arrived as
/// part of a brand-new tree. An always-present overlay keeps the tabs' identity
/// and gives the banner a stable parent to animate in and out of.
///
/// An overlay (rather than an always-installed safe-area bar) also sidesteps the
/// iOS 18 layout renegotiation an empty inset around a `TabView` could trigger.
private struct RootBannerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppNoticeCenter.self) private var notices
    let unscheduledRevisits: Int
    /// The standing capacity banner can be put away; it returns when the count
    /// changes, because that is new information.
    @State private var dismissedCapacityCount: Int?

    private var showsCapacity: Bool {
        unscheduledRevisits > 0 && dismissedCapacityCount != unscheduledRevisits
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            VStack(spacing: AppSpacing.tight) {
                AppNoticeBanner()
                if showsCapacity {
                    ReminderCapacityBanner(count: unscheduledRevisits) {
                        dismissedCapacityCount = unscheduledRevisits
                    }
                    .transition(.appBanner(edge: .top, reduceMotion: reduceMotion))
                }
            }
            .padding(.top, AppSpacing.tight)
            .animation(.appSettle(reduceMotion: reduceMotion), value: notices.current?.id)
            .animation(.appSettle(reduceMotion: reduceMotion), value: showsCapacity)
        }
    }
}
