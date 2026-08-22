# Nachbesuch V5 — Next Steps

**Status:** decided. This document is the output of a grilling session on 2026-08-20;
every decision below was made by the owner, not assumed by an agent.

**Audience:** the AI agent executing this work, over long autonomous sessions.
**Language:** English for instructions, German for anything a user sees.

> ⚠️ **This app is in production.** Two real canvassing rounds (19. and 20.08.2026) with
> real donor data exist on exactly one device and in exactly one folder. Until Task 1 and
> Task 2 are done, every action taken here operates without a safety net. Do them first,
> in order, and do not skip their verification steps.

---

# Part I — How to work

## 0.1 The autonomy contract

This document is written so an agent can run for a long time without asking questions.
That only works if the agent stays inside the contract:

**You may, without asking:**
- Execute any task in Part III (Tasks 1–4) or Part IV (the standing backlog), in order.
- Read anything, run builds, run tests, run the simulator, take screenshots.
- Create branches, commit, and push to the private remote.
- Refactor *within* a task's stated scope when the tests prove behaviour is unchanged.

**You must not, without asking:**
- Invent work that is not in Part III or Part IV. When the backlog empties, **write
  proposals into `proposals.md` and stop** — do not start building them.
- Change stored data shape (`SchemaV1`, `unitsData`, `boundaryData`, backup JSON). The
  "islands" decision removed the only reason to, and the frozen-shape comments in
  `ios/NachbesuchV5/Models/House.swift:5-9` and
  `ios/NachbesuchV5/Models/Gebiet.swift:20-22` are still literally true.
- Touch anything marked 👤 — those need a physical device or an account you don't have.
- Delete anything the owner might still need: the old app on the device, the original
  folder, a backup file, `porting.md`.
- Force-push, rewrite history, or `git commit --amend` on anything already pushed.

**When blocked:** do not idle and do not improvise. Move to the next unblocked item in
Part IV, and append the blocker to the `## Blocked` section of `status.md` with what
exactly is needed and from whom. A blocked item never silently becomes a skipped item.

## 0.2 The working loop

Run this loop per work item, indefinitely:

```
1. Read status.md. Confirm what is done, what is in flight, what is blocked.
2. Pick the highest-priority unblocked item from Part III, then Part IV.
3. git switch -c <branch>            (naming: §3.6)
4. Read the source files the item names, in full, before editing anything.
5. Implement the smallest change that satisfies the item.
6. Verify:
     a. xcodebuild ... clean build test   → 0 failures, 0 warnings
     b. the item's own acceptance check
     c. a simulator screenshot where the item touches UI
7. Commit (§3.6), push.
8. Update status.md: move the item to Done with a one-line result and the commit sha.
9. Go to 1.
```

Never batch steps 5–8 across several items. One item, one branch, one commit, one status
update. If the context is lost mid-item, §3.8 explains how to resume.

## 0.3 Rules that come from this project's own scar tissue

These are not general advice. Each one is here because it already cost this project
something:

1. **Every edit that matters gets an assertion.** Use a search-and-replace that *fails
   loudly* when the pattern does not match. A silently skipped edit shipped a bug in
   `MapScreen.openHouse` and it was only found when the owner hit it in the field.
2. **Never claim a verification you did not perform.** If a screenshot was captured but
   not looked at, it is not verification. State what you actually checked.
3. **Watch out for the synchronised file group.** The Xcode project uses
   `PBXFileSystemSynchronizedRootGroup`: any `.swift` file placed in the folder is
   automatically part of the target. A stray scratch file compiles into the app. Keep
   temporary files out of the project tree entirely — use the scratch directory.
4. **The map is a performance surface.** Anything touching `ios/NachbesuchV5/Map/` gets a seeded 2 000-pin
   check before it is considered done. Pin geometry and pin-scale logic have both
   regressed before. (Clustering is gone — do not reintroduce it.)
5. **Test count is a fact, not a vibe.** Report the number the run printed. It has been
   68, 70, 74 and 78 at different points; do not carry a remembered number forward.
6. **German user-facing strings are data.** Do not "improve", translate, or normalise
   them. Typographic quotes are `„…"`, not `"…"`.

## 0.4 `status.md` — the file that makes long runs possible

Create it at the repo root in Task 2 and keep it current. It is the only thing that
survives a context reset.

```markdown
# Status

Last updated: <ISO timestamp> · HEAD: <sha> · Tests: <n> passing

## In flight
- [ ] B3 — Split MapScreen.swift · branch `refactor/map-screen-split` · step 5 of 7

## Done
- [x] T2 — Version control · `a1b2c3d` · 71 files, remote pushed, CI green
- [x] T1 — Backup verified · 2 Gebiete, 39 Häuser, 63 Türen, 53 recorded

## Blocked
- T3 step 8 — needs 👤: device reinstall + backup restore
- B?? — needs 👤: which iPhones do the colleagues have (§7)

## Notes for the next session
- Battery baseline before the GPS change: 84 % → 61 % over one round (owner-reported)
```

---

# Part II — The decisions

## 1.1 What this app is

