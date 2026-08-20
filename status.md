# Status

Last updated: 2026-08-21T01:06:49+02:00 · HEAD: 6239c93 (last source commit; status update follows) · Tests: not completed — CoreSimulator unavailable

## In flight
- [ ] User work — Android import/map edits are present but intentionally uncommitted; inspect and commit separately.

## Done
- [x] T2 — Version control · `cb610f7` · 135 files, `v6.0-feld`, hook installed and demonstrated, `main` and tags pushed to `origin`

## Blocked
- T1 — needs 👤: create the backup on the production phone, copy it outside the app container, provide its path, and make a second copy.
- T2 CI — needs 👤: confirm GitHub plan and macOS runner budget before enabling macOS CI. The current runner documentation lists Xcode 26.6 on `macos-26`; `macos-15` currently lists Xcode 26.3.
- T2 verification — `xcodebuild clean build test` compiled and signed the app and test bundle, but the test run could not start because CoreSimulatorService refused connections; no test count is claimed.

## Notes for the next session
- Repository root is `Version 5/` under the current snapshot until Task 3 promotes it to `~/Documents/Nachbesuch/`.
- The baseline tag `v6.0-feld` must remain the exact field-tested code snapshot; do not rewrite it.
- The acceptance grep for `backup` also matches required production source names; no backup/export JSON or PDF is tracked.
- Remote: `https://github.com/joseph-kya/Nachbesuch-App.git`.
