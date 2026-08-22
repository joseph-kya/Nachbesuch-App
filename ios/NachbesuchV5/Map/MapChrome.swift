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
        .glassEffectID("map.header", in: namespace)
    }
}

/// The territory's numbers at a glance.
///
/// Every outcome is represented, not just the encouraging ones: knowing how many
/// doors said no is as much a part of a round as knowing how many joined. Each
/// figure carries a real VoiceOver label rather than an emoji the screen reader
/// would pronounce as "large red circle".
struct StatStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stats: MapDayStats
    var isStacked = false

    private var items: [(symbol: String, value: Int, label: String, tint: Color)] {
        [
            ("house.fill", stats.houseCount, "Häuser", .secondary),
            (VisitOutcome.notHome.symbolName, stats.followUpCount, "offene Nachbesuche", VisitOutcome.notHome.tint),
            (VisitOutcome.earlyNo.symbolName, stats.earlyNoCount, VisitOutcome.earlyNo.title, VisitOutcome.earlyNo.tint),
            (VisitOutcome.lateNo.symbolName, stats.lateNoCount, VisitOutcome.lateNo.title, VisitOutcome.lateNo.tint),
            (VisitOutcome.joined.symbolName, stats.joinedCount, "Beitritte", VisitOutcome.joined.tint)
        ]
    }

    var body: some View {
        // At accessibility sizes the figures **wrap** rather than stacking into a
        // single column. Five rows of one statistic each pushed the summary card to
        // roughly 40 % of the screen on a map whose entire point is the map; wrapping
        // fits the same five figures into two or three rows.
        let layout = isStacked
            ? AnyLayout(FlowLayout(spacing: AppSpacing.snug))
            : AnyLayout(HStackLayout(spacing: AppSpacing.snug))

        layout {
            ForEach(items, id: \.label) { item in
                statItem(systemImage: item.symbol, value: item.value, label: item.label, tint: item.tint)
            }
            if !isStacked { Spacer(minLength: 0) }
        }
        // Without this the wrapped block sized to its content and the card centred
        // it, so the figures floated away from the title they belong to.
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption.weight(.medium))
    }

    private func statItem(systemImage: String, value: Int, label: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .imageScale(.small)
            Text("\(value)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
        }
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
struct MapActionBar<Menu: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPlacing: Bool
    let canAddHouse: Bool
    let namespace: Namespace.ID
    let onCancelPlacement: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        HStack(spacing: AppSpacing.snug) {
            if isPlacing {
                Button("Abbrechen", action: onCancelPlacement)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .glassEffectID("map.secondary", in: namespace)
            } else {
                SwiftUI.Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .glassEffectID("map.secondary", in: namespace)
                .accessibilityLabel("Kartenoptionen")
            }

            Button(action: onPrimary) {
                HStack(spacing: 7) {
                    Image(systemName: isPlacing ? "checkmark" : "plus")
                        .contentTransition(.symbolEffect(.replace))
                    Text(isPlacing ? "Hier eintragen" : "Haus hinzufügen")
                        // At accessibility sizes this wrapped to three lines and
                        // hyphenated mid-word — "Haus + hinzufü-gen" — with the icon
                        // stranded on the second line. One line that scales down is
                        // legible; a hyphenated fragment is not.
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(!canAddHouse)
            .glassEffectID("map.primary", in: namespace)
        }
        .animation(.appFeedback(reduceMotion: reduceMotion), value: isPlacing)
    }
}

// MARK: - Locate button

/// The recenter control. Deliberately separate from the tools menu: following your
/// own position is the one map action needed mid-stride, one-handed.
/// Recenter / follow. Deliberately separate from the tools menu: following your own
/// position is the one map action needed mid-stride, one-handed.
struct LocateButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .buttonStyle(.glass)
        .controlSize(.large)
        .buttonBorderShape(.circle)
        .tint(isFollowing ? .red : nil)
        .glassEffectID("map.locate", in: namespace)
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
        .glassEffectID("map.header", in: namespace)
    }
}

// MARK: - Boundary drawing

