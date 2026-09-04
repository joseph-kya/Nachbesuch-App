import MapKit
import SwiftUI

// MARK: - Summary card

/// The territory header floating over the map.
struct MapSummaryCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let namespace: Namespace.ID
    let title: String
    let subtitle: String
    let stats: MapDayStats
    let isTwoDay: Bool
    @Binding var scope: DayScope
    let onSearch: () -> Void
    let onSelect: () -> Void
    let canSelect: Bool

    var body: some View {
        VStack(spacing: AppSpacing.snug) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.snug) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                HStack(spacing: 2) {
                    if canSelect {
                        Button(action: onSelect) {
                            Image(systemName: "checkmark.circle")
                                .font(.headline)
                                .tappable(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pins auswählen")
                    }
                    Button(action: onSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.headline)
                            .tappable(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ort auf der Karte suchen")
                }
            }

            // Counts get their own row at accessibility sizes rather than being
            // squeezed with minimumScaleFactor, which is not Dynamic Type support.
            StatStrip(stats: stats, isStacked: dynamicTypeSize.isAccessibilitySize)

            if isTwoDay {
                DayScopePicker(scope: $scope)
            }
        }
        .padding(.horizontal, AppSpacing.regular)
        .padding(.vertical, 12)
        .mapChrome()
        .compatGlassID("map.header", in: namespace)
    }
}

/// What is left in this territory, floating over the map.
///
/// **Two figures, both labelled.** This was five unlabelled counters —
/// `48 · 28 · 12 · 12 · 16` — one per outcome, over a map whose entire point is the
/// map. Two things were wrong with that. It was a reading exercise: five bare
/// numbers behind five small glyphs, and the only way to learn which was which was
/// to open the legend. And it was the *second* copy — the Archive's Bilanz already
/// draws exactly this breakdown, with words next to the numbers and a bar chart
/// underneath, on a screen you go to in order to read it.
///
/// So the map keeps the one question you ask while standing in the street — how much
/// is still open here — plus the size of the territory, and the breakdown stays where
/// there is room to explain it.
struct StatStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stats: MapDayStats
    var isStacked = false

    var body: some View {
        // At accessibility sizes the figures wrap rather than stacking into a
        // column: two rows of one figure each pushed the card down the screen.
        let layout = isStacked
            ? AnyLayout(FlowLayout(spacing: AppSpacing.snug))
            : AnyLayout(HStackLayout(spacing: AppSpacing.snug))

        layout {
            statItem(
                value: stats.openCount,
                unit: "offen",
                label: "offene Türen",
                tint: stats.openCount > 0 ? VisitOutcome.notHome.tint : .green
            )
            statItem(
                value: stats.houseCount,
                unit: stats.houseCount == 1 ? "Haus" : "Häuser",
                label: "Häuser",
                tint: .secondary
            )
            if stats.damagedHouseCount > 0 {
                Label("\(stats.damagedHouseCount) beschädigt", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(stats.damagedHouseCount) Häuser mit beschädigten Daten")
            }
            if !isStacked { Spacer(minLength: 0) }
        }
        // Without this the wrapped block sized to its content and the card centred
        // it, so the figures floated away from the title they belong to.
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption.weight(.medium))
    }

    private func statItem(value: Int, unit: String, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .monospacedDigit()
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: Double(value)))
            Text(unit)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        // `contentTransition` only animates inside an animated transaction; without
        // this the modifier is decorative.
        .animation(.appFeedback(reduceMotion: reduceMotion), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
    }
}

/// The Gesamt / Tag 1 / Tag 2 switch, written once instead of three times.
struct DayScopePicker: View {
    @Binding var scope: DayScope

