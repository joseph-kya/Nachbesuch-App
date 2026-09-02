# THE UPGRADE

## Nachbesuch iOS — a field-first product, reliability, and design brief

**Prepared:** 30 August 2026
**Target:** `Version 5/ios/NachbesuchV5`
**Platform:** iOS 26, Swift 6, SwiftUI + SwiftData, iPhone and iPad
**Scope:** iOS only. Android is useful context, but not a delivery target in this brief.
**Status:** research and audit proposal; no product code was changed by this document.

> The upgrade is not “more glass.” It is a sharper promise: when somebody is standing
> on a street with one hand occupied, Nachbesuch should make the next correct action
> obvious, record it safely, and get out of the way.

---

## 1. The north star

### The product in one sentence

**Nachbesuch is the calmest possible field companion for door-to-door follow-up work:**
it tells the user where to go next, makes recording a visit nearly instant, preserves
the truth of what happened, and closes the loop later in the archive.

### The one-minute test

Give a colleague an iPhone in bright daylight, with 40 open doors and no explanation.
Within one minute they should be able to:

1. See the active territory and their current position.
2. Identify the next useful door or street.
3. Open a house and record a result with one deliberate tap.
4. Understand that the result is saved.
5. Find the same result again in the list and archive.

If they need to interpret a legend, remember a hidden gesture, or wonder whether the
data survived a tab switch, the product is still asking too much.

### What we should not build

Do not turn a focused private field tool into a CRM, social network, analytics suite,
or generic map playground. Every proposed feature must answer one of these questions:

- Does it reduce time at the door?
- Does it reduce walking or mental load?
- Does it make data loss or ambiguity less likely?
- Does it help the user finish and hand off the work?

If the answer is no, the feature belongs in the “not now” pile.

---

## 2. What exists today

The active app is already more than a prototype. The current Version 5 tree contains:

- MapKit map work with custom house pins, location puck, camera persistence, points of
  interest, area drawing, address import, and route-related services.
- A street-grouped follow-up list with filters, quick outcome actions, undo, and revisit
  times.
- An archive with territory history, balance/statistics, search, PDF/text export, and
  JSON backup/import.
- SwiftData models for territories, houses, doors, two-day campaigns, and legacy
  compatibility.
- A design system with adaptive surfaces, metrics, motion, accessibility labels, and a
  stated “content layer vs. navigation/control layer” distinction.
- Tests for models, import/export, archive search, route planning, map pin snapshots,
  clustering history, reminders/revisit behavior, and pending saves.

The project documentation records 112 passing iOS tests at its last update, but also
states that the list, archive, and detail flows have not yet been manually operated
end-to-end. That is the central risk boundary for the next release: automated coverage
is useful, but the field workflow still needs a real device/simulator walkthrough.

The target is configured for iOS 18 in the Xcode project while the Version 5 README
describes iOS 26/Xcode 26. That mismatch may be intentional for deployment compatibility,
but it must be made explicit. Liquid Glass APIs require an availability strategy if the
deployment target remains below the platform on which the APIs exist.

There is also an older iOS app at the workspace root (`Nachbesuch.xcodeproj`) alongside
the Version 5 app. Release instructions should name the exact project, scheme, bundle
identifier, and source directory. A beautiful fix in Version 5 does not protect users if
the wrong scheme is archived.

### The two-platform contract: iOS 18 complete, iOS 26 exceptional

This is one product with two presentation tiers, not two partially different products.

**iOS 18 is the feature-complete baseline.** It must support the entire field loop:
territory selection, map/list/archive, search, door outcomes, undo, revisit scheduling,
local persistence, backup/export/import, accessibility, and a dependable handoff to
Apple Maps where that action is retained. It gets the same data model, copy, business
rules, failure states, and acceptance tests as iOS 26.

**iOS 26 is the native-excellence tier.** It may add system Liquid Glass behavior,
bottom accessories, scroll-edge effects, zoom transitions, glass morphing, and richer
symbol/haptic polish. These are presentation enhancements around the same semantic
actions. They must never be the only way to understand whether a visit was saved.

Implementation contract:

- Keep domain, persistence, import/export, reminder, and route-removal decisions in
  shared code.
- Isolate iOS 26-only views/modifiers behind `#available(iOS 26, *)` and small
  `@ViewBuilder` adapters.
- Use standard SwiftUI controls first; compiled-with-iOS-26 system components already
  carry much of the new behavior.
- Give every iOS 26 enhancement an iOS 18 equivalent: glass → material/opaque surface,
  morph → matched geometry or short fade, bottom accessory → `safeAreaInset`, zoom →
  standard sheet with a preserved selection anchor.
- Run the same golden-path UI script on the oldest supported iOS 18 device and on iOS
  26. A version is not “supported” if its fallback is merely a compile-time stub.

The release gate is behavioral parity first, then visual differentiation. The iOS 18
build should feel calm and deliberate; the iOS 26 build should feel alive because the
system is helping the controls respond to context.

### Existing strengths to preserve

- The app already corrected a serious day-2 semantic bug by separating recorded values
  from display values. Do not regress this distinction.
- Pending saves are centralized and flushed when a screen disappears or the scene leaves
  the foreground. This is the right reliability pattern.
- The map pin work moved toward a deterministic “one house, one pin” model after prior
  drift and clustering failures. Preserve deterministic geometry and performance tests.
- Stored data shape is intentionally frozen. Treat the backup format as a contract, not
  a convenient place to hide new features.
- Color is already being moved toward semantic use rather than decoration. Keep that
  discipline.

---

## 3. Audit findings: bugs and reliability risks

### Severity key

| Level | Meaning | Release rule |
|---|---|---|
| **P0** | Data can be lost, misreported, or the primary field loop can fail | Fix before feature work |
| **P1** | A common workflow is unreliable, confusing, or silently incomplete | Fix in the next upgrade slice |
| **P2** | Important quality, accessibility, performance, or maintenance gap | Schedule deliberately |
| **P3** | Polish, delight, or exploratory opportunity | Only after the core loop is excellent |

The findings below are grounded in the current source tree. “Potential” means the code
path is real but needs a focused reproduction or UI test before being called confirmed.

### P0 — damaged doors can disappear from derived views

`House` correctly exposes `isDamaged` when `unitsData` cannot decode. Several derived
systems do not preserve that truth:

- `Services/ArchiveIndex.swift` skips a house when decoding fails.
- `Services/DayExportService.swift` skips a house when decoding fails.
- `Map/MapPinSnapshot.swift`, `Features/Liste/ListModels.swift`, and
  `Features/Bilanz/BilanzStatsEngine.swift` fall back to an empty door array.

The result can look like a valid house with zero doors, or an export that silently omits
the house. That conflicts with the backup path, which intentionally aborts when it finds
unreadable door data. The same damaged record must have the same meaning everywhere.

**Fix direction**

- Introduce one explicit `HouseDataState`: readable, empty, damaged.
- Never turn damaged into empty.
- Make list, map, archive, statistics, and export show a visible “Daten beschädigt”
  state with a recovery action.
- Make exports fail closed with the affected address and a repair/export-diagnostics
  option.
- Add a test that corrupts `unitsData` and asserts identical behavior across every
  derived service.

**Acceptance:** no count, export, or pin can claim a damaged house is an empty house.

### P0 — local notification capacity can drop revisit reminders

`ReminderService` schedules one notification per revisit door and 15 recurring daily
list reminders. `UNUserNotificationCenter.add` errors are ignored. iOS limits the
number of pending local notifications; a sufficiently large backlog can therefore
leave some revisit reminders unscheduled with no in-app warning.

**Fix direction**

- Centralize scheduling into a reconciliation pass that knows the pending-request
  budget.
- Reserve capacity for door reminders; do not let the standing reminders consume the
  entire budget.
- If capacity is exceeded, show a persistent in-app warning and a deterministic fallback:
  “Heute fällig” queue, next-due summary, or a single daily digest.
