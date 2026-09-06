# Status

Last updated: 2026-09-04T07:00:00+02:00 · Tests: iOS Suite grün (volle Suite,
iPhone 17 Pro sim, 0 Warnungen), Android 77 Unit-Tests grün

## In flight
- Der iOS-18-Durchgang ist visuell geprüft (Karte, Liste, Archiv, Exportblatt,
  hell und dunkel, iPhone 11 / iOS 18.5). Zwei Dinge fehlen noch, und beide
  brauchen einen Finger: die **Ausklapp-Animation** einer Straße und der
  Wechsel in den Platzierungsmodus auf der Karte. Der geschlossene Zustand
  selbst ist geprüft (`NACHBESUCH_COLLAPSED=all`); die Bewegung dazwischen nicht.
  Auf diesem Rechner hat weder die Simulator-Integration noch AppleScript
  Bedienungsrechte, also gab es keine Möglichkeit zu tippen.
- Archiv und Detailblatt brauchen weiterhin einen vollständigen manuellen
  Golden-Path-Durchgang. Die Liste wurde auf iOS 26.5 mit 180 gesetzten Häusern
  visuell geprüft und bedient; Öffnen/Schließen der Straßen, die gemeinsame
  Glasfläche und die Accessibility-Zustände funktionieren.

## Done
- [x] iOS-Performance · 2026-09-05: Native List-Zeilenwiederverwendung statt
  eager Straßenkarten, Cache für unveränderte Hauszeilen, Filter/Sortierung/
  Gruppierung im Hintergrund, keine Start-Verzögerung durch den Save-Debounce.
  Kompass beobachtet nur das Kartenblatt; leere Pin-Auswahl zeichnet nicht alles neu.
  Messung iOS 18, 10.000 Häuser: kalter Zeilenaufbau 391 → 249 ms;
  ein geändertes Haus im Cache 14 ms. iOS 26: 282 / 19 ms.
  Je OS 143 Tests bestanden, einer übersprungen; 60 Tabwechsel mit 2.000 Häusern
  abgeschlossen, beide Prozesse danach bei 0 % CPU. Listen-Screenshots geprüft.
  Methodik, Grenzen und verbleibende Geräteabnahme: `ios/PERFORMANCE.md`.
- [x] Review-Korrekturen · 2026-09-05: Archiv-Sicherung liest den vollständigen
  Store inklusive Passanten; Lesefehler brechen ab, statt ein leeres Backup zu
  erzeugen. Erinnerungsabgleich berücksichtigt Passanten-Termine. Android
  bewahrt beim v1-Import Notizen, Mehrparteien-Kennzeichen, beide Tagesergebnisse
  und Zeitstempel. Unbekannte Backup-Versionen und Dateien mit Passanten werden
  vor dem Import abgelehnt; v3 ohne Passanten bleibt lesbar.
  Verifiziert: 137 iOS-Tests auf iOS 18.5, 73 Android-Domain/Data-Tests,
  Android Debug-Lint ohne Fehler (43 Warnungen, überwiegend Versionshinweise).
  Regressionen prüfen den Archiv-Einstieg, Terminabgleich und die gemeinsame
  iOS-v1-Fixture. Geräteabnahme und vollständiger Android-Passanten-Port bleiben offen.
- [x] Passant (Begegnung statt Haus) · SchemaV2 + Backup-Format 3, eigene
  Entität (Notiz, Koordinate, Ergebnis, Rückkehrzeit, Gebiet), runde
  Ergebnis-Scheiben statt Tropfen, Platzierungsmodus mit Personen-Fadenkreuz,
  Detailblatt mit Löschen, Export in PDF/Text (alle Bereiche), Gebiets-
  Löschung räumt mit ab. Vertragsbruch bewusst: next-steps verbietet
  Speicheränderungen ohne Rückfrage — der Auftrag kam direkt vom Eigentümer.
  Migration rein additiv (neue Tabelle, alte Zeilen unangetastet), Fallback
  bleibt der Wiederherstellungsbildschirm. Draußen bewusst: Listen-/Bilanz-
  Zähler, Android-Portierung, Tour-Seite dazu.
- [x] Anleitung (Tutorial) · 7 Seiten (Willkommen, Karte, Haus, Liste, Später,
  Archiv, Datensicherheit), einmal beim Erststart, jederzeit Archiv → ⋯ →
  Anleitung. Eine Implementierung für beide Stufen (contentCard/Hintergrund);
  auf iPhone 11 / iOS 18.5 und iPhone 17 Pro / iOS 26.5 fotografiert. Dabei
  gefunden und sofort behoben: der Tour-Start stand hinter
  `reconcileReminders()`, das auf frischen Geräten auf die
  Mitteilungsfreigabe wartet — nichts Startkritisches darf dahinter stehen.
  Offener Rest: Tour auf echter Hardware einmal durchblättern.
