# Nachbesuch

A native iOS and Android app for door-to-door canvassing teams. Volunteers mark
houses on a map, record the outcome at every door across two campaign days, and
get a worklist of doors that still need a follow-up visit (*Nachbesuch*, German for
"revisit").

The app is fully offline-first: all data stays on the device, with JSON backups,
PDF/text reports and an automatic daily safety backup.

| Platform | Stack |
|---|---|
| **iOS** (`ios/`) | Swift 6, SwiftUI, SwiftData, MapKit, Swift Testing |
| **Android** (`android/`) | Kotlin, Jetpack Compose, Room, DataStore, Google Maps Compose |

Both apps share the same domain model and backup format, so a backup made on one
platform restores on the other.

## Features

- **Map** – drop pins by long-press or crosshair, draw territory boundaries, import
  every address inside a territory from OpenStreetMap (Overpass API), live location
  with an accuracy halo and a smoothed compass heading cone.
- **Doors and outcomes** – single houses and apartment buildings with any number of
  units; outcomes are recorded strictly per campaign day (day 1 / day 2).
- **Revisit list** – houses grouped by street, open doors first, live filter counts,
  swipe actions with undo, and scheduled reminders for appointments.
- **Archive** – per-territory statistics, full-text search, PDF and text export, and
  complete JSON backup/restore with versioned formats.
- **Duplicate guard** – adding a house that already exists opens the existing record
  instead of creating a second pin.

## Engineering highlights

- **One pin per house at every zoom level.** Clustering was removed entirely; pin
  images (including text) are pre-rendered and cached, only changed pins are
  updated, and pin size is a pure function of the camera. Tested smoothly with
  3,000+ pins on screen.
- **Strict day semantics.** `DayScope` is a type rather than a raw integer, so a
  day-2 statistic can never silently fall back to day-1 data.
- **Safe persistence.** Versioned SwiftData schema with a migration plan, a recovery
  screen if the store cannot be opened, transactional imports that roll back on
  failure, and unreadable records are flagged instead of overwritten.
- **Battery-aware location.** Location streams only while the map is visible, with
  stale and imprecise fixes rejected.
- **Accessibility.** Dynamic Type up to AX5, VoiceOver labels, Reduce Motion and
  Reduce Transparency support, light and dark mode.
- **Layered Android architecture.** Four Gradle modules – `domain` (pure Kotlin
  business rules), `data` (Room, JSON, PDF), `ui` (theme and shared components) and
  `app` (screens and wiring).

## Project structure

```
ios/
  NachbesuchV5/
    App/            entry point, root navigation, schema
    Models/         SwiftData models and domain types
    Services/       backup, export, OSM import, reminders, search index
    Map/            MapKit host, pin rendering, camera persistence
    Features/       Karte (map), Liste (list), Archiv (archive), shared sheets
    DesignSystem/   spacing, surfaces, motion, iOS 18 / iOS 26 compatibility
  NachbesuchV5Tests/
android/
  domain/   pure Kotlin models and rules (+ JVM unit tests)
  data/     Room, backup codec, PDF export, OSM import
  ui/       Compose theme and shared components
  app/      activity, map, screens, reminders
```

## Building

**iOS** – Xcode 26, deployment target iOS 18:

```bash
cd ios
xcodebuild -scheme NachbesuchV5 -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

**Android** – JDK 17 and Android SDK 36. Create an untracked
`android/secrets.properties` containing `MAPS_API_KEY=<your key>` (Maps SDK for
Android). Without it, the app builds and shows a setup hint instead of the map.

```bash
cd android
./gradlew :app:assembleDebug :domain:test :data:testDebugUnitTest
```

## Note

The user interface is in German, as the app was built for canvassing teams in
Austria.