- Verify scheduled identifiers against `pendingNotificationRequests()` after writes.
- Remove `timeSensitive` unless the product truly needs it and the user understands why.

**Acceptance:** a test with 100 postponed doors proves that every due door remains
visible in the app, the user is told what could not be scheduled, and the next-due queue
is still correct.

### P0 — the field workflow is not manually verified end-to-end

The repository status explicitly says that map rendering has been exercised with seed
data, while list, archive, and detail flows have been built and tested but not operated.
This is not a cosmetic gap. It leaves open the most expensive class of bugs: navigation,
sheet dismissal, stale view state, keyboard/scroll behavior, permissions, and save timing
that unit tests do not see.

**Fix direction**

- Add a deterministic `NACHBESUCH_SEED` fixture that creates a small territory and a
  400/2,000-house performance fixture without real addresses.
- Add UI tests for the golden path, but also perform the manual script in §8 on a real
  device and a simulator.
- Record a short “field verdict” after each release candidate: what was actually tapped,
  on which device, under which accessibility settings.

### P1 — backup/import fetch failures are collapsed into empty state

`BackupService.importBackup` uses `try?` when fetching existing territories and houses.
If a fetch fails, the code proceeds with empty arrays. That can turn a storage problem
into an apparent clean import and can create duplicate records or bypass conflict logic.

**Fix direction**

- Make fetch failure a typed error; never substitute `[]` for an unreadable store.
- Show the user whether the operation was “merged,” “added,” or “not performed.”
- Add an import preview with counts and conflicts before mutation.
- Keep the rollback, then verify rollback also clears any scheduled reminders or index
  rebuild work started during the transaction.

### P1 — `replaceUnitsData` bypasses validation

`House.replaceUnitsData(_:)` writes raw `Data` and touches the record. It is described as
a backup-restore funnel, but it does not validate that the data decodes as `[DoorResult]`
before replacing the existing readable value.

**Fix direction**

- Accept `[DoorResult]` or a validated `Data` wrapper, not arbitrary bytes.
- If raw data must remain for migration, decode it first and return a typed error.
- Keep the old data until the replacement is validated and the surrounding import can
  commit atomically.

### P1 — export and index can disagree about the truth

Backup creation aborts on unreadable door data, but PDF/text export and archive indexing
skip unreadable houses. A user can therefore receive a successful operational export
that does not match the backup’s safety model.

**Fix direction:** make a shared `HouseSnapshot` validator the entry point for backup,
export, index, map art, list models, and statistics. All callers must either receive a
valid snapshot or the same surfaced error.

### P1 — dormant route code can misrepresent walking quality

The route services use external Overpass endpoints, cache responses, and report a
fallback message that says the route is shown as a straight line when the walking graph
is unavailable. That is honest, but a straight line can still look like a recommendation
to a user on a street.

**Fix direction:** remove this multi-stop path from the shipping V5 experience. It is
currently dormant, depends on external walking-network data, and can fall back to a
straight-line plan without a user-facing route workflow that explains the degradation.
Keep single-address Apple Maps handoff separate. If a future multi-stop feature returns,
it needs a preview, explicit acceptance, manual reorder, offline/degraded state, privacy
copy, and a visible confidence label before it earns a product name.

### P1 — campaign days depend on the device’s current time zone

`Gebiet.campaignCalendar` uses `Calendar.current`. The source comments acknowledge that
traveling or changing the device time zone can reinterpret saved campaign dates. A user
who records or reviews a territory in another zone can get the wrong day scope.

**Fix direction**

- Preserve the existing storage shape but store the campaign time-zone identifier in a
  migration-safe companion setting or derive a stable “campaign zone” at creation time.
- At minimum, detect a time-zone change and explain the interpretation.
- Add tests around daylight-saving transitions and a device moving from Europe/Vienna to
  another zone.

### P1 — error reporting is inconsistent and many failures are silent

The code contains useful typed errors, but multiple services use `try?` for persistence,
notification registration, route cache writes, and file cleanup. Silence is especially
dangerous for a private field tool because there may be no support team watching logs.

**Fix direction**

- Define an `AppFailure` taxonomy with user-facing German copy and a developer payload.
- Log privacy-safe context: operation, record count, format version, and error category;
  never log donor addresses or notes.
- Every user-initiated action must end in one of: success confirmation, a recoverable
  failure, or an explicit “nothing changed.”
- Keep temporary-file cleanup best-effort, but do not make data writes best-effort.

### P1 — duplicate data pathways are still a regression magnet

The status history records that map and list once held byte-for-byte duplicate save logic,
and that they drifted. The current `PendingSave` fixes the immediate issue, but the same
risk remains for status scopes, route selection, and map/list projections.

**Fix direction**

- Define one `VisitCommand`/`VisitStore` for mutations, undo snapshots, reminder
  reconciliation, index invalidation, and save confirmation.
- Keep views declarative: they issue commands and render state.
- Add parity tests that perform the same command from map, list, and detail surfaces.

### P2 — dense map pins remain a deliberate trade-off, not a solved interaction

The current “one house, one pin” approach removes clustering drift, but `collisionMode =
.none` can make overlapping pins hard to select at dense apartment locations. The current
overlap list is a safety net, not a complete interaction model.

**Fix direction**

- Keep deterministic pin rendering.
- Add a density-aware selection affordance: tap target expansion, a short candidate list,
  and a visible “3 Häuser hier” state.
- Preserve the exact coordinate and avoid changing pin artwork under MapKit transforms.
- Performance-test 2,000 and 3,000 pins with VoiceOver and reduced motion enabled.

### P1 — map semantics can stay stale when pin artwork does not change

`Map/MapAnnotations.swift` can return early when the visual bitmap cache key is
unchanged. That key does not include every semantic value VoiceOver may announce, such
as an edited address or apartment-door count. A pin can therefore look correct while
VoiceOver still reads old information.

**Fix direction:** update accessibility label/value before the visual-art early return,
and treat visual cache identity and semantic identity as separate concerns. Add a test
where only the address changes.

### P1 — archive day-2 progress may use the wrong denominator

The archive index and balance UI need to agree on what “Tag 2 progress” means. A static
audit found a path that increments the day-2 unit count for every door, even when only a
subset was eligible for a revisit. A territory with 100 doors and one revisit target can
then look 1% complete after the only target is finished.

**Fix direction:** carry `revisitTargets` through `ArchiveEntry`, calculate day-2 progress
against eligible revisit doors, and add the 100-door/one-target regression fixture.

### P1 — compass orientation is hardcoded for portrait

The project supports iPhone/iPad families, but the location service sets heading
orientation to portrait. In landscape, the direction cone can be rotated incorrectly.

**Fix direction:** derive device orientation from the active window scene, update it on
rotation, and test portrait, landscape-left, and landscape-right on iPad and iPhone.

### P1 — Dynamic Type can be defeated by single-line chrome and shrink-to-fit text

Map chrome and balance/stat elements use single-line constraints; at least one main map
action relies on a `minimumScaleFactor` as low as 0.6. This makes the text technically
fit by making it smaller, which is the opposite of the accessibility goal.

**Fix direction:** use wrapping, `ViewThatFits`, adaptive stacking, and scrolling sheets.
Treat AX1–AX5 as real layouts, not an edge case. Charts need an adaptive height and
axis-label strategy.

### P1 — German formatting is not centrally localized

The app pins the SwiftUI locale to `de_AT`, but several strings and date/distance formats
are created manually in views and models. There is no visible `.strings`/`.xcstrings`
catalog, and plurals are scattered through source.

**Fix direction:** add a German string catalog, use `String(localized:)` and pluralized
entries, give non-UI formatters an explicit `de_AT` locale, and prefer `FormatStyle` or
`MeasurementFormatter` over ad hoc `String(format:)` output.

### P2 — some apartment outcome chips are below the project’s touch-target contract

