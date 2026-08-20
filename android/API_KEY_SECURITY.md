# Google Maps key and cost policy

The Android app intentionally uses only **Maps SDK for Android without a cloud Map
ID**. It does not use Google Places, Routes, Navigation, Street View or Google web
service APIs. Search uses Android `Geocoder`; walking routes and bulk address import
use OpenStreetMap/Overpass.

## Required Google Cloud restrictions

Client-side code cannot make an API key secret after an APK is distributed. Apply
both restrictions below in Google Cloud Console before sharing the APK:

1. **Application restriction → Android apps**
   - Package: `at.volkshilfe.nachbesuch.android`
   - Add the SHA-1 of every allowed signing certificate (debug now, Play App Signing
     for production).
2. **API restriction → Restrict key**
   - Allow only **Maps SDK for Android**.
   - Disable every unused Maps/Places/Routes/Street View API in the project.

Also configure Cloud Billing budget alerts. The app contains a persistent circuit
breaker capped at 100 Google map-host creations per UTC day to stop accidental
lifecycle loops; it cannot protect against a copied, unrestricted key.

`secrets.properties` is ignored by Git and is the only local source of the key.
