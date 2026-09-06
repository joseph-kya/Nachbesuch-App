# Nachbesuch Android (fresh port)

This is a new Android implementation based only on `../porting.md`. It does not
reuse the existing Android app. The project is split into four modules:

- `domain`: pure Kotlin models, day-1/day-2 rules, search, map snapshots, route
  ordering and export document logic.
- `data`: Room persistence, Apple-date door JSON, ISO backup JSON, DataStore camera
  state, merge import and PDF rendering.
- `ui`: Compose shell, Material 3 theme and translucent surfaces.
- `app`: activity wiring, Google Maps, cached bitmap pins, location, list/archive
  screens and the house detail workflow.

Open this directory as a Gradle project in Android Studio and let it install the
Android SDK 36 components. Create an untracked `secrets.properties` file in this
directory and add `MAPS_API_KEY=...`; the key must have Maps SDK for Android enabled
and be restricted to `at.volkshilfe.nachbesuch.android` plus the signing certificate.
`local.defaults.properties` keeps builds deterministic when the secret is absent, and
the app then shows an explicit setup card instead of a silently broken map.

Recommended routing draws an immediate deterministic fallback, then
upgrades to a cached Overpass walking graph when the network is available; no route
request blocks the map.

The map persists its camera and centres on the first valid location fix exactly once.
It supports standard/hybrid satellite styles, POI density presets, address/place
search, reticle-based house placement, late clustering, multi-selection, territory
drawing/editing/deletion and an interactive recommended-route bar. Long-pressing the
map remains a fast add shortcut. The blue location puck includes accuracy and a
smoothed heading cone. List rows open the door sheet, where outcomes, multi-unit
counts and deletion are available. Archive export uses Android's Storage Access
Framework for JSON, PDF and plain text.

## Local verification

Use JDK 17 with the checked-in Gradle wrapper (a newer Android Studio bundled JDK
may be incompatible with this Gradle version). Run:

```sh
./gradlew :app:assembleDebug :app:lintDebug :domain:test :data:testDebugUnitTest
```

List and archive share the same accessible search field. The keyboard Search
button dismisses the keyboard while retaining the live results. Filter help stays
visible alongside the scrollable chips; filters, sorting and day controls have
at least 48 dp touch targets. Day controls expose selection to screen readers.

## Motion and feedback

Controls use a short, damped press spring rendered on a graphics layer; no layout
measurement is driven by the press animation. Selected tabs get a soft highlight.
Tab state is saved independently so switching away restores list scroll position
without keeping an inactive map composed. Existing rows animate placement when
ordering changes, with no appearance/disappearance fades during scrolling.

Notice and undo banners retain their last message through a short exit animation.
Haptics are light selection ticks on deliberate changes, not on recomposition or
repeat taps on an already-selected tab/filter. Compose animations use the system
animator duration scale; haptics use the platform feedback API and preferences.
Check physical-device feel before release: simulators cannot reproduce haptics.
