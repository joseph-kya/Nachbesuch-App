# Google Play release preparation

Nachbesuch 6.0 (versionCode 1), package at.volkshilfe.nachbesuch.android.
Target API 36; minimum Android 8 / API 26. Build with JDK 17 and the checked-in Gradle wrapper.

## Build and verify locally

    ./gradlew :app:assembleDebug :app:bundleRelease :app:lintDebug :domain:test :data:testDebugUnitTest
    python3 scripts/check_native_alignment.py app/build/outputs/bundle/release/app-release.aab

`bundleRelease` permits an unsigned technical build when no upload key is configured. It is not an upload-ready artifact. `:app:preparePlayRelease` additionally requires the actual publishing details, Maps SDK key and signing configuration, and never uploads anything.

## Required before upload

1. Enroll/verify the real developer account and create the app in Play Console. Confirm rights to the product name and branding.
2. Fill ui/src/main/assets/publishing.properties with the developer name, monitored support email, public HTTPS support URL and privacy-policy URL. The bundled privacy.txt explains technical data flows; the published policy must include real provider/controller details and applicable disclosures. Do not supply fictitious contacts.
3. Configure a restricted Google Maps SDK key in secrets.properties. Restrict it to this package and the Play App Signing certificate fingerprint; a debug signing restriction does not authorize the Play build. Check the app's existing API_KEY_SECURITY.md.
4. Create/select a protected upload key. Put storeFile/storePassword/keyAlias/keyPassword in the gitignored root keystore.properties. storeFile is resolved relative to app/. Preserve any existing Play identity. Do not commit or share keys/passwords.
5. Run `./gradlew :app:preparePlayRelease`. Ensure versionCode exceeds every previously uploaded build.
6. Upload through Play Console's internal testing track, inspect automated pre-launch reports, and test map rendering, optional/denied permissions, reminders, backups/imports, keyboard/back navigation, app background/restore and both dark/light appearance on a physical phone. Test a 16 KB page-size device and verify all native SDK behavior.
7. Complete Data safety, content rating, target audience, app access (no account required), ads (none), pricing/countries and developer/trader declarations. Review Maps SDK collection disclosures; local visit storage alone does not justify selecting “no data collected.” Add authentic screenshots, icon and feature graphic. Follow any testing requirements shown for the developer account.

## German listing draft

Name: Nachbesuch
Short description: Gebiete, Besuche und Erinnerungen übersichtlich organisieren.

Organisiere Gebiete und Adressen auf der Karte, halte Besuchsergebnisse und Notizen fest und plane Erinnerungen für spätere Besuche. Durchsuche deine Adressen, behalte Mehrparteienhäuser im Blick und sichere deine Daten für einen Gerätewechsel. JSON-Sicherungen sowie PDF- und Textexporte lassen sich an selbst gewählte Speicherorte weitergeben.

Kein Benutzerkonto erforderlich. Besuchsdaten werden lokal gespeichert. Karten, Ortssuche und Adressimport verwenden externe Dienste und benötigen eine Internetverbindung. Standort und Mitteilungen sind optional.

## Review notes

No login or purchases are required. Create a territory through Archive, add addresses on the map, and record outcomes by opening a house. The Archive menu provides backup/export functions and Settings. Settings → Datenschutz & Support contains privacy information and the configured support links. Location, notification and exact-alarm permissions are optional; reminders fall back to inexact scheduling without exact-alarm access. Use synthetic records for testing.

## References checked September 5, 2026
- API 36 submission requirement: https://support.google.com/googleplay/android-developer/answer/11926878?hl=en
- 16 KB compatibility: https://developer.android.com/guide/practices/page-sizes
- SDK/tool compatibility: https://developer.android.com/build/releases/about-agp
- Maps SDK data disclosure: https://developers.google.com/maps/documentation/android-sdk/play-data-disclosure

R8 remains disabled pending validation of the optimized build on a device. Release signing, public URLs, owner declarations and store submission are not completed by a successful unsigned build.