The project’s own design rules target 44 pt, but the detail sheet contains outcome chips
around 38 pt high. That is especially risky when the user is standing, moving, or using
one hand.

**Fix direction:** give every outcome control a minimum 44 pt hit region and explicit
content shape, even if the visual pill remains smaller.

### P2 — iPad is mostly an enlarged iPhone layout

The active target uses a three-tab flow but has little evidence of size-class-specific
navigation or a list-detail/split layout. That leaves iPad space, landscape, keyboard,
and pointer support underused.

**Fix direction:** add adaptive `NavigationSplitView`/inspector behavior while retaining
the compact phone flow. Keep selected-house state shared across panes.

### P2 — pin scale thresholds can create main-thread bitmap spikes

When a zoom threshold changes, visible pins can refresh together. Apartment counters
also generate unique bitmap cache keys, and the current path renders that artwork on the
main actor.

**Fix direction:** prewarm the next scale tier, cap/segment the counter cache, consider
live counter labels where appropriate, and profile threshold crossings with Instruments.

### P2 — imported territory mutations may leave the archive index stale

The backup importer can mutate an existing territory’s name or boundary directly without
advancing `updatedAt`, while the archive index uses change stamps to decide when to
rebuild.

**Fix direction:** route imported mutations through methods that touch/invalidate, or
explicitly invalidate the archive index after a successful restore.

### P2 — shared mutable date formatters are a concurrency hazard

The audit found a shared `DateFormatter` marked nonisolated and used around detached
work. Foundation formatters are mutable reference types.

**Fix direction:** replace them with value-based `Date.FormatStyle`, create formatter
instances inside the actor/task that uses them, and add a concurrent formatting test.

### P1 — inactive tabs can keep a stale list/archive projection

The list and archive maintain derived corpora/indexes and their async rebuild tasks are
gated by activation state. A static audit found a sequence where data changes on another
tab, the task exits because the tab is inactive, and returning to the tab does not change
the task key. The derived view can remain stale until another mutation or view recreation.

**Fix direction:** include activation in the task identity or rebuild on activation. Add
an integration test that changes a house on the map, activates the list/archive, and
asserts the status, count, and search result update.

### P1 — territory deletion can orphan houses and leave reminders behind

The archive’s batch house deletion is attempted with `try?` before the territory is
deleted. If that deletion fails, the territory can disappear while its houses remain
orphaned. The territory/map deletion paths also need to reconcile door reminders, not
only the detail-sheet deletion path.

**Fix direction:** prefetch dependent houses, cancel pending and delivered reminders,
delete dependents and territory as one checked operation, and abort on dependent-delete
failure. Add failure-injection tests.

### P1 — backup import is additive, not restorative, but the UI can imply both

Existing houses with matching IDs may be skipped even when the backup contains a newer
or older note, status, address, or timestamp. That is acceptable only if the product
explicitly calls the operation “add missing records.” It is not a restore.

**Fix direction:** offer explicit modes—“Nur fehlende Daten hinzufügen” and “Aus Backup
wiederherstellen”—with a conflict preview. Never overwrite silently. Test a same-ID,
different-status conflict.

### P1 — bulk area import can partially commit and duplicate on retry

The bulk importer saves in chunks. Cancellation or a later failure can leave earlier
chunks committed, while a retry may use a stale duplicate snapshot and insert them again.

**Fix direction:** stage and commit once where feasible, or record an import session with
resume/rollback semantics. Re-fetch fingerprints immediately before the final commit and
show partial progress if partial commit is the chosen behavior.

### P1 — saved revisit times are not necessarily rebuilt into notifications

Startup reapplies the standing daily-list reminders, but a clean device or post-import
state also needs a reconciliation pass for every persisted `.later` door. Otherwise a
backup can contain the appointment while Notification Center contains nothing.

**Fix direction:** derive reminders from persisted data after import, after permission is
granted, and when the app becomes active. Treat the in-app queue as canonical and
notifications as a best-effort projection with visible status.

### P2 — notification taps do not appear to deep-link to the saved house

Reminder content includes house/door IDs, but the presenter implements foreground
presentation without a corresponding response/deep-link path in the audited code.

**Fix direction:** handle notification responses, route to the relevant territory/house/
door, and gracefully fall back to the revisit list if the record no longer exists.

### P2 — delivered notifications need explicit cleanup on deletion

House reminder cleanup discovers pending requests. A reminder that already delivered can
remain in Notification Center after its house is deleted.

**Fix direction:** remove pending and delivered identifiers for the house, and cover the
sequence “reminder delivered → house deleted.”

### P2 — clearing a territory boundary can still look like a real boundary

The boundary setter encodes an empty coordinate array into non-empty `Data`, while
`hasBoundary` checks only whether the blob is empty. Deleting a boundary can therefore
leave the territory looking bounded after reopening.

**Fix direction:** represent no boundary as empty `Data`, or define `hasBoundary` from
decoded coordinate count. Add a delete/reopen regression test.

### P2 — legacy orphan repair may be skipped in an edge-case store

The migration path appears to return early when no legacy `CampaignDay` rows remain,
which can skip repairing houses that still have only a legacy `dayID`.

**Fix direction:** run orphan-house repair independently of legacy-day presence and add a
fixture containing orphan houses but no `CampaignDay` rows.

### P2 — generated PDFs need long-content fixtures

The PDF renderer measures variable-height text in some paths but draws into fixed
rectangles in others. Long addresses, notes, or apartment labels may clip or overlap.

**Fix direction:** render long German addresses and notes, use measured heights for draw
rectangles, and verify both extracted text and page images.

### P2 — test coverage is strongest in pure logic, weakest where risk is highest

The target has valuable model, route, export, and search tests, but the audited tree has
little direct coverage for backup service behavior, reminder reconciliation, archive
index invalidation, app-store recovery, and root migration.

**Fix direction:** add service-level tests with injected persistence/notification/file
dependencies before adding more UI surface.

### P1 — MapKit may continue location work outside the active map

The root keeps tabs mounted, and the custom `LocationService` activation is separate
from `MKMapView.showsUserLocation`. A user can be on Liste or Archiv while MapKit’s own
location pipeline remains enabled, despite the product promise that location is used
while the map is open.

**Fix direction:** pass active state into the map host, disable `showsUserLocation` when
inactive, and make the permission explanation match the actual lifecycle. Add a test for
Map → Liste → Archiv with the location indicator and service counter.

### P1 — the “follow me” state may be unreachable

The locate action recenters once, while a follow command exists without an apparent
caller. This makes a button/state that looks like continuous tracking behave like a
single recenter action.

**Fix direction:** either implement true follow mode with an explicit active state and a
clear stop action, or remove the follow affordance. Keep “recenter once” and “follow me”
as two different concepts.

### P1 — permission revocation can wedge the location stream

The location service can resolve denial/restriction waiters without resetting its
streaming flag. A later authorization may call `beginUpdates()` and immediately return
because the service still believes it is streaming.

**Fix direction:** reset the stream state on denial/restriction, make start/stop
idempotent, and test revoke → re-enable → resume in one process.

### P1 — location usage can leak when the map disappears early

The service uses a reference/use count. If the map disappears before the activation task
delivers its balancing `endUsing()`, the count can remain positive and location updates
can continue.

**Fix direction:** balance usage with an idempotent lifecycle token and a cancellation
`defer`; keep `onDisappear` as a safety net.

### P1 — overview map load needs a measured viewport strategy

The app intentionally removed clustering after a prior drift failure, and that decision
should not be casually reversed. However, a global set of thousands of non-colliding pins
can still create overdraw, unreadability, and memory pressure at overview zoom.

**Fix direction:** benchmark the current deterministic pins at 2,000/3,000 houses, then
consider a separate viewport-level reduction model that never mutates pin geometry or
selection identity. If aggregation returns, it must be a stable, deterministic list
surface—not the old animation-sensitive cluster mutation path.

### P2 — stacked-pin hit testing may miss partially covered houses

