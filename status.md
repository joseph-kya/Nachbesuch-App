# Status

Last updated: 2026-08-23T20:00:00+02:00 · HEAD: 7d3a0b8 · Tests: iOS 60 passing;
Android domain + data passing · Branches: `salvage/offene-arbeit`,
`refactor/minimal-ui` (beide noch nicht auf `main`)

## In flight
- `refactor/minimal-ui` — Empfohlene Route aus der Oberfläche genommen,
  Stilrichtlinie geschrieben, Entschlackungsdurchgang. Beide Plattformen
  kompilieren und die Tests laufen; **am Gerät durchgeklickt ist nichts davon.**
  Das ist der nächste Schritt.
- `salvage/offene-arbeit` — die vier Features, die als uncommittete Änderungen
  im Arbeitsbaum lagen, jetzt in eigenen Commits.

## Done
- [x] Stilrichtlinie · `51e48d7` · `style.md` — Verfahren statt Geschmack:
  Streichen → Verschieben → Gestalten. Quellen: Apples Material- und
  Design-System-Vorgaben für iOS 26, Rams, NN/g.
- [x] Empfohlene Route ohne Oberfläche · `6c72966`, `37e8698` · auf beiden
  Plattformen aus der Karte genommen, Planer und Gehwegegraph bleiben
  vollständig erhalten und getestet. Rückweg steht in `RouteSession.swift`
  und im README.
- [x] Entschlackung · `ce419ca`, `7d3a0b8` · kein fest verdrahtetes Rot mehr
  als Akzent (iOS **und** Android — auf Android blieb die Kartenchrome rot,
  wenn „Blau" gewählt war), Hintergrund von drei Verlaufsschichten auf eine,
  doppelte Aktion aus der Hinweiskarte entfernt, Identitäts- und
  Zustandsfarbe im Straßenkopf getrennt.
- [x] Listen-Erinnerungen nur Mo–Fr · `d712f63` · beide Plattformen.
- [x] Akzentfarbe konsistent durchgereicht (iOS) · `a679690` · `\.appAccent`
  statt `Color.accentColor`, das auf den Asset-Catalog auflöste.
- [x] „Später" als Chip und Filter in der Liste · `8e75c03`.
- [x] Route straßenweise planen und Termine einplanen · `944d352` · liegt jetzt
  ohne Oberfläche bereit.

## Done — früher
- [x] „Später" und Erinnerungen · `6d61029`, `1c9951d` · fünfter Status mit
  gebuchter Uhrzeit auf beiden Plattformen, plus lokale Mitteilungen: eine je
  gebuchter Tür und die stehende Erinnerung „Nachbesuchsliste an Teamleiter
  senden!" um 14:00, 16:00 und 18:00. Die Uhrzeit liegt als neues optionales
  Feld auf der Tür, nicht am Enum — das Speicherformat bleibt in beide
  Richtungen lesbar, und beide Plattformen haben einen Test dafür. Die
  Vorschlagszeiten kommen aus einem gemeinsam formulierten `RevisitPlanner`;
  ein Android-Test hält dessen Konstanten gegen die iOS-Werte. 14 neue Tests
  auf iOS, 16 auf Android.
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
