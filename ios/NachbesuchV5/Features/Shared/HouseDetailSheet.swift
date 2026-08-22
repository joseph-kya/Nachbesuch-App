import SwiftData
import SwiftUI
import UIKit

/// Everything about one address.
struct HouseDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(AppNoticeCenter.self) private var notices

    @Bindable var house: House
    let scope: DayScope
    /// Which campaign day a tap writes to. Decided by the caller from the
    /// territory's calendar, so the value read and the value written always match.
    let writeDay: Int

    @State private var draftAddress: String
    @State private var draftNote: String
    @State private var sheetRoute: DetailRoute?
    @State private var showDeleteConfirmation = false
    @State private var dismissTask: Task<Void, Never>?

    init(house: House, scope: DayScope, writeDay: Int) {
        self.house = house
        self.scope = scope
        self.writeDay = writeDay
        _draftAddress = State(initialValue: house.address)
        _draftNote = State(initialValue: house.note)
    }

    private enum DetailRoute: Identifiable {
        case convertToApartment
        case resizeUnits

        var id: String {
            switch self {
            case .convertToApartment: "convert"
            case .resizeUnits: "resize"
            }
        }
    }

    var body: some View {
        let summary = house.summary(for: scope)

        NavigationStack {
            Form {
                if house.isDamaged {
                    Section {
                        Label(
                            "Die Türdaten dieses Hauses konnten nicht gelesen werden. Bearbeitungen sind gesperrt, damit nichts überschrieben wird.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                    }
                }

                Section { header(summary: summary) }

                if house.isApartmentBuilding {
                    apartmentSection(units: summary.units)
                } else if let door = summary.units.first {
                    Section("Ergebnis") {
                        singleDoorEditor(door: door)
                    }
                    Section {
                        Button {
                            sheetRoute = .convertToApartment
                        } label: {
                            Label("Zu Mehrparteienhaus machen", systemImage: "building.2")
                        }
                    }
                }

                Section("Notiz") {
                    TextField("Notiz", text: $draftNote, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Button("Haus löschen", systemImage: "trash", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
            .navigationTitle(house.isApartmentBuilding ? "Mehrparteienhaus" : "Hausbesuch")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            Button {
                                MapNavigation.openWalkingRoute(to: house.coordinate, name: house.address)
                            } label: {
                                Label("Fußroute öffnen", systemImage: "figure.walk")
                            }
                            Button {
                                UIPasteboard.general.string = house.address
                                notices.show("Adresse kopiert")
                            } label: {
                                Label("Adresse kopieren", systemImage: "doc.on.doc")
                            }
                        }
                        Section {
                            if house.isApartmentBuilding {
                                Button {
                                    sheetRoute = .resizeUnits
                                } label: {
                                    Label("Anzahl der Parteien", systemImage: "number")
                                }
                            } else {
                                Button {
                                    sheetRoute = .convertToApartment
                                } label: {
                                    Label("Zu Mehrparteienhaus machen", systemImage: "building.2")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Weitere Aktionen")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        commitDrafts()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(item: $sheetRoute) { route in
                switch route {
                case .convertToApartment:
                    UnitCountSheet(
                        title: "Mehrparteienhaus",
                        message: "Der bestehende Status bleibt als Tür 1 erhalten.",
                        initialCount: max(2, UserDefaults.standard.integer(forKey: "lastApartmentUnitCount")),
                        currentCount: nil
                    ) { count in
                        house.convertToApartmentBuilding(unitCount: count)
                        UserDefaults.standard.set(count, forKey: "lastApartmentUnitCount")
                        save()
                    }
                case .resizeUnits:
                    UnitCountSheet(
                        title: "Anzahl der Parteien",
                        message: "Beim Verkleinern werden die hintersten Türen entfernt.",
                        initialCount: max(2, summary.units.count),
                        currentCount: summary.units.count
                    ) { count in
                        house.resizeUnits(to: count)
                        save()
                    }
                }
            }
            .confirmationDialog(
                "Haus wirklich löschen?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Haus löschen", role: .destructive) {
                    modelContext.delete(house)
                    if modelContext.save(reporting: notices, context: "Haus konnte nicht gelöscht werden") {
                        dismiss()
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            }
            .onDisappear {
                dismissTask?.cancel()
                commitDrafts()
            }
        }
    }

    // MARK: Sections

    private func header(summary: HouseSummary) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.snug) {
            Image(systemName: house.isApartmentBuilding ? "building.2.fill" : "house.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.red, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Adresse", text: $draftAddress, axis: .vertical)
                    .font(.headline)
                    .lineLimit(1...3)
                Text("\(summary.completedCount) von \(summary.units.count) erledigt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Fortschritt")
                    .accessibilityValue("\(summary.completedCount) von \(summary.units.count) Türen erledigt")
            }
        }
    }

    private func singleDoorEditor(door: DoorResult) -> some View {
        let current = door.result(on: writeDay)
        return VStack(spacing: AppSpacing.snug) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(VisitOutcome.allCases) { outcome in
                    OutcomeButton(outcome: outcome, isSelected: current == outcome) {
                        apply(outcome, to: door, current: current)
                    }
                }
            }

            if let timestamp = door.timestamp(in: scope) {
                Text("Zuletzt: \(timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(house.isDamaged)
    }

    private func apartmentSection(units: [DoorResult]) -> some View {
        Section {
            ForEach(units) { door in
                ApartmentDoorRow(
                    door: door,
                    writeDay: writeDay,
                    isDisabled: house.isDamaged,
                    onSelect: { outcome in
                        apply(outcome, to: door, current: door.result(on: writeDay))
                    },
                    onRename: { name in
                        house.renameUnit(name, id: door.id)
                        save()
                    }
                )
            }
        } header: {
            Text("Türen")
        } footer: {
            Button {
                guard house.setOutcomeForOpenDoors(.notHome, day: writeDay) > 0 else { return }
                save()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label("Alle offenen Türen als „Niemand da“", systemImage: "arrow.clockwise.circle")
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .padding(.top, 4)
            .disabled(house.isDamaged)
        }
    }

    // MARK: Actions

    private func apply(_ outcome: VisitOutcome, to door: DoorResult, current: VisitOutcome?) {
        house.setOutcome(current == outcome ? nil : outcome, for: door.id, day: writeDay)
        save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        guard !house.isApartmentBuilding, current != outcome else { return }
        // Auto-dismiss is a convenience for the single-door case, but it must be
        // cancellable — two taps inside the window used to close the sheet even when
        // the second was a correction — and it is skipped under VoiceOver, which
        // would otherwise lose the status announcement.
        guard !voiceOverEnabled else { return }
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            commitDrafts()
            dismiss()
        }
    }

    /// Address and note are buffered while typing so there is no SwiftData write per
    /// keystroke, then written once here.
    private func commitDrafts() {
        var changed = false
        let address = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty, address != house.address {
            house.address = address
            changed = true
        }
        if draftNote != house.note {
            house.note = draftNote
            changed = true
        }
        guard changed else { return }
        // Both fields feed the archive's search index, which keys off `updatedAt` —
        // an edited note used to stay unsearchable until something else changed.
        house.touch()
        save()
    }

    private func save() {
        modelContext.save(reporting: notices, context: "Änderung konnte nicht gespeichert werden")
    }
}

// MARK: - Door row

private struct ApartmentDoorRow: View {
    let door: DoorResult
    let writeDay: Int
    let isDisabled: Bool
    let onSelect: (VisitOutcome) -> Void
    let onRename: (String) -> Void

    @State private var draftLabel: String
    @FocusState private var isEditingLabel: Bool

    init(
        door: DoorResult,
        writeDay: Int,
        isDisabled: Bool,
        onSelect: @escaping (VisitOutcome) -> Void,
        onRename: @escaping (String) -> Void
    ) {
        self.door = door
        self.writeDay = writeDay
        self.isDisabled = isDisabled
        self.onSelect = onSelect
        self.onRename = onRename
        _draftLabel = State(initialValue: door.label)
    }

    var body: some View {
        let current = door.result(on: writeDay)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: AppSpacing.tight) {
                OutcomeGlyph(outcome: current)
                TextField("Bezeichnung", text: $draftLabel)
                    .focused($isEditingLabel)
                    .font(.subheadline.weight(.medium))
                    .onSubmit { commit() }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(current.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // When this door was recorded — the round is a sequence, and
                    // knowing when you were here is part of the record.
                    if let stamp = recordedAt {
                        Text(stamp, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }

            HStack(spacing: 6) {
                ForEach(VisitOutcome.allCases) { outcome in
                    Button {
                        onSelect(outcome)
                    } label: {
                        Text(outcome.emoji)
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background {
                                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                    .fill(current == outcome
                                          ? outcome.tint.opacity(0.2)
                                          : Color(uiColor: .tertiarySystemFill))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                    .strokeBorder(current == outcome ? outcome.tint : .clear, lineWidth: 1.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(outcome.title)
                    .accessibilityAddTraits(current == outcome ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .padding(.vertical, 4)
        .disabled(isDisabled)
        .onChange(of: isEditingLabel) { _, editing in
            if !editing { commit() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(door.label)
        .accessibilityValue(
            recordedAt.map {
                "\(current.displayTitle), \($0.formatted(date: .omitted, time: .shortened))"
            } ?? current.displayTitle
        )
    }

    private var recordedAt: Date? {
        writeDay == 2 ? door.day2UpdatedAt : door.updatedAt
    }

    private func commit() {
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != door.label else {
            draftLabel = door.label
            return
        }
        onRename(trimmed)
    }
}

// MARK: - Unit count sheet

private struct UnitCountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let currentCount: Int?
    let onApply: (Int) -> Void

    @State private var count: Int
    @FocusState private var isFocused: Bool

    init(title: String, message: String, initialCount: Int, currentCount: Int?, onApply: @escaping (Int) -> Void) {
        self.title = title
        self.message = message
        self.currentCount = currentCount
        self.onApply = onApply
        _count = State(initialValue: min(max(initialCount, 2), 100))
    }

    /// Clamped in the binding, so a typed `0` or `500` can never reach the model.
    private var clamped: Binding<Int> {
        Binding(get: { count }, set: { count = min(max($0, 2), 100) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: clamped, in: 2...100) {
                        HStack {
                            Text("Parteien")
                            Spacer()
                            TextField("Anzahl", value: clamped, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($isFocused)
                                .frame(width: 70)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    if let currentCount, count < currentCount {
                        Text("\(currentCount - count) Türen am Ende der Liste werden mitsamt ihren Ergebnissen entfernt.")
                            .foregroundStyle(.red)
                    } else {
                        Text(message)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") {
                        onApply(count)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                // A number pad has no return key; without this the keyboard covers
                // the footer explaining what is about to be deleted.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { isFocused = false }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