The overlap radius is smaller than the full rendered pin head. A lower pin can therefore
be visually covered but not included in the candidate list.

**Fix direction:** derive the hit envelope from the actual rendered bounds and canvas
padding, then test near-overlap cases at each zoom tier.

### P2 — search suggestions need stable identity and single-flight resolution

Suggestion rows receive new IDs on each completer callback, and rapid taps can launch
multiple uncancelled `MKLocalSearch` tasks. A late result can update a dismissed sheet or
select a result the user no longer intended.

**Fix direction:** derive stable suggestion IDs, keep one cancellable resolution task,
disable rows during resolution, and reject stale results before applying selection.

### P2 — invalid coordinates can still reach MapKit

The code has coordinate plausibility validation for bounds, but snapshot creation can
copy raw house coordinates into annotations without the same quarantine. A malformed
import can therefore exclude a record from bounds while still handing MapKit an invalid
annotation.

**Fix direction:** validate house coordinates before snapshot creation and surface the
record as “Koordinate ungültig” instead of using `0,0`/non-finite data.

### P2 — map camera persistence should be territory-specific

If the camera store key is global rather than keyed by territory ID, switching from a
Vienna territory to another city can reopen on the previous territory’s camera and show
an apparently empty map.

**Fix direction:** persist camera state by `gebiet.id`, using the global camera only as a
first-launch fallback.

### P2 — malformed boundary points need sanitation before overlays

Boundary coordinates are decoded and passed toward polygon/polyline construction. A
malformed legacy or imported blob can stretch the overlay unexpectedly.

**Fix direction:** reject non-finite/out-of-range points and require a minimum valid
polygon before drawing. Show a recoverable boundary warning.

### P2 — external map/import dependencies need a stronger offline story

Area address import and walking-network loading depend on network services. The app is
used in stairwells, courtyards, and places where connectivity can disappear.

**Fix direction**

- Add a first-class offline banner and last-success timestamp.
- Keep the map and existing data fully usable without network access.
- Let users save a territory as “ready for field use,” including required map context
  and address data where licensing permits. Do not make a route graph a V5 dependency.
- Make retry a deliberate action, not an automatic spinner that burns battery.

### P2 — the deployment target and Liquid Glass adoption plan are not aligned

The project file reports `IPHONEOS_DEPLOYMENT_TARGET = 18.0`, while the product docs
describe iOS 26. A direct use of current Liquid Glass APIs must be gated or the minimum
deployment target must be raised.

**Fix direction**

- Decide whether iOS 26 is the real minimum for this private app.
- If yes, raise the target and state the device requirement.
- If no, wrap Liquid Glass in `if #available` and keep an accessible, opaque fallback
  using existing `AdaptiveSurface` rules.
- Test both paths; do not let the fallback be a barely legible afterthought.

### P2 — destructive actions need a consistent recovery contract

House and territory deletion is present, and the UI has confirmation affordances, but
the product should establish one rule: destructive work is either undoable immediately
or preceded by a verified export/backup path. A deleted territory with a failed save or
failed reminder cleanup must never leave ghosts behind.

**Fix direction**

- Use a short-lived undo snackbar for house deletion where safe.
- For territory deletion, show what will be removed and offer “Backup first.”
- Reconcile reminders by territory/house after deletion and test pending + delivered
  notification cleanup.

### P3 — the archive is an opportunity to close the loop

The archive already contains the right raw ingredients, but it should answer the human
question “What remains, what happened, and what do I need to send?” before it offers
export formats.

**Fix direction:** make the archive a completion surface with a single next action,
not a storage cabinet full of links.

## 3A. Decision: remove “Empfohlene Route” from V5

The current feature should be removed from the primary experience, not cosmetically
rebranded. The source tree itself says the recommendation UI is absent, while the route
planner/session/network code remains dormant infrastructure. The result is the worst
middle state: code and tests imply a feature, but the user cannot complete a trustworthy
prepare → preview → reorder → start → return → record workflow.

A broken recommendation creates false confidence. For V5, delete the product promise:

> “We found the best route for you.”

Do not replace it with an automatic next-house recommendation. The field worker can
read the map and decide where to go; promoting an inferred choice only occupies the
map's most valuable action area and can be wrong when the location is stale or the
territory data is broad. The map's persistent primary action remains `Haus hinzufügen`.

### Removal scope

- Remove “Empfohlene Route” labels, entry points, route ribbon copy, route-start actions,
  and dormant route state from the main map/list/detail flow.
- Remove or archive `RouteSession`, `RouteStore`, `RoutePlanner`, `RouteOrdering`,
  `RouteSchedule`, `WalkingNetwork`, route overlay props, and route-specific UI/tests
  once a dependency scan confirms they are no longer needed.
- Remove `nextHouse` and every automatic next-stop selector or presentation.
- Remove `Fußroute öffnen` as well. The field distances are short enough to understand
  directly, and leaving Nachbesuch for Apple Maps creates more context switching than
  value. Keep address copy and the in-app house selection as the honest alternatives.
- Update README/status documentation so no dormant route feature is presented as
  shipped functionality.

### Reintroduction bar

Do not bring back multi-stop planning until there is a separate, user-visible product
slice with a preview map/list, manual reorder, “Jetzt hierhin,” skip/recovery behavior,
offline/degraded states, a clear source of truth, and UI tests for returning from Apple
Maps. The later name should be `Route planen`, not `Empfohlene Route`; the user must
accept the plan and be able to explain or undo it.

---

## 4. Steve Jobs–inspired product principles, translated responsibly

This is not an attempt to cosplay Steve Jobs or turn a difficult personality into a
design system. It is a set of product behaviors associated with the strongest Apple
work: focus, end-to-end responsibility, clarity, and care for the unseen details.

### 4.1 Start with the experience, then make the technology disappear

The field user does not want “SwiftData,” “MapKit,” “Overpass,” or “Liquid Glass.” They
want to know which door is next and whether the last tap counted.

**Product consequence:** every technical feature must have a plain-language outcome:

- “Next stop” instead of route graph.
- “Saved” instead of SwiftData write.
- “No connection — using saved map” instead of URLSession failure.
- “Some reminders need your attention” instead of a notification API error.

### 4.2 Focus means saying no to good ideas

The app has several attractive expansion paths: live collaboration, advanced analytics,
AI address cleanup, a full CRM, gamification, custom map styles, and deep settings. The
right question is not whether each is possible; it is whether it strengthens the one-minute
test.

**The first ten things to say no to:**

1. A second dashboard that duplicates the list.
2. A full-screen onboarding tour.
3. Decorative glass on every content card.
4. A map mode that hides pins behind a novel visualization.
5. Route planning or automatic destination suggestions for short field distances.
6. A notification for every minor state change.
7. A required account or cloud sync for an islands workflow.
8. AI-generated notes that invent certainty.
9. Analytics that measure activity instead of completion.
10. Settings that expose implementation details the product can choose itself.

### 4.3 End-to-end responsibility includes the invisible parts

The beautiful screen is not the product if the export loses one house, the reminder is
silently dropped, or an undo leaves a stale map pin. Jobs’s useful lesson here is not
minimalism as decoration; it is caring about the whole object, including the parts no one
sees.

**Product consequence:** reliability work is a headline feature. “Never lose a visit” is
more valuable than another animation.

### 4.4 Make the common action feel inevitable

The most common flow should have one visual answer:

`Map → next house → result → saved → next house`

The UI should not make the user decide whether to use the map, list, archive, or route
system before every visit. Those are views of one work queue, not competing products.

### 4.5 Great details are evidence of respect

Respect shows up as:

- no lost tap when the phone locks or the user changes tabs;
- no tiny controls for a user holding a clipboard;
- no dark gray on translucent glass in sunlight;
- no unexplained color semantics;
- no address read aloud twice by VoiceOver;
- no “success” message when a background operation actually failed;
- no false precision in a route or GPS puck.

### 4.6 The test for every screen

Ask:

> If this screen had to be explained in a product launch sentence, what would the
> sentence be?

If the answer contains “and also,” the screen probably has two jobs. Split the jobs in
the information architecture before polishing the surface.

### 4.7 Jobs’ useful lens: intersection, not imitation

The most useful reading of Jobs’ philosophy is not “make it look like Apple.” It is the
intersection of technology and the liberal arts: technology should disappear into a
humanly legible experience. For Nachbesuch that means the map, local database, haptics,
and system materials only matter insofar as they reduce hesitation at the door.

Apply the lens as five review questions:

1. **Focus:** what is the one action for this moment, and what can be removed?
2. **End-to-end ownership:** does the promise survive persistence, interruption,
   export, accessibility, and the walk back from Apple Maps?
3. **Taste:** does the visual hierarchy make the important thing feel inevitable, or
   merely make every surface look expensive?
4. **Courage:** are we willing to delete dormant route infrastructure and old targets
   rather than protect sunk cost?
5. **Delight with purpose:** does the haptic, morph, or symbol animation confirm a real
   state change, or is it asking for attention without returning value?

The product consequence is intentionally severe: a flawless iOS 18 save flow is more
“Apple-like” than an iOS 26 glass effect that hides a failed write. The upgrade should
feel simpler because decisions, uncertainty, and recovery work have been designed away.

---

## 5. Liquid Glass: what the research actually says

### Ground rules from Apple

Apple’s current guidance is unusually clear:

- Liquid Glass is a dynamic material for controls and navigation that blurs, reflects,
  refracts, and responds to interaction.
- Standard SwiftUI/UIKit components already adopt the system behavior.
- Custom effects use SwiftUI `glassEffect(_:in:)` and can add tint and interactivity.
- Related glass elements should be grouped with `GlassEffectContainer` for performance
  and morphing.
- Liquid Glass belongs primarily in the functional/navigation layer, not as a blanket
  treatment for content cards.
- The clear variant is for visually rich backgrounds; regular glass is the safer default.
- Effects must be limited onscreen and tested with reduced transparency, increased
  contrast, reduced motion, Dynamic Type, light/dark appearance, and real-world lighting.

These rules align with the project’s existing `AdaptiveSurface` and style document. The
upgrade should extend that system rather than create a parallel visual language.

### A useful mental model

```text
                FUNCTIONAL LAYER
       navigation · add house · actions · filters
                 Liquid Glass, sparingly
                           │
                           ▼
                 CONTENT / WORK LAYER
       map · house rows · stats · archive records
              system backgrounds / content panels
```

The map and the visit data are the content. The controls that float above them are the
glass layer. “Glass everywhere” would flatten this hierarchy and make the thing the
user needs to read compete with the thing that helps them act.

### The app’s glass vocabulary

Use a small, named vocabulary rather than ad hoc modifiers:

| Token | Role | Material rule |
|---|---|---|
| `navigationGlass` | tab bar, top-level navigation | system component first; custom only when needed |
| `mapChrome` | map controls, add-house action, map filters | regular glass; one container per region |
| `actionGlass` | transient high-value action dock | tinted only for the primary action |
| `contentPanel` | rows, stats, archive content | opaque/standard material, never nested glass |
| `opaqueFallback` | reduced transparency/increased contrast | no blur dependency; same hierarchy |

### Liquid Glass anti-patterns

- Glass inside glass.
- A glass background behind every list row.
- Clear glass over a busy satellite map with small gray text.
- A colored glass control whose color means nothing.
- A morph animation that moves the user’s focus while they are trying to record a door.
- A blur-heavy screen that looks great in a design file and drops frames with 3,000 pins.
- A “custom” control that ignores VoiceOver, Dynamic Type, reduced motion, or reduced
  transparency.

---

## 6. New product concepts

Each concept includes a product promise, a restrained visual direction, implementation
notes, and a kill condition. The kill condition matters: it keeps innovation honest.

### 6.1 Mission Control — restrained map chrome

**Promise:** “I know what matters right now.”

A compact glass dock floats over the map and contains only:

- current territory name;
- open-door count;
- location confidence;
- one primary action: “Haus hinzufügen.”

When the user is outside the territory, a separate location/territory action can appear.
The map must never replace the add-house action with an inferred destination.

**Implementation**

- One `GlassEffectContainer` around the dock’s sibling controls.
- One `glassEffectID` per morphing role.
- Use `regular` glass over the normal map; switch to an opaque/high-contrast fallback
  when system settings require it.
- Keep the dock above the map content layer and below system alerts/sheets.
- Reuse `AppMetrics`, `Motion`, and `AdaptiveSurface`.

**Kill condition:** if the dock duplicates the filter bar and route bar, remove one of
them. The user gets one answer, not three chrome systems.

### 6.2 Door Action Dock — record without hunting

**Promise:** “I can finish a door in one glance.”

When a house is open, a bottom action dock presents the actual outcomes in a stable
order, with text + symbol + haptic feedback:

`Zusagen · Niemand da · Frühes Nein · Spätes Nein · Später`

The dock is a control layer. The house detail remains content. “Später” opens the time
chooser without displacing the other actions.

**Implementation**

- Use standard `Button` semantics and 44 pt targets.
- Keep action labels visible on iPhone; use a more spacious two-column arrangement on
  iPad and large Dynamic Type.
- Show a small “Gespeichert” confirmation that is tied to the actual save completion.
- Offer an immediate Undo that restores both result and reminder state.
- Avoid color-only differentiation; keep the existing symbols and German labels.

**Kill condition:** if the dock causes a second tap to reach the same action on small
  phones, keep the current detail controls and improve their hierarchy instead.

### 6.3 Automatic next-stop capsule — rejected

No automatic next-stop capsule is part of V5. It duplicates a decision the field worker
can make directly from the map, can surface absurd distances from stale/seeded data, and
displaces the much more frequent `Haus hinzufügen` action. Delete its selector, UI and
tests; do not merely hide it behind a flag.

**Kill condition:** if the capsule does not reduce time-to-next-door in a five-visit
test, remove it and keep the list as the honest source of next work.

### 6.4 Revisit Glance — turn “Später” into a promise

**Promise:** “Postponed does not mean forgotten.”

The app already has revisit times. Make the meaning visible:

- overdue: “Jetzt fällig”;
- next 60 minutes: “Bald”;
- later today: “Heute um 16:00”;
- future campaign day: “Tag 2”.

Use semantic tint sparingly, with words and icons always present. A small glass glance
can appear in the action dock or list header, but the individual list rows remain content
surfaces.

**Implementation**

- Reconcile the glance from the same source as reminder scheduling.
- Never show a reminder as guaranteed unless it was actually scheduled or the fallback
  queue is visible.
- Add “Alle fälligen anzeigen” as the single action.

### 6.5 Adaptive Glass — one design, three realities

**Promise:** “The app works in the sun, at dusk, and with accessibility settings on.”

Define three material modes:

1. **Dynamic:** system Liquid Glass with restrained tint.
2. **Readable:** increased contrast, less translucency, stronger text separation.
3. **Opaque:** reduced transparency or reduced motion path; no blur-dependent meaning.

Do not create a manual “pretty/ugly” switch. Follow system settings and test every
custom surface against the same content.

### 6.6 iPad field desk

**Promise:** “The same truth scales up without becoming a different product.”

On iPad, use a `NavigationSplitView` or adaptive inspector:

- sidebar: territories and active queue;
- center: map or list;
- inspector: selected house/detail or archive facts.

Use glass for the sidebar/inspector chrome, not for every row. On narrow widths, collapse
back to the iPhone flow. Test rotation, Stage Manager/window resizing, keyboard focus,
and pointer hover.

### 6.7 Archive as “done”

**Promise:** “The day ends cleanly.”

Replace the export-link cluster with a completion view:

1. “Was the work complete?”
2. “What remains?”
3. “What should be sent?”
4. “Make backup” as a safety action.