- [x] B1 Automatische Tagessicherung · höchstens 1×/Tag beim Start, komplett
  neben dem Hauptthread, Files-sichtbar (letzte 7, Rest gelöscht), Fehler nur
  im Log. Archiv → Sicherung zeigt die letzte mit Teilen-Knopf. Verifiziert
  auf iPhone 11: 2 Starts → genau 1 Datei, Format 2, 2 Gebiete, 40 Häuser,
  64 Türen, 53 eingetragen. Anfänglicher Fehler (Sicherung lief vor Seed und
  stempelte ein leeres Backup) behoben: Start nach ensureSelection, leere
  Bestände stempeln nicht.
- [x] B2 v1-Importer-Test · Fixture + 4 Tests (Dekodieren, Struct-Treue,
  verwaistes Haus wird übersprungen, Roundtrip verlustfrei). Fixture heißt
  absichtlich `LegacyV1Fixture.json`, damit Hook und .gitignore scharf bleiben.
- [x] T4 Standortgenauigkeit + ehrlicher Punkt · Precision folgt der
  sichtbaren Karte (AccuracyProfile, ein Auslöser), Liste bleibt grob. Punkt
  wird über 25 m hohl/blass, unter 18 m solide (9 Tests). Degradiert-Status
  per NACHBESUCH_FAKE_ACCURACY erzwingbar. Echte Runde (Treffer + Batterie)
  steht aus; Rückfall vorbereitet. Hinweis: Puck-Screenshots auf diesem
  Rechner nicht möglich (kein Tap → keine Standortfreigabe → kein Punkt).
- [x] B6 Ungefährer Standort · einmalige Erklärung mit Weg in die
  Einstellungen; solange Entfernungen versteckt, Punkt unsicher (ergibt sich
  aus der km-Genauigkeit von selbst). Kein plist-Wörterbuch nötig, weil kein
  temporäres, sondern das dauerhafte Recht verlinkt wird.
- [x] B11 Diagnose-Export · Archiv → Sicherung → Diagnose exportieren:
  Version, System, Anzahlen, Speicherstatus, letzte Autosicherung — Tests
  beweisen Abwesenheit von Adressen/Notizen/Koordinaten/Namen.
- [x] B12 Löschen-nach-Export (Schalter aus) · Einstellungen → Daten; Export
  bietet das Löschen an, Löschlogik liegt einmal in GebietDeletion (Archiv
  nutzt denselben Pfad).
- [x] B8 Duplikat öffnen · Warnung bietet Öffnen (statt nur Trotzdem-anlegen),
  plus Abstandstests für die 12-m-Regel.
- [x] B4 Diagnose-Blatt (nur Debug) · Archiv-⋯ lang drücken: Fix-Zähler,
  mittlere Genauigkeit, Ungenau-Anteil, plus Signpost-Events.
- [x] B9 Benchmark-Schranken · Katastrophen-Schranken (25-%-Tor braucht
  Xcode-Baselines, sobald CI existiert).
- [x] Frische Installationen fragen nicht mehr beim Kaltstart nach
  Mitteilungen (Standard aus; Bestand unverändert). Einschalten fragt
  kontextbezogen in den Einstellungen.
- [x] BilanzStatsEngine entfernt · rechnete produktiv nichts mehr; add-Helfer
  nach OutcomeTally, 3 Tests auf ArchiveIndexBuilder umgezogen. Verwaiste
  Routen-Kommentare bereinigt.
- [x] Android Routenfunktion entfernt (Parität mit iOS) · Planer, Graph,
  Overpass-Routenclient, RouteStore, Karten-App-Sprung, Hinweise, toter Key,
  Routen-Tests. Meter-Mathematik als GeoDistance weiterverwendet. Dazu
  versionName 6.0 (eine Produktversion), Android-User-Agent 6.0,
  Release-Signing über keystore.properties verdrahtet, ProGuard-Regeln
  hinterlegt (Minify aus bis zur Geräteprüfung).
- [x] Archiv-Diagnosedocs gelöscht · docs/archive (Audit, UPGRADE, Motion,
  Pin-Drift) war vollständig umgesetzt; porting.md bleibt (Vertrag),
  next-steps.md bleibt (offene 👤-Punkte T1/T3/Feldabnahmen).
