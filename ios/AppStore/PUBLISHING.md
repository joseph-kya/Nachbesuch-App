# App Store release

Target: public App Store, iPhone and iPad, iOS 18+. Bundle ID: at.volkshilfe.nachbesuch.v6. Version 6.0 (2). Preserve this identifier for the App Store Connect record.

## Technical preparation
Run from ios:

    python3 scripts/app_store_preflight.py
    bash scripts/archive.sh --unsigned

The unsigned archive proves the Release device build compiles; it cannot be uploaded. Before a distribution archive:

1. Publish a support page with a real monitored contact and a privacy policy with the provider/controller identity, contact details, applicable rights and lawful basis, retention and relevant third-party processing. Use the bundled PrivacyPolicy.txt as the factual feature/data-flow inventory, not as a complete legal policy. Validate server practices before final privacy disclosures.
2. Put the real DeveloperName, SupportEmail, SupportURL and PrivacyPolicyURL in NachbesuchV5/AppStoreMetadata.plist. No placeholder domain or fictional provider is supplied.
3. Run `python3 scripts/app_store_preflight.py --submission`. This checks configuration, not the legal adequacy or public availability of the pages; open both links on a device and check them separately.
4. In Xcode, select the enrolled developer team, verify the bundle ID matches App Store Connect, and ensure a signing certificate/profile is available. Increment the build if 6.0 (2) has already been uploaded.
5. Run `bash scripts/archive.sh`, open the resulting archive in Xcode Organizer, Validate App, then Distribute App → App Store Connect. The script never uploads.
6. Complete LISTING.de-DE.md owner decisions, screenshots, privacy/age/export-compliance questionnaires and review contact. Test the signed build through TestFlight on physical iOS 18 and iOS 26 devices before submitting.

## Public support page content
Explain how to create a territory, add addresses, record results and schedule a follow-up. Link to the privacy policy and provide a monitored support email. Include: backup before a device change using the Archive menu; restore only trusted backups; location and notifications can be changed in iOS Settings. Tell users to omit personal addresses/notes from support requests and use the diagnostic export. Publish the actual provider identity/contact before linking from the app.

## Final device checks
Fresh install, denied permissions, map/search/import network failure, create/edit/delete, reminders, JSON backup/restore, iPad export popover, large text, dark mode and VoiceOver. Confirm no real visit information appears in screenshots. Verify deletion and backup behavior matches the published policy. Simulator tests and an unsigned archive do not establish device frame rates or guarantee App Review approval.

## Apple references
- SDK 26 minimum for uploads since April 28, 2026: https://developer.apple.com/news/?id=ueeok6yw
- Completeness, support and privacy: https://developer.apple.com/app-store/review/guidelines/
- Privacy labels: https://developer.apple.com/app-store/app-privacy-details/
- Screenshots: https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
- EU trader information: https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements

## Verification completed on September 5, 2026
- Unsigned Release archive built with the installed Xcode 26.6 device SDK: `/tmp/Nachbesuch-AppStore-20260905-105228.xcarchive`. Bundled privacy text, metadata, manifest, icon, bundle ID and iOS 18 deployment target checked.
- Regression suite passed on iOS 18.5 and iOS 26.5 simulators (143 passed, 1 skipped per runtime).
- Six direct simulator screenshots in Screenshots/: iPhone 17 Pro Max at 1320×2868 and iPad Pro 13-inch at 2064×2752. Captured with 120 synthetic addresses, no real visit records; no image rescaling. List, archive and map screens.
- Submission preflight deliberately fails while publishing details are blank. The technical-only mode remains available for building the project.
- Apple signing identity check was blocked by automatic approval review with a usage-limit error. Distribution signing, Organizer validation, TestFlight and submission have not been completed.

September 6 refresh: the latest unsigned archive including the information audit and UI refinements is `/tmp/Nachbesuch-Polished-Release.xcarchive`. Both iOS 18.5 and 26.5 test suites pass. Earlier screenshots must be refreshed before upload because labels/glass styling have changed. See ../../QUALITY_AND_RELEASE.md.
