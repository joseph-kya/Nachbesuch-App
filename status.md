# Status

Last updated: 2026-08-21T00:23:00+02:00 · HEAD: pending · Tests: blocked by CoreSimulator

## In flight
- [ ] T2 — Version control · baseline commit and tag in progress

## Done
- (none yet)

## Blocked
- T1 — needs 👤: create the backup on the production phone, copy it outside the app container, provide its path, and make a second copy.
- T2 remote — needs 👤: create the private GitHub repository `nachbesuch` and provide its URL.
- T2 CI — needs 👤: confirm GitHub plan and macOS runner budget before enabling macOS CI. The current runner documentation lists Xcode 26.6 on `macos-26`; `macos-15` currently lists Xcode 26.3.
- T2 verification — `xcodebuild clean build test` compiled and signed the app and test bundle, but the test run could not start because CoreSimulatorService refused connections; no test count is claimed.

## Notes for the next session
- Repository root is `Version 5/` under the current snapshot until Task 3 promotes it to `~/Documents/Nachbesuch/`.
- The baseline tag `v6.0-feld` must remain the exact field-tested code snapshot; do not rewrite it.