PDF, text, JSON, and import remain available, but behind an organized actions sheet.
The archive should make completion legible before it exposes file formats.

### 6.8 Command surface: Shortcuts and quick actions

Only after the core loop is stable:

- “Open active territory.”
- “Show today’s open doors.”
- “Open next revisit.”
- Home Screen quick action: “Weiterarbeiten.”

These are useful because they reduce navigation, not because they add a marketing bullet.

### 6.9 Saved-and-ready: the signature microinteraction

The best “cool” moment is the moment the user trusts the record. After the local
transaction succeeds, do four things together:

1. Change the status symbol and count immediately.
2. Show `Gespeichert.` beside the action, long enough to be noticed.
3. Keep Undo available and make it restore both outcome and reminder state.
4. Keep Undo in the same action plane.

On iOS 26, use one `GlassEffectContainer` and stable glass IDs for genuine state
changes. On iOS 18, use the same semantic layout with a material capsule and the same copy.
The haptic is a soft confirmation only after `ModelContext.save` succeeds; a failed
save gets an error state and an actionable retry, not a celebratory vibration.

**Test:** tap Save, background the app immediately, return, switch tabs, and verify the
same outcome, count, Undo state, and reminder state.

### 6.10 Haptic language that means something

Use one semantic feedback service rather than scattered calls in views:

| Event | Visual | Tactile rule |
|---|---|---|
| Selection changes | selected pin/status changes | light selection pulse, only on real change |
| Save succeeds | symbol settles + `Gespeichert.` | soft impact or success; after persistence only |
| Undo | status visibly rolls back | crisp light impact |
| Revisit scheduled | date chip appears | selection/appointment pulse |
| Import completes | count summary becomes stable | success notification once |
| Offline begins | `Offline · lokal gespeichert` badge | muted warning once |
| Error | persistent recovery message | warning/error pattern, never max intensity |
| Final door complete | progress reaches zero | one calm success; no confetti |

For iOS 18, prefer `sensoryFeedback`, `UISelectionFeedbackGenerator`,
`UIImpactFeedbackGenerator`, and `UINotificationFeedbackGenerator`. Reserve Core Haptics
for two or three signature patterns such as `Saved and ready` or `Spatial lock`. Detect
hardware capability; iPad and unsupported devices must receive the full visual/text
fallback. Respect Reduce Motion, a user haptics toggle, and Low Power Mode. Never pulse
continuously for location updates, map panning, scrolling, or every imported record.

The visual and textual equivalent is mandatory: haptics can reinforce confidence, but
they can never be the only confirmation.

### 6.11 Spatial lock: make map placement feel precise

When the user manually places or corrects a house, show a crosshair and a small validity
state: `Adresse möglich`, `Koordinate ungenau`, or `Position gespeichert`. As a valid
coordinate threshold is crossed, let the pin and crosshair converge once, then give a
single light impact. Do not continuously vibrate as the map moves.

On iOS 26, a small glass action control can morph from `Haus hinzufügen` to
`Hier eintragen`. On iOS 18, use a material capsule and a short scale/fade transition.
The actual coordinate provenance should be stored (`manuell`, `importiert`, `GPS`, or
`korrigiert`) so the polish does not hide uncertainty.

### 6.12 Selected house lifts; the map stays anchored

Tapping a pin or list row should preserve identity through the transition:

```text
map pin / list row → selected house callout → door outcome sheet
```

On iOS 26, use a source-to-detail zoom transition where available. On iOS 18, use
`matchedGeometryEffect` or a standard detented sheet. In both versions, keep the pin
visible above the sheet, keep the address as the title, and make the same selected house
the VoiceOver focus target. The animation explains continuity; it must not be required
to understand which record opened.

### 6.13 Scroll-edge chrome that gets out of the way

The list should feel spacious at rest and legible when content passes underneath pinned
controls. On iOS 26, adopt the system tab-bar minimization and scroll-edge behavior
where it improves the content boundary. On iOS 18, use `safeAreaInset`, an opaque or
regular material bar, and a one-point separator that appears only while scrolled.

Use this for the boundary between chrome and content, not as decorative blur. At large
Dynamic Type, prefer the stronger readable boundary. With Reduce Transparency, remove
the blur dependency without changing layout or hierarchy.

### 6.14 Status symbols tell the story in place

Animate only the symbol whose state changed:

- open circle → filled checkmark;
- clock → revisit badge;
- location arrow → follow mode;
- warning triangle → damaged or incomplete data.

Use SF Symbol replacement/draw effects where available; use a static symbol or a short
opacity change with Reduce Motion. Never animate every visible row after one save. A
single changed symbol is faster to parse and gives the app a polished identity without
turning the field into a game.

### 6.15 Door stack depth for apartment buildings

For a house with multiple doors, use a restrained layered card or offset stack to show
that the user is working through several doors. The front card is the active door; a
small count says `4 Türen · 2 offen`. Tapping a door advances the stack, with a light
selection pulse. The list remains flat and searchable. Do not use perspective, 3D
rotation, or translucent cards behind dense text.

### 6.16 Confidence, not false precision

Make location and data confidence a first-class, low-noise state:

```text
Hauptstraße 18
Position ±8 m · GPS · 17:42
```

When suspicious, say `93 m vom gespeicherten Standort entfernt` and offer
`Trotzdem öffnen` / `Andere Adresse wählen`. Do not block ordinary work solely on GPS.
Likewise, show `Luftlinie — prüfen` only in legacy route diagnostics; the shipped V5
flow should not present a crow-flight fallback as an optimized walk.

### 6.17 Undo rail with a real recovery contract

After a destructive or consequential change, show a compact rail:

`Gelöscht · Rückgängig`

The action must remain available for a useful interval, be accessible as a named button,
and restore linked state such as reminders and archive/index projections. If undo cannot
restore everything, replace it with a confirmation sheet that says exactly what remains.
This is a stronger trust signal than a decorative completion animation.

### 6.18 Day-end closure, not gamification

When the user finishes a territory, the final state should settle into a calm summary:

```text
Gebiet abgeschlossen
18 von 22 erledigt · 2 Nachbesuche · 2 offen
✓ Lokal gespeichert   ✓ Backup erstellt
```

The progress ring completes once, the remaining count becomes explicit, and the next
actions are `Zusammenfassung`, `Offene Adressen`, or `Export`. No confetti, no infinite
celebration, and no “100%” that hides damaged or unresolved records.

### 6.19 Search as a destination, not a buried field

Search should find addresses, streets, door labels, territories, outcomes, and revisit
dates. Useful scopes are `Offen`, `Nachbesuch`, `Heute`, `Tag 1`, `Tag 2`, and `Straße`.
On iOS 26, use the system search role/bottom presentation if it improves thumb reach;
on iOS 18, keep `.searchable` and make the same scopes available in a compact filter
sheet. Stable suggestion IDs and single-flight resolution are correctness requirements,
not polish.

## 6A. V5-only consolidation: simplify the repository safely

The workspace contains the active Version 5 app plus older top-level app material and a
Version 4 tree. The product direction is V5-only, but deletion is a release operation,
not a cleanup impulse. First make V5 independently buildable and recoverable; then
remove obsolete source from the shipping repository.

### Canonical target

For this iOS brief, the canonical target is:

`Version 5/ios/NachbesuchV5.xcodeproj` → scheme `NachbesuchV5`

The V5 Android tree should not be deleted as a side effect of an iOS consolidation. If
the repository is eventually made iOS-only, archive Android separately and record that
decision in the repository README.

### Safe sequence

1. Create a recoverable archive of the old app and Version 4 outside the shipping tree.
2. Tag or commit the last known-good V5 state before moving files.
3. Run a dependency scan for `Nachbesuch/`, `Nachbesuch.xcodeproj`, `NachbesuchTests/`,
   and `Version 4/`; check scripts, schemes, CI, documentation, and release tooling.
