# Status

Last updated: 2026-08-21T01:31:56+02:00 · HEAD: 8f9a9e1 (cleanup commit follows) · Tests: iOS 78 passing, 1 skipped; Android 11 passing

## In flight
- None.

## Done
- [x] T2 — Version control · `cb610f7` · 135 files, `v6.0-feld`, hook installed and demonstrated, `main` and tags pushed to `origin`
- [x] Platform verification — iOS clean build/test: 78 passed, 1 diagnostic PDF test skipped, 0 failed; Android unit tests: 11 passed, 0 failed
- [x] Android retained — active import/map work integrated under `android/`; generated Gradle/IDE/schema files excluded
- [x] Repository cleanup — platform source grouped under `ios/` and `android/`; documentation and build commands aligned with the monorepo layout

## Blocked
- T1 — needs 👤: create the backup on the production phone, copy it outside the app container, provide its path, and make a second copy.
- T2 CI — needs 👤: confirm GitHub plan and macOS runner budget before enabling macOS CI. The current runner documentation lists Xcode 26.6 on `macos-26`; `macos-15` currently lists Xcode 26.3.

## Notes for the next session
- Repository root is `Version 5/` under the current snapshot until Task 3 promotes it to `~/Documents/Nachbesuch/`; platform source now lives under `ios/` and `android/`.
- The baseline tag `v6.0-feld` must remain the exact field-tested code snapshot; do not rewrite it.
- The acceptance grep for `backup` also matches required production source names; no backup/export JSON or PDF is tracked.
- Remote: `https://github.com/joseph-kya/Nachbesuch-App.git`.
