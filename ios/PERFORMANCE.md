# iOS glass & motion pass — 2026-09-23

Rendering changes that came with the all-glass redesign. Not yet measured on
device; the Xcode build and the checks below are still to be run.

- **No more view-tree rebuilds for banners.** The root notice banner and the list's
  undo banner were installed with `if banner { content.safeAreaBar } else { content }`.
  Each appearance rebuilt the whole `TabView` (or `List`), discarding scroll position
  and state. Both are now always-present overlays.
- **Glass cost is spent where it shows.** iOS 26 uses system Liquid Glass. iOS 18
  uses a real material only for floating chrome (a handful of panels over the map)
  and a blur-free frosted fill for anything that scrolls, so a list row never
  samples its backdrop.
- **Shadows sit on shapes, not views.** A `.shadow` on a whole card rendered its
  text offscreen as well. Scrolling cards (archive, list) no longer cast shadows,
  and iOS 26 glass gets none, because glass brings its own.
- **Progress bars without `GeometryReader`.** `ProgressFillShape` gets its rect for
  free and interpolates its own width: one less measuring pass per bar, which was
  six per balance card plus one per archive card.
- **Dead animation modifiers removed.** Street headers and list rows carried numeric
  morphs, bounces and celebrate springs that never ran, because the list swaps data
  with animations disabled. They were still evaluated per row.

Checks to run on device: scroll a 2,000-house list on an iPhone 11 / iOS 18 and on
iOS 26; open and close streets; switch filters; trigger a notice while scrolled
down (scroll position must hold); Reduce Transparency and Reduce Motion on both OS
versions.

---

# iOS performance checks — 2026-09-05

The list uses native `List` row reuse on iOS 18 and iOS 26. An expanded street,
including a territory-wide nearest-first ranking, no longer instantiates every
house button in an eager card. Street grouping, collapse state, filters, search,
accessibility labels and house-detail transitions remain available.

A value-only cache retains the current list corpus. Reads still include the
complete current territory so deletions cannot be missed, but unchanged houses
reuse their decoded and formatted rows. Scope changes rebuild rows; territory
changes replace the cache. No persisted schema or backup format changed.

Filtering, grouping, distance sorting, filter counts and initial collapse-state
calculation run off the main actor. Cancelled work cannot publish stale results.
Cold loads and scope changes no longer wait through the 180 ms save debounce.
The address parser now splits each new row once, and collapse defaults no longer
sort and group a second copy of the corpus.

Compass observation lives in a map-only child view, avoiding heading-driven
rebuilds of the map screen's chrome. Entering an empty pin selection does not
reconfigure all annotations.

## Measurements

XCTest Debug builds on the same Mac, synthetic 10,000-house inputs, seven measured
iterations with setup outside the measured block. Values are mean wall time.
These are CPU-side preparation timings, not end-to-end launch/save latency or
physical-device frame rates.

| Work | Before, iOS 18.5 | After, iOS 18.5 | After, iOS 26.5 |
|---|---:|---:|---:|
| Build 10,000 list rows from scratch | 391.1 ms | 248.5 ms | 282.2 ms |
| Refresh list after one house changes | Full rebuild (above) | 14.2 ms | 18.5 ms |
| Build 10,000 map pins | 55.2 ms | 56.1 ms | 65.0 ms |
| Patch 100 of 10,000 pins | 1.31 ms | 1.19 ms | 1.58 ms |

The cold list build is about 36% faster on iOS 18. The cached row-preparation
path is about 28 times faster than the previous full rebuild for a single change.
Map snapshot timings are effectively unchanged; the map changes remove
unnecessary UI invalidations rather than replacing the snapshot algorithm.
No before/after speedup is claimed for iOS 26 without a same-runtime baseline.

## Regression coverage

143 tests passed, one skipped, and zero failed on each of iOS 18.5 and iOS 26.5.
Added checks cover unchanged-row
reuse, changed notes/results, insertion, deletion, scope switches, filter counts,
search semantics and empty filtered rankings. Performance tests cover cold list
builds and one-row cache updates alongside the existing map benchmarks.

Run the suite with the current simulator's identifier:

```sh
xcodebuild -project NachbesuchV5.xcodeproj -scheme NachbesuchV5 \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' test
```

For timings only, add `-only-testing:NachbesuchV5Tests/PerformanceBenchmarkTests`.
Xcode's result bundle contains clock, CPU and memory metrics. Preserve a comparable
machine/build configuration when interpreting changes; simulator results do not
establish real-device scrolling, battery use or memory pressure limits.

The interactive simulator-control tool timed out during this pass. Screenshot
inspection and the existing automated tab-switch harness supplement unit tests;
hands-on scrolling and expand/collapse animation acceptance remain device checks.


## Runtime checks

The isolated iPhone 11 / iOS 18.5 and iPhone 17 Pro / iOS 26.5 simulators each
completed the existing 60-switch stress harness with 2,000 synthetic houses
(350 ms between requested tab switches). Both emitted `[TabStress] completed 60
switches`; a subsequent `ps` sample reported 0.0% CPU for each app. This checks
for a sustained redraw loop, not individual dropped frames. The list was also
visually checked in screenshots on both runtimes.

The iOS 26 simulator emitted a UIKit constraint-limit warning during the stress
run. It did not cause a test failure or persistent CPU load; its source and
physical-device impact are not established by this pass.

## Responsiveness and archive pass — 6 September 2026

