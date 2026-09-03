import SwiftData
import SwiftUI
import UIKit

/// Everything about one address.
struct HouseDetailSheet: View {
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppNoticeCenter.self) private var notices

    @Bindable var house: House
    let scope: DayScope
    /// Which campaign day a tap writes to. Decided by the caller from the
    /// territory's calendar, so the value read and the value written always match.
    let writeDay: Int
    /// Fires after a confirmed delete saved, so the presenter can drop the pin
    /// in the same turn instead of waiting for the store refresh to notice a
    /// row that comes back in no fetch.
    let onDelete: (UUID) -> Void

    @State private var draftAddress: String
    @State private var draftNote: String
    @State private var sheetRoute: DetailRoute?
    @State private var showDeleteConfirmation = false
    @State private var dismissTask: Task<Void, Never>?

    init(house: House, scope: DayScope, writeDay: Int, onDelete: @escaping (UUID) -> Void = { _ in }) {
        self.house = house
        self.scope = scope
        self.writeDay = writeDay
        self.onDelete = onDelete
        _draftAddress = State(initialValue: house.address)
        _draftNote = State(initialValue: house.note)
    }

    private enum DetailRoute: Identifiable {
        case convertToApartment
        case resizeUnits
        /// Booking a return time for one door. Carries the door rather than a
        /// binding so the sheet cannot outlive the door it was opened for.
        case revisitTime(door: DoorResult)
        /// Booking one return time for every still-open door of a building.
        case revisitTimeForOpenDoors

        var id: String {
            switch self {
            case .convertToApartment: "convert"
            case .resizeUnits: "resize"
            case let .revisitTime(door): "revisit-\(door.id)"
            case .revisitTimeForOpenDoors: "revisit-open"
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
                case let .revisitTime(door):
                    RevisitTimeSheet(
                        subject: subjectText(for: door),
                        existing: door.revisitTime(on: writeDay),
                        onPick: { date in
                            applyLater(to: door.id, at: date)
                        },
                        onClear: door.result(on: writeDay) == .later
                            ? { clearOutcome(for: door.id) }
                            : nil
                    )
                case .revisitTimeForOpenDoors:
                    RevisitTimeSheet(
                        subject: "\(house.address) — alle offenen Türen",
                        onPick: { date in applyLaterToOpenDoors(at: date) }
                    )
                }
            }
            .confirmationDialog(
                "Haus wirklich löschen?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Haus löschen", role: .destructive) {
                    let houseID = house.id
                    Task { await ReminderService.cancelAllRevisits(house: houseID) }
                    modelContext.delete(house)
                    if modelContext.save(reporting: notices, context: "Haus konnte nicht gelöscht werden") {
                        onDelete(houseID)
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
                .background(accent, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Adresse", text: $draftAddress, axis: .vertical)
                    .font(.headline)
                    .lineLimit(1...3)
                Text("\(summary.completedCount) von \(summary.units.count) erledigt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(summary.completedCount)))
                    .animation(
                        .appFeedback(reduceMotion: reduceMotion),
                        value: summary.completedCount
                    )
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
                ForEach(VisitOutcome.primary) { outcome in
                    OutcomeButton(outcome: outcome, isSelected: current == outcome) {
                        apply(outcome, to: door, current: current)
                    }
                }
            }

            LaterButton(
                isSelected: current == .later,
                bookedAt: door.revisitTime(on: writeDay)
            ) {
                // Tapping an already-postponed door edits its time; the sheet's
                // own "Zeit entfernen" is the way back to no status.
                sheetRoute = .revisitTime(door: door)
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
                    onLater: { sheetRoute = .revisitTime(door: door) },
                    onRename: { name in
                        house.renameUnit(name, id: door.id)
                        save()
                    }
                )
            }
        } header: {
            Text("Türen")
        } footer: {
            VStack(alignment: .leading, spacing: 10) {
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

                Button {
                    sheetRoute = .revisitTimeForOpenDoors
                } label: {
                    Label("Alle offenen Türen auf „Später“", systemImage: VisitOutcome.later.symbolName)
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisitOutcome.later.tint)
            }
            .padding(.top, 4)
            .disabled(house.isDamaged)
        }
    }

    // MARK: Actions

    private func apply(_ outcome: VisitOutcome, to door: DoorResult, current: VisitOutcome?) {
        house.setOutcome(current == outcome ? nil : outcome, for: door.id, day: writeDay)
        save()
        // Any non-"Später" answer settles the door, so its pending reminder has to
        // go — otherwise a phone buzzes at 18:00 for a household that joined at 17.
        cancelReminder(for: door.id)

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

    /// Postpones one door to `date` and books the reminder.
    private func applyLater(to unitID: UUID, at date: Date) {
        house.setOutcome(.later, for: unitID, day: writeDay, revisitAt: date)
        save()
        scheduleReminder(for: unitID, at: date)
        notices.show("Später um \(RevisitPlanner.clockFormatter.string(from: date))")
    }

    /// The building-wide version, booking the same time for every open door.
    private func applyLaterToOpenDoors(at date: Date) {
        let openDoorIDs = house.units
            .filter { $0.isOpen(in: writeDay == 2 ? .day2 : .day1) }
            .map(\.id)
        guard house.setOutcomeForOpenDoors(.later, day: writeDay, revisitAt: date) > 0 else { return }
        save()
        for unitID in openDoorIDs {
            scheduleReminder(for: unitID, at: date)
        }
        notices.show("\(openDoorIDs.count) Türen: später um \(RevisitPlanner.clockFormatter.string(from: date))")
    }

    private func clearOutcome(for unitID: UUID) {
        house.setOutcome(nil, for: unitID, day: writeDay)
        save()
        cancelReminder(for: unitID)
    }

    private func subjectText(for door: DoorResult) -> String {
        house.isApartmentBuilding ? "\(house.address) — \(door.label)" : house.address
    }

    private func scheduleReminder(for unitID: UUID, at date: Date) {
        let houseID = house.id
        let address = house.address
        let isApartment = house.isApartmentBuilding
        let label = house.units.first { $0.id == unitID }?.label ?? "Haushalt"
        let day = writeDay
        Task {
            await ReminderService.scheduleRevisit(
                house: houseID, door: unitID, day: day,
                address: address, doorLabel: label,
                isApartmentBuilding: isApartment, at: date
            )
        }
    }

    private func cancelReminder(for unitID: UUID) {
        let houseID = house.id
        let day = writeDay
        Task { await ReminderService.cancelRevisit(house: houseID, door: unitID, day: day) }
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
        if modelContext.save(reporting: notices, context: "Änderung konnte nicht gespeichert werden") {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

// MARK: - Door row

private struct ApartmentDoorRow: View {
    let door: DoorResult
    let writeDay: Int
    let isDisabled: Bool
    let onSelect: (VisitOutcome) -> Void
    let onLater: () -> Void
    let onRename: (String) -> Void

    @State private var draftLabel: String
    @FocusState private var isEditingLabel: Bool

    init(
        door: DoorResult,
        writeDay: Int,
        isDisabled: Bool,
        onSelect: @escaping (VisitOutcome) -> Void,
        onLater: @escaping () -> Void,
        onRename: @escaping (String) -> Void
    ) {
        self.door = door
        self.writeDay = writeDay
        self.isDisabled = isDisabled
        self.onSelect = onSelect
        self.onLater = onLater
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
                    Text(current?.label(revisitAt: door.revisitTime(on: writeDay)) ?? current.displayTitle)
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
                ForEach(VisitOutcome.primary) { outcome in
                    OutcomeChip(
                        emoji: outcome.emoji,
                        tint: outcome.tint,
                        isSelected: current == outcome,
                        width: nil,
                        action: { onSelect(outcome) }
                    )
                    .accessibilityLabel(outcome.title)
                    .accessibilityAddTraits(current == outcome ? [.isButton, .isSelected] : .isButton)
                }

                // Narrower than the four results: "Später" postpones the door, it
                // does not close it, so it does not get equal billing.
                OutcomeChip(
                    emoji: VisitOutcome.later.emoji,
                    tint: VisitOutcome.later.tint,
                    isSelected: current == .later,
                    width: 46,
                    action: onLater
                )
                .accessibilityLabel(VisitOutcome.later.title)
                .accessibilityHint("Fragt nach einer Uhrzeit")
                .accessibilityAddTraits(current == .later ? [.isButton, .isSelected] : .isButton)
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
                "\(current?.label(revisitAt: door.revisitTime(on: writeDay)) ?? current.displayTitle), \($0.formatted(date: .omitted, time: .shortened))"
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

/// One emoji status chip in an apartment door row.
///
/// Extracted because the inline version of this — five chips, each with its own
/// conditional fill and border — was past what the type checker would solve in one
/// expression.
private struct OutcomeChip: View {
    let emoji: String
    let tint: Color
    let isSelected: Bool
    /// `nil` means "share the row equally"; a value pins the chip narrower.
    let width: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.body)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .frame(width: width, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(isSelected ? tint.opacity(0.2) : Color(uiColor: .tertiarySystemFill))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .strokeBorder(isSelected ? tint : .clear, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
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
