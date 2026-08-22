# Status

Last updated: 2026-08-22T16:40:00+02:00 · HEAD: d8750dc · Tests: iOS 78 passing, 1 skipped; Android 31 domain + 5 data passing

## In flight
- None.

## Done
- [x] Android UI-Parität · `d8750dc` · Oberfläche neu gebaut, Domain und Daten
  aus der Parallel-Sitzung übernommen. Einstellungen, NoticeCenter, Undo,
  Legende, Bilanz, Filter, Gebietseditor, Exportoptionen, App-Icon und eine
  dunkle Kartenpalette sind dazugekommen; drei echte Fehler behoben
  (Straßenumbruch, gestauchter Inhalt unter der Tableiste, ignorierte
  Exportoptionen). Tests: 31 Domain, 5 Data. Am Emulator geprüft
  (Pixel 10a, API 36). Die iOS-App ist unverändert.
- [x] Android visual quality pass · `e8a5c73` · full neutral colour scheme replacing
  the four-token Material-baseline override (was leaking violet into every
  surfaceContainer/chip/nav-bar tone), bolder type ramp, unified `ChromePanel`/
  `ChromeIconButton` chrome family, floating pill tab bar replacing the stock
  full-width `NavigationBar`. Two real bugs found and fixed along the way: List/
  Archiv content drew under the status bar (RootScaffold was only forwarding the
  Scaffold's bottom padding, not the full edge-to-edge inset set), and the
  "Gebiet anlegen" FAB used the pale `primaryContainer` tint instead of `primary`
  (poor contrast, inconsistent with the rest of the app). Verified on an emulator
  (Pixel 10a, API 36) with before/after screenshots of Karte, Liste and Archiv.
  `.gitignore`'s `data/schemas/` pattern was root-anchored and stopped matching
  after the ios/android split — fixed to `**/data/schemas/` in a separate commit
  (`f24ea67`) so the Room schema export doesn't show up as an untracked file.
- [x] T2 — Version control · `cb610f7` · 135 files, `v6.0-feld`, hook installed and demonstrated, `main` and tags pushed to `origin`
- [x] Platform verification — iOS clean build/test: 78 passed, 1 diagnostic PDF test skipped, 0 failed; Android unit tests: 11 passed, 0 failed
- [x] Android retained — active import/map work integrated under `android/`; generated Gradle/IDE/schema files excluded
- [x] Repository cleanup — platform source grouped under `ios/` and `android/`; documentation and build commands aligned with the monorepo layout

## Blocked
- T1 — needs 👤: create the backup on the production phone, copy it outside the app container, provide its path, and make a second copy.
- T2 CI — needs 👤: confirm GitHub plan and macOS runner budget before enabling macOS CI. The current runner documentation lists Xcode 26.6 on `macos-26`; `macos-15` currently lists Xcode 26.3.

## Notes for the next session
- Google Maps tiles took several seconds to appear on a cold emulator launch —
  a `SecurityException: GoogleCertificatesRslt: not allowed` for the debug
  keystore's SHA-256 appears in logcat at startup, but tiles rendered correctly
  once loading finished, so this looks like a benign Play-services flag-config
  warning rather than a hard block. Worth registering the debug SHA-1
  (`1F:43:73:55:DE:1E:1B:95:6C:20:44:03:93:7D:AF:81:FE:DD:B9:E2`) against the
  Maps API key in Cloud Console anyway so no feature silently degrades — 👤,
  needs console access.
- Android still has no debug-seed harness equivalent to iOS's `NACHBESUCH_SEED`
  (porting.md §13.2 called for one); the 1490-house "Klagenfurt" territory seen
  while testing is leftover data from an earlier session's Room database, not
  anything this session created.
- Not yet touched this pass: the archive's plain-text export action row
  (`Backup JSON · PDF · Text · Importieren`) is a bare `TextButton` row and
  looks more like a list of links than the toolbar it functions as; the
  `OutlinedTextField` search bars don't match the app's rounded chrome radii.
  Neither is broken, both are candidates for a follow-up polish pass.
- Repository root is `Version 5/` under the current snapshot until Task 3 promotes it to `~/Documents/Nachbesuch/`; platform source now lives under `ios/` and `android/`.
- The baseline tag `v6.0-feld` must remain the exact field-tested code snapshot; do not rewrite it.
- The acceptance grep for `backup` also matches required production source names; no backup/export JSON or PDF is tracked.
- Remote: `https://github.com/joseph-kya/Nachbesuch-App.git`.