    var body: some View {
        Picker("Zeitraum", selection: $scope) {
            ForEach(DayScope.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .sensoryFeedback(.selection, trigger: scope)
        .accessibilityLabel("Angezeigter Kampagnentag")
    }
}

// MARK: - Action bar

/// The primary map controls.
///
/// Each control carries its own glass rather than sitting inside one big glass
/// panel. That is the iOS 26 idiom — nesting glass inside glass is explicitly
/// discouraged — and the surrounding `GlassEffectContainer` lets the shapes merge
/// into each other as they appear and disappear.
/// Which kind of thing the action bar is about to place, if any.
enum MapPlacement {
    case house
    case passant

    var idleTitle: String {
        switch self {
        case .house: "Haus hinzufügen"
        case .passant: "Passant eintragen"
        }
    }

    var idleShortTitle: String {
        switch self {
        case .house: "Hinzufügen"
        case .passant: "Eintragen"
        }
    }

    var idleSystemImage: String {
        switch self {
        case .house: "plus"
        case .passant: "person.fill.badge.plus"
        }
    }
}

struct MapActionBar<Menu: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    /// Non-nil while aiming the reticle — a house or a street encounter.
    /// `nil` is browsing, where the primary button starts the house flow.
    let placement: MapPlacement?
    let canAddHouse: Bool
    let namespace: Namespace.ID
    let onCancelPlacement: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        HStack(spacing: AppSpacing.snug) {
            if placement != nil {
                Button("Abbrechen", action: onCancelPlacement)
                    .compatGlassButton(role: .map)
                    .controlSize(.large)
                    // Plain appear/disappear, no morph identity: a Menu inside the
                    // shared container breaks morphing from iOS 26.1 on, so this
                    // pair doesn't attempt one — the swap cross-fades instead.
                    .standaloneGlassTransition(reduceMotion: reduceMotion)
            } else {
                SwiftUI.Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 24, height: 24)
                }
                .compatGlassButton(shape: .circle, role: .map)
                // Same as above: no glassEffectID on a Menu. It never had a
                // genuine morph partner — only a swap — and the ID asked the
                // container for exactly the morph that breaks.
                .standaloneGlassTransition(reduceMotion: reduceMotion)
                .tint(.primary)
                .controlSize(.large)
                .accessibilityLabel("Kartenoptionen")
            }

            Button(action: onPrimary) {
                ViewThatFits(in: .horizontal) {
                    if placement != nil {
                        Label("Hier eintragen", systemImage: "checkmark")
                        Label("Eintragen", systemImage: "checkmark")
                    } else {
                        Label(
                            MapPlacement.house.idleTitle,
                            systemImage: MapPlacement.house.idleSystemImage
                        )
                        Label(
                            MapPlacement.house.idleShortTitle,
                            systemImage: MapPlacement.house.idleSystemImage
                        )
                    }
                    Image(systemName: placement == nil ? MapPlacement.house.idleSystemImage : "checkmark")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .compatGlassButton(prominent: true)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .tint(accent)
            .disabled(!canAddHouse)
            .compatGlassID("map.primary", in: namespace)
        }
        .animation(.appFeedback(reduceMotion: reduceMotion), value: placement == nil)
    }
}

// MARK: - Locate button

/// The recenter control. Deliberately separate from the tools menu: following your
/// own position is the one map action needed mid-stride, one-handed.
/// Recenter / follow. Deliberately separate from the tools menu: following your own
/// position is the one map action needed mid-stride, one-handed.
struct LocateButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    let isFollowing: Bool
    let isBusy: Bool
    let isDenied: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 26, height: 26)
                // A gentle pulse only while a fix is being acquired — a repeating
                // effect has to stop as soon as it stops meaning something.
                .symbolEffect(.pulse, isActive: isBusy && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
        }
        .compatGlassButton(shape: .circle, role: .map)
        .controlSize(.large)
        .buttonBorderShape(.circle)
        .tint(isFollowing ? accent : nil)
        .compatGlassID("map.locate", in: namespace)
        .accessibilityLabel(isFollowing ? "Standortverfolgung beenden" : "Zu meinem Standort")
        .accessibilityAddTraits(isFollowing ? [.isSelected] : [])
        .animation(.appFeedback(reduceMotion: reduceMotion), value: isFollowing)
    }

    private var symbolName: String {
        if isDenied { return "location.slash" }
        return isFollowing ? "location.fill" : "location"
    }
}

// MARK: - Selection bar

struct MapSelectionBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let namespace: Namespace.ID
    let selectedCount: Int
    let totalCount: Int
    let onCancel: () -> Void
    let onToggleAll: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.tight) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .tappable(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auswahl beenden")

            VStack(alignment: .leading, spacing: 0) {
                Text("\(selectedCount) ausgewählt")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(selectedCount)))
                Text("von \(totalCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .animation(.appFeedback(reduceMotion: reduceMotion), value: selectedCount)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Auswahl")
            .accessibilityValue("\(selectedCount) von \(totalCount) Pins")

            // Title toggles rather than the button appearing and disappearing, which
            // used to shift the destructive buttons sideways under the user's thumb.
            Button(selectedCount == totalCount ? "Keine" : "Alle", action: onToggleAll)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .tappable()

            Button(action: onExport) {
                Image(systemName: "square.and.arrow.up")
                    .font(.headline)
                    .tappable(Circle())
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0)
            .accessibilityLabel("Auswahl exportieren")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.headline)
                    .tappable(Circle())
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0)
            .accessibilityLabel("Auswahl löschen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .mapChrome()
        .compatGlassID("map.header", in: namespace)
    }
}

