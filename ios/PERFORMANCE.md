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