struct BoundaryDrawingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pointCount: Int
    let namespace: Namespace.ID
    let onCancel: () -> Void
    let onUndo: () -> Void
    let onAddPoint: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.snug) {
            Text("Karte bewegen und an jeder Ecke einen Punkt setzen")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .mapChrome(cornerRadius: AppRadius.control)
                .glassEffectID("map.drawHint", in: namespace)

            HStack(spacing: AppSpacing.snug) {
                Button(action: onCancel) {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .buttonBorderShape(.circle)
                .glassEffectID("map.drawCancel", in: namespace)
                .accessibilityLabel("Gebiet abbrechen")

                Button(action: onUndo) {
                    Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .buttonBorderShape(.circle)
                .disabled(pointCount == 0)
                .glassEffectID("map.drawUndo", in: namespace)
                .accessibilityLabel("Letzten Punkt entfernen")

                Button(action: onAddPoint) {
                    Label("Punkt \(pointCount + 1)", systemImage: "plus")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .contentTransition(.numericText(value: Double(pointCount + 1)))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(.red)
                .glassEffectID("map.drawAdd", in: namespace)

                Button(action: onSave) {
                    Image(systemName: "checkmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .buttonBorderShape(.circle)
                .tint(.green)
                .disabled(pointCount < 3)
                .glassEffectID("map.drawSave", in: namespace)
                .accessibilityLabel("Gebiet speichern")
            }
            .animation(.appFeedback(reduceMotion: reduceMotion), value: pointCount)
        }
    }
}

// MARK: - Reticle

/// Crosshair for placing a house or a boundary corner.
///
/// The artwork hangs off a **zero-height anchor** pinned to the map centre. The
/// previous version offset the whole composite upward by 25 pt, so the house landed
/// roughly 8–15 m from where the user aimed.
struct PlacementReticle: View {
    enum Kind { case house, boundaryPoint }
    let kind: Kind

    var body: some View {
        // A zero-size anchor sitting exactly on the map centre.
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .bottom) {
                switch kind {
                case .house:
                    VStack(spacing: 0) {
                        Image(systemName: "house.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.red, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        Triangle()
                            .fill(.red)
                            .frame(width: 12, height: 9)
                    }
                case .boundaryPoint:
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 26, height: 26)
                        Circle()
                            .stroke(.red, lineWidth: 2.5)
                            .frame(width: 26, height: 26)
                        Rectangle().fill(.red).frame(width: 2, height: 36)
                        Rectangle().fill(.red).frame(width: 36, height: 2)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    // Centred on the anchor, not resting above it.
                    .offset(y: 18)
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

struct MapGuideCard: View {
    let namespace: Namespace.ID
    let onAddHouse: () -> Void
    let onDrawArea: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.snug) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dein Gebiet")
                        .font(.headline)
                    Text("Karte bewegen, Gebiet markieren oder direkt dein erstes Haus erfassen.")
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

            HStack(spacing: AppSpacing.tight) {
                Button(action: onAddHouse) {
                    Label("Haus hinzufügen", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: AppTouch.minimum)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)

                Button(action: onDrawArea) {
                    Label("Gebiet", systemImage: "pentagon")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 88, minHeight: AppTouch.minimum)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(AppSpacing.regular)
        .mapChrome()
        .glassEffectID("map.guide", in: namespace)
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
        .background(.regularMaterial)
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
        .buttonStyle(.glass)
        .controlSize(.large)
        .buttonBorderShape(.circle)
        .glassEffectID("map.territory", in: namespace)
        // Entry/exit is owned by the caller's `standaloneGlassTransition`, so the
        // glass shape and the view animate as one thing instead of a SwiftUI scale
        // fighting a glass morph.
        .accessibilityLabel("Zum Gebiet")
        .accessibilityHint("Zeigt das ganze Gebiet auf der Karte")
    }
}


// MARK: - Route

/// Prompts for a starting point before planning.
struct RouteStartPrompt: View {
    let canUseLocation: Bool
    let onUseLocation: () -> Void
    let onPickOnMap: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.snug) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Startpunkt wählen")
                        .font(.headline)
                    Text("Von dort aus wird die kürzeste Reihenfolge durch alle offenen Häuser berechnet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .tappable(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Abbrechen")
            }

            HStack(spacing: AppSpacing.tight) {
                Button(action: onUseLocation) {
                    Label("Mein Standort", systemImage: "location.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 26)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(.red)
                .disabled(!canUseLocation)

                Button(action: onPickOnMap) {
                    Label("Auf der Karte", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 26)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding(AppSpacing.regular)
        .mapChrome()
    }
}

/// The running route: where you are in it and what comes next.
///
/// No hand-off to Apple Maps: the route itself is drawn on this map, along the
/// streets, so leaving the app to be told the same thing would only lose your place.
struct RouteBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let remainingCount: Int
    let totalCount: Int
    let nextAddress: String?
    let distanceToNext: Double?
    /// True when the street network could not be loaded and the drawn line is
    /// crow-flight — worth saying rather than quietly showing a wrong path.
    let isStraightLine: Bool
    /// True while a (re-)plan is being fetched and computed.
    let isPlanning: Bool
    /// Whether the line and the ring are currently drawn on the map.
    let showsOverlay: Bool
    let onToggleOverlay: () -> Void
    let onFocusNext: () -> Void
    /// False when the current house is the last one — nothing to skip to.
    let canSkip: Bool
    let onSkip: () -> Void
    let onEnd: () -> Void

    private var formattedDistance: String? {
        guard let distanceToNext else { return nil }
        if distanceToNext < 950 { return "\(Int((distanceToNext / 10).rounded() * 10)) m" }
        return String(format: "%.1f km", distanceToNext / 1000)
    }

    /// Clamped: houses deleted under a running route used to push this past the
    /// total and read "13/12".
    /// Everything that changes what the bar *says*, in one key.
    ///
    /// Chrome layout lives in `MapScreen`'s container key; this is the other half of
    /// the same rule. `showsOverlay` in particular used to be toggled inside a
    /// `withAnimation` at the call site, which the container's `.animation(_:value:)`
    /// stripped before it ever reached the symbol.
    private struct ContentKey: Equatable {
        let remainingCount: Int
        let nextAddress: String?
        let showsOverlay: Bool
        let isPlanning: Bool
        let isStraightLine: Bool
    }

    private var contentKey: ContentKey {
        ContentKey(
            remainingCount: remainingCount,
            nextAddress: nextAddress,
            showsOverlay: showsOverlay,
            isPlanning: isPlanning,
            isStraightLine: isStraightLine
        )
    }

    private var position: String {
        let index = min(max(totalCount - remainingCount + 1, 1), totalCount)
        return "\(index)/\(totalCount)"
    }

    var body: some View {
        HStack(spacing: 8) {
            // The label itself is the "show me" button: tapping it flies to the next
            // house, which is the question this bar exists to answer.
            Button(action: onFocusNext) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("Nächstes Haus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(position)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(remainingCount)))
                    }
                    .lineLimit(1)

                    Text(isPlanning ? "Route wird berechnet …" : (nextAddress ?? "Route abgeschlossen"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 6) {
                        if isPlanning {
                            ProgressView().controlSize(.mini)
                        }
                        if let formattedDistance {
                            Text(formattedDistance).monospacedDigit()
                        }
                        if !showsOverlay {
                            Label("ausgeblendet", systemImage: "eye.slash")
                        }
                        if isStraightLine {
                            Label("Luftlinie", systemImage: "exclamationmark.triangle")
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(nextAddress == nil)
            .accessibilityLabel("Nächstes Haus \(nextAddress ?? ""), \(position)")
            .accessibilityHint("Springt auf der Karte zum nächsten Haus")

            // Compact circular controls. Large ones squeezed the street name down to
            // three characters on a narrow phone.
            RouteBarButton(
                systemImage: "forward.end.fill",
                label: "Haus überspringen",
                hint: "Verschiebt dieses Haus ans Ende der Route",
                action: onSkip
            )
            .disabled(!canSkip)

            RouteBarButton(
                systemImage: showsOverlay ? "eye.fill" : "eye.slash.fill",
                label: showsOverlay ? "Route ausblenden" : "Route einblenden",
                action: onToggleOverlay
            )

            RouteBarButton(
                systemImage: "xmark",
                label: "Route beenden",
                tint: .red,
                action: onEnd
            )
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .mapChrome()
        .animation(.appFeedback(reduceMotion: reduceMotion), value: contentKey)
        .accessibilityElement(children: .contain)
    }
}

/// One small circular glass control in the route bar.
private struct RouteBarButton: View {
    let systemImage: String
    let label: String
    var hint: String?
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.bold))
                .frame(width: 34, height: 34)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(tint)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

/// Choosing where the route begins.
///
/// Two ways to answer, because both are natural: move the map so the crosshair sits
/// where you will start, or simply tap the house you intend to begin at. The
/// crosshair matters because a round often starts at a corner, a tram stop or where
/// you parked — not at an address that happens to be in the list.
struct RouteStartPicker: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.snug) {
            Text("Karte auf den Startpunkt schieben — oder ein Haus antippen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: AppSpacing.snug) {
                Button(action: onCancel) {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Routenplanung abbrechen")

                Button(action: onConfirm) {
                    Label("Hier starten", systemImage: "flag.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 26)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(.red)
            }
        }
        .padding(12)
        .mapChrome()
    }
}
