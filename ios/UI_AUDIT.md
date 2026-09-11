# iOS UI audit — 2026-09-11

## Changes

- Content cards and street sections now use opaque system surfaces. Map controls retain glass. Removed accent washes behind content.
- Status editors and the legend use the same system symbols as list rows; selection stays inside the control, with no protruding badges.
- Result grids wrap to one column at accessibility text sizes. Normal-size tiles reserve equal label space. Appointment controls give large text the full row width.
- Standardized form backgrounds, settings card widths, search clear-button touch targets, and apartment status-button heights.
- Consolidated booked appointments into one control. Removed misleading note counters, automatic clipboard reads, extra count bounces, duplicate map guide actions, and launch schema text.
- List filters remain available through a compact picker submenu; common filters remain visible as chips.
- Import exposes every address for individual selection, rather than silently hiding selected addresses after item 60. Selection and dismissal are blocked while saving.
- Export clears stale text and PDF results when rebuilding and offers a retry after PDF failure. Removed premature share-success feedback and the unverified “exported, delete now” shortcut; archive deletion remains available.
- Improved reminder wording, compact-export naming, archive menu wording, and distinction between recorded results and completed visits.
- Denied location permission no longer triggers an approximate-location warning.

## Review coverage

Source review covered the app shell, launch/recovery views, shared surfaces and controls, map controls and menus, search and import, house and encounter forms, list and legend, archive and balance, territory editor, export and backup sharing, settings, support/privacy, tutorial, and notices.

Live simulator inspection covered the map, denied-location flow, populated list, expanded apartment details, archive, archive menu, settings, and support screen. Existing screenshots were used only as historical references, not proof of the final appearance.

Fresh `UIReviewTests` render shared status and appointment controls at 390 pt in light/dark appearances and standard/AX5 text sizes. These renders caught and drove corrections to unequal tiles and cramped large-text appointment rows.

Not exhaustively exercised: network search/import results, system share destinations, every dialog, real-device gestures, iPad, and iOS 18 visual behavior. Android is outside this iOS audit.

## Validation

Final build and regression suite passed: 161 tests in 39 suites on iPhone 17 Pro / iOS 26.5, including the denied-location regression and four refreshed UI renders. `git diff --check` passed.