| Question | Decision | Consequence |
|---|---|---|
| **Purpose** | A private tool that colleagues use. **Not** an official Volkshilfe project. | The owner personally carries responsibility for the donor data. No organisational Apple account, no organisational repo, no claim on `at.volkshilfe.*`. |
| **Maturity** | In production. Field-tested over two real rounds. | Field verdict: *"pretty perfect"* apart from GPS. Feature work is **not** the priority; safety and precision are. |
| **Source control** | `git init` + private GitHub remote. | Part III §3 |
| **Project layout** | One repository with `ios/` and `android/`; promote `Version 5` to a top-level folder and rename the iOS app to **Nachbesuch**. | §4 |
| **Bundle id** | `at.volkshilfe.nachbesuch.v5` → **`com.kyamakya.nachbesuch`** (no domain owned, so the `com.` form is right; Apple requires no ownership proof). | §4 — **data-destroying if done wrong** |
| **Data flow between people** | **Islands.** Everyone draws their own territory and imports their own addresses. No coordinator hand-off, no sync. | Kills the "territory without results" export → **no schema change needed** |
| **Distribution** | Free provisioning for now; 7-day expiry and a cable per colleague accepted. | TestFlight parked (§6.1) |
| **Retention** | Manual delete only, for now. | Export-then-delete prompt parked behind a trigger (§6.2) |
| **GPS** | Full precision while the map is visible **+** the puck visibly de-emphasises when the fix is untrustworthy. | §5 |
| **Android port** | Source stays in the repository; release/distribution is parked until its acceptance work is complete. | §6.3 |

## 1.2 Two consequences worth internalising

**"Islands" removed the forcing function for a schema change.** No `SchemaV2`. No new
document type. The backup JSON stays the only bridge between devices — and in Task 3 it
becomes the migration vehicle as well. Any backlog item that seems to need a stored-shape
change is out of contract; write it into `proposals.md` instead.

**"Free provisioning" means the team story is currently aspirational.** A colleague's app
stops launching after 7 days and must be re-signed with their phone plugged into the
owner's Mac. So the work that pays off now is *personal-tool quality* — precision,
safety, robustness — not team plumbing. Part IV is ordered on that basis.

---

# Part III — The four ordered tasks

## 2. Task 1 — Back up today 👤

**Why first:** two irreplaceable rounds of fieldwork exist on one phone. Every subsequent
task touches either the folder or the app container.

### 2.1 Owner steps

1. On the phone: **Archiv → ⋯ → Sicherung → „Backup erstellen"**
   (`ios/NachbesuchV5/Features/Archiv/ArchiveScreen.swift:200-203` → `BackupService.makeBackup`).
2. Share the file off the device — AirDrop to the Mac, or Files → iCloud. Do **not**
   leave the only copy inside the app's own container.
3. Tell the agent the path.

### 2.2 Agent verification — perform these, do not trust the file's existence

```bash
B=<path to backup>

# 1. Valid JSON, expected envelope
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); \
print('formatVersion', d['formatVersion']); \
print('gebiete', len(d['gebiete'])); print('houses', len(d['houses']))" "$B"

# 2. Both real rounds present — expect 2026-08-19 and 2026-08-20
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); \
print(sorted({g['day1Date'][:10] for g in d['gebiete']}))" "$B"

# 3. Doors carry recorded outcomes, i.e. this is not an empty shell
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); \
u=[x for h in d['houses'] for x in h['units']]; \
print('doors', len(u), 'recorded', sum(1 for x in u if x.get('outcome') or x.get('day2Outcome')))" "$B"

# 4. Boundaries decode — base64 → JSON → coordinate list
python3 -c "import json,base64,sys; d=json.load(open(sys.argv[1])); \
print([len(json.loads(base64.b64decode(g['boundaryData']))) if g['boundaryData'] else 0 for g in d['gebiete']], 'vertices per Gebiet')" "$B"
```

**Acceptance:** a file outside the app container; valid JSON; `formatVersion: 2`; both
campaign days; a non-zero recorded count the owner recognises; boundaries decode to
plausible vertex counts. **Then copy it to a second location** (different disk or cloud)
before Task 3 starts.

---

## 3. Task 2 — Version control

The codebase exists in one place, with no history, and is currently being edited in place
by an agent. This task fixes that permanently. It is small in effort and the largest
single reduction of risk in this document, so it is specified in full.

### 3.1 Where the repository root goes

The root should be the **promoted** folder from Task 3 (`~/Documents/Nachbesuch/`). Two
paths:

- **Owner available now** → do Task 3's folder move first (§4.3 steps 1–4 only), then
  `git init` in the new location. Cleaner history, no rename commit.
- **Owner not available** → `git init` in `Version 5/` immediately and `git mv` later.
  Safety beats tidiness. Do not delay this task waiting for a decision.

**Do not** put the repo root at `Nachbesuchs-app-code-v2.8/`. That folder also contains
`Version 4` and an unrelated older app at its root; committing all of it means the repo
contains three apps and no clear identity.

### 3.2 What about the other folder copies?

There are four parallel trees (`Nachbesuchs-app-code`, `…-v2.8` with `Version 4` and
`Version 5` inside, `…-v3.0`). Do **not** try to reconstruct history from them — the
folders are snapshots with no reliable ordering, and a fabricated history is worse than
an honest single commit.

Instead: after Task 3 is confirmed, archive them as a single tarball outside the repo
(`~/Documents/Archiv/nachbesuch-alte-versionen-2026-08.tar.gz`) and note it in
`status.md`. Do not delete them until the owner says so.

