# Quality, glass UI and release pass — September 6, 2026

## Information accuracy

- Day-two “not home” and “later” results remain open on both platforms. New tests cover those regressions; Android additionally checks every pair of outcomes across all three day scopes against map/list projections.
- Android archive day-two statistics count actual day-two records instead of carrying a first-day success into the second-day report. First-day “later” is included in iOS revisit targets.
- Progress based on recorded outcomes is labelled “erfasst”, not “erledigt”. Android street progress reflects closed work, matching iOS. Map summaries explicitly say “Türen offen” so door counts are not mistaken for house counts.
- Android list and archive searches are independent. Per-tab saved state preserves list position. A list loading indicator replaces the misleading initial empty state while the saved corpus loads, and clearing the active territory clears its houses.
- Android JSON backups read both database tables in one transaction, reject unreadable records and refuse to export an unreadable store's scratch database. They no longer depend on UI StateFlow caches being populated.

## Performance and presentation

- Android does not rebuild status-sorted lists on GPS updates. Tallies accumulate into local counters with one final value allocation; archive summaries group houses once instead of scanning all houses per territory.
- Android floating controls, navigation and cards use static highlight gradients and rims. List rows have no per-row shadow or live backdrop blur. Existing layer-only press motion and row-placement animation are retained.
- iOS 18 floating navigation surfaces use restrained regular material, stronger map fills and glossy rims. Reduce Transparency/Increase Contrast keep opaque surfaces. iOS 26 retains native Liquid Glass with a subtle highlight on custom floating panels.
- Existing reduced-motion handling, light haptics, stable tabs and banner transitions are retained. Physical-device frame pacing and haptic feel still need hands-on testing.

## Verification

- Android API 36 debug APK and unsigned Release AAB build successfully with AGP 8.9.2 / Gradle 8.11.1 / JDK 17. 76 domain/data tests pass. Lint has no errors (remaining warnings are recorded in app/build/reports/lint-results-debug.html).
- The release bundle includes privacy resources. Its four bundled arm64/x86_64 native libraries pass ELF 16 KB load-segment alignment checks; the debug APK passes zipalign's 16 KB check. A physical/emulated 16 KB device and Play-delivered artifact must still be tested.
- iOS 18.5 and iOS 26.5 regression/performance suites pass; the iOS 26 structured result reports 145 passed, 1 skipped, 0 failures. The final map wording compiles, and an updated unsigned device archive is at /tmp/Nachbesuch-Polished-Release.xcarchive.
- Android 10,000-house projection benchmark ran successfully. Timing was noisy during concurrent builds (median 243 ms in that run), so it is not a claimed device speedup. Earlier controlled iOS baseline/results remain in ios/PERFORMANCE.md.
- iOS 18 map controls and Android dark map/list surfaces were visually inspected. The Android map capture did not establish successful external tile loading; production Maps key restrictions/network behavior still require the release-device check.

## Publishing remains owner-dependent

Android instructions and listing draft: android/PlayStore/RELEASE.md. `:app:verifyPlayPublishing` intentionally fails while actual provider/support/privacy details are missing. The release AAB is unsigned; there is no production signing block.

iOS instructions: ios/AppStore/PUBLISHING.md. Refresh store screenshots after finalizing the publishing metadata: earlier captures predate the latest labels and glass treatment. Both stores still require actual seller/contact details, public privacy/support pages, signing, owner declarations and device testing. Nothing has been uploaded or submitted.

Final interaction check: entered a temporary list query, opened Archive and confirmed its search field was empty, then returned to List and confirmed the original query remained. Android's final build/lint/test run including the loading-state correction succeeded. The temporary emulator used read-only storage; this did not modify the saved emulator snapshot.
