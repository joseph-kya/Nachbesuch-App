# V6 — Total Polish: Motion

**Scope:** iOS only. Android is explicitly out of scope for this pass.
**Goal:** every animation in the app is deliberate, consistent, and correct. No
snapping where motion is intended, no motion where none is intended, no two
animations fighting over the same change.

---

## 1. The diagnosis

The app has three animation systems layered on top of each other, and they cancel
each other out. This is not a matter of taste — it produces provably wrong behaviour.

### 1.1 The core bug: cancelled transactions

`.animation(_:value:)` does **not** simply "animate when this value changes". It sets
the animation for its entire subtree, keyed on that value. When the value has *not*
changed, it applies `nil` — which **overrides any ambient `withAnimation`
transaction** coming from outside.

`MapScreen.bottomChrome` ends with:

```swift
.animation(.appFeedback(reduceMotion: reduceMotion), value: mode)
.animation(.appFeedback(reduceMotion: reduceMotion), value: isSelecting)
```

Neither watches `routePhase` or `isAwayFromTerritory`. So this, at the call site:

```swift
withAnimation(.appFeedback(reduceMotion: reduceMotion)) { routePhase = .choosingStart }
```

…is silently discarded by the time it reaches the view. **Every route card
(`RouteStartPrompt`, `RouteStartPicker`, `RouteBar`) appears and disappears with no
animation whatsoever**, and so does `TerritoryButton` — even though both the call
site and the view are written as if they animate. The `.transition(.scale(0.7))` on
`TerritoryButton` never plays.

Affected, confirmed: `routePhase` (4 call sites), `isAwayFromTerritory`.

### 1.2 Stacked animation modifiers

Two `.animation(_:value:)` on the same container means that when a single action
changes both watched values — `exitSelection()` sets `selectedHouseIDs = nil` while
`mode` may also change — two animation scopes fire over the same subtree in the same
transaction. The result is timing-dependent and not reproducible.

Present on both `topChrome` (`isSelecting`, `hasSeenGuide`) and `bottomChrome`
(`mode`, `isSelecting`).

### 1.3 Blanket animation over an entire screen

`ListScreen` applies:

```swift
.animation(.appFeedback(reduceMotion: reduceMotion), value: undo?.id)
```

after `.safeAreaBar`, `.searchable`, `.navigationTitle` and `.toolbar` — i.e. it wraps
the **whole list**. Every time a quick status is applied (which sets `undo`), every
animatable change in the entire list animates: row content, filter-chip counters,
section layout, scroll adjustments. This is the "everything wobbles when I tap a
status" effect. The banner it was meant for already carries its own `.transition`.

### 1.4 Undefined glass transitions for standalone panels

Both chrome containers set `.glassEffectTransition(.matchedGeometry)` as the default
for all descendants. `matchedGeometry` is correct for the two pairs that genuinely
morph into one another (`map.header`: summary ⇄ selection bar; `map.secondary`:
menu ⇄ cancel). It is *wrong* for panels with a unique `glassEffectID` and no
counterpart to morph into — `map.guide`, `map.territory`, `map.locate` — where there
is nothing on the other side of the transition.

### 1.5 Inconsistent conventions

- `MapChrome.swift:368` hardcodes `reduceMotion: false`, ignoring the accessibility
  setting.
- `TerritoryButton` uses `.scale(0.7)`; `Motion.appChrome` defines `.scale(0.97)`.
  Two scale conventions for the same job.
- `AnyTransition.appChrome(reduceMotion:)` exists in `Motion.swift` and is **never
  used anywhere**. The reduce-motion transition path is dead code.
- Only 3 explicit `.transition()` calls exist in the entire app; every other
  conditional view falls back to the implicit default.

---

## 2. The principle for V6

> **One owner per change.** The container that lays out a set of panels owns the
> animation for *whether those panels are present*. The panel owns the animation for
> *its own contents*. Nothing else animates either.

Concretely:

1. **Chrome layout animation is container-owned**, driven by a single composite
   `Equatable` key covering *every* flag that adds or removes a panel. Impossible to
   forget: a new flag that isn't in the key is a compile-time-visible omission, not a
   silent snap.
2. **Call sites stop wrapping chrome-layout state in `withAnimation`.** With the key
   in place it is redundant, and redundancy here is what produced the double-fire.
3. **Content animation is view-owned and narrow** — `statItem` animating its own
   counter is correct and stays.
4. **Every conditional view declares how it enters and leaves.** Glass panels with a
   morph partner use `matchedGeometry`; standalone glass panels use `materialize`;
   non-glass panels use one shared `AnyTransition`.
5. **Reduce Motion is never hardcoded** and always degrades to a fade, never merely a
   shorter slide.

---

## 3. Work items

| # | Item | File |
|---|---|---|
| **M1** | Motion system: make `appChrome` real and used; single scale convention | `DesignSystem/Motion.swift` |
| **M2** | Composite chrome keys; one `.animation` per container; drop redundant call-site `withAnimation` | `Map/MapScreen.swift` |
| **M3** | Correct glass transition per panel (`materialize` for standalone IDs) | `Map/MapScreen.swift`, `Map/MapChrome.swift` |
| **M4** | Explicit transitions on the three route cards | `Map/MapScreen.swift` |
| **M5** | Scope the blanket list animation to the undo banner | `Features/Liste/ListScreen.swift` |
| **M6** | Fix hardcoded `reduceMotion: false`; unify `TerritoryButton`/`LocateButton` | `Map/MapChrome.swift` |
| **M7** | Verify: build, tests, and a screenshot of every chrome state | — |

### Acceptance

- Route cards, territory button and locate button visibly animate in and out.
- Tapping a status in the list animates the banner and **nothing else**.
- Switching selection mode morphs the header rather than cross-fading two panels.
- Reduce Motion produces fades everywhere, no scale and no translation.
- `grep -rn "reduceMotion: false"` returns nothing.
- Build clean, all tests green.

---

## 4. Out of scope for this pass

Deliberately not touched, to keep the change reviewable:

- Map pin/cluster animation (UIKit side, `PinArtCache` + `MapCoordinator`) — already
  reworked and field-verified.
- The next-stop halo/arrow `CAAnimation` — already correct, including the
  reduce-motion and foreground-restart paths.
- Sheet presentation and zoom navigation transitions — system-owned.
- Anything in `android/`.
