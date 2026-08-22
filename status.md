# Status

Last updated: 2026-08-21T23:55:00+02:00 · HEAD: 659811c · Tests: iOS all passing; Android domain+data 26 passing

## In flight
- None.

## Done (pin & boundary bug-fix round — uncommitted working tree)
- [x] Pin state jumping to a random house — root cause: houses stream ordered by
  `updatedAt DESC`, so recording an outcome moved that house to index 0 and the
  marker `forEach` matched composables positionally, shifting every marker slot.
  Fix: each Marker/cluster/draft marker is now wrapped in `key(id)` for stable
  composition identity, and `visibleHouses` renders sorted by id so an edit only
  recomposes that one pin.
- [x] Territory drawing was triangle-only — the primary button flipped from
  "Punkt setzen" to "Speichern" at exactly 3 points (4th point required an
  undocumented long-press). New `BoundaryDrawingCard`: separate always-available
  "Punkt N setzen", explicit "Speichern" (enabled ≥3), undo, live point count,
  plus a filled preview polygon while drawing (iOS parity). Long-press hack removed.
- [x] Placement reticle rebuilt as a visible circular target with label chip
  ("Neues Haus"/"Startpunkt") instead of a lone floating glyph.
- [x] `frameTerritory` no longer crashes when every point is implausible
  (`LatLngBounds.build()` guard) — falls back to a centre move.
- [x] AddHouseDialog: coordinates are read-only by default with a "Koordinaten
  korrigieren" disclosure; implausible manual input can't be submitted.
- [x] Outcome buttons in the detail sheet are labelled chips (emoji + Kurztitle)
  with the current state highlighted — bare emoji buttons before; bulk-fill row
  uses the same labelled chips. `VisitOutcome.shortTitle` added.
- [x] Global rounded shape family added to the theme (text fields, menus,
  buttons, dialogs all consistent).

## Done (Android parity & quality pass)
- [x] Critical cross-platform bug: Android backups emitted fractional-second
  ISO timestamps that Apple's `.iso8601` decoder rejects. `AppJson.iso` now
  truncates to whole seconds (`isoNow` for `exportedAt`); `epochMillis` gained a
  lenient fallback (fractional seconds, ±HH:MM offsets) and returns null on garbage.
- [x] Backup losslessness: export now aborts on damaged/empty-door houses
  (`UnreadableHouseException`, iOS parity) instead of silently exporting empty
  door lists; import backfills missing boundary/name onto existing territories
  and reports skipped records. MainActivity shows import results and abort
  reasons in dialogs.
- [x] Route lifecycle persistence: new `RouteStore` (DataStore) persists start,
  order, skip list, drawn legs and status per territory. Routes survive tab
  switches and process death; deleted houses are pruned live; skips persist;
  switching territories suspends/restores instead of leaking stops; "Route neu
  planen" menu item added.
- [x] Threading: Room no longer force-opened on the main thread (async probe,
  scratch-store swap via repository Flow); air-distance route planning moved off
  the UI thread; 2-opt refinement capped at 6 passes.
- [x] Bilanz statistics ported (`domain/stats/BilanzStats.kt`): strict day-1/day-2
  tallies, pendingRevisits, revisitTargets, day2Progress; archive rows show stat
  pills (Offen/Dabei/Tag 1/Tag 2/Nachbesuche).
- [x] Scored archive search (`ArchiveSearchEngine`): outcome keywords
  (offen/fertig/dabei/früh/spät/niemand/nachbesuch), relative dates
  (heute/morgen/gestern/vorgestern/übermorgen), exact-word > prefix > substring
  scoring with stable tie-breaks.
- [x] Walking-graph edge snapping (`WalkingGraph.snapped`): mid-block stops split
  the nearest segment instead of degrading the whole plan to Luftlinie (iOS parity);
  graph plan now threads snapped waypoints end-to-end.
- [x] House bulk actions: `setOutcomeForOpenDoors`, `restore(units:)`,
  `renameUnit` + detail-sheet UI ("Alle offenen Türen" row, per-door rename dialog).
- [x] Export options dialog (visitedOnly/includeNotes, notes default true like
  iOS) wired through text/PDF exports; PDF renderer rewritten with measured
  pagination, wrapped lines, subtitle, generation header, correct footers;
  slugged file names ("Nachbesuch-Ottakring-2026-08-21.pdf").
- [x] Semantics aligned with iOS: `writeScope` writes Tag 2 only on the exact
  second campaign day; null-island band widened to ±0.0001°; marker outcome rule
  unified in `MapPinSnapshotBuilder.markerOutcome` (no more triple implementation);
  tilt gestures disabled (plan view); `Gebiet.dayIndex`/`formattedDateRange` added.
- [x] Map UX: dark-mode pin palette variants, stacked-pin disambiguation sheet for
  tight clusters (<8 m), haptics on boundary save/route finish, persisted
  satellite/POI/route-overlay toggles (AppSettingsStore), distance-to-next shown
  in the route card.
- [x] Chrome consistency: all five map cards use the shared `ChromePanel`;
  `GlassRow` gained matching elevation; archive export row is a contained toolbar;
  street headers show house counts.
- [x] Tests: domain 21 (+11 new), data 5 new (backup format contract incl.
  fractional-second regression). Full `assembleDebug` green.
- [x] iOS fixes: stale hardcoded User-Agent "Nachbesuch-iOS/2.8" replaced with
  dynamic `AppInfo.userAgent`; silent failure paths now log faults (Gebiet
  boundary encode, RouteStore save/skip-list encode). xcodebuild test SUCCEEDED.

## Blocked
- T1 — needs 👤: create the backup on the production phone, copy it outside the app container, provide its path, and make a second copy.
- T2 CI — needs 👤: confirm GitHub plan and macOS runner budget before enabling macOS CI.
- Android emulator verification of the visual pass — needs 👤 to run the app on a device/emulator (build is green; screenshots not taken in this session).

## Notes for the next session
- Android still has no debug-seed harness equivalent to iOS's `NACHBESUCH_SEED`.
- Remaining known gaps vs iOS: territory auto-naming service (reverse geocoding),
  selection-export from the map selection bar, first-time map guide card,
  performance signposts. All small, none field-blocking.
- `local.defaults.properties`/`secrets.properties` handling unchanged; API key
  still treated as exposed-by-copy (rotate per API_KEY_SECURITY.md).
- The baseline tag `v6.0-feld` must remain the exact field-tested code snapshot; do not rewrite it.
- Remote: `https://github.com/joseph-kya/Nachbesuch-App.git`.