- Construct `HouseReadService` in a detached task before using its SwiftData actor. This applies to list, map, archive, reminder repair and duplicate-address checks; creating the context from a view did not guarantee a background executor.
- Keep startup backup behind completed initialization, but construct and run its actor off the UI actor. Export scratch cleanup also runs detached and excludes files created during this launch.
- Archive save notifications invalidate a revision rather than counting all houses. Hidden archive tabs defer their encounter-count and backup-label reads until activation.
- Replace duplicate metric tiles and Swift Charts with one result breakdown. Fixed outcome rows keep the card height stable; animation is scoped to numbers and progress tracks, and disabled for those values with Reduce Motion.
- Retain opaque iOS 18 chrome and the existing tab/inset freeze fix. This pass does not add live blur or full-card layout animation.
- Preserve incremental reminder scheduling, but compare trigger/content as well as identifier so changed requests get repaired.

Simulator tests and visual checks are useful regression evidence, not a physical iPhone frame-rate guarantee. A device Instruments run is still required to quantify hitch rate and time to respond under real GPS/map/network load.

Validation for this pass: iOS 18.5 and iOS 26.5 each passed 146 tests, with one intentionally skipped PDF-dump test. The final cancellation-banner fix subsequently passed a simulator build and a repeated 62-switch stress run on iOS 18 with 2,000 synthetic houses. The run completed, showed no cancellation banner, and settled to 0% sampled CPU (RSS fell from approximately 415 MiB shortly after the run to 214 MiB at 70 seconds). These are simulator observations, not controlled before/after device benchmarks.

The iOS 26 repeat also completed 62 switches and settled to 0% sampled CPU (~137 MiB RSS at 51 seconds). Light iOS 26 and dark iOS 18 archive screenshots were inspected. The largest accessibility size exposed a cramped summary header; its title and house count now stack vertically at accessibility sizes. This final layout-only adjustment passed a simulator build.

## Area-selection follow-up

Area selection now scrolls the existing archive layout to the top before committing the new territory in a non-animated transaction. This avoids changing the scroll content height and interpolating unrelated statistics during the same scroll. A superseded request, a filter change, or leaving Archive invalidates the pending switch. Switching from Tag 2 to a one-day territory resets the scope in the same transaction.

The DEBUG-only `NACHBESUCH_AREA_STRESS=12` harness exercises the actual row-selection handler after scrolling to each territory card, alternating between populated and empty areas. It checks that each requested selection commits. This supplements, rather than substitutes for, physical-device animation inspection.

Validation: the area-switch harness completed 12 selections on each of iOS 18.5 and iOS 26.5 with 2,000-house synthetic data. Final screenshots showed the requested area and the new Abblocker label. iOS archive-search tests passed, Android's 63 domain tests passed, and both platform builds succeeded. This wording change retains `earlyNo` as the serialized status, including compatibility with old backups; existing search aliases remain accepted.

## Screenshot-driven UI corrections

- Result choices reserve identical title/description line counts; decorative glyphs are capped. The house editor drops the nested grey result-group panel and uses restrained native-glass controls on iOS 26, with solid accessibility/iOS 18 fallbacks.
- Map search now uses an inline top text field, a stable opaque sheet background, and one large detent. Keyboard focus waits until after initial presentation. This removes the system searchable toolbar relocation and simultaneous medium-to-large detent change.
- Native glass is wired into the actual collapsed street-row backgrounds (the prior SectionSurface component was unused by the current native List). Expanded address rows retain their inexpensive standard backgrounds. iOS 18 stays opaque.
- The visible list filters are All/Open, plus Later when populated or selected. Remaining filters and the legend are in the view menu; an active secondary filter remains visible in the bar.

Validation: simulator build succeeded; iOS 26 dark-mode screenshots of actual house, search, and collapsed list views were inspected. Search field placement was verified, but first-use system keyboard onboarding prevented complete keyboard-interaction validation in this run. No physical-device frame-rate claim is made.

### Unified corners and glass (7 September 2026)

- Audited custom SwiftUI surface, clipping, radius and outline call sites across map, list, archive, house details, appearance, tutorial and notices. Native glass now owns its luminous edge; removed redundant fixed rims from map chrome, content cards and street surfaces.
- Result controls use one press animation instead of combining label scaling with interactive glass deformation. Selection rings share an inset continuous shape, including apartment status chips. Search-field glass stays geometrically stable while editing.
- Inset the result grid inside the transparent Form row: UIKit still clips transparent grouped rows, so the previous smaller tile corners were being cut by the outer Form corners. Archive status icons now use the shared continuous small radius.
- iOS 18 retains opaque surfaces. No added blur, glass containers or per-row shadows. Simulator build: `/tmp/nachbesuch-unified-corners-final.log`. Static visual verification is not a real-device frame-time measurement.
- Inspected simulator screenshots: iOS 26 dark list and house-result sheet, iOS 26 light archive, and iOS 18 dark house-result sheet. Result tiles retain matching upper corners and inset selection rings. Full real-device interaction/animation testing remains outstanding.

### Wave 4 reserves (September 2026)

- Static backdrop only (flat gradients, `drawingGroup`): no full-screen blur behind scrolling content. Pin artwork is prewarmed off the critical path (`PinArtCache.prewarm`, utility QoS) and stays bounded (LRU 260, `clear(keeping:)` trim on memory pressure).
- `DidSaveRefreshGate` folds save bursts (bulk import) into one refresh; `HouseReadService` export/ID reads abort past 10,000 entries (`HouseReadError.tooManyResults`) instead of building unbounded arrays for the main actor.
- Reminder batching stays capped at 49 pending requests with the overflow visible in-app; past times cancel rather than schedule. List query tokens are capped at 10 builder-side as defense in depth.
