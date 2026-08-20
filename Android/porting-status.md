# Nachbesuch Android – Porting Status

## M0 – Project skeleton

- [x] New four-module Gradle project (`app`, `ui`, `data`, `domain`)
- [x] JVM 17, Compose, Room, DataStore, kotlinx.serialization, MapLibre dependencies
- [x] German three-tab shell and Android manifest
- [ ] CI/lint/detekt and baseline profile

## M1 – Domain models

- [x] DayScope, strict day-1/day-2 door semantics, territory invariants
- [x] Monotonic timestamps and damaged-data guard shape
- [x] Search, street parsing, centroid, map snapshot, route planner foundations
- [x] JVM tests for the load-bearing semantics

## M2 – Persistence + JSON

- [x] Room schema v1 with frozen Gebiet/House blobs and `updatedAt` indexes
- [x] DataStore camera persistence
- [x] Apple-reference-date door blob codec and ISO backup models
- [ ] Real iOS backup fixture round-trip (fixture still needs to be supplied)
- [ ] Corrupt-store recovery UI

## M3–M12 (current slice)

- [x] M3 shell/theme/surfaces with a native Compose navigation shell
- [x] M4 MapLibre host, persisted camera, one-time first-fix centring, long-press add,
  boundary overlay and live balanced-power location updates
- [x] M5 cached bitmap pins, stable marker diffing, visible-window reduction above
  1,200 houses and off-main Room decoding
- [x] M6 house detail sheet, strict day scope recording, apartment resizing, damaged
  blob warning and delete action
- [x] M7 street-grouped searchable list
- [x] M8 archive with active territory, statistics, territory deletion and creation
- [x] M9 plain-text/PDF/JSON export through the Storage Access Framework; JSON import
  is merge-only and reports skipped records in the data layer
- [x] M10 balanced foreground location updates, persisted first-fix camera centring,
  custom location puck with smoothed rotation-vector heading and German denial notice
- [x] M11 walking-network/Overpass client with three mirrors, 40-second deadline,
  30-day disk cache, cancellable fetch and immutable OSM graph/Dijkstra route; the
  recommended route draws the deterministic `Luftlinie` immediately and upgrades to
  street geometry when the network is available
- [ ] M12 OSM bulk address import, fixture round-trip, corrupt-store recovery UI,
  accessibility audit, baseline profile and release signing

The new project is intentionally not sharing code with the old Android app. It is a
fresh implementation from `porting.md`; the unchecked items are explicit follow-up
work rather than silently substituted behaviour.

## Decisions

- Map SDK: MapLibre Android, so the port does not require a Google API key or billing.
- Minimum Android: API 26.
- Package: `at.volkshilfe.nachbesuch.android`.
- Sync: file-based backup only; no backend.
