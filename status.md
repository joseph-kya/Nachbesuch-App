# Status

Last updated: 2026-08-30T23:21:00+02:00 · Tests: iOS 89 passing, 1 diagnostic
PDF test skipped, 0 fehlgeschlagen on iOS 26.5 and iOS 18.5;
Android domain + data passing · `refactor/minimal-ui` und `salvage/offene-arbeit`
sind auf `main` und auf `origin`

## In flight
- Archiv und Detailblatt brauchen weiterhin einen vollständigen manuellen
  Golden-Path-Durchgang. Die Liste wurde auf iOS 26.5 mit 180 gesetzten Häusern
  visuell geprüft und bedient; Öffnen/Schließen der Straßen, die gemeinsame
  Glasfläche und die Accessibility-Zustände funktionieren.

## Done
- [x] `THE UPGRADE` reliability pass · damaged/empty/readable house data now has
  one shared meaning across map, archive, balance and export; damaged exports
  fail closed. Raw replacements validate before overwrite, backup fetches fail
  explicitly, territory mutations invalidate derived state, and deletion removes
  dependent houses plus reminders only after persistence succeeds.
- [x] Reminder reconciliation · saved revisit promises are rebuilt on launch,
  foregrounding and data changes; the deterministic 49-item revisit budget leaves
  room for the 15 daily reminders and shows overflow/failures persistently in-app.
- [x] Field loop polish · save feedback follows the real SwiftData commit, search
  resolution is single-flight, map cameras are territory-specific, location work
  follows the active map and real scene orientation, and Dynamic Type uses adaptive
  labels without replacing the primary `Haus hinzufügen` action.
- [x] Upgrade regression contract · corrupt data, Tag-2 denominator and reminder
  overflow have dedicated tests. Full suites pass
  on both the current iOS 26.5 and minimum iOS 18.5 simulator runtimes.
- [x] Verlorene Türen auf der Karte · `PendingSave` · Der Karten-Screen brach
  beim Verlassen des Tabs die verzögerte Speicherung **ab**, statt sie
  abzuräumen: ein Status, der innerhalb der 350 ms vor dem Tabwechsel gesetzt
  wurde, war weg. Die Liste hatte diesen Fehler schon behoben, die Karte nicht —
  weil beide Screens eine eigene, wortgleiche Kopie von `scheduleSave()` hielten.
  Die Entprellung und das Abräumen liegen jetzt einmal in
  `Services/PendingSave.swift`, beide Screens räumen in `onDisappear` **und**
  bei jedem Szenenwechsel weg vom Vordergrund ab (das Telefon in der Tasche ist
  auch ein Abbau). Drei Tests halten den Vertrag.
- [x] Nachlese zur Entschlackung · Der Durchgang vom 23.8. hatte vier fest
  verdrahtete Farben stehen lassen — tatsächlich waren es achtzehn Fundstellen,
  weil die erste Suche die Kurzform `.foregroundStyle(.red)` nicht traf.
  Geändert wurde, was den Akzent vertritt statt Bedeutung zu tragen: das
  Platzierungs-Fadenkreuz und der Haus-Pin auf der Karte, die Haus-Kachel im
  Detailkopf, der Bestätigen-Knopf im Gebietseditor (grün neben einem
  akzentgetönten Nachbarn) und zwei blaue Tönungen — Blau ist laut
  `VisitOutcome.later` bereits „noch kein Status" und darf nicht nebenbei
  Dekoration sein. Grün als „erledigt" heißt jetzt `Color.doneTone`. Die Rot-
  und Orangetöne für Warnungen, offene Arbeit und Zerstörendes **bleiben** —
  das ist Bedeutung, nicht Geschmack.
- [x] `extension UUID: @retroactive Identifiable` entfernt · stand am Ende von
  `ListScreen.swift` und erklärte modulweit eine Foundation-Type-Konformität,
  damit genau ein `sheet(item:)` daran binden konnte. Ersetzt durch ein lokales
  `HouseSelection` — dasselbe Muster, das die anderen Screens längst benutzen.
- [x] Stilrichtlinie · `51e48d7` · `style.md` — Verfahren statt Geschmack:
  Streichen → Verschieben → Gestalten. Quellen: Apples Material- und
  Design-System-Vorgaben für iOS 26, Rams, NN/g.
- [x] Routen- und Folgevorschlagsfunktion vollständig entfernt · Planer,
  Gehwegegraph, Overlays, Apple-Maps-Handoff, automatischer Folgevorschlag und
  zugehörige Tests sind aus iOS entfernt. Die Wahl des nächsten Hauses bleibt beim
  Menschen; `Haus hinzufügen` ist wieder die primäre Kartenaktion.
- [x] Entschlackung · `ce419ca`, `7d3a0b8` · kein fest verdrahtetes Rot mehr
  als Akzent (iOS **und** Android — auf Android blieb die Kartenchrome rot,
  wenn „Blau" gewählt war), Hintergrund von drei Verlaufsschichten auf eine,
  doppelte Aktion aus der Hinweiskarte entfernt, Identitäts- und
  Zustandsfarbe im Straßenkopf getrennt.
- [x] Listen-Erinnerungen nur Mo–Fr · `d712f63` · beide Plattformen.
- [x] Akzentfarbe konsistent durchgereicht (iOS) · `a679690` · `\.appAccent`
  statt `Color.accentColor`, das auf den Asset-Catalog auflöste.
- [x] „Später" als Chip und Filter in der Liste · `8e75c03`.

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