4. Build and test the canonical V5 scheme from a clean checkout.
5. Remove the old targets in one reviewable change, not by deleting similarly named
   files from a broad glob.
6. Update all paths in README, status, next steps, scripts, and onboarding notes.
7. Run the golden path, import/export round trip, notification checks, accessibility
   pass, and clean build again.

Candidate removal is the top-level legacy app and Version 4 only after the scan proves
there is no required migration, fixture, or release dependency. Preserve a dated archive
until at least one production release has shipped from V5 and its backup has been
verified. Never remove user data, SwiftData migration code, or backup compatibility just
because an old UI target is being retired.

### Consolidation acceptance criteria

- One documented iOS project and one documented release scheme.
- No source or docs imply that the old app is still a supported release target.
- No route-only dead code remains after the “Empfohlene Route” removal.
- A clean checkout builds without relying on the archived directories.
- Existing V5 backups import successfully before and after the consolidation.
- The old source is recoverable without restoring it to the shipping target.

## 6B. Comparative research: borrow confidence, not enterprise bloat

The strongest field-service products converge on a simple sequence: prepare a bounded
work package, preview what will happen, work from cached data, record immediately, and
reconcile at the end. Their advantage is not that they expose more controls; it is that
they make state and recovery visible.

### Route products: preview and manual agency

Routific’s mobile workflow separates route preview from active execution and lets a
driver choose a later stop as “go here first” while preserving the remaining work. Apple
Maps supports drag-to-reorder multi-stop routes, but Apple Maps owns navigation rather
than visit state. Nachbesuch should borrow the mental model only for a future explicitly
accepted `Route planen` feature:

- preview map plus list before start;
- visible stop count, distance, and estimated duration;
- manual reorder and `Jetzt hierhin`;
- completed stops never silently reorder;
- returning from external navigation restores the same selected house.

For current V5, this research strengthens removal of `Empfohlene Route`: a label without
those controls is not a route experience; it is an implication the app cannot defend.

### Offline field products: cache, outbox, reconciliation

ServiceNow Field Service, Salesforce Field Service, and ArcGIS Survey123 distinguish
local work from uploaded work. Their useful pattern is portable to an offline-first
private app:

```text
Entwurf → Lokal gespeichert → Backup/Export ausstehend → Exportiert
                                      ↘ Fehler → Erneut versuchen
```

Recommended Nachbesuch copy:

- `Offline-Paket bereit.`
- `12 Änderungen lokal gespeichert.`
- `Letzte Sicherung: heute 17:42.`
- `Export fehlgeschlagen · Erneut versuchen.`

Even without cloud sync, this separates “the phone accepted the visit” from “the file
was exported” and prevents a spinner or silent fallback from becoming a false promise.

### Scoped offline data beats downloading everything

Microsoft Dynamics 365 Field Service emphasizes scoped offline profiles: download only
the active territory, open visits, relevant revisit history, notes, and coordinates.
This suggests a future `Offline-Paket` preflight with record count, last refresh, and
storage estimate. Do not make the archive or unrelated territories a dependency for
today’s field loop.

### Location accuracy as provenance

ArcGIS Field Maps and delivery tools treat coordinate accuracy, source, and capture time
as data. Nachbesuch can implement a smaller version without turning GPS into a gate:
`Position ±8 m · GPS · 17:42`, `Manuell gesetzt`, or `Genauigkeit unbekannt`. This makes
review possible and is more trustworthy than a decorative “precise” location marker.

### What not to import

Do not copy dispatch dashboards, inventory, signatures, chat, or gamified driver scores.
Those systems solve different organizational problems. The transferable insight is
state clarity: planned, attempted, completed, postponed, unresolved, locally saved,
exported, and failed must never collapse into one green percentage.

---

## 7. A proposed information architecture

The three existing tabs are sensible. The upgrade should clarify their jobs:

| Surface | Job | Primary action |
|---|---|---|
| **Karte** | See field work and add or open houses | Haus hinzufügen / Haus öffnen |
| **Liste** | Move through the queue quickly | Ergebnis eintragen |
| **Archiv** | Understand, secure, and send the finished work | Backup / Export |

### Rules

- A selected house is one shared state, not three different detail implementations.
- “Active territory” is global context, not a hidden per-tab setting.
- Filters change the queue, not the underlying data.
- A completed action must update map, list, archive counters, revisit glance, and reminders
  through one mutation path.
- Secondary actions belong in a menu or detail sheet, not beside the primary field action.

### Suggested copy

Keep user-facing German copy short and concrete:

- “Haus hinzufügen”
- “6 Türen offen”
- “Gespeichert”
- “Keine Verbindung — gespeicherte Daten werden verwendet”
- “Daten beschädigt — Wiederherstellung nötig”
- “Erinnerung konnte nicht geplant werden”
- “Backup vor dem Löschen erstellen?”

---

## 8. Verification plan: the work is not done until it survives the field

### 8.1 Golden-path manual script

Run on an iPhone and a simulator with seeded, fictional data:

1. Cold launch with no permission decisions.
2. Grant location while using the app.
3. Confirm first map placement and then pan away.
4. Switch Map → Liste → Archiv → Map; confirm camera and active territory remain.
5. Open a single-house address from the map.
6. Record each outcome once.
7. Record “Später,” choose a suggested time, and verify the list/archive.
8. Leave the app before the debounce interval ends; relaunch and confirm the result.
9. Use Undo; confirm status, timestamp, pin, list, and reminder all revert together.
10. Open a multi-door building; record one door without changing the others.
11. Switch to day 2; confirm day-1 values are not counted as day-2 answers.
12. Filter open/later/completed; verify counts and rows.
13. Search by address, territory, “heute,” and “übermorgen.”
14. Confirm `Haus hinzufügen` remains the persistent primary map action.
15. Disable the network; confirm all saved field work remains usable.
16. Import a fictional area; cancel before commit; confirm no partial houses remain.
17. Export PDF/text/JSON; reopen the generated files.
18. Import the JSON twice; confirm identity-based, idempotent behavior.
19. Corrupt one house’s door data in a test fixture; confirm every surface says damaged.
20. Delete a house; confirm pending and delivered reminders are removed.
21. Delete a territory; confirm its houses and reminders are handled as one operation.
22. Background the app with a pending save.
23. Lock/unlock the device during a visit.
24. Run with Low Power Mode and poor GPS accuracy.
25. Finish with backup verification outside the app container.

### 8.2 Accessibility matrix

Test all core screens with:

- VoiceOver;
- Dynamic Type at the largest accessibility size;
- Increase Contrast;
- Reduce Transparency;
- Reduce Motion;
- Bold Text;
- Differentiate Without Color;
- Assistive Access where the app can expose a simpler core flow;
- light and dark appearance;
- outdoor/bright-room viewing.

The app must not depend on blur, color, tiny icons, or animation to communicate a state.

### 8.3 Performance matrix

Measure before and after visual changes:

| Scenario | Budget / check |
|---|---|
| 400 seeded houses | map opens and list scrolls without obvious hitching |
| 2,000 pins | pan/zoom remains responsive; no mass artwork churn |
| 3,000 pins | memory and frame pacing measured with Instruments |
| 100 revisit doors | reminder reconciliation remains deterministic |
| 10,000 archive houses | index/search stays off the main thread |
| poor network | cancellation and timeout return control to the user |

Liquid Glass effects must be included in the performance budget. Apple explicitly warns
that too many containers/effects can degrade rendering.

### 8.4 Data contract tests

Add fixtures for:

- empty door data;
- corrupt door data;
- legacy v1 backup;
- unsupported backup version;
- truncated JSON;
- duplicate territory IDs;
- two territories on the same day;
- day-2-only answers;
- DST boundary;
- repeated import;
- save failure and rollback;
- notification scheduling beyond capacity.

---

## 9. Delivery roadmap

### Phase 0 — make the truth impossible to lose

**Priority:** P0/P1 reliability.