// MARK: - Boundary drawing

struct BoundaryDrawingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent
    let pointCount: Int
    /// 1-based number of the vertex being re-aimed, if any. While one is
    /// selected the primary button moves it instead of appending.
    let selectedPointNumber: Int?
    let namespace: Namespace.ID
    let onCancel: () -> Void
    let onUndo: () -> Void
    let onAddPoint: () -> Void
    let onMoveSelected: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.snug) {
            Text(hintText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .mapChrome(cornerRadius: AppRadius.control)
                .compatGlassID("map.drawHint", in: namespace)

            HStack(spacing: AppSpacing.snug) {
                Button(action: onCancel) {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .compatGlassButton(shape: .circle, role: .map)
                .controlSize(.large)
                .buttonBorderShape(.circle)
                .compatGlassID("map.drawCancel", in: namespace)
                .accessibilityLabel("Gebiet abbrechen")

                Button(action: onUndo) {
                    Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 24)
                }
                .compatGlassButton(shape: .circle, role: .map)
                .controlSize(.large)
                .buttonBorderShape(.circle)
                .disabled(pointCount == 0)
                .compatGlassID("map.drawUndo", in: namespace)
                .accessibilityLabel("Letzten Punkt entfernen")

                if let selected = selectedPointNumber {
                    Button(action: onMoveSelected) {
                        Label("Punkt \(selected) versetzen", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .compatGlassButton(prominent: true)
                    .controlSize(.large)
                    .tint(accent)
                    .compatGlassID("map.drawAdd", in: namespace)
                    .accessibilityLabel("Punkt \(selected) an die Fadenkreuzposition versetzen")
                } else {
                    Button(action: onAddPoint) {
                        Label("Punkt \(pointCount + 1)", systemImage: "plus")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .contentTransition(.numericText(value: Double(pointCount + 1)))
                    }
                    .compatGlassButton(prominent: true)
                    .controlSize(.large)
                    .tint(accent)
                    .compatGlassID("map.drawAdd", in: namespace)
                }

                Button(action: onSave) {
                    Image(systemName: "checkmark").frame(width: 24, height: 24)
                }
                .compatGlassButton(prominent: true)
                .controlSize(.large)
                .buttonBorderShape(.circle)
                // Prominent circles need the clip or the glass leaves artifacts
                // at the rim; the wide pills keep the automatic shape.
                .clipShape(Circle())
                .tint(accent)
                .disabled(pointCount < 3)
                .compatGlassID("map.drawSave", in: namespace)
                .accessibilityLabel("Gebiet speichern")
            }
            .animation(.appFeedback(reduceMotion: reduceMotion), value: pointCount)
        }
    }

    private var hintText: String {
        if let selected = selectedPointNumber {
            "Punkt \(selected) ist ausgewählt. Karte bewegen und Punkt versetzen — nochmals auf den Punkt tippen bricht ab."
        } else {
            "Karte bewegen und an jeder Ecke einen Punkt setzen. Punkt antippen korrigiert ihn, Linie antippen fügt dazwischen ein."
        }
    }
}

// MARK: - Reticle

/// Crosshair for placing a house or a boundary corner.
///
/// The artwork hangs off a **zero-height anchor** pinned to the map centre. The
/// previous version offset the whole composite upward by 25 pt, so the house landed
/// roughly 8–15 m from where the user aimed. The boundary cross is centred
/// exactly on the anchor — `draftBoundary.append(camera.region.center)` must land
/// in the middle of the cross, not 18 pt away.
struct PlacementReticle: View {
    @Environment(\.appAccent) private var accent
    enum Kind { case house, passant, boundaryPoint }
    let kind: Kind

    var body: some View {
        switch kind {
        case .house:
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Image(systemName: "house.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(accent, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        Triangle()
                            .fill(accent)
                            .frame(width: 12, height: 9)
                    }
                }
        case .passant:
            // A person has no tip to hang off the anchor: the badge sits
            // centred on it, so the encounter lands exactly where aimed.
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: .center) {
                    Image(systemName: "person.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(accent, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
        case .boundaryPoint:
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: .center) {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 26, height: 26)
                        Circle()
                            .stroke(accent, lineWidth: 2.5)
                            .frame(width: 26, height: 26)
                        Rectangle().fill(accent).frame(width: 2, height: 36)
                        Rectangle().fill(accent).frame(width: 36, height: 2)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(y: 22)
                }
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Guide card

/// Shown once, on an empty map, and never again after it is dismissed.
///
/// It offers **one** action. It used to offer two — "Haus hinzufügen" and "Gebiet" —
/// but the action bar directly beneath it already carries "Haus hinzufügen", and
/// "Gebiet einzeichnen" is the first item of the menu next to it. A card whose job is
/// to orient someone on their first launch should not be the third place the same two
/// commands appear; it should say where they are. So it says that, and keeps the one
/// button worth pressing first.
struct MapGuideCard: View {
    @Environment(\.appAccent) private var accent
    let namespace: Namespace.ID
    let onAddHouse: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.snug) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dein Gebiet")
                        .font(.headline)
                    Text("Karte auf deine Straße schieben und das erste Haus erfassen. Das Gebiet einzeichnen kannst du im Menü daneben.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .tappable(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hinweis schließen")
            }

            Button(action: onAddHouse) {
                Label("Haus hinzufügen", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: AppTouch.minimum)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(accent)
        }
        .padding(AppSpacing.regular)
        .mapChrome()
        .compatGlassID("map.guide", in: namespace)
    }
}