### 3.3 `.gitignore`

Write this **before** the first `git add`. The last block is not housekeeping — a backup
file pushed to GitHub publishes donor addresses and outcomes.

```gitignore
# ── Xcode ───────────────────────────────────────────────
build/
DerivedData/
*.xcworkspace/xcuserdata/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
xcuserdata/
*.xcuserstate
*.xcscmblueprint
*.moved-aside
*.hmap
*.ipa
*.dSYM.zip
*.dSYM

# ── Swift Package Manager ───────────────────────────────
.swiftpm/
.build/
Packages/

# ── macOS ───────────────────────────────────────────────
.DS_Store
._*

# ── Agent / tooling scratch ─────────────────────────────
*.log
/scratch/
*.png            # screenshots are verification artefacts, not source

# ── FIELD DATA — never commit ───────────────────────────
# Backup files contain donor addresses, outcomes and free-text notes.
*backup*.json
*Backup*.json
backups/
*.nachbesuch-backup.json
```

Note `*.png` is ignored deliberately: verification screenshots are throwaway. If an image
ever becomes a real asset (an app icon), add it with `git add -f` and a comment.

### 3.4 Pre-commit guard against committing donor data

`.gitignore` protects against accident, not against `git add -f` or a renamed file. Add a
hook. Hooks are not versioned by git, so also commit the script and install it.

`scripts/pre-commit` (committed, executable):

```bash
#!/bin/sh
# Blocks staged files that look like exported field data. Donor addresses and
# outcomes must never reach the remote, private repo or not.
if git diff --cached --name-only | grep -qiE '(backup|export).*\.(json|pdf)$'; then
    echo "✋ Ein Backup- oder Export-File ist gestaged. Das enthält Spender-Adressen."
    echo "   Prüfe: git diff --cached --name-only"
    exit 1
fi
# A crude but effective check for coordinates pasted into source
if git diff --cached -U0 | grep -qE '^\+.*"(48|47)\.[0-9]{4,}, ?1[5-7]\.[0-9]{4,}"'; then
    echo "⚠️  Sieht nach echten Koordinaten im Code aus. Wenn das Testdaten sind: --no-verify"
    exit 1
fi
exit 0
```

Install: `chmod +x scripts/pre-commit && ln -sf ../../scripts/pre-commit .git/hooks/pre-commit`
Record the install command in the repo `README.md` so it survives a fresh clone.

### 3.5 The initial commit

```bash
cd "<repo root>"
git init -b main

# .gitignore and scripts/pre-commit written first, then:
git add -A
git status --short | head -80        # eyeball it — this is the last cheap moment
git ls-files | wc -l                 # expect roughly 130–160, NOT thousands
git ls-files | grep -iE '(^|/)(DerivedData|build)/|(backup|export).*\.(json|pdf)$' || echo "clean"
git ls-files '*.png'                 # expect only deliberate source assets such as the app icon
```

If `git ls-files | wc -l` is in the thousands, `DerivedData` or `build/` leaked in — fix
`.gitignore` and re-stage before committing, not after.

```bash
git commit -m "Nachbesuch V5 — erster Stand aus dem Feldeinsatz

Dieser Commit ist der Stand, der am 19. und 20.08.2026 zwei echte Runden
gelaufen ist: Karte mit Pins und Clustering, Liste, Archiv mit Bilanz,
empfohlene Route über echte Straßen, PDF-Export und Backup.

Kein Verlauf davor — die Versionierung lief bis hierher über kopierte Ordner.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"

git tag -a v6.0-feld -m "Im Feld bewährt: 19./20.08.2026, vor Umbenennung und Bundle-ID-Wechsel"
```

The tag matters: it is the last commit whose exact binary the owner has *proven* in the
field. If Task 3 or 4 goes wrong, that tag is the way back.

### 3.6 Branch and commit conventions — follow these for every later item

**Branches:** `<type>/<slug>` — `feat/gps-precision`, `fix/puck-hysteresis`,
`refactor/map-screen-split`, `test/backup-legacy-v1`, `chore/ci`.