- Unify readable/empty/damaged data handling.
- Fix silent fetch fallbacks and raw unit replacement.
- Reconcile reminders with capacity and visible fallback.
- Add typed failure reporting.
- Finish the manual golden path.
- Lock down deployment-target/availability decision.

**Exit condition:** a field user can trust the result, export, and reminder story.

### Phase 1 — make the main loop one gesture shorter

- Unify visit mutation path across map/list/detail.
- Add saved confirmation tied to actual persistence.
- Restore `Haus hinzufügen` as the persistent primary map action.
- Make open/later counts and day scope unambiguous.
- Remove the dormant “Empfohlene Route” plumbing and its misleading entry points.
- Remove the single-address Apple Maps handoff and all automatic next-stop guidance.

**Exit condition:** the one-minute test passes without explanation.

### Phase 2 — add Liquid Glass to the control layer

- Establish `navigationGlass`, `mapChrome`, `actionGlass`, `contentPanel`, and
  `opaqueFallback` tokens.
- Build Mission Control as one glass container.
- Build the Door Action Dock only if it reduces taps.
- Add reduced-transparency, increased-contrast, reduced-motion snapshots/tests.
- Measure 2,000/3,000-pin performance before and after.

**Exit condition:** the app feels current without putting glass on content.

### Phase 3 — close the route and day-end loops

- Keep destination choice manual on the map; add no route or next-stop recommendation.
- Revisit Glance tied to reminder reconciliation.
- Archive completion surface.
- iPad inspector/sidebar behavior.

**Exit condition:** the user can move, revisit, and finish without hunting through tabs.

### Phase 4 — selective delight

- Shortcuts/quick actions.
- Subtle, semantic morphing.
- More refined map focus states.
- App icon refresh only if it communicates the product better.

**Exit condition:** every added delight survives the “does this reduce work?” test.

---

## 10. Decision log to keep the team honest

Before implementing a new idea, write one row:

| Question | Answer required |
|---|---|
| What field moment does it improve? | One sentence |
| What does it replace or remove? | A concrete element or step |
| What is the default state? | The choice for a busy user |
| What happens offline? | A usable fallback |
| What happens with accessibility settings? | Opaque/readable behavior |
| What data does it read/write? | Exact models/services |
| What is the failure message? | Plain German copy |
| How will we test it? | Unit, UI, manual, performance |
| What is the kill condition? | A measurable reason to remove it |

If the row cannot be completed, the idea is not ready for the backlog.

---

## 11. Research notes and sources

### Apple platform and Liquid Glass

- [Apple — Liquid Glass technology overview](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [Apple — Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Apple — Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Apple — `glassEffect(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffect%28_%3Ain%3A%29)
- [Apple — `Glass`](https://developer.apple.com/documentation/swiftui/glass)
- [Apple HIG — Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple HIG — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines)
- [Apple HIG — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple HIG — Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Apple HIG — Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Apple HIG — Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)
- [Apple HIG — Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)
- [Apple — Core Haptics](https://developer.apple.com/documentation/corehaptics)
- [Apple — `sensoryFeedback`](https://developer.apple.com/documentation/swiftui/view/sensoryfeedback(_:trigger:))
- [Apple — Preparing an app to play haptics](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics)
- [Apple — `GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- [Apple — `glassEffectID`](https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:))
- [Apple — Tab view bottom accessory](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:))
- [Apple — Scroll edge effects](https://developer.apple.com/design/human-interface-guidelines/scroll-views)
- [Apple — Zoom navigation transition](https://developer.apple.com/documentation/swiftui/zoomnavigationtransition)
- [Apple — Controlling animation timing and movement](https://developer.apple.com/documentation/SwiftUI/Controlling-the-timing-and-movements-of-your-animations)
- [Apple — `PhaseAnimator`](https://developer.apple.com/documentation/swiftui/phaseanimator)
- [Apple — `KeyframeAnimator`](https://developer.apple.com/documentation/swiftui/keyframeanimator)
- [Apple — SF Symbols 7, WWDC25](https://developer.apple.com/videos/play/wwdc2025/337/)
- [Apple — Build a SwiftUI app with the new design, WWDC25](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Apple — New design system, WWDC25](https://developer.apple.com/videos/play/wwdc2025/356/)
- [Apple — Display priority for MapKit annotation views](https://developer.apple.com/documentation/mapkit/mkannotationview/displaypriority)
- [Apple — MapKit annotation clustering](https://developer.apple.com/documentation/mapkit/decluttering-a-map-with-mapkit-annotation-clustering)
- [Apple — Handling location updates in the background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [Apple — Local notification scheduling and the 64-request limit](https://developer.apple.com/documentation/uikit/uilocalnotification)
- [Apple — iOS 26 design announcement](https://www.apple.com/newsroom/2025/06/apple-elevates-the-iphone-experience-with-ios-26/)

### Field-service and navigation comparisons

- [Routific — using the mobile app](https://help.routific.com/en/articles/16-using-the-routific-mobile-app)
- [Routific — changing stop sequence](https://help.routific.com/en/articles/42-how-drivers-can-complete-stops-in-a-different-sequence)
- [Apple Support — multi-stop routes in Maps](https://support.apple.com/en-ie/guide/iphone/iph837d13d03/ios)
- [Apple — `MKDirections`](https://developer.apple.com/documentation/mapkit/mkdirections)
- [ServiceNow — working offline in Agent](https://www.servicenow.com/docs/r/field-service-management/work-order-management/work-offline-fieldservice-mobile.html)
- [Microsoft — mobile offline profiles for Field Service](https://learn.microsoft.com/en-us/dynamics365/field-service/mobile/set-up-offline-profile)
- [Salesforce — Field Service offline considerations](https://help.salesforce.com/s/articleView?id=service.mfs_offline_considerations.htm&language=en_US&type=5)
- [ArcGIS Survey123 — folders and outbox](https://doc.arcgis.com/en/survey123/capture/field-app/quickreferencegetanswers.htm)
- [ArcGIS Field Maps — high-accuracy data collection](https://doc.arcgis.com/en/field-maps/latest/prepare-maps/high-accuracy-data-collection.htm)
- [Routific — completion-location verification](https://help.routific.com/en/articles/70-see-where-deliveries-were-completed)

### Steve Jobs and product philosophy

Use these as historical material to extract principles, not as authority for every
modern design decision:

- [Stanford Report — Steve Jobs’ 2005 commencement address](https://news.stanford.edu/stories/2005/06/youve-got-find-love-jobs-says)
- [Steve Jobs Archive — Make Something Wonderful](https://book.stevejobsarchive.com/)
- [Fortune — Steve Jobs: The Playboy interview](https://fortune.com/2010/11/20/steve-jobs-the-playboy-interview/)
- [Stanford Technology Ventures Program — Secrets at Apple’s Core transcript](https://stvp.stanford.edu/wp-content/uploads/sites/3/2024/09/secrets-at-apples-core-entire-talk-transcript.pdf)
- [Smithsonian — How Steve Jobs’ love of simplicity fueled a design revolution](https://www.smithsonianmag.com/arts-culture/how-steve-jobs-love-of-simplicity-fueled-a-design-revolution-23868877/)

### How the research was translated

The source-backed conclusions are intentionally narrow:

1. Use current system components where they already provide the right behavior.
2. Put custom Liquid Glass around functional controls, not around the content users
   must read.
3. Limit effects and test them under accessibility/performance constraints.
4. Treat simplicity as reduction of decisions, not reduction of visual detail alone.
5. Give reliability, clarity, and end-to-end ownership the same product status as visual
   polish.

---

## 12. The final product sentence

When this upgrade is complete, the app should be describable without a feature list:

> **Open it, see the next useful door, record what happened in one clear action, and
> trust that the work is still there when the day is over.**

That is the bar. Liquid Glass can make the controls feel alive. Research can keep the
patterns current. Steve Jobs’s most useful lesson is the discipline to keep asking what
the product is for until the answer becomes that simple.