- [x] Menü-Wege auf iOS 18 entlastet · `2dd9afe` · „Haus hinzufügen" und
  „Häuser laden" materialisierten zur Sheet-Animation das ganze Gebiet auf dem
  Hauptthread (Fetch + Normalisierung je Adresse); beide lesen jetzt
  `HouseReadService.addressFingerprints` im Hintergrund, der Index baut über
  `offMainActor`. „Auswahl exportieren" holte ebenfalls das volle Gebiet im
  Sheet-Builder — jetzt Holt per ID. `territoryHouses()` ersatzlos entfallen.
  Filterleiste: Gradienten-Maske (Offscreen-Pass pro Frame) durch statischen
  Rand-Fade ersetzt; auf iPhone 11 / iOS 18.5 vorher/nachher fotografiert,
  optisch identisch. Sauberer Checkout baut warnungsfrei, Suite grün.
- [x] `RenderingAndLifecycleTests.swift` vorerst nicht eingecheckt · `608a817` ·
  die Datei braucht `AppTab.isActive` + `DebugSeed.gridDimensions` aus noch
  nicht committeter Arbeit und brach den Test-Build sauberer Checkouts; liegt
  wieder untracked daneben, bis die zugehörige Arbeit committed wird.
- [x] iOS 18 · das Einfrieren beim Tabwechsel · Zwei Ursachen, beide gemessen.
  **Erstens das Layout.** Der Kartenschirm war als
  `Color.clear.overlay { mapStack }` plus zwei weitere Overlays geschrieben, und
  die Chrome-Leisten trugen `safeAreaPadding`. Ein Overlay wird von seiner Basis
  vermessen — eine Basis, die den sicheren Bereich beachtet, mit einem Kind, das
  ihn ignoriert, lässt SwiftUI also zwei verschiedene sichere Bereiche für
  dieselbe Box ausverhandeln; jedes `safeAreaPadding` legte eine weitere Ebene
  darauf. Die `InsetViewLayout`-Aushandlung prüft jedes Kind mehrfach pro Ebene,
  der Aufwand vervielfacht sich also mit der Tiefe, und nach einem Tabwechsel
  konvergiert ein Durchgang gar nicht mehr. Der Hauptthread kehrt aus diesem
  **einen** Layoutdurchgang nie zurück — kein Absturz, keine Schleife im `body`,
  nur ein Bildschirm, der stehen bleibt. Ein `ZStack` sagt dasselbe ohne die
  Aushandlung. **Zweitens die Daten.** `MapScreen` hielt weiterhin eine
  `@Query` über das ganze Gebiet, und `pipelineKey` las im `body` deren `count`
  und `first?.updatedAt` — jedes Neuzeichnen, auch das bloße Wechseln der
  Tab-Auswahl, materialisierte damit 5.000 Modelle auf dem Hauptthread. Karte,
  Liste und Archiv lesen jetzt alle über `HouseReadService`, einen
  `@ModelActor`, und geben unveränderliche Werte zurück; ein Statusklick holt
  über eine Wasserlinie auf `updatedAt` nur die tatsächlich geänderten Häuser
  statt das Gebiet neu zu lesen. Dazu: der Abgleich der Erinnerungen lief nach
  **jedem** Speichern über den ganzen Bestand auf dem Hauptthread und liegt
  jetzt ebenfalls auf dem Aktor, und die Duplikatprüfung der Blätter wird als
  Closure übergeben, weil `.sheet(item:)` seinen Inhalt bei jedem `body` des
  präsentierenden Schirms neu baut. Gemessen mit 5.000 Häusern auf
  iPhone 11 / iOS 18.5: vorher genügte **ein** Wechsel weg von der Karte für
  ~90 % CPU und +2,7 MB/s, dauerhaft. Jetzt fallen 200 Wechsel auf 0 % zurück,
  der Speicher bleibt flach. Harness: `NACHBESUCH_TAB_STRESS`.