**Commits:** German subject line (this project's language), imperative, ≤ 72 chars, then
a body explaining *why*. The codebase's comments are unusually good at explaining
reasoning — commits should match that standard.

```
Standortgenauigkeit an die Karte koppeln, nicht an die Kameraverfolgung

Volle Präzision lief bisher nur, während die Kamera dem Nutzer folgt — und
die App folgt bewusst nicht. Im Normalbetrieb lief also dauerhaft
Zehn-Meter-Genauigkeit, was an einer Haustür drei Häuser breit ist.

Beide Bedingungen (Karte sichtbar, Kamera folgt) laufen jetzt durch eine
Funktion, damit setFollowing(false) keine fremde Anforderung überschreibt.

Tests: 84 grün.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

**One item per commit.** No "and also fixed X" commits — this is the history that a future
agent will bisect through.

### 3.7 Remote

👤 Owner creates a **private** GitHub repo named `nachbesuch` and provides the URL.

```bash
git remote add origin git@github.com:<user>/nachbesuch.git
git push -u origin main
git push --tags
```

Then, if the owner's GitHub plan allows it: enable branch protection on `main` requiring
the CI check. Optional for a single-author repo, but it makes "tests are green" a fact
rather than a habit.

**Private is not optional.** The repo contains no donor data if the hooks work, but it
does contain the exact structure and location logic of a charity's fundraising operation.

### 3.8 Resuming after a context reset

This project has already lost context mid-task once. The recovery procedure:

```bash
git log --oneline -15               # what actually happened
git status                          # uncommitted work in flight
git branch --show-current           # which item was in progress
cat status.md                       # what the last session believed
xcodebuild -project ios/NachbesuchV5.xcodeproj -scheme NachbesuchV5 -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | tail -5
```

Trust, in this order: the test run > `git log` > `status.md` > any remembered summary. If
`status.md` disagrees with `git log`, `git log` is right and `status.md` is stale — fix it
as the first action of the session.

### 3.9 CI

A workflow that runs the tests on every push. Two things to verify **before** writing the
file, rather than assuming:

- Which Xcode versions the GitHub-hosted macOS runner images actually provide. This
  project needs **Xcode 26.x with the iOS 26 SDK**; if no runner image has it, CI is
  blocked — record that in `status.md` and move on, do not commit a workflow that fails
  on every push.
- macOS runner minutes are billed at a **higher multiplier** than Linux, and a private
  repo has a limited free allowance. Check the owner's plan before enabling it on every
  push; restricting to `main` plus manual dispatch may be the right call.

`.github/workflows/tests.yml`:

```yaml
name: Tests
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  test:
    runs-on: macos-15          # ← verify this image has Xcode 26.x before committing
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_26.app   # ← verify the path
      - name: Test
        run: |
          xcodebuild test \
            -project ios/NachbesuchV5.xcodeproj \
            -scheme NachbesuchV5 \
            -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
            -resultBundlePath TestResults.xcresult \
            | tee build.log
      - name: Fail on warnings
        run: "! grep -E 'warning:' build.log | grep -v appintentsmetadataprocessor"
      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: TestResults
          path: TestResults.xcresult
```

The zero-warnings gate is deliberate: this codebase currently builds clean in Swift 6
language mode, and that is a property worth defending automatically rather than by
memory.

### 3.10 Repo `README.md`

The existing `README.md` is excellent — it documents every fixed bug and the reasoning
behind current behaviour, and it is the single best onboarding artefact in the project.
Keep it as the main README. Add a short section at the top:

```markdown
## Arbeiten an diesem Projekt

    git clone https://github.com/joseph-kya/Nachbesuch-App.git && cd Nachbesuch-App
    ln -sf ../../scripts/pre-commit .git/hooks/pre-commit   # blockt Felddaten im Commit
    xcodebuild -project ios/NachbesuchV5.xcodeproj -scheme NachbesuchV5 -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
    (cd android && ./gradlew test)

- `next-steps.md` — was als Nächstes zu tun ist, in welcher Reihenfolge
- `status.md` — was gerade läuft, was blockiert ist
- `porting.md` — fachlicher Android-Portierungsplan und Paritätsvertrag
- `android/porting-status.md` — aktueller Android-Implementierungsstand
```

### 3.11 Acceptance for Task 2

- [ ] `git log --oneline` shows the baseline commit and tag `v6.0-feld`
- [ ] `git ls-files | wc -l` is plausible for both platforms (~130–160 files)
- [ ] no generated `build/` or `DerivedData/` path and no backup/export JSON or PDF is tracked
- [ ] The pre-commit hook is installed and demonstrably blocks a test backup file
      (prove it: `touch test-backup.json && git add -f test-backup.json && git commit` must fail;
      then `git reset` and delete the file)
- [ ] Remote configured, `main` pushed, tags pushed
- [ ] `status.md` exists and is accurate
- [ ] CI either green, or explicitly recorded as blocked with the reason

---

## 4. Task 3 — Promote, rename, migrate the bundle id

Three changes, one irreversible. Read the whole section before starting.

### 4.1 What changes

| | From | To |
|---|---|---|
| Folder | `Documents/Nachbesuchs-app-code-v2.8/Version 5/` | `Documents/Nachbesuch/` |
| Display name | `NachbesuchV5` | `Nachbesuch` |
| Bundle id | `at.volkshilfe.nachbesuch.v5` | `com.kyamakya.nachbesuch` |
| Test bundle id | `at.volkshilfe.nachbesuch.v5.tests` | `com.kyamakya.nachbesuch.tests` |

`MARKETING_VERSION` stays `6.0`. Do not add a fourth version number to the pile.

### 4.2 The data hazard, stated plainly

iOS keys an app's data container to its bundle identifier. Changing it means the next
install is, to the system, **a different app with an empty database**. The two real rounds
do not migrate themselves; the backup file from Task 1 is the only bridge.

**`UserDefaults` does not survive either.** Two things live there:

- the persisted camera and the `map.didEverCenterOnUser` flag
  (`ios/NachbesuchV5/Map/MapCameraStore.swift:17-21`) → the app will centre on the user once more, as if
  freshly installed. Harmless, but expected — do not treat it as a bug afterwards.
- **any active recommended route** (`ios/NachbesuchV5/Route/RouteStore.swift`, keys `route.<uuid>`) →
  👤 **finish or end the current route before migrating**, or the plan is lost while the
  houses remain.

### 4.3 Procedure — do not reorder

1. **Verify Task 1's acceptance checks pass.** Not "a backup exists" — the checks.
2. Copy the backup to a second location.
3. 👤 Owner: end any active route in the app.
4. Copy the folder — copy, not move; the original stays as a fallback until the new tree
   is proven:
   ```bash
   cd ~/Documents && cp -R "Nachbesuchs-app-code-v2.8/Version 5" Nachbesuch
   ```
5. In the new folder, edit `ios/NachbesuchV5.xcodeproj/project.pbxproj`:
   - `PRODUCT_BUNDLE_IDENTIFIER = at.volkshilfe.nachbesuch.v5;` → `com.kyamakya.nachbesuch;`
   - `PRODUCT_BUNDLE_IDENTIFIER = at.volkshilfe.nachbesuch.v5.tests;` → `com.kyamakya.nachbesuch.tests;`
   - `INFOPLIST_KEY_CFBundleDisplayName = NachbesuchV5;` → `Nachbesuch;`
   - Leave `DEVELOPMENT_TEAM = V8TS2P6862` and `CODE_SIGN_STYLE = Automatic` alone.

   There are **two** occurrences of the app id (Debug and Release) and two of the test id.
   Use an asserting replacement, then verify:
   ```bash
   grep -c "com.kyamakya.nachbesuch;" ios/NachbesuchV5.xcodeproj/project.pbxproj        # 2
   grep -c "com.kyamakya.nachbesuch.tests;" ios/NachbesuchV5.xcodeproj/project.pbxproj  # 2
   grep -c "at.volkshilfe" ios/NachbesuchV5.xcodeproj/project.pbxproj                   # 0
   ```
6. Update everything else that hard-codes the old id or version:
   ```bash
   grep -rn "at.volkshilfe.nachbesuch.v5" . --include="*.swift" --include="*.md" --include="*.sh" --include="*.yml"
   ```
   At minimum `README.md`, `next-steps.md`, `porting.md` and any `simctl` command.
   Align the two Overpass `User-Agent` strings —
   `ios/NachbesuchV5/Services/AreaHouseImportService.swift` currently sends `"Nachbesuch-iOS/2.8"` while
   `ios/NachbesuchV5/Route/WalkingNetwork.swift` derives one from `CFBundleShortVersionString`. Make both
   read `Nachbesuch-iOS/<MARKETING_VERSION>` from the bundle. Overpass mirrors block
   anonymous or inconsistent clients, so this is not cosmetic.
7. Build and test:
   ```bash
   xcodebuild -project ios/NachbesuchV5.xcodeproj -scheme NachbesuchV5 -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build test
   ```
   Expect the current count passing, 0 failing, 0 warnings.
8. 👤 Owner, on the device, in this order:
   - Install the renamed app **without deleting the old one**. They are different apps
     now and can coexist.
   - New app: **Archiv → ⋯ → Sicherung → „Backup importieren"**.
   - Verify: both territories present; house counts right; spot-check a handful of doors
     against what was actually recorded; run an export and compare it against one from the
     old app.
   - **Only then** delete the old `NachbesuchV5`.
9. Commit the rename as its own commit; tag nothing yet.
10. After the owner confirms the device is good, archive the old folders (§3.2).

### 4.4 Rollback

Before step 8's deletion: delete the new app, keep the old one, nothing is lost. After it:
the backup file is the only recovery path, and `git checkout v6.0-feld` restores the code
that produced the app the data came from. This is exactly why step 1 is a verification.

### 4.5 Acceptance

New app on the device named **Nachbesuch**; both rounds present and correct; an export
matching the old app's; old app deleted; tests green; commits pushed; `status.md` updated.

---

## 5. Task 4 — GPS precision and an honest puck

The only feature work in Part III, and it comes straight from two days in the field:
*"GPS accuracy could be better"* — wrong while standing at a door, and worse between
buildings.

### 5.1 What the code does today

`ios/NachbesuchV5/Location/LocationService.swift:57-66`:

```swift
manager.activityType = .fitness
manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
manager.distanceFilter = 3
```

`:126-134`:

```swift
func setFollowing(_ following: Bool) {
    manager.desiredAccuracy = following ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
    manager.distanceFilter = following ? 1 : 3
}
```

Full precision is active **only while the camera is locked to the user** — and this app
deliberately does not follow, because "don't move my map" was an explicit requirement. In
normal use the app therefore runs permanently at ten-metre accuracy. At a door in a
terraced street, ten metres is three houses.

### 5.2 Change A — precision follows the map, not the camera lock

Two independent conditions want high precision, and today they fight: `setFollowing(false)`
stamps on any other caller's request. Resolve both through one function.

```swift
/// Location precision is a function of two independent conditions, resolved in one
/// place. The previous shape let `setFollowing(false)` overwrite an unrelated caller's
/// request — two writers, one property, last one wins.
private struct AccuracyProfile: Equatable {
    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance

    static func resolve(mapVisible: Bool, following: Bool) -> AccuracyProfile {
        if following {
            return AccuracyProfile(desiredAccuracy: kCLLocationAccuracyBest, distanceFilter: 1)
        }
        if mapVisible {
            // Standing at a door, ten-metre accuracy is three houses wide. The map is
            // only visible with the screen on, and the screen costs far more than the
            // GPS duty cycle does.
            return AccuracyProfile(desiredAccuracy: kCLLocationAccuracyBest, distanceFilter: 2)
        }
        // The list only needs coarse distances for „Nächste zuerst".
        return AccuracyProfile(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 3)
    }
}
```

- Hold `mapVisible` and `following` as private state; recompute and apply on either
  change; skip the `CLLocationManager` write when the resolved profile is unchanged.
- Add `func setMapVisible(_ visible: Bool)`.
- Call it from `ios/NachbesuchV5/Map/MapScreen.swift:381-383`, next to the existing
  `location.beginUsing()` / `endUsing()` pair.
- **Do not** call it from `ios/NachbesuchV5/Features/Liste/ListScreen.swift:329-332` — the list wants a
  position for distance sorting, not metre precision, and it is often open with the phone
  in a pocket.
- Keep `activityType = .fitness` and `pausesLocationUpdatesAutomatically = false`; the
  comments at `:61-64` explain why, and both still apply.

### 5.3 Change B — the puck tells the truth

Nothing fixes multipath. Between 19th-century Viennese blocks the phone genuinely does not
know which side of the street it is on, and the right response is to stop pretending. The
halo already grows (`ios/NachbesuchV5/Map/MapCoordinator.swift:424-425` → `ios/NachbesuchV5/Map/UserLocationPuck.swift:126-128`),
but a big faint ring is easy to miss.

```swift
/// How much the drawn position can be trusted.
///
/// Hysteresis on purpose: a fix hovering at the threshold would make the puck flicker
/// between states, which reads as a bug rather than as information.
enum PuckConfidence {
    case trusted
    case uncertain

    static func from(horizontalAccuracy: Double, current: PuckConfidence) -> PuckConfidence {
        switch current {
        case .trusted:   return horizontalAccuracy > 25 ? .uncertain : .trusted
        case .uncertain: return horizontalAccuracy <= 18 ? .trusted : .uncertain
        }
    }
}
```

Presentation in `UserLocationPuckView`:

- `.trusted` — today's appearance: solid blue core, white ring.
- `.uncertain` — hollow core (blue ring, no fill), overall alpha ≈ 0.55, slightly stronger
  halo stroke. **Not** red, **no** warning icon: this is reduced confidence, not an error,
  and it happens constantly in a street canyon.
- Transition with `Animation.appFeedback` semantics (`ios/NachbesuchV5/DesignSystem/Motion.swift`) — no
  bounce, ~0.24 s; cross-fade only under Reduce Motion.
- Accessibility: when uncertain, the label becomes `„Dein Standort, ungenau"`.

Wire it into `MapCoordinator.refreshPuck()` where `horizontalAccuracy` is already read
(`:424`), keeping the previous state so the hysteresis works.

### 5.4 Tests

Both rules are pure functions — no device needed:

```
LocationPrecisionTests
  followingWinsOverMapVisibility()
  mapVisibleRaisesPrecision()
  listOnlyStaysCoarse()
  profileIsStableWhenNothingChanged()     // no redundant CLLocationManager writes

PuckConfidenceTests
  degradesAboveTwentyFiveMetres()
  recoversOnlyBelowEighteen()             // the hysteresis band
  staysPutInsideTheBand()                 // 20 m keeps whatever state it had
```

### 5.5 Verification

The simulator reports optimistic accuracy, so the degraded state needs forcing. Follow the
existing harness convention and add a DEBUG-only override:

```bash
env SIMCTL_CHILD_NACHBESUCH_SEED=40 SIMCTL_CHILD_NACHBESUCH_FAKE_ACCURACY=40 \
  xcrun simctl launch booted com.kyamakya.nachbesuch
xcrun simctl io booted screenshot --type=png puck-uncertain.png
```

Capture both states **and look at them**. Guard the override with `#if DEBUG`.

👤 **The real check is in the field.** Walk one street, stand at a door, answer two
questions: does the dot now sit on the right house, and does the puck go hollow exactly
when you would stop trusting it? Record the battery percentage at the start and end of the
round and compare against a previous round. If the cost exceeds a few points over a full
shift, the fallback is `kCLLocationAccuracyNearestTenMeters` with `distanceFilter = 1`,
which keeps most of the responsiveness at a lower duty cycle.

### 5.6 Acceptance

Tests green including the new ones; both puck states captured and inspected; owner
confirms after one real round that the dot picks the right house and the battery cost is
acceptable.

---

# Part IV — The standing backlog

Work these in order after Task 4. Each is self-contained, has an acceptance check, and
is inside the autonomy contract. When this list is empty, write `proposals.md` and stop.

---

### B1 — Automatic safety backup 🔴 highest value

**Why:** the entire risk story of this project is "one device, one copy", and the current
protection is a human remembering to tap a menu item. It did not exist during the two
rounds already walked.

**What:** on app launch, and at most once per day, write a backup into the app's
**Files-visible** documents directory (add `UIFileSharingEnabled` +
`LSSupportsOpeningDocumentsInPlace` so it appears in the Files app and is picked up by the
owner's device backup). Keep the last 7, delete older ones. Run entirely off the main
actor; never block launch; failures are silent in the UI but logged.

Reuse `BackupService.makeBackup` — do not write a second serialiser.

Surface in **Archiv → ⋯ → Sicherung**: „Letzte automatische Sicherung: heute, 08:12" plus
a button to reveal the folder.

**Acceptance:** kill and relaunch the app twice on one day → exactly one new file. Set the
clock forward → a second. After 8 days of simulated launches → 7 files, oldest deleted.
Launch time unchanged within noise. The file imports cleanly via the existing restore path.

---

### B2 — A test for the legacy v1 backup importer

**Why:** `ios/NachbesuchV5/Services/BackupService.swift` carries a whole `LegacyAppBackup` reader
(`days:` instead of `gebiete:`, reduced fields) with **no test at all**. It is a data path
that runs on a user's only copy of their work.

**What:** build a v1 fixture by hand from the `LegacyAppBackup` struct, commit it to the
test bundle, assert the import produces the right territories and doors, and that a
territory missing from the file leaves its houses counted as `skippedHouses` rather than
orphaned or crashed.

**Acceptance:** ≥ 4 new tests; the v1 fixture lives in the test resources; the round-trip
v1 → import → export-as-v2 → import is lossless for everything v1 could express.

---

### B3 — Split `MapScreen.swift` (1 187 lines)

**Why:** it is the file every future map change touches, it already exceeded the Swift
type-checker once elsewhere in the project (`ArchiveScreen`), and its size is why a
mis-targeted edit went unnoticed.

**What:** extract, with **no behaviour change** —
`MapRouteCoordination` (route phases, planning, skipping, `auditRoute`),
`MapPinPipeline` (`PipelineKey`, `refreshPins`, patch path),
`MapModes` (selection, boundary drawing, placement),
leaving `MapScreen` as composition + chrome layout.

**Acceptance:** tests green before and after; a seeded 2 000-pin screenshot is
pixel-identical to the pre-refactor capture; the route harness modes (`auto`, `skip`,
`hidden`, `pick`, `tap`) all still behave; no file over ~450 lines.

---

### B4 — Battery instrumentation for the GPS change

**Why:** Task 4's fallback decision ("if the cost exceeds a few points") currently depends
on the owner eyeballing a battery indicator.

**What:** a DEBUG-only `os_signpost`/`Trace` around location updates plus a tiny counter of
fixes-per-minute, exposed in a hidden diagnostics view (Archiv → ⋯ → long-press).
No third-party analytics; nothing that leaves the device.

**Acceptance:** after one simulated hour, the diagnostics view reports fix count, mean
`horizontalAccuracy`, and the proportion of time in `.uncertain`.

---

### B5 — Error-path audit

**Why:** every one of these paths runs in a stairwell with no signal, and none has been
verified since the code was written.

**What:** walk and verify each, fixing what is wrong —
Overpass unreachable during address import; Overpass unreachable during route planning
(must fall back to „Luftlinie" and say so); location permission denied; location
permission "reduced accuracy" (Android's precise-location twin exists on iOS as
`accuracyAuthorization == .reducedAccuracy` — **currently unhandled, check it**); disk full
during export; corrupt store (`StoreLoadResult.failed`) actually rendering its recovery
screen; a house with a damaged `unitsData` blob showing its badge and refusing writes.

**Acceptance:** a short table in `status.md`, one row per path: what was tested, how it was
forced, what the user sees. Every row either ✅ or a linked fix commit.

---

### B6 — Reduced-accuracy authorisation

**Why:** if the owner or a colleague grants "Ungefährer Standort", `horizontalAccuracy`
jumps to kilometres and every distance, the route bar and the puck become nonsense. The
code reads `authorizationStatus` but **not** `accuracyAuthorization`.

**What:** detect it, and show a one-time explanation with a button to request temporary
full accuracy (`requestTemporaryFullAccuracyAuthorization(withPurposeKey:)` plus the
matching `NSLocationTemporaryUsageDescriptionDictionary` Info.plist entry). Suppress
distances and force `.uncertain` while reduced.

**Acceptance:** simulator with reduced accuracy → explanation appears once, distances
hidden, puck uncertain; after granting, everything returns to normal.

---

### B7 — Accessibility and Dynamic Type pass

**Why:** the code has `accessibilityLabel`s throughout — they have never been *used*. The
app is operated one-handed, outdoors, sometimes by people who will raise the text size.

**What:** VoiceOver sweep of map chrome, route bar, list rows, house sheet; layout check at
the largest accessibility text sizes (the `ViewThatFits` in `StreetHeader` suggests this
was anticipated but not verified); contrast check of the outcome colours; confirm every
control meets the 44 pt target (`AppMetrics` has `.tappable()` for exactly this).

**Acceptance:** screenshots at `.accessibility3` for all three tabs with nothing clipped or
overlapping; Accessibility Inspector audit clean on each screen.

---

### B8 — Manual add-house duplicate guard

**Why:** the OSM import de-duplicates within 12 m (`AreaHouseImportService.duplicateRadius`),
but adding a house by hand does not. Adding the same building twice mid-round is easy and
silently corrupts the day's counts.

**What:** on manual add, if a house exists within ~12 m or with the same normalised
address, offer „Dieses Haus gibt es schon — öffnen?" instead of creating a second pin.

**Acceptance:** tests for the match rule (same address different case, 8 m away, 30 m away);
the sheet offers to open rather than duplicate.

---

### B9 — Performance regression harness

**Why:** pins and pin-scale have each regressed at least once, and every check
so far has been a human looking at a screenshot.

**What:** an XCTest performance test over a seeded 2 000-house territory measuring
`MapPinSnapshotBuilder.build`, `.patch`, and the archive index rebuild, with baselines
committed. Plus a documented manual pan/zoom checklist for the parts that cannot be
automated.

**Acceptance:** baselines committed; the test fails if the builder regresses > 25 %.

---

### B10 — Route graph pre-warm

**Why:** the Overpass fetch is a 40 s wall the first time a territory is routed, and the
30-day disk cache only helps *after* that first wait. A territory is usually created the
evening before it is walked — on Wi-Fi, with time to spare.

**What:** when a territory gains a boundary and houses, opportunistically fetch and cache
the walking graph in the background on Wi-Fi, once, silently. Never on cellular, never
blocking, and never as a reason to keep the app awake.

**Acceptance:** create a seeded territory on Wi-Fi → cache file exists within a minute;
plan a route → completes in under 2 s with no network; on cellular, no fetch occurs.

---

### B11 — Diagnostics export

**Why:** with sideloaded builds on colleagues' phones and no crash reporting, a failure on
someone else's device is completely invisible.

**What:** **Archiv → ⋯ → „Diagnose exportieren"** producing a text file with app version,
build, iOS version, device model, store health, territory/house/door counts, last N
`os_log` entries — and **no donor data**: no addresses, no notes, no coordinates.

**Acceptance:** the exported file is inspected line by line and provably contains no
address, note or coordinate.

---

### B12 — Retention prompt (pre-built, behind a flag)

**Why:** §6.2's trigger is "the day a second person installs it", and on that day the
owner will not want to wait for a feature.

**What:** implement the export-then-delete follow-up — „Gebiet exportiert. Jetzt vom Gerät
löschen?" — plus a note-field placeholder discouraging anything about a resident that
could not be handed to a manager. Ship it behind a simple setting, defaulted **off**.

**Acceptance:** with the flag on, exporting offers deletion and deletion actually removes
territory and houses; with it off, behaviour is unchanged from today.

---

# Part V — Parked, with triggers

Nothing here is cancelled. Each has a condition that reopens it — check the condition;
do not rebuild the reasoning.

### 6.1 TestFlight and a paid Apple Developer account
**Parked because:** free provisioning was chosen for now.
**Cost of the status quo:** every colleague's app **stops launching after 7 days** and must
be re-signed with their phone plugged into the owner's Mac.
**Trigger:** the third re-signing session, or the second colleague — whichever comes first.
€99/year, and it removes the owner as a weekly bottleneck. Worth asking Volkshilfe to
sponsor just the account; far smaller an ask than adopting the project.

### 6.2 Export-then-delete retention prompt
**Parked because:** manual deletion is fine while it is one person's phone.
**Trigger:** the day a second person installs it — at that point donor addresses and notes
sit on a device the owner does not control, and the owner is personally the data
controller. Implementation is pre-built in **B12**; the trigger only flips the flag.
Deliberately **not** automatic deletion after N days: that risks deleting work someone
still needs.

### 6.3 The Android port
The Android implementation is part of this repository under `android/`; do not delete or
split it into a second repository. `porting.md` is the parity contract and
`android/porting-status.md` records what is implemented and still missing.

**Release remains parked until:** backup fixture round-trip, accessibility audit,
baseline profile/performance work, CI/lint and physical-device acceptance are complete.
Every shared semantic change — especially day-1/day-2 behaviour, backup, export and
route rules — must be implemented and tested on both platforms.

### 6.4 The iOS 26 minimum
**Blocked, not parked** — see Part VI.
**Cost if it must drop:** the entire design system is iOS 26 API (`glassEffect`,
`GlassEffectContainer`, `safeAreaBar`, `scrollEdgeEffectStyle`). Dropping to iOS 18 means
`if #available` fallbacks for every glass surface — substantial, but mechanical.

---

# Part VI — Facts still missing

One, and it gates §6.4:

**Which iPhones do the other colleagues have?** iOS 26 requires an A13 chip or newer —
iPhone 11 / SE 2nd gen and up. An iPhone XR, XS, X, 8 or SE 1 **cannot install this app at
any version**. If everyone is on an iPhone 12 or newer, §6.4 closes with zero work. If even
one person is not, that is a real decision, not a technical detail.

👤 Owner action: ask them. One message.

---

# Part VII — Summary

| # | Task | Who | Blocked by |
|---|---|---|---|
| T1 | Backup, off the device, **verified** | 👤 + agent | — |
| T2 | git init, hooks, first commit, tag, remote, CI, `status.md` | agent + 👤 for the repo | — |
| T3 | Promote folder, rename, migrate bundle id, restore on device | agent + 👤 | T1 verified |
| T4 | GPS precision + honest puck | agent, field-verified by 👤 | T3 |
| B1–B12 | Standing backlog, in order | agent | T4 |
| — | Ask colleagues what phones they have | 👤 | — |

**Agent effort:** T1–T4 roughly a day; B1–B12 several days of autonomous work.
**Owner effort:** a backup, a repo, an app reinstall, one street walked, one message sent.

When B12 is done and the field has been quiet for a while: write `proposals.md`, update
`status.md`, and stop. Do not invent the next thing.
