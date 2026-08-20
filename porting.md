# Nachbesuch V5 → Android: Implementierungsplan

**Zielgruppe:** ein KI-Agent, der diesen Port ausführt.
**Sprache:** Dieses Dokument ist auf Englisch, weil es Code-Bezeichner, API-Namen und
Testnamen enthält. Die **Produkt-UI bleibt Deutsch (de-AT)** — jeder Anzeigetext in
diesem Dokument ist wörtlich zu übernehmen.

---

## 0. How to use this document

You are porting a shipping iOS app to Android. The iOS source is the specification.
This document tells you what to build, in what order, and — most importantly — **which
behaviours are load-bearing** because they encode bugs that were already found and
fixed once. Re-introducing them on Android is the single most likely failure mode of
this project.

### Working rules

1. **Read the Swift source before porting a unit.** Every section below names exact
   files. Open them. The comments in that code explain *why* the behaviour is what it
   is; those reasons carry over even though the APIs do not.
2. **Do not invent APIs.** If you are unsure whether an Android API exists or what its
   signature is, verify it (documentation, the library's source, or a compile) before
   writing code that depends on it. A plausible-looking wrong API costs more than a
   lookup.
3. **Work milestone by milestone.** Each milestone below has an *Exit criteria*
   section. Do not start milestone N+1 until N's criteria hold and the build is green.
4. **Port the tests first where they exist.** `ios/NachbesuchV5Tests/` contains the iOS tests
   that pin the domain semantics. They are pure-logic tests and translate almost
   mechanically to JVM unit tests. Porting them first gives you an executable spec.
5. **Never widen scope silently.** If a section is blocked (missing key, unavailable
   API), finish everything else, and record the block in `porting-status.md` with what
   exactly is missing.
6. **Keep a running log.** Create `porting-status.md` at the repo root and update it
   at the end of each milestone: what is done, what is verified, what is open.
7. **German strings are data, not decoration.** Do not "improve", translate or
   normalise them. `„Frühes Nein"`, `„Spätes Nein"`, `„Niemand da"`, `„Dabei"` are the
   vocabulary the fundraisers use.

### Definition of "done" for the whole project

The Android app can, on a mid-range device with 2 000 houses in one territory:
draw the territory, record door outcomes, run a recommended street route, export the
same PDF, import/export the same backup JSON as iOS, and scroll/pan at a steady frame
rate. See §14 for the full checklist.

---

## 1. What the app is

**Nachbesuch** is a door-to-door canvassing tool for Volkshilfe Austria fundraisers.
A fundraiser is assigned a *Gebiet* (territory) for one or two calendar days, walks it
street by street, knocks on every door, and records what happened at each door. The
app is used outdoors, one-handed, on a phone, often with poor connectivity, for hours
at a time.

### Domain glossary (keep these words)

| German term | Meaning in code | Notes |
|---|---|---|
| **Gebiet** | `Gebiet` entity | A territory = one round of work, 1 or 2 days |
| **Haus** | `House` entity | One address. Has 1..n doors |
| **Tür / Haushalt** | `DoorResult` | One household. `Haushalt` when the house has exactly one |
| **Nachbesuch** | revisit | Going back to a door where nobody was home |
| **Niemand da** | `VisitOutcome.notHome` | Open work — needs a revisit |
| **Frühes Nein** | `.earlyNo` | Refused before the form came out |
| **Spätes Nein** | `.lateNo` | Refused at the form |
| **Dabei** | `.joined` | Signed up as a long-term donor |
| **Bilanz** | balance / stats | The archive's statistics section |
| **Empfohlene Route** | recommended route | The TSP walking route feature |

### The three tabs

1. **Karte** (map) — the primary surface. Pins for every house, colour/emoji coded by
   outcome; draw a territory boundary; add houses; import addresses from OSM; run the
   recommended route.
2. **Liste** (list) — the same houses grouped by street, collapsible, searchable,
   sortable (including "nearest first"), with swipe actions.
3. **Archiv** (archive) — all territories by day, statistics for the active one,
   search, export, backup/restore.

---

## 2. Source inventory → Android target

Every Swift file, what it does, and where its behaviour lands on Android. `LOC` is the
iOS line count — a rough complexity signal, not a target.

### 2.1 Models — `ios/NachbesuchV5/Models/`

| File | LOC | Responsibility | Android target |
|---|---|---|---|
| `Gebiet.swift` | 208 | Territory entity, campaign-day invariants, boundary blob, date formatting | `data/db/GebietEntity.kt` + `domain/model/Gebiet.kt` + `domain/CampaignDays.kt` |
| `House.swift` | 198 | Address entity, doors blob, mutation guards, `touch()` | `data/db/HouseEntity.kt` + `domain/model/House.kt` |
| `DoorResult.swift` | 109 | One door; day-1/day-2 semantics | `domain/model/DoorResult.kt` (pure Kotlin, `@Serializable`) |
| `VisitOutcome.swift` | 58 | The four outcomes; raw values are **storage format** | `domain/model/VisitOutcome.kt` (enum with explicit `serialName`) |
| `DayScope.swift` | 29 | combined / day1 / day2 | `domain/model/DayScope.kt` |
| `CampaignDay.swift` | 32 | Legacy entity, still in the schema | `data/db/CampaignDayEntity.kt` — port for store compatibility only |
| `OutcomeTally.swift` | 105 | Counting doors into a tally | `domain/OutcomeTally.kt` |
| `StoredCoordinate.swift` | 25 | `{latitude, longitude}` JSON, plausibility check | `domain/model/StoredCoordinate.kt` |
| `AppCoders.swift` | 37 | Every JSON coder + its compatibility constraints | `data/json/AppJson.kt` — **read §4.3 before touching** |

### 2.2 App shell — `ios/NachbesuchV5/App/`

| File | LOC | Responsibility | Android target |
|---|---|---|---|
| `NachbesuchApp.swift` | 65 | Entry point, container wiring | `NachbesuchApplication.kt` + `MainActivity.kt` |
| `AppSchema.swift` | 80 | Versioned schema + corrupt-store recovery path | Room `@Database(version=1)` + `RoomDatabase.Callback`; recovery per §4.5 |
| `RootView.swift` | 199 | TabView, notice banner, tab restoration | `ui/RootScaffold.kt` with `NavigationBar` |
| `AppAppearance.swift` | 155 | Colour/typography tokens | `ui/theme/` (Color.kt, Type.kt, Theme.kt) |
| `DebugSeed.swift` | 101 | `NACHBESUCH_SEED=n` test data generator | `debug/DebugSeed.kt`, triggered by intent extra — see §13.2 |

### 2.3 Map — `ios/NachbesuchV5/Map/` (2 578 LOC, the hardest part)

| File | LOC | Responsibility | Android target |
|---|---|---|---|
| `MapScreen.swift` | 1187 | The whole map surface: state, pin pipeline, modes, route phases | Split into `ui/map/MapScreen.kt` (composable), `ui/map/MapViewModel.kt`, `ui/map/MapUiState.kt`. **Do not port as one file.** |
| `MapHost.swift` | 176 | `UIViewRepresentable` bridge, one-shot camera commands | `ui/map/MapContainer.kt` — the maps-compose host |
| `MapCoordinator.swift` | 787 | Annotation diffing, clustering gate, pin scale, overlays, taps | `ui/map/MarkerController.kt` + `ui/map/ClusterGate.kt` |
| `MapAnnotations.swift` | 552 | Pin views, cluster bubble, next-stop halo, draft points | `ui/map/markers/*` — bitmaps + one overlay for the halo |
| `PinArtCache.swift` | 335 | Pre-rendered pin bitmaps, LRU, scale tiers | `ui/map/markers/PinBitmapCache.kt` — 1:1 port, `Canvas`/`Paint` |
| `MapPinSnapshot.swift` | 258 | Immutable pin payload + builder + bounds | `domain/map/MapPinSnapshot.kt` (pure, unit-tested) |
| `MapCameraStore.swift` | 153 | Camera persistence, one-time-ever centring | `data/prefs/MapCameraStore.kt` (DataStore) |
| `MapChrome.swift` | 855 | Every floating control over the map | `ui/map/chrome/*.kt` |
| `UserLocationPuck.swift` | 218 | Custom location dot + heading cone | `ui/map/markers/UserPuck.kt` |
| `MapPointsOfInterest.swift` | 67 | POI filter presets | `ui/map/PoiPresets.kt` (map style JSON, see §7.6) |

### 2.4 Route — `ios/NachbesuchV5/Route/` (1 157 LOC)

| File | LOC | Responsibility | Android target |
|---|---|---|---|
| `WalkingNetwork.swift` | 480 | Overpass fetch, graph build, Dijkstra + min-heap, disk cache | `domain/route/WalkingGraph.kt`, `data/route/OverpassClient.kt`, `data/route/OverpassCache.kt` |
| `RoutePlanner.swift` | 307 | Cost matrix, nearest-neighbour, 2-opt, leg extraction | `domain/route/RoutePlanner.kt` — **pure Kotlin, no Android imports** |
| `RouteSession.swift` | 272 | Live route state, queue, skipping, drawn path | `domain/route/RouteSession.kt` + state in `MapViewModel` |
| `RouteStore.swift` | 98 | Per-territory persistence | `data/prefs/RouteStore.kt` (DataStore, JSON blob) |

### 2.5 Features

| File | LOC | Responsibility | Android target |
|---|---|---|---|
| `Liste/ListScreen.swift` | 733 | List tab | `ui/list/ListScreen.kt` + `ListViewModel.kt` |
| `Liste/ListModels.swift` | 250 | Sections, sorting, filtering (pure) | `domain/list/ListSectionBuilder.kt` |
| `Archiv/ArchiveScreen.swift` | 722 | Archive tab | `ui/archive/ArchiveScreen.kt` + `ArchiveViewModel.kt` |
| `Archiv/BalanceSection.swift` | 170 | Stats + bar chart | `ui/archive/BalanceSection.kt` (chart: Compose `Canvas`, no library needed) |
| `Archiv/GebietEditorSheet.swift` | 164 | Create/edit territory | `ui/archive/GebietEditorSheet.kt` (`ModalBottomSheet`) |
| `Shared/HouseDetailSheet.swift` | 516 | Record outcomes per door | `ui/house/HouseDetailSheet.kt` — **highest-traffic screen, get the ergonomics right** |
| `Shared/ExportSheet.swift` | 180 | Export options + share | `ui/export/ExportSheet.kt` |
| `Shared/FilterBar.swift` | 123 | Filter chips | `ui/common/FilterBar.kt` |
| `Shared/OutcomeButton.swift` | 62 | The four outcome buttons | `ui/common/OutcomeButton.kt` |
| `Karte/AddHouseSheet.swift` | 233 | Add a house | `ui/map/AddHouseSheet.kt` |
| `Karte/AreaHouseImportSheet.swift` | 153 | OSM address import UI | `ui/map/AreaImportSheet.kt` |
| `Karte/MapSearchSheet.swift` | 138 | Search within the territory | `ui/map/MapSearchSheet.kt` |
| `Bilanz/BilanzStatsEngine.swift` | 95 | Statistics (pure) | `domain/stats/BilanzStatsEngine.kt` |

### 2.6 Services

| File | LOC | Responsibility | Android target |
|---|---|---|---|
| `DayExportService.swift` | 607 | PDF + plain-text export | `data/export/PdfExporter.kt` + `domain/export/ExportDocumentBuilder.kt` |
| `BackupService.swift` | 427 | JSON backup/restore incl. legacy v1 | `data/backup/BackupService.kt` — **format is cross-platform, §4.4** |
| `AreaHouseImportService.swift` | 295 | Overpass address import | `data/import/AreaHouseImportService.kt` |
| `GebietNamingService.swift` | 197 | Reverse-geocode a territory name | `data/naming/GebietNamingService.kt` (Android `Geocoder`, §12.3) |
| `ArchiveIndex.swift` | 150 | Cached per-territory tallies | `domain/archive/ArchiveIndex.kt` |
| `ArchiveSearchEngine.swift` | 89 | Diacritic-insensitive token search | `domain/archive/ArchiveSearch.kt` |
| `GermanPlaceNameExtractor.swift` | 120 | Pull a usable place name from a geocode | `domain/naming/GermanPlaceNameExtractor.kt` |
| `GebietCentroidCalculator.swift` | 74 | Polygon centroid, null-island guard | `domain/geo/Centroid.kt` |
| `StreetNameParser.swift` | 35 | Split "Teststraße 12" → street + number | `domain/StreetNameParser.kt` |
| `BulkHouseImporter.swift` | 45 | Batched inserts | Room `@Insert` in a transaction |
| `AppNoticeCenter.swift` | 123 | Transient banners, error queueing | `ui/common/NoticeCenter.kt` (`SharedFlow` + `Snackbar`) |
| `PerformanceTrace.swift` | 27 | Signposts | `androidx.tracing.Trace` |

### 2.7 Design system

| File | LOC | Responsibility | Android target |
|---|---|---|---|
| `AdaptiveSurface.swift` | 177 | Glass chrome, content cards, backdrop | `ui/theme/Surfaces.kt` — see §10 |
| `AppMetrics.swift` | 42 | Radii + spacing tokens | `ui/theme/Dimens.kt` |
| `Motion.swift` | 34 | Three animation curves + reduce-motion | `ui/theme/Motion.kt` |
| `VisitOutcome+UI.swift` | 28 | Outcome → colour/icon | `ui/theme/OutcomeStyle.kt` |
| `FlowLayout.swift` | 48 | Wrapping layout | `FlowRow` (Compose Foundation) |

---

## 3. Target stack

Resolve exact versions yourself at implementation time; pin them in
`gradle/libs.versions.toml`. Do not copy version numbers out of this document.

| Concern | Choice | Why |
|---|---|---|
| Language | Kotlin, JVM target 17 | — |
| UI | Jetpack Compose + Material 3 | Closest structural match to SwiftUI |
| Min SDK | **26** | Below that, `java.time` and adaptive icons get painful. Blur effects need 31 → graceful fallback (§10.3) |
| Target SDK | latest stable | — |
| Architecture | Single Activity, Compose Navigation, MVVM with `StateFlow` | Maps 1:1 onto the `@Observable` + `@State` structure in the Swift code |
| DI | Hilt | — |
| Database | **Room** | Direct analogue of SwiftData. §4 |
| Key-value | **DataStore (Preferences)** | Replaces `UserDefaults` |
| JSON | **kotlinx.serialization** | §4.3 has hard constraints |
| HTTP | **OkHttp** (or Ktor-OkHttp) | Overpass POST + timeouts |
| Concurrency | Coroutines + Flow | `Task.detached` → `Dispatchers.Default`, `@MainActor` → `Dispatchers.Main.immediate` |
| Maps | **Google Maps + maps-compose** (primary), MapLibre as fallback | §7.1 |
| Clustering | Hand-written; **not** `maps-compose-utils` clustering by default | §7.4 |
| Location | `FusedLocationProviderClient` | §8 |
| Heading | `SensorManager` `TYPE_ROTATION_VECTOR` | §8.2 |
| PDF | `android.graphics.pdf.PdfDocument` | §9 |
| File I/O | Storage Access Framework + `FileProvider` share | §9.4, §11 |
| Tests | JUnit5 (or JUnit4 + Truth), Robolectric where needed, Compose UI tests, Macrobenchmark | §13 |

### 3.1 Module layout

Use one Gradle module per layer. It keeps the pure logic honest — the domain module
must not compile against Android.

```
:app          — Activity, Application, DI wiring, navigation
:ui           — Compose screens, theme, map UI          (depends on :domain)
:data         — Room, DataStore, network, export, backup (depends on :domain)
:domain       — pure Kotlin: models, route planner, stats, snapshot builders
                *** no android.* imports, no Compose, JVM-only unit tests ***
```

`:domain` is where ~40 % of the ported code lives, and it is where all the ported
tests run in milliseconds without a device. Be strict about this boundary: on iOS the
equivalent discipline is the `nonisolated` annotation you will see all over the
source.

---

## 4. Data layer

### 4.1 Entities

Room entities mirror the SwiftData `@Model` classes **exactly**, including the legacy
columns. Do not "clean up" the schema — see the frozen-shape comments in
`House.swift:5-9` and `Gebiet.swift:20-22`.

```kotlin
@Entity(tableName = "Gebiet")
data class GebietEntity(
    @PrimaryKey val id: String,          // UUID as lowercase-canonical string
    val name: String,
    val districtOrCity: String,
    val notes: String,
    val isTwoDay: Boolean,
    val day1Date: Long,                  // epoch millis, UTC
    val day2Date: Long?,
    val boundaryData: String,            // JSON array of StoredCoordinate
    val createdAt: Long,
    val updatedAt: Long,
)

@Entity(
    tableName = "House",
    indices = [Index("gebietID"), Index("updatedAt")]
)
data class HouseEntity(
    @PrimaryKey val id: String,
    val address: String,
    val note: String,
    val latitude: Double,
    val longitude: Double,
    val isApartmentBuilding: Boolean,
    val gebietID: String?,
    val dayID: String?,                  // legacy twin, always written = gebietID
    val unitsData: String,               // JSON array of DoorResult
    val createdAt: Long,
    val updatedAt: Long,
)
```

Notes that matter:

- `boundaryData` / `unitsData` are **blobs of JSON**, not relations. Keep it that way:
  the iOS app depends on this shape, the backup format serialises `boundaryData`
  verbatim, and a house's doors are always read and written as a unit.
- Index `updatedAt` — the map's incremental patch path (§6.3) queries houses ordered by
  `updatedAt DESC` and takes a prefix. Without the index it degrades to a table scan on
  every door tap.
- Store UUIDs as canonical lowercase strings and **never** compare them
  case-sensitively against user input.

### 4.2 DAOs and Flows

```kotlin
@Dao interface HouseDao {
    @Query("SELECT * FROM House WHERE gebietID = :gebietId ORDER BY updatedAt DESC")
    fun observeForTerritory(gebietId: String): Flow<List<HouseEntity>>

    @Query("SELECT * FROM House WHERE gebietID = :gebietId ORDER BY updatedAt DESC LIMIT :limit")
    suspend fun recentlyChanged(gebietId: String, limit: Int): List<HouseEntity>
    // ...
}
```

Room `Flow` queries replace SwiftData's `@Query`. Two rules:

1. **Never decode `unitsData` on the main dispatcher.** Every decode goes through
   `withContext(Dispatchers.Default)`. On iOS this is `Task.detached`; the reason is the
   same — a territory of 2 000 houses is 2 000 JSON parses.
2. **`distinctUntilChanged()` on anything feeding the map.** Room re-emits on any table
   write; the pin pipeline must not rebuild because an unrelated territory changed.

### 4.3 JSON — the cross-platform trap ⚠️

Read `ios/NachbesuchV5/Models/AppCoders.swift` first. There are **two different date formats** in play,
and getting them wrong silently corrupts timestamps by 31 years.

| Payload | iOS coder | Date encoding | Kotlin equivalent |
|---|---|---|---|
| `House.unitsData` | `JSONEncoder()` default | **`.deferredToDate`** = `Double` seconds since **2001-01-01 UTC** | Custom serializer, §below |
| `Gebiet.boundaryData` | `JSONEncoder()` default | no dates in payload | plain |
| Backup file | `backupEncoder()` | **ISO-8601 strings** | `Instant` ↔ ISO-8601 |

So a `DoorResult.updatedAt` inside `unitsData` looks like `776_952_301.123` on disk, and
that number is **Apple reference time**. The conversion constant is
`978_307_200` seconds (2001-01-01T00:00:00Z in Unix epoch).

```kotlin
/**
 * DoorResult timestamps inside `unitsData` are Apple reference dates: Double seconds
 * since 2001-01-01 UTC, because iOS wrote them with JSONEncoder's default
 * `.deferredToDate` strategy. Every blob ever written uses it, so the format is
 * frozen. Reading it as a Unix epoch puts every door 31 years in the past.
 */
object AppleDateSerializer : KSerializer<Instant> {
    private const val APPLE_EPOCH_OFFSET_SECONDS = 978_307_200L
    override val descriptor = PrimitiveSerialDescriptor("AppleDate", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: Instant) {
        val seconds = value.toEpochMilliseconds() / 1000.0 - APPLE_EPOCH_OFFSET_SECONDS
        encoder.encodeDouble(seconds)
    }
    override fun deserialize(decoder: Decoder): Instant {
        val seconds = decoder.decodeDouble() + APPLE_EPOCH_OFFSET_SECONDS
        return Instant.fromEpochMilliseconds((seconds * 1000.0).toLong())
    }
}
```

Additional constraints:

- `VisitOutcome` is persisted **by raw value** (`notHome`, `earlyNo`, `lateNo`,
  `joined`). Use `@SerialName` on every case. Renaming one is a data migration.
- `DoorResult` field names are the storage keys: `id`, `label`, `outcome`, `updatedAt`,
  `day2Outcome`, `day2UpdatedAt`. Absent optional fields must decode as `null`, so give
  them defaults and configure `Json { ignoreUnknownKeys = true; encodeDefaults = true }`.
- UUIDs serialise as **uppercase** strings in Apple's `Codable` (`"5B7E...-..."`).
  Accept either case on read; write uppercase for maximum symmetry with iOS backups.
- **Write a round-trip test against a real iOS blob.** Export a backup from the iOS app,
  commit it to `:data/src/test/resources/ios-backup.json`, and assert that importing and
  re-exporting is byte-stable modulo key order. This one test protects the entire
  interop story.

### 4.4 Backup format (cross-platform interchange)

`ios/NachbesuchV5/Services/BackupService.swift:1-70` defines the envelope:

```json
{
  "formatVersion": 2,
  "exportedAt": "2026-08-20T09:12:33Z",
  "gebiete": [ { "id": "...", "name": "...", "districtOrCity": "...", "notes": "...",
                 "isTwoDay": false, "day1Date": "...", "day2Date": null,
                 "boundaryData": "<base64>", "createdAt": "...", "updatedAt": "..." } ],
  "houses":  [ { "id": "...", "address": "...", "note": "...", "latitude": 48.2,
                 "longitude": 16.3, "isApartmentBuilding": true, "gebietID": "...",
                 "dayID": "...", "units": [ DoorResult... ],
                 "createdAt": "...", "updatedAt": "..." } ]
}
```

- `boundaryData` is `Data` → **base64 string** in JSON (Apple's `Codable` default), and
  the bytes inside it are UTF-8 JSON of `[{latitude, longitude}]`. Yes, JSON inside
  base64 inside JSON. Reproduce it exactly.
- `units` here are **inline objects**, and because the backup coder uses ISO-8601, the
  `DoorResult` dates inside the *backup* are ISO strings — **not** Apple reference
  doubles. The same struct therefore needs two serialization contexts. Model this
  explicitly: `DoorResultStorage` (Apple dates) and `DoorResultBackup` (ISO), or one
  class with two `Json` instances that install different serializer modules. Do not
  paper over it.
- **Legacy v1 backups** (`formatVersion: 1`) use `days:` instead of `gebiete:` with
  a reduced field set — see `LegacyAppBackup` in the Swift source. Port the reader; a
  fundraiser with an old export must not be stuck.
- Import is **merge, not replace**: existing ids win, unknown ids are inserted,
  houses whose territory is missing are counted as `skippedHouses` and reported.

**Acceptance:** an Android-written backup imports into iOS with zero data loss, and
vice versa. Verify by hand at least once before shipping.

### 4.5 Corrupt-store recovery

`ios/NachbesuchV5/App/AppSchema.swift:38-80` treats an unopenable store as a first-class state, not a
crash: the app still launches, on a scratch in-memory container, and offers the user a
copy of the store file. Reproduce this:

```kotlin
// Do NOT use fallbackToDestructiveMigration(). The whole value of this app is field
// work that cannot be re-collected; deleting it to make the app launch is worse than
// not launching.
```

- Open Room normally. Catch failure at first access.
- On failure: expose `AppState.StoreUnreadable(dbFile)` and render a screen that
  explains the problem in German and offers "Datenbank exportieren" via SAF so the file
  can be sent for recovery.
- Log the exception; never delete the file.

---

## 5. Domain semantics — the executable specification

**This is the most important section of this document.** Everything here is behaviour
that was wrong once, was diagnosed, and was fixed. Port every rule and port its test.

### 5.1 Day-1 / day-2 door semantics (`DoorResult.swift`)

A door carries two independent results. Four accessors exist because they answer four
different questions, and collapsing any two of them was a real shipped bug.

| Accessor | Rule |
|---|---|
| `result(on day)` | Strictly what was recorded that day. **No fallback.** A door answered only on day 1 has *no* day-2 result. Used for statistics. |
| `finalOutcome` | `day2Outcome ?: outcome` |
| `recordedOutcome(in scope)` | day1 → `outcome`; day2 → `day2Outcome`; combined → `finalOutcome`. Used for **reports**: a report headed "Tag 2" must not list a door settled on day 1. |
| `displayOutcome(in scope)` | day1 → `outcome`; day2 → `day2Outcome`, else `outcome == notHome ? null : outcome`; combined → `finalOutcome`. Used for **pins and rows**: in day-2 scope, a door still awaiting its revisit must read as *unanswered*, otherwise the doors you came back for are the ones the screen marks finished. |
| `isPendingRevisit` | `outcome == notHome && day2Outcome == null` |
| `isOpen(in scope)` | day1: `outcome == null \|\| outcome == notHome`; day2: `isPendingRevisit \|\| (outcome == null && day2Outcome == null)`; combined: `finalOutcome == null \|\| finalOutcome == notHome` |
| `timestamp(in scope)` | day1 → `updatedAt`; day2 and combined → `day2UpdatedAt ?: updatedAt` |

**Test names to port:** `day2CountsOnlyRealRevisits`, `pendingRevisitsReadAsOpen`,
`settledDoorsNeedNoRevisit`, `markerPrefersOpenWork`, `markOpenDoorsHitsRevisitTargets`.

### 5.2 Write scope comes from the calendar, not the picker

`Gebiet.writeScope(on:)`: which day an edit is written to is derived from *today's
date* against the territory's assigned days — **never** from whatever the on-screen
day picker shows. The picker is a view filter. Porting this wrong makes day-2 data
land on day 1 for anyone who looks at "Tag 1" while working day 2.

### 5.3 Territory invariants (`Gebiet.normalizeDays`)

One guard enforces: `isTwoDay ⇒ day2Date != null && day2Date > day1Date`. Both the
constructor and backup import previously wrote past it and could produce a territory
labelled "2 Tage" with no second day.

- All campaign dates are **start-of-day in the device's current calendar**. This is a
  known, deliberate limitation (documented at `Gebiet.swift:63-68`) — the existing
  stores were written that way and switching to a fixed zone would shift every saved
  date. Use `java.time.LocalDate` + the system zone, and add the same comment.
- `byAdding: .day` across a DST boundary can land on 23:00 — always re-apply
  start-of-day after date arithmetic.

**Tests:** `twoDayAlwaysHasSecondDay`, `switchingToSingleDayClearsSecondDay`,
`freelyChosenSecondDayIsKept`, `sameDayIsRejected`, `writeScopeFollowsCalendar`.

### 5.4 `touch()` is monotonic

```
updatedAt = max(now, updatedAt + 1ms)
```

`updatedAt` is the change signal that the archive index, the search index, the export
pipeline and the map's incremental patch path all key off. Rewinding it — which undo
used to do — leaves those caches convinced they are current while showing stale data.

**Tests:** `undoMovesTimestampForward`, `renameTouchesTimestamp`.

### 5.5 Damaged blobs are never overwritten

`House.decodedUnits()` returns `null` (not `[]`) when `unitsData` cannot be parsed, and
**every mutation refuses to run** on an unreadable blob. This converts a transient
decode failure into a visible "beschädigt" badge rather than permanent silent data
loss. `isDamaged` is surfaced in the UI.

**Test:** `damagedHouseRefusesWrites`.

### 5.6 Boundary cache invalidation

`Gebiet.cachedBoundary` is invalidated **by the setter**, not by hashing the blob —
`Data.hashValue` only mixes a bounded prefix, so editing a later vertex produced an
identical stamp and returned a stale polygon. In Kotlin, keep the decoded polygon in
the repository keyed by `(id, updatedAt)` and never by a content hash of the blob.

### 5.7 Search

`ArchiveSearchEngine`: diacritic-**insensitive**, token-based, and **all tokens must
match** (AND, not OR). Kotlin:
`java.text.Normalizer.normalize(s, NFD).replace("\\p{Mn}+".toRegex(), "").lowercase()`.
Note `ß` does not decompose — lowercase comparison handles it; verify "Teststrasse"
matches "Teststraße" and add that as a test case (it is a real user expectation).

**Tests:** `diacriticInsensitive`, `allTokensMustMatch`.

### 5.8 Street name parsing

`StreetNameParser`: split at the first house number. Handles the importer format and
**non-breaking spaces** (OSM data contains them). Regex must not use lookbehind if you
later share it with any engine that lacks it — the Swift version hit exactly that.

**Tests:** `splitsAtHouseNumber`, `handlesNonBreakingSpace`, `handlesImporterFormat`,
`fallsBackWithoutHouseNumber`.

### 5.9 Centroid

`GebietCentroidCalculator`: polygon centroid, **not** the average of vertices (a densely
sampled edge would drag the result), plus a **null-island guard** rejecting `(0,0)`.

**Tests:** `simpleSquare`, `denseEdgeDoesNotSkewCentroid`, `rejectsNullIsland`.

### 5.10 Coordinate plausibility

`StoredCoordinate.isPlausible` gates everything that consumes coordinates — bounds
computation, distance display, route planning. Implausible values (0,0 / out of range /
NaN) are dropped rather than propagated.

**Test:** `rejectsImplausibleCoordinates`.

---

## 6. The pin pipeline (map data path)

This is what makes the map fast. Port the structure, not just the result.

### 6.1 Snapshot model

`MapPinSnapshot` is a plain immutable value: id, address, lat/lon, `markerOutcome`,
`unitCount`, `completedCount`, `followUpCount`, `joinedCount`, `earlyNoCount`,
`lateNoCount`. Derived: `markerText` (the outcome emoji for a single household,
`"3/8"` for an apartment building) and `hasOpenWork`.

`PreparedMapSnapshot` holds `pinsByID: Map<UUID, MapPinSnapshot>` plus `MapBounds`.

### 6.2 Build off the main thread

```kotlin
val snapshot = withContext(Dispatchers.Default) {
    MapPinSnapshotBuilder.build(rawHouses, scope)
}
```

`MapPinSnapshotBuilder` lives in `:domain` and takes plain data (`RawMapHouse`) — never
Room entities, never `LiveData`. Same reason as the Swift `Sendable` structs.

### 6.3 The incremental patch path ⚠️

`MapScreen.swift:688-728`. When only *content* changed (a door outcome was tapped) —
same territory, same scope, same house count — do **not** rebuild the whole snapshot.
Houses are ordered by `updatedAt DESC`, so everything touched since the last known
newest timestamp forms a **prefix**: take that prefix, patch those pins, bump a
`contentVersion`, done.

Two versions are tracked separately and both are needed:

- `structuralVersion` — the pin *set* changed (houses added/removed, territory switch)
- `contentVersion` — pin *content* changed (an outcome was recorded)

Plus `changedHouseIDs: Set<UUID>` so the marker layer can update exactly those markers.

**Critical detail:** if the prefix comes back empty although the key moved, **fall
through to a full rebuild**. Advancing the key on a no-op used to leave the map
permanently showing the pre-change status.

**Test:** `patchIsSurgical` — asserts the patch touches only the changed houses.
**Test:** `scalesToTenThousand` — the builder must handle 10 000 houses within budget.

### 6.4 Pipeline key

```kotlin
data class PipelineKey(
    val territoryId: String?,
    val scope: DayScope,
    val houseCount: Int,
    val newestUpdate: Long?,
)
```

The pipeline runs when this key changes — nothing else triggers it. On Android, drive it
with `combine(...).distinctUntilChanged().mapLatest { }` and cancel in-flight work
(`mapLatest` gives you the cancellation for free; the Swift version uses `.task(id:)`).

---

## 7. The map layer

### 7.1 Choosing the map SDK

**Default: Google Maps via `maps-compose`.** Reasons: POI display for orientation comes
for free and matches what the iOS build shows (§7.6); marker rendering is battle-tested
at volume; the tooling is familiar. Cost: an API key, billing setup, and Play Services.

**Fallback: MapLibre GL Android** if the key/billing is unacceptable. It renders vector
tiles with a style JSON you control (so POI filtering is precise), and its `SymbolLayer`
approach is *faster* for thousands of markers than individual `Marker` objects. Cost:
you must supply a tile source, and every marker/overlay API in this document has to be
re-mapped to layers + sources.

**Decide before milestone M4 and record the decision in `porting-status.md`.** Do not
start the marker work with the choice open — the abstractions differ enough that a
retrofit is a rewrite.

Everything below is written for the Google Maps path with notes where MapLibre differs.

### 7.2 The host and the camera

The iOS `MapHost` exists to keep the map view **alive and outside the reactive graph**:
gestures must not invalidate any UI state. On Android this means:

- Hoist the `CameraPositionState` in the ViewModel-adjacent layer, but **do not** feed
  every camera change back into Compose state that other composables read. Collect
  camera movement into a plain holder (`MutableStateFlow` that nothing recomposes on)
  and only publish *idle* positions.
- Never recreate the map composable on data changes. Keep it high in the tree with a
  stable key.

**Camera persistence and the one-time centring rule** (`MapCameraStore.swift`):

- Persist `latitude`, `longitude`, `latitudeDelta`, `longitudeDelta` and a boolean
  `map.didEverCenterOnUser` in DataStore.
- On launch, restore the persisted region. **The app centres on the user exactly once,
  ever** — the first time it ever gets a fix — and then never again, not on relaunch,
  not on tab switch. This was an explicit user requirement, and the flag must be
  *persistent*, not per-process (the iOS bug was a per-instance flag reset by tab
  switching).
- First-ever centring uses a **tight** zoom: `firstLaunchSpan = 0.0032°`
  (≈ zoom 15.5–16 on Android). Manual "locate me" uses `recenterSpan = 0.0045°`.
- Debounce writes (the iOS store batches and flushes on disappear) so panning does not
  hammer DataStore.
- ⚠️ **iOS bug to avoid the Android equivalent of:** `setRegion` in `makeUIView` ran with
  zero bounds and was ignored, so the map opened at world zoom. On Android the analogue
  is setting the camera before the map is laid out — apply the restored position in the
  `GoogleMap` `onMapLoaded` callback, or via `CameraPositionState` initial value, and
  verify on a cold start that the map opens where the user left it.

### 7.3 Markers: pre-rendered bitmaps, never composables

`PinArtCache.swift` bakes geometry **and text** into one `UIImage` per distinct
appearance, keyed by `(outcome, text, isSelected, isDark, scale)`, with an LRU cap of
260 entries. The old version composed a live label on top of an image view and paid a
layout pass per visible pin.

On Android:

```kotlin
data class PinKey(
    val outcome: VisitOutcome?,   // null = no status yet
    val text: String,             // "🔴" or "3/8" or "" at dot scale
    val isSelected: Boolean,
    val isDark: Boolean,
    val scale: PinScale,
)

class PinBitmapCache(private val density: Float) {
    private val cache = object : LruCache<PinKey, BitmapDescriptor>(260) { }
    fun descriptor(key: PinKey): BitmapDescriptor = /* draw with Canvas + Paint */
}
```

Geometry (port exactly — the user rejected a redesign and asked for the original back):

- Silhouette: a **circle plus a short quad-curve tip**, white ring stroked on the
  **circle only**, drop shadow with 4 dp padding so it is never clipped.
- `headDiameter`: `full = 34`, `compact = 25`, `dot = 15` (dp).
- `tipHeight = head * 10/34`, `tipWidth = head * 12/34`.
- Anchor: the **tip** sits on the coordinate → `Marker(anchor = Offset(0.5f, 1.0f))`
  after accounting for the shadow padding. Verify visually; an off-anchor pin points at
  the wrong house.
- Cluster bubble: diameter 46 dp, count abbreviated (`1.2k`), accent differs when any
  member has open revisits.

**Never** use `MarkerComposable` / `rememberComposeBitmap` per pin. It re-renders on
recomposition and will not survive 2 000 pins.

### 7.4 Clustering — late, with hysteresis

The user's explicit requirement: cluster **as late as possible** while keeping
performance. An earlier build clustered far too early and made the app unusable.

Port the gate from `MapCoordinator.swift`:

| Constant | Value | Meaning |
|---|---|---|
| `clusterOnMeters` | 3 000 | switch clustering **on** above this visible width |
| `clusterOffMeters` | 2 000 | switch **off** below this |
| `clusterOnVisiblePins` | 1 200 | or when this many pins are visible |
| `clusterOffVisiblePins` | 800 | and off again below this |

The on/off thresholds differ on purpose — a single threshold flickers when the user
pinches around it. Below the gate, clustering is **fully disabled** and markers do not
collide-cull: overlapping pins stack visibly rather than one silently winning, because
"the pin is not there" is a worse failure than "the pins overlap" when you are standing
in front of the house.

Because you disable clustering below the gate, the built-in clustering utility is a poor
fit (it owns marker lifecycle unconditionally). Write the gate yourself: keep a
`ClusterGate` that maps `(visibleSpanMeters, visibleMarkerCount)` → `Boolean` with
hysteresis, and swap between "all individual markers" and "grid-clustered markers"
(quadtree or simple screen-space grid at ~60 dp cells).

**iOS-specific trap that has an Android twin:** `MKAnnotationView.displayPriority`
defaults to `.required`, meaning never culled and never clustered — leaving the default
forced MapKit to render every pin. The Android equivalent is holding strong references
to every `Marker` object and adding them all: with 2 000 markers you must add only what
is in (padded) view when clustering is off. Maintain a padded visible-rect window.

### 7.5 Pin scale tiers — pull, don't push

Bug that was fixed and must not return: pins got **stuck in colour-only mode**. Three
causes, all of which have Android analogues:

1. **Push-only updates.** The coordinator pushed a new scale to annotations inside the
   *visible* rect only, so views realised just outside it kept stale art and scrolled in
   wrong. **Fix: views pull the current scale on every configure/redisplay.** On
   Android: keep `pinScale` in a single source of truth and re-derive each marker's
   icon from it whenever you (re)add or update a marker — never cache the tier on the
   marker.
2. **The compact tier dropped the glyph entirely**, turning every house into an
   anonymous dot at ordinary working zoom. **Fix: `showsGlyph` is true for `full` and
   `compact`; only `dot` is bare.**
3. **Symmetric thresholds** left the map sitting in the shrunken state. **Fix:
   asymmetric hysteresis:**

```kotlin
fun scaleFor(metersAcross: Double, current: PinScale): PinScale = when (current) {
    PinScale.FULL    -> if (metersAcross > 1_500) PinScale.COMPACT else PinScale.FULL
    PinScale.COMPACT -> when {
        metersAcross <= 1_300 -> PinScale.FULL
        metersAcross > 3_200  -> PinScale.DOT
        else                  -> PinScale.COMPACT
    }
    PinScale.DOT -> when {
        metersAcross <= 1_300 -> PinScale.FULL
        metersAcross <= 3_000 -> PinScale.COMPACT
        else                  -> PinScale.DOT
    }
}
```

Evaluate this on every camera frame (it is cheap), not only on idle, so the size tracks
the pinch instead of snapping afterwards.

### 7.6 Points of interest

Requirement: shops, banks, bus stops etc. are shown **for orientation**, visually muted
so they never compete with the pins.

- **Google Maps:** POIs are on by default. Apply a `MapStyleOptions` JSON that reduces
  POI label saturation/lightness and hides irrelevant categories. Build presets
  mirroring `MapPointsOfInterest.swift` (`aus`, `wesentlich`, `alle` — off / essential /
  all). Keep transit + shops in "essential".
- **MapLibre:** filter the style's POI layers directly.
- Either way, POI **labels must not be tappable in a way that hijacks a pin tap**. On
  Google Maps set `MapUiSettings` / consume `onPOIClick` so it does nothing.

### 7.7 Attribution and safe areas

Legal requirement on both platforms: the Google logo and attribution must never be
covered. The iOS code sets `mapView.layoutMargins` from the floating chrome's measured
height. On Android use `GoogleMap`'s `contentPadding` (or `setPadding`) with the same
measured insets from your bottom bar/route bar. Do not fake it with margins.

### 7.8 Overlays

- **Territory boundary:** `Polygon` (or `Polyline` when the user is still drawing).
  While drawing, numbered draft point markers (1, 2, 3…) mark each dropped corner.
- **Route line:** `Polyline`, `systemBlue` equivalent, width 5 dp, round caps, drawn
  **below** the boundary so a boundary outline stays readable on top.
- Diff overlays by content hash; do not remove-and-re-add every frame.

### 7.9 Next-stop marker (route)

The house you should walk to next carries a **pulsing blue ring plus a bobbing arrow
above it**, and it is drawn **on top** of the pins (`zPriority = .max` on iOS) so it wins
in a dense row of houses. It is not part of the pin bitmap on purpose: it survives every
pin scale tier and can animate without re-rendering a cached bitmap.

Android implementation: a separate `Marker` with a higher `zIndex`, `isClickable = false`,
whose icon is an animated drawable, **or** a small `AndroidView`/Compose overlay
positioned via `Projection.toScreenLocation()` and updated on camera move. Prefer the
overlay for animation quality; make sure it updates on every camera frame or it will lag
behind the map during a pan.

Geometry: the ring diameter is `headDiameter * 1.6` and it is anchored to the pin's
**head**, i.e. lifted by `tipHeight + headDiameter / 2` above the coordinate — the first
iOS attempt used a fixed offset and the ring hung under the pin.

Respect reduce-motion (`Settings.Global.ANIMATOR_DURATION_SCALE == 0f` /
`AccessibilityManager`): no pulse, no bob — the ring stays, static.

### 7.10 Tap handling

- Tap on a pin opens the house sheet — **immediately** on touch-up, not after a
  selection round trip.
- Per-house tap debounce (the iOS coordinator keeps one) so a double tap does not open
  two sheets.
- Long press → context menu (Android: a small `ModalBottomSheet` or `DropdownMenu`) with
  the same actions as the iOS context menu, **minus** "Fußroute öffnen" if you keep the
  in-house router only. The Apple-Maps hand-off button was deliberately removed; do not
  add a Google-Maps equivalent unless the user asks.
- ⚠️ **Mode precedence bug to avoid:** when the route feature is asking the user to pick
  a start point, a tap on a house **must** pick the start, not open the house sheet.
  On iOS this is passed as a *value* into the coordinator each update rather than read
  from a captured closure, precisely because a stale closure got it wrong. On Android:
  keep the map interaction mode in the ViewModel state that the tap handler reads at
  call time.

---

## 8. Location and heading

### 8.1 Continuous location

Requirement: the position updates **live**, not "a few times per whenever".

```kotlin
LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 2_000L)
    .setMinUpdateDistanceMeters(3f)      // 1f while actively following
    .setWaitForAccurateLocation(false)
    .build()
```

Mirrors the iOS settings (`kCLLocationAccuracyNearestTenMeters`, `distanceFilter = 3`,
tightened to `1` while following, `pausesLocationUpdatesAutomatically = false`).

- Foreground only. No background location permission — the app is used while held.
- Permissions: `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION`. Handle "precise
  location off" (Android 12+) with a German explanation, and handle permanent denial by
  falling back to a fully usable map (the iOS copy: *"Standortzugriff ist deaktiviert.
  Du kannst ihn in den Einstellungen erlauben."*).
- Stop updates when the map tab is not resumed; restart on resume.

### 8.2 Heading indicator

Requirement: a direction cone like the Maps app.

- Source: `SensorManager` `TYPE_ROTATION_VECTOR` → `getRotationMatrix` →
  `getOrientation`, then apply the display rotation. Do **not** use the deprecated
  orientation sensor.
- **Circular low-pass smoothing**, alpha by accuracy — port the iOS curve directly
  (`LocationService.swift:227-234`): `alpha = accuracy < 15 ? 0.35 : accuracy < 30 ? 0.18 : 0.08`.
  Interpolate the *shortest angular delta*; naive averaging jumps at the 0/360 wrap.
- Draw the puck yourself (dot + accuracy circle + heading cone) rather than relying on
  the SDK's my-location layer, exactly as iOS does — the built-in cone on both platforms
  only appears in a follow-with-heading camera mode that rotates and zooms the map,
  which is not what is wanted here.
- Hide the cone when heading accuracy is poor rather than showing a lie.

---

## 9. Export

### 9.1 Document model

Port `ExportDocument` / `ExportHouse` / `ExportDoor` / `ExportSummary` verbatim into
`:domain`. Build it off the main thread from plain values.

Rules the user asked for explicitly and that are easy to get wrong:

1. **Only houses actually visited** (`visitedOnly = true` by default). An export is a
   record of work done; padding it with hundreds of untouched addresses buries the part
   anyone reads.
2. **Chronological order** by `recordedAt` — the report reads as the sequence of the
   round. Street grouping was deliberately removed.
3. **The time itself is never printed.** It orders, it does not appear. (`recordedAt`
   exists in the model *only* to sort.)
4. Notes are optional (`includeNotes`), because field shorthand ("Hund", "Abends
   wiederkommen") is not always appropriate to pass on.
5. The summary lists **only outcomes that actually occurred** — never a column of zeroes.

### 9.2 PDF rendering

`android.graphics.pdf.PdfDocument`, A4 at 72 dpi = **595 × 842 points**.

- Monochrome, professional, no decorative banners, no emoji, no tinted metric boxes —
  the previous "slop PDF" was explicitly rejected.
- **Two-pass page numbering**: render once to count pages, then render again with
  "Seite n von m". (The iOS renderer does exactly this.)
- Text measurement: `Paint.measureText` / `StaticLayout` for wrapped cells. Budget the
  same margins as the iOS layout; read `DayExportService.swift`'s `PDFRenderer` for the
  exact column structure, header, and footer.
- Write to a per-export scratch directory (`context.cacheDir/export/<uuid>/`) and clean
  it up after sharing, mirroring `ExportScratch`.

### 9.3 Plain-text export

There is a second, plain-text form for pasting into mail or a messenger: no banner, no
emoji, no column padding. Port it — it is used more than you would think.

### 9.4 Sharing

`FileProvider` + `Intent.ACTION_SEND` with `application/pdf`, `FLAG_GRANT_READ_URI_PERMISSION`.
Declare the provider and an `xml/file_paths.xml` covering the cache export directory.
File name: same scheme as iOS (territory name + date, filesystem-sanitised).

---

## 10. Design system: translating Liquid Glass

The iOS app leans heavily on iOS 26 Liquid Glass. **Android has no equivalent, and
faking it badly looks worse than not faking it.** Translate the *intent*: a legible
floating navigation layer that sits above content and reads as a distinct material.

### 10.1 Token mapping

| iOS token | Value | Android |
|---|---|---|
| `AppRadius.small` | 12 | `Dimens.radiusSmall = 12.dp` |
| `AppRadius.control` | 16 | `radiusControl = 16.dp` |
| `AppRadius.row` | 22 | `radiusRow = 22.dp` |
| `AppRadius.card` | 28 | `radiusCard = 28.dp` |
| `AppRadius.chrome` | 28 | `radiusChrome = 28.dp` |
| `AppSpacing` | 6 / 10 / 16 / 24 | `tight/snug/regular/loose` |

Corner style: iOS uses `.continuous` (squircle). Compose's `RoundedCornerShape` is a
plain arc. Accept the difference — do **not** hand-roll a squircle shape; at these radii
the visual delta is small and a custom shape costs an outline computation per frame.

### 10.2 Surfaces

Three surface roles, matching the iOS code after the last redesign:

1. **Floating chrome** (over the map): `Surface` with `tonalElevation`, a translucent
   scrim (`surfaceContainerHigh.copy(alpha = 0.86f)`), a 0.5 dp outline, and a soft
   shadow. Optionally a real blur (§10.3).
2. **Content cards** (list rows, archive cards): translucent container + hairline
   outline. **Cards get a shadow, list rows do not** — a soft shadow per row is an
   offscreen pass per row and it is exactly what made the iOS list scroll unevenly.
3. **Inner panels** (blocks inside a card): plain tinted fill, **never** the card
   material. Material inside material reads as mud.

### 10.3 Blur

`RenderEffect.createBlurEffect` (API 31+) via `Modifier.graphicsLayer { renderEffect = ... }`
or `Modifier.blur()` for the *backdrop* of chrome. Below API 31, use a solid
`surfaceContainer` colour at higher opacity. Gate on
`Build.VERSION.SDK_INT >= 31 && !powerSaveMode`. Blurring a live map behind chrome is
expensive — measure it (§13.4) and drop it if it costs frames.

### 10.4 The backdrop

List and archive sit on a faintly tinted ground (`AppBackdrop`) so translucent cards have
something to sample. **Keep it very faint** — the accent colour here is red, and a tint
that reads as subtle on a neutral accent turned the whole screen pink on the first
attempt (linear gradient at 0.055 / radial at 0.035 alpha in light mode).

### 10.5 Motion

Port the three curves from `Motion.swift` and use nothing else:

| Role | iOS | Compose |
|---|---|---|
| Everyday feedback (selection, chips, chrome) | `.snappy(0.24, extraBounce: 0.03)` | `spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMediumLow)` |
| Settling (sheets, camera, layout) | `.smooth(0.34)` | `tween(340, easing = FastOutSlowInEasing)` or a critically damped spring |
| Celebration (completion only) | `.spring(0.45, bounce: 0.35)` | `spring(dampingRatio = 0.55f)` |

Reduce-motion: replace positional transitions with **fades**, do not merely shorten
them. Read the system animation scale and the accessibility setting.

Haptics: map `UINotificationFeedbackGenerator(.success)` →
`HapticFeedbackConstants.CONFIRM`, selection → `HapticFeedbackConstants.CLOCK_TICK`, and
respect the system haptics setting.

### 10.6 List performance rules (learned the hard way)

- `LazyColumn` with **stable keys** (`key = { it.id }`) and immutable, `@Stable` row
  models. The iOS equivalent is `.equatable()` on the row.
- Do not put an expensive effect on every row (the iOS bug: interactive glass **and** a
  per-row matched-geometry transition on dozens of rows made collapsing a street
  stutter). One press-state animation per row is enough.
- Row press feedback: scale 0.98 + opacity 0.85, `appFeedback` curve.
- Precompute section models in `:domain` (`ListSectionBuilder`), not in the composable.

---

## 11. Route feature ("Empfohlene Route")

Port order: `:domain` planner and graph first (pure, testable), then the network client
and cache, then the UI.

### 11.1 The walking graph

`WalkingNetwork.swift`. Fetch walkable ways from **Overpass** for the territory's padded
bounding box:

```
[out:json][timeout:40];
way["highway"~"^(footway|path|pedestrian|steps|living_street|residential|unclassified|
                 service|tertiary|tertiary_link|secondary|secondary_link|primary|
                 primary_link|track|cycleway|road)$"]["foot"!="no"]["access"!="private"](BBOX);
out geom qt;
```

- Padding `0.0025°`; refuse areas larger than `0.12° × 0.16°` (`WalkingNetworkError.areaTooLarge`).
- Three mirrors, tried in order: `overpass-api.de`, `overpass.kumi.systems`,
  `lz4.overpass-api.de`.
- **Hard overall deadline of 40 s across all mirrors**, per-request timeout
  `min(18, remaining)`. Three sequential 45 s timeouts meant a user could watch an empty
  bar for over two minutes.
- **Cancellation:** OkHttp cancellation surfaces as `IOException("Canceled")`, not as a
  coroutine `CancellationException`, in the same way `URLSession` throws
  `URLError(.cancelled)` on iOS. If you do not detect it, the remaining mirrors get
  hammered after the user has already walked away. Check `!coroutineContext.isActive`
  at the top of each mirror attempt **and** map the cancellation IOException.
- **Node merging:** quantise coordinates to 1e-6 degrees and key on the pair so ways
  that share a junction actually connect. Use a `data class` key or
  `(latMicro * 10_000_000L) + lonMicro`; the iOS packing is bbox-safe but brittle —
  prefer the explicit key on Android.
- **Disk cache:** keep the raw Overpass payload keyed by the formatted bbox in
  `context.cacheDir/walking-network/`, TTL 30 days. A canvasser works the same streets
  for days and often has no signal in a stairwell; this is the difference between an
  instant route and a 40 s wait that silently degrades to straight lines.

### 11.2 Shortest paths

Dijkstra with a **binary min-heap** (port `MinHeap` from the Swift file; do not use a
`PriorityQueue<Pair>` with boxing on the hot path — measure if you do).
`nearestNode(to:within: 120 m)` snaps a coordinate onto the graph.

`Geo.metres` is an **equirectangular approximation**, not haversine:
`latScale = 110_540`, `lonScale = 111_320 * cos(lat)`. Keep it — it is called in inner
loops, and at territory scale the error is irrelevant. Also port `squaredMetres` for
comparisons that never need the square root.

### 11.3 Ordering (TSP)

Nearest-neighbour, then **2-opt** to pull out the crossings greedy construction always
leaves. Limits: skip refinement above **400** stops; skip the matrix entirely above
**150** stops (fall back to straight-line ordering, but still draw along streets).

⚠️ **The cost matrix must include the door-to-pavement hop at BOTH ends:**

```kotlin
matrix[i][j] = departureOffset(i) + graphDistance(node[i], node[j]) + arrivalOffset(j)
```

Without it, every house on a long straight street snaps to the same OSM vertex, all
pairs cost 0, nearest-neighbour picks by array order, 2-opt sees no improvement, and the
route zig-zags across the street — the exact failure the feature exists to prevent.

**Tests to port:** `visitsEveryHouseOnce`, `untanglesACrossing`,
`refinementNeverMakesItWorse`, `walksAStraightStreetInOrder`, `pathFollowsTheNetwork`,
`fallsBackWithoutNetwork`, `graphJoinsSharedNodes`, `handlesAFullTerritory` (400 stops
under 10 s), `housesOnOneLongStreetKeepTheirOrder`.

### 11.4 Legs, not one polyline ⚠️

`PlannedRoute` carries `legs: List<List<Coordinate>>` aligned with `stops` — the points
to append *after* the previous position to reach that stop.

The drawn line is rebuilt **leg by leg in current queue order**, not by trimming the
original polyline to the nearest point. Trimming breaks the moment a house is skipped
or worked out of order: the line then runs backwards through doors already finished, and
when the skipped house came around again it redrew nearly the whole original route.

Where the queue deviates from the plan (after a skip), draw a **straight connector** for
that pair and be honest about it rather than inventing a detour.

**Tests:** `drawnLineNeverRunsBackwards`, `drawnLineStartsAtTheNextHouse`.

### 11.5 Session, queue and skipping

```
queue = plannedOrder.filter { open && !skipped } + skipped.filter { open }
nextStop = queue.first
```

- Skipping moves a house to the **back** of the queue; it is never dropped. Persisted.
- The planned order **does not re-plan as you work** — a route that shifts under your
  feet is not a route. Completed houses simply fall out of the queue.
- The whole route is **persisted per territory** (DataStore, key `route.<uuid>`): a round
  takes hours, and re-planning after every interruption would make the feature useless.
- `fellBackToStraightLines` must be **restored too** (`= !followsStreets`), otherwise a
  crow-flight route loses its "Luftlinie" warning after relaunch while still drawing a
  line through buildings.
- On restore, **prune** planned/skipped ids against houses that still exist, and clamp
  the position label — deleted houses used to push the counter to "13/12" and leave a
  route that could never be finished.
- When the queue empties: **auto-finish**, clear the stored route, and show
  *"Route geschafft: N Häuser, rund X km Weg."*
- Guard against re-entrancy: a second plan while one is in flight must be refused or
  cancel the first; a territory switch cancels the in-flight plan. Otherwise the slower
  Overpass mirror wins and can resurrect a route the user already ended.

**Tests:** `skippingMovesToTheBack`, `doneHousesLeaveTheQueue`,
`repeatedSkipsKeepTheirOrder`.

### 11.6 Route UI

- **Start point:** the user's location, a tapped house, or a free point picked with a
  crosshair on the map.
- **Route bar** (bottom): tapping the label flies the camera to the next house; three
  compact circular buttons — **Überspringen** (`forward.end.fill` equivalent),
  **Ein-/Ausblenden** (eye / eye-slash, persisted), **Beenden** (✕).
- Distance to the next stop is shown **only when the fix is usable** and under a 20 km
  plausibility cap — without the guard it once read "12258 km".
- Menu entry **"Route neu planen"** re-plans from the current position over the houses
  still open.
- While planning: *"Route wird berechnet …"* plus a progress indicator.
- No hand-off to an external maps app. This is deliberate.

---

## 12. Networking and third-party data

### 12.1 Overpass etiquette

- `User-Agent` must identify the app and version: `Nachbesuch-Android/<versionName>`.
  Overpass mirrors block anonymous clients.
- POST with `application/x-www-form-urlencoded; charset=utf-8`, body `data=<query>`.
- Never retry in a tight loop; respect the deadline; cache (§11.1).

### 12.2 Address import

`AreaHouseImportService`: fetch every `addr:housenumber` node/way/relation inside the
drawn polygon (`poly:"lat lon lat lon …"`), cap at **5 000** results, refuse areas over
**8 km** extent. De-duplicate against existing houses within **12 m**. The result is a
selectable list the user confirms before insert; insert in one Room transaction.

### 12.3 Reverse geocoding for territory names

iOS uses `CLGeocoder` + `GermanPlaceNameExtractor` to name a territory after its place,
with duplicate numbering ("Ottakring 2").

Android: `android.location.Geocoder`. On API 33+ use the async
`getFromLocation(..., GeocodeListener)`; below that the blocking overload must run off
the main thread. **`Geocoder.isPresent()` can be false** on devices without Play
Services — handle it by leaving the generic name and retrying later, exactly as the iOS
code refuses to write a "Gebiet" sentinel that would count as generic forever and be
re-geocoded on every launch.

Port `GermanPlaceNameExtractor` (it picks the useful component out of an Austrian
address — district over city over region) and `GebietNameAllocator` (duplicate
numbering, generic-name detection).

---

## 13. Testing and verification

### 13.1 Ported unit tests (`:domain`, JVM, no device)

Port these first. They are the specification.

| iOS suite | What it pins |
|---|---|
| `ModelSemanticsTests` | day scope, tallies, change signals, damaged blobs, territory invariants |
| `RoutePlannerTests` | TSP quality, network routing, queue/skip, drawn line |
| `ServiceTests` | street parsing, search, centroid, map bounds, pin building/patching |
| `ExportTests` | export scope, note inclusion, ordering |

Target: **all of them green before any UI work starts** (milestone M2 exit criteria).

### 13.2 Debug harness

iOS drives verification through environment variables (`NACHBESUCH_SEED`,
`NACHBESUCH_TAB`, `NACHBESUCH_ROUTE`, `NACHBESUCH_REDUCE_TRANSPARENCY`). Reproduce with
intent extras in debug builds only:

```bash
adb shell am start -n at.volkshilfe.nachbesuch/.MainActivity \
  --ei seed 40 --es tab map --es route auto
adb exec-out screencap -p > route.png
```

Modes to support: `route=pick` (stop at the start-point step), `route=tap` (run the
house-tap branch), `route=auto` (plan immediately), `route=skip` (plan, then skip
twice), `route=hidden` (plan, then hide the overlay). These exist because tap-dependent
paths are otherwise unverifiable from a script — and the one bug that shipped on iOS was
exactly such a path.

Guard all of it behind `BuildConfig.DEBUG`.

### 13.3 Instrumented tests

- Compose UI tests for: recording an outcome, collapsing a street, filter chips,
  export sheet options.
- Screenshot tests (Paparazzi or Roborazzi) for the design system: light/dark, the four
  outcome styles, card and row surfaces, route bar at 320 dp width **with a long German
  street name** (the iOS route bar was crowded until it was measured at that width).

### 13.4 Performance

Macrobenchmark, on a real mid-range device, with a seeded 2 000-house territory:

| Scenario | Budget |
|---|---|
| Cold start to first map frame | < 2.0 s |
| Pan/zoom over 2 000 pins | ≥ 55 fps, zero jank frames > 32 ms |
| Recording one door outcome → pin updated | < 120 ms |
| Territory switch (full pipeline rebuild) | < 800 ms |
| Route plan, graph cached | < 1.5 s |
| List scroll, 2 000 rows | ≥ 58 fps |

Ship a **Baseline Profile**. Add `androidx.tracing` sections mirroring the iOS
signposts (`PerformanceTrace`) so these numbers are attributable.

---

## 14. Milestones

Each milestone ends with a green build, green tests, and an updated
`porting-status.md`.

### M0 — Project skeleton
- Gradle module layout (§3.1), version catalog, Hilt, Compose, Room, DataStore, lint,
  detekt/ktlint, CI that runs `./gradlew test`.
- `de-AT` as the only locale; `strings.xml` with the German copy extracted from the
  Swift sources (do not hard-code strings in composables).
- **Exit:** empty app installs and launches; `./gradlew build` green.

### M1 — Domain models
- `VisitOutcome`, `DayScope`, `DoorResult`, `StoredCoordinate`, `OutcomeTally`,
  pure `Gebiet`/`House` domain models, `CampaignDays`.
- All accessors from §5.1–5.3.
- **Exit:** `:domain` compiles with **zero Android imports**; day-semantics tests green.

### M2 — Persistence + JSON
- Room entities/DAOs, migrations set up (version 1), corrupt-store recovery (§4.5).
- `AppJson` with the Apple-date serializer (§4.3); backup reader/writer incl. legacy v1.
- **Exit:** the iOS backup fixture imports and re-exports byte-stable; all ported
  `:domain` tests green; a 2 000-house insert completes in one transaction < 1 s.

### M3 — App shell and design system
- Theme, tokens, motion, surfaces (§10), notice/snackbar centre, three-tab scaffold with
  tab restoration, debug seed.
- **Exit:** all three tabs navigable with placeholder content; screenshot tests for the
  surface roles in light and dark.

### M4 — Map: render and camera
- **Decide the SDK (§7.1) and record it.**
- Map host, camera persistence + one-time-ever centring, POI presets, attribution
  padding, boundary polygon rendering.
- **Exit:** cold start opens at the persisted camera (verified by killing and relaunching
  after panning 300 km away); POIs visible and muted; attribution never covered.

### M5 — Map: pins
- `PinBitmapCache`, pin pipeline with structural/content versions and the patch path,
  scale tiers with hysteresis, clustering gate with hysteresis, marker windowing.
- **Exit:** 2 000-pin seed pans at budget (§13.4); pins never stick in the wrong tier
  across a full zoom sweep in and out; clustering only appears above the gate.

### M6 — House detail and recording
- `HouseDetailSheet`: per-door outcome buttons, notes, apartment vs single household,
  day-1/day-2 sections, damaged-blob state, undo.
- Entry timestamps shown on every recorded entry.
- **Exit:** recording an outcome updates the pin within budget; undo moves `updatedAt`
  forward; instrumented test covers the full record → pin update loop.

### M7 — List tab
- Sections by street, collapse/expand, filter chips with live counts, search, sort
  (including distance/"Nächste zuerst"), swipe actions, quick status.
- **Exit:** 2 000-row scroll at budget; collapse animation smooth; row surfaces per §10.2.

### M8 — Archive tab
- Territory list by day, active-territory `BalanceSection` with the bar chart, search,
  create/edit territory, day scope picker.
- **Exit:** statistics match the iOS app for the same seeded data (compare numbers
  side by side, screenshot both).

### M9 — Export
- Document builder, PDF renderer with two-pass paging, plain-text export, share sheet,
  export options.
- **Exit:** an Android PDF and an iOS PDF for the same territory contain the same houses
  in the same order, with no times printed.

### M10 — Location and heading
- Continuous updates, permission flows incl. coarse-only and permanent denial, custom
  puck with smoothed heading cone, "locate me", "zum Gebiet springen".
- **Exit:** the dot tracks a walk; the cone is stable (no 0/360 flicker); denial leaves a
  fully usable map.

### M11 — Route
- Graph client + cache, planner, session/queue/skip, overlay, next-stop marker, route
  bar, re-plan, auto-finish.
- **Exit:** all route tests green; on a real territory the drawn line follows streets
  (verify by screenshot against the map's own street geometry); skipping redraws
  correctly; overlay toggle persists; ending during a fetch does not resurrect the route
  on relaunch.

### M12 — Import, backup, polish, release prep
- OSM address import, backup/restore UI, accessibility pass (TalkBack labels for every
  control — the iOS code has them all, port the strings), large-text layouts, baseline
  profile, Play listing, signing, ProGuard rules (keep kotlinx-serialization models).
- **Exit:** §13.4 budgets met on a mid-range device; accessibility scanner clean;
  release build installs and runs from a signed AAB.

---

## 15. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| **Apple-date JSON mishandled** | Every door timestamp off by 31 years; export ordering garbage | §4.3 + a fixture round-trip test in M2, before any UI exists |
| **Marker performance collapse** | The app's core screen is unusable | Bitmap cache + windowing + gate, benchmarked in M5, not at the end |
| **Maps SDK chosen late or changed** | Rewrite of the whole map layer | Decide in M4, record it, do not revisit without a written reason |
| **Liquid Glass copied literally** | Uncanny, slow UI | §10 — translate intent to Material 3, measure blur |
| **Route line wrong after a skip** | User walks the wrong way | Legs, not trimming (§11.4) + the two drawing tests |
| **Clustering too aggressive** | Explicitly rejected by the user once already | Port the exact thresholds and hysteresis (§7.4) |
| **Camera re-centres on every launch** | Explicitly rejected by the user once already | Persistent flag, verified by a cold-start test (M4 exit) |
| **Geocoder unavailable on device** | Territories stay unnamed forever | `isPresent()` check, retry later, never write a sentinel name |
| **Overpass rate limiting / outage** | No route, no address import | Three mirrors, deadline, 30-day disk cache, honest "Luftlinie" fallback |
| **Room destructive migration slips in** | Irreversible loss of field work | Ban it in review; recovery path per §4.5 |

---

## 16. Open decisions for the user

Do not guess these — ask, and record the answer here.

1. **Maps SDK:** Google Maps (needs an API key + billing) or MapLibre (needs a tile
   source)? Affects M4 onward.
2. **Minimum Android version:** 26 proposed. Anything lower complicates dates and blur.
3. **Cross-platform sync:** currently none — backup files are the only bridge. Is
   file-based interchange enough, or is a shared backend expected later? (If later,
   keep `:data` repository interfaces clean now; do not build it.)
4. **Package name / app id** and signing identity.
5. **Distribution:** Play Store, or internal distribution to the fundraiser team?

---

## 17. Quick reference: iOS → Android idiom map

| iOS | Android |
|---|---|
| `@Model` (SwiftData) | Room `@Entity` |
| `@Query` | Room `Flow<List<T>>` query |
| `ModelContext.save()` | Room DAO in a coroutine + transaction |
| `@Observable` class | ViewModel + `StateFlow` |
| `@State` / `@Binding` | `remember { mutableStateOf }` / hoisted state |
| `@Environment(\.self)` | Hilt injection / `CompositionLocal` |
| `Task.detached(priority:)` | `withContext(Dispatchers.Default)` |
| `@MainActor` | `Dispatchers.Main.immediate` |
| `Task.isCancelled` | `coroutineContext.isActive` / `ensureActive()` |
| `.task(id:)` | `LaunchedEffect(key)` / `flatMapLatest` |
| `UserDefaults` | DataStore (Preferences) |
| `Sendable` struct | immutable `data class` in `:domain` |
| `UIViewRepresentable` | `AndroidView` / `maps-compose` |
| `MKAnnotation` / `MKAnnotationView` | `Marker` + `BitmapDescriptor` |
| `MKPolyline` / `MKPolygon` | `Polyline` / `Polygon` |
| `CLLocationManager` | `FusedLocationProviderClient` |
| `CLHeading` | `SensorManager` `TYPE_ROTATION_VECTOR` |
| `UIGraphicsImageRenderer` | `Canvas` + `Bitmap` |
| `PDFRenderer` (UIKit) | `android.graphics.pdf.PdfDocument` |
| `UIActivityViewController` | `Intent.ACTION_SEND` + `FileProvider` |
| `.sheet` | `ModalBottomSheet` |
| `.glassEffect` | translucent `Surface` + optional `RenderEffect` blur (§10) |
| `LazyVStack` / `List` | `LazyColumn` with stable keys |
| `UINotificationFeedbackGenerator` | `HapticFeedbackConstants` |
| `AccessibilityLabel` | `Modifier.semantics { contentDescription = … }` |
| `accessibilityReduceMotion` | animation scale + `AccessibilityManager` |
| Swift Testing `#expect` | JUnit `assertThat` |

---

## 18. First actions for the executing agent

1. Read, in this order: `ios/NachbesuchV5/Models/DoorResult.swift`,
   `ios/NachbesuchV5/Models/House.swift`, `ios/NachbesuchV5/Models/Gebiet.swift`,
   `ios/NachbesuchV5/App/AppSchema.swift`, `ios/NachbesuchV5/Map/MapPinSnapshot.swift`,
   `ios/NachbesuchV5/Route/RoutePlanner.swift`. That is ~1 000 lines and it is the heart of the app.
2. Read `README.md` at the repository root — it documents every fixed bug and the reasoning
   behind the current behaviour. Treat it as the change log of things not to undo.
3. Keep `android/porting-status.md` current against the milestone list from §14.
4. Ask the user the §16 questions.
5. Start M0.
