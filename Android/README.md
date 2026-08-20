# Nachbesuch Android (fresh port)

This is a new Android implementation based only on `../porting.md`. It does not
reuse the existing Android app. The project is split into four modules:

- `domain`: pure Kotlin models, day-1/day-2 rules, search, map snapshots, route
  ordering and export document logic.
- `data`: Room persistence, Apple-date door JSON, ISO backup JSON, DataStore camera
  state, merge import and PDF rendering.
- `ui`: Compose shell, Material 3 theme and translucent surfaces.
- `app`: activity wiring, MapLibre map, cached bitmap pins, location, list/archive
  screens and the house detail workflow.

Open this directory as a Gradle project in Android Studio and let it install the
Android SDK 35 components. The app uses MapLibre to avoid a Google Maps key/billing
requirement. Recommended routing draws an immediate deterministic fallback, then
upgrades to a cached Overpass walking graph when the network is available; no route
request blocks the map.

The map persists its camera and centres on the first valid location fix exactly once.
Long-press the map to add an address. The blue location puck includes a smoothed
heading cone when sensors provide a reliable fix. List rows open the door sheet, where
outcomes, multi-unit counts and deletion are available. Archive export uses Android's
Storage Access Framework for JSON, PDF and plain text.