- [x] iOS 18 · zwei Ebenen statt einer heruntergeschraubten · Die iOS-18-Fassung
  war iOS 26 mit abgeschalteter Renderpipeline: jede Glas-API hatte darunter ein
  „Material-Äquivalent", und das Ergebnis war genau das, was
  `IOS18_UI_AUDIT_AND_REMEDIATION.md` beschreibt — ein runder Knopf in einer
  zweiten, anders geformten Kiste (Systemstil **plus** eigene Materialkapsel
  **plus** eigener Rahmen um denselben Knopf), eine Tableiste, die sich in der
  Karte auflöst, und Material auf Material bis zum Matsch im Dunkelmodus.
  `LegacyCompat.swift` ist jetzt ein **Zweig**, keine Notlösung: eine Regel, und
  jeder Wrapper hält sie — *eine* View besitzt die Form, *eine* die Füllung,
  *eine* den Rahmen, *eine* den Druckzustand, *eine* die Trefferfläche.
  Konkret: undurchsichtige Flächen statt Materialien (`CompatSurfaceRole`
  unterscheidet Karte, Inhalt und „sitzt auf einer Karte"), die Systemstile
  `.bordered`/`.borderedProminent` allein wo sie reichen und ein eigener Stil nur
  dort wo sie es nicht tun (Kartenknöpfe — eine getönte Füllung bei 15 % ist über
  Kartenkacheln nichts), eine undurchsichtige System-Tableiste
  (`LegacyBarAppearance`), Radien auf iOS-18-Maß (32 pt auf einer flachen Karte
  ist kein Ruhe-, sondern ein Klumpengefühl: 16), ein Hintergrund ohne
  Verlaufsfeld und ohne `blur(60)`, und ein Statuschip-Ton, der im Dunkelmodus
  kräftiger füllt, damit Rot auf Rot lesbar bleibt. Der Hilfeknopf steht auf
  iOS 18 fest neben den Filtern statt rechts aus ihnen herauszuscrollen; die
  Chipreihe blendet nach rechts aus, statt ein Wort abzuschneiden.
  **Die iOS-26-Fassung ist unverändert** — gegengeprüft mit Aufnahmen beider
  Laufzeiten aus demselben Bestand.
- [x] Der Absturz auf dem iPhone 11 · Speicher, nicht Logik · Die App schloss
  sich beim Öffnen von Liste oder Archiv und war im Simulator nicht
  reproduzierbar — die Signatur von Jetsam, denn ein Simulator hat keine
  Speichergrenze und leiht sich die des Macs. Drei vollständige
  `@Query`-Abfragen über *alle* Häuser lagen gleichzeitig im Speicher:
  `RootView` (dauerhaft, für eine Revisionszeichenkette und einen Durchgang
  durch die Türen), `ArchiveScreen` (ungefiltert, also jedes Gebiet, solange der
  Tab montiert ist — und alle drei Tabs bleiben absichtlich montiert) und
  `ListScreen` (das aktive Gebiet). Dazu baute die Liste ihre Zeilen in einem
  `VStack`: bei 1500 Adressen also 1500 Zeilen, Trenner, Knöpfe und
  `matchedTransitionSource` vor dem ersten Bild. Beide Abfragen sind durch
  gebündelte Lesevorgänge über einen eigenen `ModelContext` ersetzt, der mit dem
  Aufruf endet, die Liste ist `LazyVStack`, und das Archiv schlägt Gebiete über
  ein Dictionary statt über einen linearen Durchlauf je Zeile nach.
  Gemessen mit 1500 Häusern auf iPhone 11 / iOS 18.5, Debug: **650 MB → 270–380 MB**,
  und vor allem wächst die Zahl der gebauten Zeilen nicht mehr mit dem Gebiet.
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

## Fehlerpfade (B5-Audit)

| Pfad | Erzwungen durch | Was der Nutzer sieht | Stand |
|---|---|---|---|
| Overpass down (Import) | Flugmodus beim Laden | „Import nicht möglich“ + Wiederholen-Knopf | ✅ Code + UI vorhanden |
| Overpass 429/504 | Drossel/Timeout | Eigene Texte (serviceBusy/requestTimedOut) im Blatt | ✅ vorhanden |
| Standort verweigert | Ablehnung im Systemdialog | Keine Ortungsaktionen; Hinweis mit Weg in Einstellungen | ✅ vorhanden |
| Ungefährer Standort | Genauigkeit „Ungefähr“ | Einmalige Erklärung + Einstellungen; Entfernungen aus, Punkt unsicher | ✅ neu (B6) |
| Platte voll (Export/Backup) | — | Fehlermeldung über NoticeCenter | ⚠️ nicht erzwungen (do/catch vorhanden, Pfad ungeprüft) |
| Datenbank korrupt | — | Wiederherstellungsbildschirm mit Sichern-Angebot | ✅ vorhanden, Start nie provoziert |
| Türdaten beschädigt | Fixture `not-json` | Badge + Sperre, Export bricht ab | ✅ Tests vorhanden |

## Blocked
- T1 — needs 👤: create the backup on the production phone, copy it outside the app container, provide its path, and make a second copy.
- T2 CI — needs 👤: confirm GitHub plan and macOS runner budget before enabling macOS CI. The current runner documentation lists Xcode 26.6 on `macos-26`; `macos-15` currently lists Xcode 26.3.

## Notes for the next session
- Latent gefunden (Tutorial-Arbeit): `reconcileReminders()` wartet auf frischen
  Geräten auf die Mitteilungsfreigabe — `ensureAuthorized()` fragt per Alert und
  kehrt erst nach Antwort zurück. Startkritisches steht davor (Tour, Sicherung),
  aber das Banner `unscheduledRevisits` aktualisiert sich bis zur Antwort nicht.
  Kandidat: erst Settings lesen, nur bei expliziten Aktionen fragen.
- `HouseReadServiceTests` wirft Warnungen („no async operations in await") —
  Datei unberührt, neuere Xcode-Strenge, nicht angefasst.
- Bewusst offen: B3 MapScreen-Split (parallele Arbeit an derselben Datei),
  B7 formale Audit-Artefakte (Geräte), T4 Feldabnahme, T1/T3/CI/Keys (👤).
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

### App Store preparation (2026-09-05)
- Added settings → Datenschutz & Support, bundled German data/permission information, optional real publishing links via AppStoreMetadata.plist, and OpenStreetMap attribution link.
- Added the file-timestamp required-reason API declaration (C617.1). Opening settings with daily reminders disabled no longer requests notification permission; removed redundant daily reminder scheduling from store-save reconciliation.
- Unsigned iOS Release archive succeeded; iOS 18.5 and 26.5 regression suites passed (143 passed, 1 skipped each).
- Prepared German public listing/review notes, six original iPhone/iPad screenshots with synthetic data, archive script and submission preflight. See ios/AppStore/PUBLISHING.md.
- Not submitted: provider/contact/public support/privacy URLs still need actual owner details; privacy/age/trader declarations and Apple signing/TestFlight remain. Signing identity inspection was blocked by automatic approval review (usage-limit error).

### Android and iPhone UI polish (2026-09-05)
- Android list/archive now share a labelled search field, accessible clear button and Search keyboard action that dismisses the keyboard without clearing results.
- Filter help remains visible beside horizontally scrolling chips. Filter, help, sort and day controls use 48 dp minimum targets; day selection is exposed to accessibility services.
- Added list-row disclosure chevrons and distinct lazy-list content types/keys for street headers and houses, preserving row reuse.
- iPhone list headers have slightly more breathing room, address rows have a 44 pt minimum content height, and filter titles keep their intrinsic width. Updated the iPhone list screenshot.
- Verification: iOS simulator build passed; Android assembleDebug, lintDebug, 59 domain tests and 14 data tests passed. Lint: 0 errors, 43 existing warnings, 1 informational item. Use JDK 17 with the checked-in Gradle wrapper.
- The earlier unsigned archive predates this visual pass; regenerate it before TestFlight/submission using ios/scripts/archive.sh after supplying the publishing configuration.

### Motion and haptic refinement (2026-09-05)
- Android: damped layer-only press feedback on outcome tiles, filters and tabs; animated tab highlight and light selection ticks only on actual tab/filter changes. Status picks use a lighter tick instead of a long-press vibration.
- Android: retain saveable state per tab without mounting inactive map content; animate list-row placement without scroll-entry fades; retain banner text throughout shortened, shallow enter/exit transitions.
- iOS: light tab-selection feedback; routine status-save confirmation uses a selection tick, while note/address autosaves stay quiet. Selected outcome scales less; Reduce Motion removes outcome scaling, symbol replacement motion, street-completion bounce and animated chevron rotation.
- Verification: Android build/lint and 73 domain/data tests passed; iOS simulator build passed. Physical-device haptic intensity and frame pacing still require hands-on validation.

### Information accuracy, glass surfaces and Play release preparation (2026-09-06)
- Corrected open-work counting for day-two return visits on both platforms, Android's strict day-two archive statistics, and iOS's first-day “later” revisit targets. Clarified recorded/finished metrics and door/house units.
- Split Android list/archive queries; avoid GPS-driven status-list rebuilds; reduce tally allocations and repeated archive scans. Backups now fetch a strict transactional database snapshot instead of UI caches. Added initial list-loading state.
- Added glossy Android surfaces and richer iOS 18 navigation material with accessibility fallbacks; native iOS 26 glass gets a subtle rim.
- Updated Android to API 36, AGP 8.9.2 and Gradle 8.11.1. Added public-release configuration checks, privacy/support UI, explicit backup extraction rules and native alignment verification. Unsigned AAB builds; 76 Android tests pass, lint has no errors. iOS 18/26 suites pass; refreshed unsigned iOS archive built.
- See QUALITY_AND_RELEASE.md for verification and remaining store-owner/device checks. No submission performed.
