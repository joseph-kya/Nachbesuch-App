# Nachbesuch Android – Porting Status

## M0 – Project skeleton

- [x] New four-module Gradle project (`app`, `ui`, `data`, `domain`)
- [x] JVM 17, Compose, Room, DataStore, kotlinx.serialization, Google Maps dependencies
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
- [x] M4 Google Maps Compose host, persisted camera, one-time first-fix centring,
  standard/hybrid map styles, POI presets, address/place search, long-press and
  reticle-based add, territory draw/edit/delete, framing and live location updates
- [x] M5 cached bitmap pins, one house per pin at every zoom, three deterministic
  readable pin scales, padded visible-window reduction above 1,200 houses,
  selection state and off-main Room decoding
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
  street geometry when the network is available — ENTFERNT (Produktentscheidung
  30.08., Parität mit iOS): Planer, Graph, Overpass-Routenclient, RouteStore und
  Karten-App-Handoff sind ausgebaut; die Meter-Mathematik lebt als GeoDistance weiter
- [x] Interactive route start selection, next-house focus/halo, skip, overlay toggle
  and end controls on the Google map — ENTFERNT (siehe oben)
- [x] M12 OSM polygon address import with preview, safety limits, duplicate filtering
  and batched normal-house creation
- [ ] M12 remainder: fixture round-trip, accessibility audit, baseline profile and
  release signing

## UI-Parität mit iOS (2026-08-22)

Die Oberfläche ist neu gebaut; Domain und Daten blieben bestehen. Neu gegenüber
dem vorherigen Stand:

- [x] Einstellungen: Darstellung (System/Hell/Dunkel) und vier Akzentfarben,
  über DataStore gesichert — vorher gab es auf Android gar keine Einstellungen
- [x] NoticeCenter samt Banner; jeder Schreibpfad meldet Fehler, statt sie zu
  verschlucken
- [x] Undo für Statuseingaben
- [x] Statuslegende samt Gestenhilfe
- [x] Liste: Statusfilter mit Trefferzahlen, einklappbare Straßenabschnitte mit
  Fortschritt, Sortierung nach offener Arbeit oder Entfernung, Schnellstatus
  per Langdruck, Leerzustand je Filter
- [x] Archiv: Bilanz mit Fortschritt, Kacheln und Diagramm, Gruppierung nach
  Kampagnentag, gewichtete Suche, Gebiete bearbeiten
- [x] Detailblatt: Adresse und Notiz bearbeitbar, Türen umbenennbar,
  Sammelaktion, Zeitstempel, Adresse kopieren („Fußroute öffnen“ entfernt, Parität mit iOS)
- [ ] Passant (iOS SchemaV2): Begegnungen erfassen, Scheiben, Detailblatt,
  Backup- und Export-Anbindung — Android-Portierung steht aus
- [x] Export mit Zeitraum, "nur besuchte Adressen" und "Notizen einbeziehen"
- [x] Gemeinsame Positionsquelle (LocationService) für Karte und Liste
- [x] Adaptives App-Icon in der Bildsprache des iOS-Icons
- [x] Karte folgt dem Farbschema (dunkle Palette im Dunkelmodus)

Behobene Fehler: Straßenname brach am falschen Muster um; die Tableiste
stauchte den Inhalt und hinterließ schwarze Kerben; die Exportoptionen
erreichten den Dokumentenbau nie.

MapSurface.kt (1.273 Zeilen) ist in MapSurface/MapChrome/MapDialogs/MapSupport
aufgeteilt, AppScreens.kt in eigene Screens unter `feature/`.

The new project is intentionally not sharing code with the old Android app. It is a
fresh implementation from `porting.md`; the unchecked items are explicit follow-up
work rather than silently substituted behaviour.

## Decisions

- Map SDK: Google Maps through maps-compose. A billing-enabled, Android-restricted
  `MAPS_API_KEY` is required in untracked `secrets.properties`.
- Minimum Android: API 26.
- Package: `at.volkshilfe.nachbesuch.android`.
- Sync: file-based backup only; no backend.
