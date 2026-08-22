# Pin drift after a cluster round trip — measured findings

**Symptom (reported):** pins are exact at launch. Zoom fully out until everything
collapses into one cluster, then zoom back to street level: the pins return but sit
off their coordinates and drift in different directions on further zoom/pan.
Permanent until an app restart.

**Already tried and ruled out by the reporter:** pin sizes, canvas, anchor points,
cluster hysteresis, removing and re-adding all annotations, creating fresh annotation
objects. A canvas change made it *more* pronounced.

---

## 1. What was measured

A DEBUG harness (`NACHBESUCH_ZOOMBUG=1`) drives the sequence programmatically and
dumps, per realised pin view: coordinate, converted screen point, `center`,
`centerOffset`, `image.size`, `bounds.size`, `transform`.

### Finding A — MapKit puts its own transform on member views (confirmed)

While clustering is active, every member view carries a non-identity transform, and
**a different translation per pin**:

```
transform=CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx:  0.183, ty: 10.374)
transform=CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx:  0.733, ty:  9.038)
transform=CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: -0.183, ty:  9.706)
```

This is MapKit gathering members toward the cluster centre. It is expected behaviour,
not the fault — but it means the views are *not* in a neutral state during the whole
cluster transition.

### Finding B — the app swaps artwork underneath that transform (confirmed, 78×)

`HousePinView.applyArt()` assigns `image` (which replaces `bounds`) and
`centerOffset`. Instrumenting it showed this happening **78 times in a single
zoom-out/zoom-in round trip while the view had a live MapKit transform**:

```
PIN-ART-UNDER-TRANSFORM #1 ty=9.71 oldBounds=23x28
PIN-ART-UNDER-TRANSFORM #2 ty=10.37 oldBounds=23x28
...
```

Cause: the pin scale tier changes (`full → compact → dot → full`) during exactly the
zoom range where MapKit is animating the cluster. `UIView`'s `frame` is documented as
undefined while a non-identity transform is applied, so mutating `bounds` there is
unsafe regardless of whether it is *this* bug.

**Recommended fix** (neutralise, swap, restore):

```swift
let activeTransform = transform
if !activeTransform.isIdentity { transform = .identity }
image = cache.pinImage(for: key)
centerOffset = cache.centerOffset(for: scale)
if !activeTransform.isIdentity { transform = activeTransform }
```

**Caveat, stated plainly:** the transforms observed are *pure translations*. For a
pure translation the rendered position is `center + translation` and a bounds swap
alone should not move the pin. So Finding B is a real defect and worth fixing, but it
is **not proven** to be the cause of the reported drift.

---

## 2. What could NOT be reproduced

Three scripted attempts, all showing **zero drift** in the final state:

| Attempt | Method | Result |
|---|---|---|
| 1 | `setRegion` out (120° span) → wait 5 s → back → wait 6 s | 0 drifted / 39 |
| 2 | Same, with art-under-transform counting | 0 drifted / 39 |
| 3 | Five overlapping `setRegion` calls interrupting each other mid-flight | 0 drifted / 39 |

When each animation is allowed to finish, MapKit re-lays the views out at the end and
any intermediate inconsistency is repaired. The reported repro therefore likely needs
something the harness does not do — most plausibly a **real continuous pinch** (many
small region changes per frame) and/or zooming further out than a 120° span.

### A correction worth recording

The first metric compared `view.center` against
`convert(coordinate) + view.centerOffset`. That is close to tautological: it uses the
view's *own* offset on both sides, so a stale `centerOffset` cancels out and the check
reports success even when the pin is visibly wrong.

The corrected metric measures the **pin tip** — the part that must land on the
building — against the coordinate, via
`HousePinView.tipOffsetFromCoordinate(in:)`. With that metric the clustered state
immediately reports drift equal to MapKit's own translation, confirming the metric
now detects real positional error.

---

## 3. How to capture the real repro

`NACHBESUCH_PINWATCH=1` enables a continuous watch. It runs on every
`regionDidChangeAnimated`, is skipped while clustering is on (where MapKit's gathering
offset is intentional), and prints only when unclustered pins are off their
coordinates by more than 1.5 pt:

```
PINWATCH drift=12/39 worst=18.4pt (8936) clustering=off scale=full
```

Run a debug build with that variable, perform the failing gesture by hand, and the log
lines pin down when the corruption starts and how large it is.

---

## 4. Other suspects, not yet tested

1. **The gate rebuild is itself a previous fix attempt.**
   `updateClusteringGate` removes and re-adds every annotation at the gate transition,
   inside `CATransaction.setDisableActions(true)` — i.e. exactly while MapKit may be
   mid-cluster-animation. A failed fix left in place can become the new cause. Worth
   testing with that block disabled.
2. **`centerOffset` changed mid-animation.** It differs per tier (−22 pt full,
   −9.7 pt dot). If MapKit computes a target centre using the old offset and does not
   recompute, a permanent ~12 pt vertical error follows. This matches the reported
   magnitude and the "canvas change made it worse" observation; it does not obviously
   explain drift in *different* directions.
