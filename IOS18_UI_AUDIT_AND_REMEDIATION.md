# iOS 18 UI Audit and Remediation Specification

## Purpose

This document defines how the Nachbesuch app should look, move, and respond on **iPhone 11 running iOS 18**. It is based on the captured iOS 18 screens in `simulator-screenshots/ios18`, a comparison with the iOS 26 captures, an inspection of the current SwiftUI design-system structure, and Apple's platform guidance.

This is a UI specification, not an implementation patch. No source code was changed while producing it.

The central finding is straightforward:

> The iOS 18 interface is not failing because iOS 18 is inherently incapable of a polished UI. It is failing because an interface designed around iOS 26 Liquid Glass concepts is being translated into iOS 18 as a collection of independent materials, borders, shadows, and backgrounds. Those layers do not compose into one control. They often remain visible as a rounded control inside a separate rectangular or capsule-shaped box.

The result is most severe on the map and in Dark Mode:

- The bottom navigation bar has insufficient separation from map content.
- Several rounded controls have a second, incompatible background around them.
- Materials become muddy or nearly invisible over detailed map imagery.
- The interface has too many simultaneous floating surfaces.
- Controls do not share one consistent iOS 18 visual hierarchy.
- The compatibility layer removes iOS 26 morphing behavior without replacing it with a complete iOS 18 motion language.

The goal is **not** to imitate Liquid Glass on iOS 18. The goal is to make an excellent native iOS 18 interface using iOS 18's own strengths: semantic colors, standard materials, system navigation, native menus and sheets, clear contrast, predictable geometry, and restrained animation.

---

## 1. Evidence reviewed

### iOS 18 captures

1. Map home
2. Map options menu
3. Map search
4. Add-house placement
5. Add-house form
6. List home
7. Archive home
8. Archive global menu
9. Archive item menu
10. List sort menu
11. List help sheet
12. House detail
13. House action menu

### Relevant current architecture

The app already separates several concepts:

- `RootView` owns a three-item SwiftUI `TabView`.
- `AdaptiveSurface.swift` defines navigation surfaces, content cards, panels, and the app backdrop.
- `LegacyCompat.swift` replaces iOS 26 glass APIs with iOS 18 material and bordered-button fallbacks.
- `MapScreen` draws edge-to-edge MapKit content and overlays custom top and bottom chrome.
- Lists, archive cards, menus, and sheets combine system components with custom surfaces.

That separation is useful, but the iOS 18 fallback currently applies visual effects at multiple levels. For example, an iOS 18 button can receive a system `.bordered` treatment and then receive another `.regularMaterial` capsule plus a separator stroke. This is the most likely direct cause of the visible **rounded button inside a square/rectangular box** effect.

---

## 2. Apple guidance that applies to iOS 18

The following are the rules this redesign must follow.

### 2.1 Buttons

Apple recommends recognizable controls, adequate spacing, a hit region of at least **44 × 44 points**, explicit pressed feedback for custom buttons, and only one or two prominent actions in a view. System styles provide interaction states, accessibility adaptation, and appearance adaptation automatically.

Source: [Apple Human Interface Guidelines — Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)

Implications for this app:

- A button must have one visual container, not a system border plus a custom material plus another stroke.
- Icon-only map controls need a 44 × 44 point hit target even if the visible symbol is smaller.
- The red add-house button is the map's single prominent action. Other controls must be visually quieter.
- Every custom button needs an immediate pressed state.
- Disabled controls must remain understandable and sufficiently visible.

### 2.2 Tab bars and navigation bars

Apple defines a tab bar as navigation between top-level app sections. It should remain visible and predictable, use concise labels, and preferably use filled SF Symbols. Actions belong in a toolbar, not in the tab bar.

Sources:

- [Apple Human Interface Guidelines — Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- [Apple Human Interface Guidelines — Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)

Implications:

- Karte, Liste, and Archiv are valid top-level tabs.
- The tab bar must be a stable system-owned navigation surface on iOS 18.
- Map actions must not visually merge with the tab bar.
- Search, sort, share, add, and overflow are toolbar actions.
- A custom floating imitation of a later iOS tab bar should not replace the native iOS 18 tab bar.

### 2.3 Materials and hierarchy

iOS 18 provides standard ultra-thin, thin, regular, and thick materials. Thicker materials provide stronger contrast; thinner materials preserve more background context. Apple recommends choosing material by meaning and ensuring labels remain legible through appropriate vibrancy and contrast.

Source: [Apple Human Interface Guidelines — Materials](https://developer.apple.com/design/human-interface-guidelines/materials)

Implications:

- Navigation over a map needs a more opaque surface than navigation over a quiet grouped background.
- Materials must not be stacked on top of materials unless the hierarchy is intentional and visually verified.
- A map is extremely high-frequency content. `ultraThinMaterial` or a weak regular material is often insufficient.
- The tab bar, top summary, and bottom action area must each have a clearly defined hierarchy.

### 2.4 Dark Mode

Apple recommends semantic colors, separate base and elevated background levels, adaptive labels, and a minimum contrast ratio of 4.5:1 for ordinary small text. Dark Mode is not a color inversion. Elevated foreground surfaces should be distinguishable from the base layer.

Sources:

- [Apple Human Interface Guidelines — Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- [Apple Human Interface Guidelines — Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Apple Human Interface Guidelines — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/)

Implications:

- Never use hard-coded pale fills as the sole means of separating controls.
- Use semantic system backgrounds and label colors.
- Do not rely on a faint translucent bar over a dark satellite map.
- Test normal contrast, Increase Contrast, and Reduce Transparency independently.
- Red must not be used for both ordinary navigation and destructive meaning without supporting context.

### 2.5 Motion

Apple recommends purposeful, brief, precise motion that provides continuity and feedback. Motion should be cancellable, should respect Reduce Motion, and should not delay repeated actions. Standard controls already provide familiar motion.

Sources:

- [Apple Human Interface Guidelines — Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [WWDC24 — Enhance your UI animations and transitions](https://developer.apple.com/videos/play/wwdc2024/10145/)
- [WWDC24 — What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10144/)

Implications:

- iOS 18 does not need Liquid Glass morphs to feel polished.
- Buttons need short press feedback.
- Menus should use native presentation motion.
- Sheets should follow the finger when dismissed.
- Changing map mode should animate spatially and predictably, not replace multiple unrelated layers simultaneously.
- Reduce Motion should replace movement with a fast crossfade, not simply accelerate every animation.

### 2.6 Search

A search field should clearly communicate scope and should normally use the system search experience. Search should begin while typing when possible and show meaningful suggestions or empty states.

Source: [Apple Human Interface Guidelines — Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields)

Implications:

- Use native `.searchable` presentation on iOS 18.
- Do not build a blank full-screen white sheet whose only useful content is a field at the top.
- The keyboard tutorial is test contamination, but the underlying empty search screen still needs structure.

---

## 3. Root cause analysis

### 3.1 The compatibility fallback is visually double-wrapping controls

The current compatibility strategy for a nonprominent glass button effectively combines:

1. A system bordered button style.
2. A separate regular-material capsule background.
3. A separate capsule separator stroke.

On iOS 18, the system button style owns its own shape, padding, clipping, pressed state, and tint behavior. The custom material background is applied to a different view boundary. If the label, button, or parent proposes a rectangular size, the material can occupy that rectangle while the system control remains rounded inside it.

This produces exactly the reported symptom:

> A rounded button appears to sit inside another square or rounded-rectangle box.

#### Required rule

Every interactive element must have **one owner for fill, one owner for shape, and one owner for press feedback**.

Acceptable patterns:

- Entirely system-owned: `.buttonStyle(.bordered)`, `.borderedProminent`, or toolbar styling.
- Entirely custom: `.buttonStyle(.plain)` with one custom shape, one fill/material, one content shape, and one pressed-state transform/opacity.

Unacceptable pattern:

- System border + external material + external border around the same button.

### 3.2 iOS 26 navigation concepts are being cosmetically approximated on iOS 18

The app's iOS 26 design uses glass containers, merging effects, morph identities, and a floating navigation language. On iOS 18, those behaviors do not exist. Replacing each glass element with an isolated blur does not preserve the composition.

The correct fallback is not a visual counterfeit. It should be a separate platform-appropriate composition:

- Native fixed tab bar.
- Opaque or thick-material map controls.
- Standard toolbar items.
- Standard menus.
- Standard sheets.
- Fewer floating objects.

### 3.3 The map has too many competing navigation surfaces

Visible simultaneously on the map:

- Large top territory summary.
- Select button.
- Search button.
- Locate button.
- Additional map mode button.
- Overflow button.
- Large add-house CTA.
- Three-item tab bar.
- Apple Maps attribution.

This is too much chrome for an iPhone 11. The controls compete with both the map and each other. In Dark Mode, transparency reduces boundaries further.

### 3.4 The same surface recipe is used across incompatible backgrounds

A grouped list background, an elevated sheet, and a detailed map need different treatments. A regular material that works over a pale grouped background may disappear over satellite imagery or become muddy over a dark map.

The design system needs semantic roles, not a single fashionable effect:

- `mapNavigationSurface`
- `standardNavigationSurface`
- `contentCardSurface`
- `selectedControlSurface`
- `destructiveControlSurface`
- `disabledControlSurface`

### 3.5 Animation parity is incomplete

On iOS 26, some continuity comes from glass merging and morphing. The compatibility layer makes those APIs inert below iOS 26. Ordinary transitions remain, but there is no explicit end-to-end iOS 18 choreography.

Consequences can include:

- Controls popping between states.
- Multiple layers fading independently.
- Layout changes that appear disconnected from the initiating button.
- Press states that differ between custom and system buttons.

---

## 4. iOS 18 visual language

### 4.1 Design principle

The iOS 18 version should be **solid, quiet, and native**.

It should not try to look futuristic. It should optimize for legibility in the field, one-handed operation, predictable navigation, and clear status changes.

### 4.2 Surface hierarchy

#### Level 0 — content

- Map or grouped system background.
- No decorative red/pink glow in Dark Mode unless contrast testing proves it helps.
- Content extends edge to edge where appropriate.

#### Level 1 — cards

- `secondarySystemGroupedBackground` or a single regular material.
- No stacked material.
- Thin semantic separator only when needed.
- Shadows should be subtle in Light Mode and generally avoided as the primary separator in Dark Mode.

#### Level 2 — navigation over content

- Map navigation uses `thickMaterial` or an adaptive opaque fallback.
- Standard screens use native navigation and tab bars.
- A hairline can supplement contrast, but it must follow exactly the same shape as the surface.

#### Level 3 — modal content

- Native sheets and menus.
- Use elevated semantic system background.
- The system owns dimming, corner geometry, drag indicator, and presentation motion.

### 4.3 Shape policy

Use only a small, coherent set:

- Circle: icon-only controls.
- Capsule: horizontal filter chips and a single primary CTA.
- Continuous rounded rectangle: cards and grouped panels.
- Native menu/sheet geometry: never manually imitate it.

Do not apply a capsule background to an element that is already a bordered button. Do not apply a rectangular material behind a circular control.

### 4.4 Color policy

- Primary action: app accent red.
- Selected state: accent red plus shape/fill/checkmark, never red alone.
- Destructive action: system red with destructive role.
- Success/active: system green.
- Warning/revisit: system orange or indigo according to meaning.
- Primary text: semantic primary.
- Secondary text: semantic secondary.
- Separators: semantic separator.
- Disabled content: system-provided disabled behavior; do not arbitrarily lower opacity on a translucent parent.

### 4.5 Typography

- Use Dynamic Type text styles rather than fixed sizes wherever possible.
- Screen title: system navigation title.
- Card title: headline.
- Primary row value: body or headline.
- Metadata: subheadline or footnote with secondary color.
- Button labels: body/semibold only where emphasis is needed.
- Avoid oversized percentages competing with primary navigation unless the dashboard is the primary content.

---

## 5. Navigation bar and tab bar specification

### 5.1 Bottom tab bar — highest-priority defect

#### Current failure

On the map, the iOS 18 bar visually dissolves into the content. In Dark Mode this becomes worse because the map and bar can share similar values. The bar's icons and labels remain, but the containing navigation surface is barely perceptible. It can appear like three loose buttons floating over the map.

#### Required iOS 18 design

- Use the native `TabView`/`UITabBar` appearance as the only tab-bar container.
- Give it an opaque or strongly legible adaptive background on the map tab.
- Use standard blur only if it passes contrast over every supported map style.
- Preserve the bottom safe area.
- Use filled SF Symbols.
- Keep all three labels visible: Karte, Liste, Archiv.
- Selected item uses accent color; unselected items use semantic secondary label color.
- Add a top separator or shadow only if the background still lacks separation.
- Never place another custom material behind each individual tab item.
- Do not mimic the floating iOS 26 capsule on iOS 18.

#### Acceptance criteria

- The bar boundary is identifiable within one glance over standard, satellite, Light, and Dark maps.
- Every tab has a minimum 44-point hit region.
- The selected tab remains identifiable in grayscale and with Differentiate Without Color enabled.
- No tab icon or label intersects the home indicator.
- Switching tabs preserves each tab's navigation and scroll state.

### 5.2 Top navigation

#### Current failure

List and archive actions occupy custom or mixed toolbar treatments while the map uses a large custom summary card. Geometry and action hierarchy differ dramatically between tabs.

#### Required design

- Use native navigation titles and toolbar placements on list and archive.
- Keep sort/share/search/add/overflow in semantic toolbar positions.
- On map, retain a compact territory summary only because it carries map-specific state.
- Reduce the map summary height and avoid making it look like a second navigation bar.
- Select and Search must be 44-point controls with one shared surface treatment.

---

## 6. Every visible button and control

### 6.1 Map summary: Select checkmark

Current concern:

- Icon-only meaning is ambiguous without context.
- It occupies a large custom card and can look like a decorative status icon.

Required behavior:

- Accessibility label: “Häuser auswählen”.
- 44 × 44 point hit area.
- One circular or borderless toolbar-style treatment.
- Brief scale/opacity press feedback.
- Entering selection mode visibly replaces the summary actions with Cancel, selected count, Select All, Export, and Delete as appropriate.
- Selection transition should be a 0.2–0.3 second crossfade plus small positional continuity on iOS 18.

### 6.2 Map summary: Search

Current concern:

- Competes with a large amount of custom chrome.
- Search presentation becomes an almost empty sheet.

Required behavior:

- Accessibility label: “Adresse oder Gebiet suchen”.
- Native search symbol.
- Native sheet/navigation transition.
- Search field focuses once the sheet settles; avoid a visible layout jump.
- Show recent searches, suggestions, or an explanatory empty state before typing.
- Dismiss button remains visible and reachable above the keyboard.

### 6.3 Map: Locate button

Current concern:

- The button appears as a faint rounded control and may receive double surface styling.
- Location-following, busy, denied, and idle states need clearer differentiation.

Required behavior:

- One 44–50 point circle.
- Strong map-legible background: thick material or adaptive opaque surface.
- Idle: location arrow.
- Busy: replace or overlay with progress indicator without changing outer geometry.
- Following: filled/tinted selected state.
- Denied: location-slash symbol and an accessibility hint explaining Settings.
- Tap feedback is immediate; camera movement follows with a short ease animation.

### 6.4 Map: Overflow button

Current concern:

- Sits beside a very large CTA and above the tab bar.
- Its pale background can become a visible square/capsule behind the intended round shape.

Required behavior:

- One circular 44–50 point control.
- No external capsule behind a bordered button.
- Native `Menu` anchored to the control.
- Menu sections: territory actions, map style, points of interest.
- Selected map options use checkmarks supplied by native picker/menu behavior.
- Disabled import remains readable and includes a reason through context or help text.

### 6.5 Map: Add house

Current concern:

- The CTA is visually dominant, which is appropriate, but it crowds the tab bar and overflow control.
- It appears as an independent floating layer immediately above navigation.

Required behavior:

- Remain the single prominent map action.
- Minimum height 50 points.
- One capsule fill using accent color; no external material.
- Maintain at least 8–12 points of clear separation from nearby controls and the tab bar.
- Press state: 0.97 scale and subtle darkening, approximately 100–150 ms.
- On activation, transform content to “Hier eintragen” while a separate Cancel control appears. On iOS 18 this should use matched geometry where reliable or a coordinated crossfade/slide—not an attempted glass morph.

### 6.6 Placement mode: Cancel

- Use a secondary bordered or plain button, not a pale red rectangle that competes with the primary action.
- Keep equal control height with “Hier eintragen”.
- Give Cancel enough width for localization.
- Restore browsing mode with the reverse transition.

### 6.7 Placement mode: Here enter

- Keep prominent red treatment.
- Confirm the selected coordinate with a brief pin settle/bounce or haptic.
- Do not make the user wait for a long camera animation before the form appears.
- Respect Reduce Motion by using a crossfade and haptic only.

### 6.8 Add-house form: Cancel and Save

- Use native toolbar placements.
- Cancel is leading; Save is trailing.
- Save is disabled until required data is valid, but must remain legible.
- Saving should dismiss only after persistence succeeds.
- A failure must leave the form open and present an actionable error.

### 6.9 House type segmented control

- Use a native picker with segmented style.
- One container only.
- Selected state must be visible in both appearances and Increased Contrast.
- Validate German labels at accessibility text sizes; if they no longer fit, change to a vertical picker/list instead of shrinking text.

### 6.10 Outcome/status buttons

Visible outcomes include Niemand da, Frühes Nein, Spätes Nein, Dabei, and Später.

Current concern:

- Emoji-like symbols dominate.
- Each outcome is placed in a rounded tile; selected tiles add another border/fill.
- Repetition creates a wall of boxes.

Required behavior:

- One tile shape per button.
- The selected state changes fill, border, and accessibility value coherently.
- Symbols must not be the only carrier of meaning.
- Press feedback must be immediate.
- Status update should animate only the affected row/tile and progress value.
- Use haptics sparingly: selection feedback for a status change, notification/success only for completion.
- A second tap on a time-dependent “Später” result should reveal the time sheet predictably.

### 6.11 List: Sort

- Native toolbar `Menu`.
- Use checkmark for current order.
- Keep “Alle Straßen öffnen/schließen” in a separate section because those are display commands, not sort modes.
- Disabled “open all” must be understandable based on current expansion state.
- Menu should dismiss immediately after a choice.

### 6.12 List: Share/export

- Use native share symbol and toolbar placement.
- Present a native share/export sheet.
- Disable only when no exportable content exists.
- Provide an accessibility label that includes scope if needed.

### 6.13 Filter chips

Current concern:

- Chips overflow the screen and labels are visibly clipped.
- Selected and unselected chips are visually heavy.

Required behavior:

- Horizontal scrolling is acceptable, but the leading selected chip must begin fully visible.
- Provide trailing fade or spacing as an affordance that more filters exist.
- One capsule per chip, no nested capsule.
- Selected: accent fill plus high-contrast text/icon.
- Unselected: secondary fill with primary label.
- At least 44-point hit height even if visible capsule is slightly smaller.
- Help is visually separated from filtering because it is an action, not a filter.

### 6.14 Street disclosure button

- Entire street header is tappable.
- Chevron rotates 180 degrees or changes direction over roughly 0.2 seconds.
- Rows expand from the header's location rather than fading independently.
- Progress and count should not jump horizontally.
- Reduce Motion: instant geometry change with short opacity transition.

### 6.15 House/list rows

- Entire row is a button with a clear pressed highlight.
- Chevron is secondary and does not need a separate hit target.
- Outcome icon, house number, note/status, badge, and chevron need a consistent alignment grid.
- Avoid custom row backgrounds that reveal rectangular pressed-state layers outside rounded section clipping.

### 6.16 Help button and sheet

- Help button must remain fully visible at the end of the filter row.
- Present a medium/large detent sheet using native system background.
- Status rows should not each look like separate buttons if they are explanatory only.
- “Fertig” uses native toolbar placement.
- Sheet must scroll correctly at larger Dynamic Type sizes.

### 6.17 Archive: Add

- Native plus toolbar item.
- Accessibility label: “Gebiet hinzufügen”.
- Presents editor sheet using native transition.
- Do not combine it with overflow inside a shared custom background on iOS 18 unless the entire group is one intentionally designed toolbar surface.

### 6.18 Archive: Global overflow

- Native menu with Settings in its own section and Backup actions grouped under a clear heading.
- Use native menu geometry and roles.
- No custom material wrapper around the menu trigger.

### 6.19 Archive item overflow

- Entire 44-point target.
- Native menu anchored to the record.
- Export and Edit are ordinary actions.
- Delete uses destructive role and stays in a separate section.
- Destructive confirmation is required when recovery is not obvious.

### 6.20 House details: More menu

- Native menu in trailing toolbar.
- Conversion action, copy address, and party count editing should use concise labels.
- Do not put an additional material rectangle behind the toolbar menu trigger.
- Copy should produce lightweight confirmation without rebuilding the entire tab tree.

### 6.21 House details: Done

- Native trailing toolbar action.
- Use “Fertig” consistently across sheets.
- Dismissal follows native sheet animation.

### 6.22 Bulk status actions

- Treat as buttons, not colored text links floating between cards.
- Provide adequate vertical spacing and 44-point targets.
- Confirm if an action overwrites existing status values.
- Animate only changed rows and aggregate progress.

### 6.23 Delete house

- Use destructive role, system red, trash symbol, and a full-width row at the end of the form.
- Require confirmation.
- Ensure it cannot be triggered while another menu/sheet transition is still active.

---

## 7. Screen-by-screen remediation

### 7.1 Map home

Priority: **P0**

Required changes:

1. Make the native iOS 18 tab bar fully legible over map content.
2. Remove all double backgrounds from circular controls.
3. Use one stronger map-navigation material.
4. Reduce bottom chrome to one primary CTA plus a compact overflow and locate control.
5. Verify safe-area and attribution spacing.
6. Reduce the top summary card's visual mass.
7. Ensure map pins are present before visual comparison.

### 7.2 Map options menu

Priority: **P0**

Problems:

- Menu is very large and visually detached.
- Rows look like custom blocks rather than a concise native choice hierarchy.
- Disabled import has low contrast.

Required changes:

- Use native picker submenus for map style and POIs.
- Keep territory actions in a separate section.
- Do not manually apply menu backgrounds.
- Test menu anchoring near the bottom safe area.

### 7.3 Map search

Priority: **P1**

Required changes:

- Retake screenshots after dismissing keyboard onboarding.
- Use native search presentation.
- Supply suggestions, recent items, or an empty-state explanation.
- Prevent a large blank white canvas from being the dominant experience.

### 7.4 Add-house placement

Priority: **P0**

Required changes:

- Align Cancel and Confirm on one baseline.
- Keep one clear primary action.
- Avoid overlapping map attribution, controls, and tab bar.
- Use explicit iOS 18 transition choreography.

### 7.5 Add-house form

Priority: **P1**

Required changes:

- Native form/sheet hierarchy.
- Avoid status cards being clipped without a clear scroll affordance.
- Keep toolbar actions stable when keyboard appears.
- Validate Dynamic Type and Dark Mode.

### 7.6 List home

Priority: **P0**

Required changes:

- Fix filter overflow and help-button discoverability.
- Simplify card backgrounds.
- Ensure row pressed states stay inside section clipping.
- Keep the native tab bar visually distinct from content.
- Reduce simultaneous use of red for tab selection, filter selection, status, progress, and actions.

### 7.7 List sort menu

Priority: **P1**

- Use native sections.
- Preserve menu anchor.
- Keep selected checkmark.
- Use concise labels that do not crowd the menu.

### 7.8 List help

Priority: **P1**

- Use a system sheet surface.
- Treat definitions as content rows, not interactive cards.
- Ensure lower sections are discoverable and scrollable.

### 7.9 Archive home

Priority: **P1**

- Simplify visual hierarchy around the 89% dashboard.
- Ensure records use consistent data and layout.
- Reduce decorative translucency on content cards.
- Keep item overflow controls visible without pale circular halos.

### 7.10 Archive menus

Priority: **P0**

- Remove external backgrounds from menu triggers.
- Use native menu sections and destructive roles.
- Confirm popover placement on iPhone 11.

### 7.11 House detail

Priority: **P0**

- Reduce the grid-of-boxes appearance.
- Ensure outcome tiles have one container.
- Keep selected state clear in Dark Mode and grayscale.
- Coordinate row, count, and completion animations.
- Use native navigation and menus.

---

## 8. Motion specification for iOS 18

### 8.1 Global principles

- Motion explains state change.
- Press feedback begins immediately.
- Repeated field operations stay fast.
- Only the affected region animates.
- Navigation uses system transitions wherever possible.
- No animation blocks interaction longer than necessary.

### 8.2 Timing guidance

These are design targets, not rigid constants:

- Button press: 0.10–0.15 seconds.
- Selection/highlight change: 0.15–0.22 seconds.
- Chip or row state update: 0.18–0.25 seconds.
- Expand/collapse section: 0.25–0.35 seconds.
- Map chrome mode transition: 0.25–0.35 seconds.
- Success/banner entry: 0.20–0.30 seconds.
- Sheet and menu: system-owned duration.

### 8.3 Button press state

For fully custom buttons:

- Scale to approximately 0.97–0.98.
- Slightly alter fill/opacity.
- Keep text and symbol crisp.
- Do not reveal an unclipped rectangular background during the press.
- Return with a short ease-out.

### 8.4 Tab switching

- Let `TabView` own the navigation transition.
- Do not animate the entire destination hierarchy manually.
- Preserve map camera, list scroll/filter state, and archive scroll position.
- Selected icon/tint changes immediately and coherently.

### 8.5 Status selection

- Highlight the tapped outcome tile.
- Update row status and progress in one transaction.
- Animate numeric progress using a short interpolation.
- Avoid bouncing every sibling tile.
- Trigger selection haptic once.

### 8.6 Expand/collapse

- Header remains anchored.
- Chevron rotation and content reveal share one transaction.
- Avoid stacking multiple `.animation(value:)` modifiers on overlapping ancestors.
- Clip content throughout the animation so no rectangular backgrounds escape the rounded section.

### 8.7 Map mode changes

Browsing → placing:

1. Add-house CTA changes label/state.
2. Pin/crosshair appears at map center.
3. Secondary Cancel action enters.
4. Nonessential locate control may fade if it conflicts.

All four events should read as one transition.

### 8.8 Reduce Motion

When Reduce Motion is enabled:

- Replace spatial slides and scaling with short opacity changes.
- Do not merely speed animations to 1.8×.
- Avoid map camera flights; use a short, direct camera adjustment.
- Keep state feedback and haptics.

---

## 9. Dark Mode specification

Dark Mode needs its own acceptance pass, not a visual spot-check.

### 9.1 Map

- Test standard and satellite styles.
- Tab bar must use an elevated, sufficiently opaque surface.
- Map controls must have a boundary under every map color.
- Symbols use semantic primary/vibrant foreground.
- Do not use low-opacity gray borders as the only edge.

### 9.2 Lists and archive

- Base screen uses `systemGroupedBackground` equivalent.
- Cards use `secondarySystemGroupedBackground` equivalent.
- Inner panels use tertiary fills sparingly.
- Avoid bright white strokes around every card.
- Avoid large translucent red fields that muddy content.

### 9.3 Buttons

- Selected red fills need high-contrast labels.
- Pale red selected backgrounds must not become brown/gray against dark surfaces.
- Disabled controls must remain readable.
- Destructive red remains reserved for destructive actions or clearly contextual outcomes.

### 9.4 Required test configurations

1. Light Mode.
2. Dark Mode.
3. Light + Increase Contrast.
4. Dark + Increase Contrast.
5. Light + Reduce Transparency.
6. Dark + Reduce Transparency.
7. Differentiate Without Color.
8. Reduce Motion.
9. Large accessibility text.

---

## 10. Technical implementation direction

This section describes the intended engineering approach without modifying code.

### 10.1 Create a true iOS 18 branch in the design system

Do not make iOS 18 a series of one-line visual substitutions for iOS 26 APIs. Define complete semantic implementations for:

- Tab bar/background behavior.
- Map toolbar controls.
- Standard toolbar controls.
- Content cards.
- Menus and menu triggers.
- Sheets.
- Pressable rows.
- Motion/reduced motion.

### 10.2 Eliminate double ownership

Audit every usage of:

- `.buttonStyle(.bordered)` plus `.background(...)`.
- `.background(..., in:)` on both parent and child.
- `.overlay` strokes on controls that already draw borders.
- `.clipShape` applied at a different hierarchy level from pressed background.
- Material nested inside material.

For each control, document:

1. Which view owns geometry?
2. Which view owns fill?
3. Which view owns border?
4. Which view owns pressed feedback?
5. Which view owns the hit region?

There should be one clear answer for each.

### 10.3 Prefer native containers

Use native SwiftUI components where they meet the requirement:

- `TabView`
- `NavigationStack`
- `ToolbarItem`/`ToolbarItemGroup`
- `Menu`
- `Picker`
- `.searchable`
- `.sheet`
- `List`/`Form`
- `Button` roles

Custom styling should enhance content, not recreate navigation infrastructure.

### 10.4 Safe-area ownership

- The native tab bar owns the bottom safe area.
- Map action chrome sits above the tab bar with explicit spacing.
- The map can ignore safe area; its controls cannot.
- Sheets use system safe-area behavior.
- Keyboard presentation must not cover Save, Cancel, search dismissal, or critical fields.

### 10.5 Appearance adaptation

- Use semantic `Color`/`UIColor` values.
- Define asset variants only for genuinely custom brand colors.
- Do not calculate Dark Mode by merely changing opacity.
- Test accessibility environments in previews and simulator.

### 10.6 Performance

- Avoid many independent material blur passes over MapKit.
- Avoid per-row shadows in long lists.
- Avoid animating entire lists when one status changes.
- Keep map annotation updates independent from chrome animations.
- Profile on an iPhone 11-class device, not only a modern simulator host.

---

## 11. Validation matrix

Every screen must be captured in a controlled state on the same iPhone 11 simulator.

| Area | Light | Dark | Increase Contrast | Reduce Transparency | Reduce Motion | Large Text |
|---|---:|---:|---:|---:|---:|---:|
| Map home | Required | Required | Required | Required | Required | Required |
| Map options | Required | Required | Required | Required | — | Required |
| Map search | Required | Required | Required | Required | Required | Required |
| Placement mode | Required | Required | Required | Required | Required | Required |
| Add-house form | Required | Required | Required | Required | Required | Required |
| List home | Required | Required | Required | Required | Required | Required |
| List sort/help | Required | Required | Required | Required | Required | Required |
| Archive | Required | Required | Required | Required | Required | Required |
| House detail | Required | Required | Required | Required | Required | Required |

For each capture:

- Use identical seed data.
- Use identical selected territory.
- Use identical map region and map style.
- Dismiss all system onboarding prompts first.
- Wait for map tiles and annotations to finish loading.
- Record active appearance/accessibility configuration.
- Capture menus only after their opening animation settles.

---

## 12. Acceptance criteria

The iOS 18 UI is ready only when all of the following are true.

### Geometry

- No rounded button has a rectangular or differently shaped background visible around it.
- No pressed state escapes its clipping shape.
- No filter text is unintentionally clipped.
- No control intersects the tab bar, home indicator, keyboard, or map attribution.

### Navigation

- The tab bar is clearly visible over every map style and appearance.
- Every toolbar action occupies a native and predictable position.
- Menus open from the correct trigger.
- Sheets dismiss interactively and preserve parent state.

### Contrast

- Small text reaches at least 4.5:1 contrast where required.
- Selected, unselected, disabled, and destructive states remain distinguishable in Light and Dark modes.
- Increase Contrast and Reduce Transparency produce intentional layouts.

### Interaction

- Every control has at least a 44 × 44 point hit target.
- Every custom button has immediate pressed feedback.
- VoiceOver labels describe icon-only controls.
- Color is not the only means of communicating state.

### Motion

- State changes animate only relevant elements.
- Map-mode transitions read as one coordinated event.
- Expand/collapse remains spatially coherent.
- Reduce Motion avoids large spatial motion.
- No animation blocks repeated field work.

### Consistency

- A control has one surface, one shape, and one pressed state.
- Navigation surfaces are visually distinct from content surfaces.
- iOS 18 uses a native iOS 18 language rather than a degraded imitation of iOS 26.

---

## 13. Recommended execution order

### Phase 1 — P0 foundation

1. Replace double-wrapped iOS 18 button fallbacks.
2. Fix native tab-bar visibility and Dark Mode separation.
3. Define the map-navigation surface.
4. Correct safe-area relationships between map actions and tab navigation.
5. Establish iOS 18 press and Reduce Motion behavior.

### Phase 2 — P0 interaction surfaces

1. Map buttons and placement mode.
2. Menus and menu triggers.
3. List filters and row press states.
4. House outcome controls.
5. Archive item controls.

### Phase 3 — P1 screens

1. Search experience.
2. Add-house form.
3. Help sheet.
4. Archive dashboard hierarchy.
5. Dynamic Type refinements.

### Phase 4 — verification

1. Full Light/Dark matrix.
2. Accessibility configurations.
3. Animation review at normal speed and slow-motion recording.
4. iPhone 11 performance pass.
5. Controlled screenshot comparison.

---

## Final design decision

The app should deliberately support two platform languages:

- **iOS 26:** native Liquid Glass navigation and transitions where appropriate.
- **iOS 18:** native fixed navigation, semantic opaque/material surfaces, system menus and sheets, and concise conventional motion.

Feature parity is required. Pixel parity is not.

Trying to force pixel parity is what creates the visible square boxes, weak map navigation, muddy Dark Mode surfaces, and inconsistent animation. A good iOS 18 implementation should look intentionally designed for iOS 18—not like iOS 26 with its rendering engine removed.