// MARK: - Long-press preview

struct ApartmentStatusPreview: View {
    let address: String
    let units: [DoorResult]
    /// Previously missing entirely, so the preview showed day-1 results while the
    /// rest of the app was in Tag-2 mode.
    let scope: DayScope

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.snug) {
            Label(address, systemImage: "building.2.fill")
                .font(.headline)
                .lineLimit(2)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(units) { unit in
                        let outcome = unit.displayOutcome(in: scope)
                        HStack(spacing: AppSpacing.tight) {
                            Image(systemName: outcome?.symbolName ?? "circle.dashed")
                                .foregroundStyle(outcome.displayTint)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(unit.label)
                                    .font(.subheadline.weight(.semibold))
                                Text(outcome.displayTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Color(uiColor: .secondarySystemFill).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(unit.label)
                        .accessibilityValue(outcome.displayTitle)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(AppSpacing.regular)
        .frame(minWidth: 260, maxWidth: 340)
        .legacyPreviewSurface()
    }
}

/// Long-press preview over the map. A material samples the live tiles every
/// frame — on an iPhone 11 the least legible and most expensive option, same
/// finding as the floating chrome. Opaque on the legacy branch, like it.
private struct LegacyPreviewSurface: ViewModifier {
    func body(content: Content) -> some View {
        if LegacyChrome.isActive {
            let shape = RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            content
                .background(Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay { shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5) }
        } else {
            content.background(.regularMaterial)
        }
    }
}

private extension View {
    func legacyPreviewSurface() -> some View {
        modifier(LegacyPreviewSurface())
    }
}

// MARK: - Stacked pins

/// Shown when several pins are drawn on top of one another, so a tap cannot pick
/// between them — otherwise whichever view happened to be on top would always win.
struct StackedPinsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let houses: [House]
    let scope: DayScope
    let onSelect: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List(houses) { house in
                let summary = house.summary(for: scope)
                Button {
                    dismiss()
                    onSelect(house.id)
                } label: {
                    HStack(spacing: AppSpacing.snug) {
                        Image(systemName: summary.markerOutcome?.symbolName ?? "circle.dashed")
                            .foregroundStyle(summary.markerOutcome.displayTint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(house.address)
                                .font(.body.weight(.medium))
                            Text(summary.markerOutcome.displayTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(house.address)
                .accessibilityValue(summary.markerOutcome.displayTitle)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Pins an dieser Stelle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Territory button

/// Frames the whole territory in one tap.
///
/// Only rendered while the territory is off screen — a control that does nothing
/// from where you are standing is just another thing to read past.
struct TerritoryButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "scope")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .compatGlassButton(shape: .circle, role: .map)
        .controlSize(.large)
        .buttonBorderShape(.circle)
        .compatGlassID("map.territory", in: namespace)
        // Entry/exit is owned by the caller's `standaloneGlassTransition`, so the
        // glass shape and the view animate as one thing instead of a SwiftUI scale
        // fighting a glass morph.
        .accessibilityLabel("Zum Gebiet")
        .accessibilityHint("Zeigt das ganze Gebiet auf der Karte")
    }
}
