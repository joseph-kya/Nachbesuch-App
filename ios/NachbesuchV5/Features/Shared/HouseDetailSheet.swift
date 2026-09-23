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
    @Environment(\.scenePhase) private var scenePhase
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
    /// Ausstehende Umwandlung (Ziel-Parteienzahl), bis der Datenverlust-Dialog entschieden ist.
    @State private var pendingConvertCount: Int?
    @State private var showConvertConfirm = false
    /// Ausstehende Verkleinerung — gleiches Dialogmuster wie Umwandeln (wiederverwendet).
    @State private var pendingResizeCount: Int?
    @State private var showResizeConfirm = false
    @State private var dismissTask: Task<Void, Never>?
    /// Entprelltes Notiz-Autosave, damit Tippen weder pro Taste schreibt noch beim Wischen verloren geht.
    @State private var draftAutosave: Task<Void, Never>?
    @State private var pendingSave = PendingSave()
    /// Feuert die Fertig-Haptik genau einmal pro Fertigstellung (Token-Muster wie StreetHeader).
    @State private var celebrateToken = 0

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
        // Fertig heißt: keine offene Tür übrig — nicht schon bei „erfasst".
        let isDone = !summary.units.isEmpty && summary.openCount == 0

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
                    .glassRows()
                }

                Section { header(summary: summary) }
                    .glassRows()

                // Haus fertig: nur für Mehrparteienhäuser. Ein Einzelhaus schließt
                // sich nach dem Tipp von selbst — eine Zeile, die einfährt, während
                // das Blatt schon abfährt, ist Bewegung ohne Leser.
                if isDone, house.isApartmentBuilding {
                    Section {
                        Label("Fertig — alle Türen erledigt", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .transition(.blockSwap(reduceMotion: reduceMotion))
                            .accessibilityLabel("Fertig, alle Türen erledigt")
                    }
                    .glassRows()
                }

                if house.isApartmentBuilding {
                    apartmentSection(units: summary.units)
                } else if let door = summary.units.first {
                    Section("Ergebnis") {
                        singleDoorEditor(door: door)
                            // Form still clips a transparent row to its grouped
                            // corners. Concentric spacing keeps the smaller tile
                            // corners entirely inside that outer silhouette.
                            .padding(AppRadius.card - AppRadius.control)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    Section {
                        Button {
                            sheetRoute = .convertToApartment
                        } label: {
                            Label("Zu Mehrparteienhaus machen", systemImage: "building.2")
                        }
                    }
                    .glassRows()
                }

                Section {
                    TextField("Notiz", text: $draftNote, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Notiz")
                } footer: {
                    // Zeichenzahl als Hinweis, kein Limit — lange Notizen bleiben erlaubt.
                    Text("\(draftNote.count)/500")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .glassRows()

                Section {
                    Button("Haus löschen", systemImage: "trash", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
                .glassRows()
            }
            // The sheet's own glass shows through instead of an opaque ground.
            .glassForm()
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
                        requestConvert(to: count)
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                case .resizeUnits:
                    UnitCountSheet(
                        title: "Anzahl der Parteien",
                        message: "Beim Verkleinern werden die hintersten Türen entfernt.",
                        initialCount: max(2, summary.units.count),
                        currentCount: summary.units.count
                    ) { count in
                        requestResize(to: count)
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                case .revisitTimeForOpenDoors:
                    RevisitTimeSheet(
                        subject: "\(house.address) — alle offenen Türen",
                        onPick: { date in applyLaterToOpenDoors(at: date) }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .confirmationDialog(
                "Haus wirklich löschen?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Haus löschen", role: .destructive) {
                    let houseID = house.id
                    // Adresse vorher sichern: Nach `delete` ist das Modell weg und kein Undo mehr möglich.
                    let deletedAddress = house.address
                    Task { await ReminderService.cancelAllRevisits(house: houseID) }
                    modelContext.delete(house)
                    if modelContext.save(reporting: notices, context: "Haus konnte nicht gelöscht werden") {
                        // Kein Undo — Modell ist fort — darum wenigstens eine lesbare Quittung mit Adresse.
                        notices.show("Haus „\(deletedAddress)“ gelöscht")
                        onDelete(houseID)
                        dismiss()
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            }
            // Datenverlust-Dialoge: alle deutsch, Bestätigung destruktiv.
            // Fokus-Rücksprung aufs auslösende Element ist Systemstandard.
            .confirmationDialog(
                "Türen haben bereits Status",
                isPresented: $showConvertConfirm,
                titleVisibility: .visible
            ) {
                Button("Trotzdem umwandeln", role: .destructive) {
                    if let count = pendingConvertCount { applyConvert(to: count) }
                    pendingConvertCount = nil
                }
                Button("Abbrechen", role: .cancel) { pendingConvertCount = nil }
            } message: {
                Text("Der bestehende Status bleibt als „Tür 1“ erhalten, die Bezeichnung wird zurückgesetzt. Trotzdem umwandeln?")
            }
            .confirmationDialog(
                "Ergebnisse gehen verloren",
                isPresented: $showResizeConfirm,
                titleVisibility: .visible
            ) {
                Button("Trotzdem verkleinern", role: .destructive) {
                    if let count = pendingResizeCount { applyResize(to: count) }
                    pendingResizeCount = nil
                }
                Button("Abbrechen", role: .cancel) { pendingResizeCount = nil }
            } message: {
                Text("Die hintersten Türen werden mitsamt ihren Ergebnissen entfernt. Trotzdem verkleinern?")
            }
            // Erfolg nur bei false→true: Token steigt nur beim Fertigwerden, nie beim Wiederöffnen.
            // The done row arrives on the calm feedback curve — this used to be a
            // bouncing spring over the entire form, every row wobbling with it.
            .animation(.appFeedback(reduceMotion: reduceMotion), value: isDone)
            .sensoryFeedback(.success, trigger: celebrateToken)
            .onChange(of: isDone) { _, done in
                guard done else { return }
                celebrateToken &+= 1
            }
            .onChange(of: sheetRoute?.id) { _, newValue in
                // Sheet ist zu, erst jetzt darf der Bestätigungsdialog hoch —
                // zwei gleichzeitige Präsentationen verliert SwiftUI still.
                if newValue == nil {
                    if pendingConvertCount != nil { showConvertConfirm = true }
                    else if pendingResizeCount != nil { showResizeConfirm = true }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Hintergrund braucht die Entwürfe im Modell, nicht nur den
                // Puffer-Flush — sonst geht Tippen beim Weglegen verloren.
                if phase != .active { commitDrafts() }
            }
            // Entprelltes Autosave: kein Schreiben pro Taste, aber nach 2 s
            // Ruhe steht die Notiz im Modell — Wisch-Geste verliert nichts.
            .onChange(of: draftNote) { _, _ in scheduleDraftAutosave() }
            .onChange(of: draftAddress) { _, _ in scheduleDraftAutosave() }
            .onDisappear {
                dismissTask?.cancel()
                draftAutosave?.cancel()
                // Wisch-Geste zum Schließen landet hier — Entwürfe sichern.
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
                .background(accent.gradient, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Adresse", text: $draftAddress, axis: .vertical)
                    .font(.headline)
                    .lineLimit(1...3)
                Text("\(summary.completedCount) von \(summary.units.count) erledigt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(summary.completedCount)))
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
                columns: [GridItem(.flexible(), spacing: AppSpacing.snug), GridItem(.flexible(), spacing: AppSpacing.snug)],
                spacing: AppSpacing.snug
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

            // Gebuchte Zeit als indigofarbene Glanz-Zeile mit relativem Label;
            // tippen öffnet denselben Zeit-Sheet wie der Später-Button.
            if current == .later, let booked = door.revisitTime(on: writeDay) {
                BookedTimeGlance(bookedAt: booked) {
                    sheetRoute = .revisitTime(door: door)
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
                    onLater: { sheetRoute = .revisitTime(door: door) },
                    onRename: { name in
                        house.renameUnit(name, id: door.id)
                        scheduleSave()
                    }
                )
            }
        } header: {
            Text("Türen")
        } footer: {
            VStack(alignment: .leading, spacing: AppSpacing.snug) {
                Button {
                    guard house.setOutcomeForOpenDoors(.notHome, day: writeDay) > 0 else { return }
                    // Leichtes Tippen sofort, Erfolg erst beim Schreiben: so fühlt
                    // sich die Masse an wie eine Einzeltür, nur lauter.
                    UISelectionFeedbackGenerator().selectionChanged()
                    pendingSave.schedule(in: modelContext, reporting: notices) {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
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
        .glassRows()
    }

    // MARK: Actions

    private func apply(_ outcome: VisitOutcome, to door: DoorResult, current: VisitOutcome?) {
        // Zustand zuerst, Speichern danach: Das Modell steht sofort, der Chip
        // füllt sich im selben Frame — der verzögerte Save darf nie sichtbar sein.
        house.setOutcome(current == outcome ? nil : outcome, for: door.id, day: writeDay)
        UISelectionFeedbackGenerator().selectionChanged()
        scheduleSave()
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
            // Long enough for the selection ring to finish settling, so the tap
            // is seen to land before the sheet leaves — one motion, then the next.
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            commitDrafts()
            dismiss()
        }
    }

    /// Postpones one door to `date` and books the reminder.
    ///
    /// Kein eigenes Feedback hier: Der Zeit-Sheet feuert beim Übernehmen bereits
    /// den Erfolg — doppelt vibriert schlechter als gar nicht.
    private func applyLater(to unitID: UUID, at date: Date) {
        house.setOutcome(.later, for: unitID, day: writeDay, revisitAt: date)
        scheduleSave()
        scheduleReminder(for: unitID, at: date)
        notices.show("Später um \(RevisitPlanner.clockFormatter.string(from: date))")
    }

    /// The building-wide version, booking the same time for every open door.
    ///
    /// Wie der Masse-nichtZuhause-Button: leichtes Tippen sofort, Erfolg erst
    /// beim Schreiben — Einzeltüren bleiben dagegen leise.
    /// Batch über `scheduleRevisits`: eine Prüfung, ein Hintergrund-Task.
    private func applyLaterToOpenDoors(at date: Date) {
        guard house.setOutcomeForOpenDoors(.later, day: writeDay, revisitAt: date) > 0 else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        pendingSave.schedule(in: modelContext, reporting: notices) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        // Snapshot für den Hintergrund: nur sendbare Werte, kein Modellzugriff dort.
        let filterScope: DayScope = writeDay == 2 ? .day2 : .day1
        let houseID = house.id
        let address = house.address
        let isApartment = house.isApartmentBuilding
        let day = writeDay
        let batch: [RevisitReminderCandidate] = house.units
            .filter { $0.isOpen(in: filterScope) }
            .prefix(ReminderService.revisitBudget)
            .map { door in
                RevisitReminderCandidate(
                    houseID: houseID, doorID: door.id, day: day,
                    address: address, doorLabel: door.label,
                    isApartmentBuilding: isApartment, date: date
                )
            }
        let total = batch.count
        // Ein Call statt Schleife: die einzelne Prüfung lebt in der Batch-API.
        // Fällt die Batch-API weg, hier auf Einzelschleife mit `scheduleRevisit` zurückfallen.
        Task.detached(priority: .utility) {
            await ReminderService.scheduleRevisits(batch)
        }
        notices.show("\(total) Türen: später um \(RevisitPlanner.clockFormatter.string(from: date))")
    }

    /// Kein eigenes Feedback: Der Zeit-Sheet bestätigt "Zeit entfernen" selbst.
    private func clearOutcome(for unitID: UUID) {
        house.setOutcome(nil, for: unitID, day: writeDay)
        scheduleSave()
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

    /// Ob irgendeine Tür je einen Status bekam (Tag 1 oder 2) — dann ist
    /// Umwandeln/Verkleinern möglicher Datenverlust und braucht Bestätigung.
    private var hasAnyOutcome: Bool {
        house.units.contains { $0.outcome != nil || $0.day2Outcome != nil }
    }

    /// Ob beim Verkleinern auf `target` eine Tür mit Ergebnis wegfiele.
    private func removedDoorsHaveOutcomes(target: Int) -> Bool {
        let units = house.units
        guard target < units.count else { return false }
        return units[target...].contains { $0.outcome != nil || $0.day2Outcome != nil }
    }

    /// Entwürfe zuerst ins Modell, dann prüfen: Ohne Status geht es sofort,
    /// mit Status entscheidet der Bestätigungsdialog nach dem Schließen des Sheets.
    private func requestConvert(to count: Int) {
        commitDrafts()
        guard hasAnyOutcome else {
            applyConvert(to: count)
            return
        }
        pendingConvertCount = count
    }

    private func applyConvert(to count: Int) {
        commitDrafts()
        house.convertToApartmentBuilding(unitCount: count)
        UserDefaults.standard.set(count, forKey: "lastApartmentUnitCount")
        scheduleSave()
    }

    /// Gleiches Muster wie Umwandeln: Vergrößern ist harmlos, Verkleinern mit
    /// Ergebnissen auf den hinteren Türen braucht Bestätigung.
    private func requestResize(to count: Int) {
        commitDrafts()
        guard removedDoorsHaveOutcomes(target: count) else {
            applyResize(to: count)
            return
        }
        pendingResizeCount = count
    }

    private func applyResize(to count: Int) {
        commitDrafts()
        house.resizeUnits(to: count)
        scheduleSave()
    }

    /// Schreibt die Entwürfe nach 2 s Tipppause — kein Schreiben pro Taste.
    private func scheduleDraftAutosave() {
        draftAutosave?.cancel()
        draftAutosave = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            commitDrafts()
        }
    }

    /// Address and note are buffered while typing so there is no SwiftData write per
    /// keystroke, then written once here.
    private func commitDrafts() {
        var touched = false
        let address = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty, address != house.address {
            house.address = address
            touched = true
        }
        if draftNote != house.note {
            house.note = draftNote
            touched = true
        }
        // Both fields feed the archive's search index, which keys off `updatedAt` —
        // an edited note used to stay unsearchable until something else changed.
        if touched { house.touch() }
        flushPendingSave()
    }

    private func scheduleSave() {
        pendingSave.schedule(in: modelContext, reporting: notices)
    }

    private func flushPendingSave() {
        pendingSave.flush(in: modelContext, reporting: notices)
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
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            HStack(spacing: AppSpacing.tight) {
                OutcomeGlyph(outcome: current)
                if isEditingLabel {
                    TextField("Bezeichnung", text: $draftLabel)
                        .focused($isEditingLabel)
                        .font(.subheadline.weight(.medium))
                        .onSubmit { commit() }
                } else {
                    Text(draftLabel.isEmpty ? door.label : draftLabel)
                        .font(.subheadline.weight(.medium))
                        .contentShape(.rect)
                        .onTapGesture {
                            guard !isDisabled else { return }
                            isEditingLabel = true
                        }
                }
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

            HStack(spacing: AppSpacing.tight) {
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

            // Gebuchte Zeit mit relativem Label; tippen öffnet den Zeit-Sheet.
            if current == .later, let booked = door.revisitTime(on: writeDay) {
                BookedTimeGlance(bookedAt: booked, action: onLater)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let emoji: String
    let tint: Color
    let isSelected: Bool
    /// `nil` means "share the row equally"; a value pins the chip narrower.
    let width: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Text(emoji)
                    .font(.body)
                    .frame(maxWidth: width == nil ? .infinity : nil)
                    .frame(width: width, height: 38)
                    .contentCard(cornerRadius: AppRadius.control, elevated: false)
                    .selectionRing(isSelected, tint: tint, cornerRadius: AppRadius.control)
                    .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))

                // Kein Chip-Skalieren: In der Form clippt das an den
                // Abschnittsrändern. Stattdessen wächst nur das Häkchen
                // (0.6 → 1, RM-sicher) und hüpft einmal — das Emoji ist Text,
                // kein Symbol, darum lebt der Bounce auf dem Badge.
                if isSelected {
                    badge
                        .offset(x: 5, y: -5)
                        .transition(.appChrome(reduceMotion: reduceMotion, anchor: .center))
                }
            }
        }
        .buttonStyle(PressableRowStyle())
        .animation(.appFeedback(reduceMotion: reduceMotion), value: isSelected)
    }

    /// One motion for the selection: the check fades and settles in with the
    /// ring. The old version scaled it from 0.6 *and* bounced the symbol — two
    /// animations for one tap.
    private var badge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(tint)
            .background(.background, in: Circle())
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
                    HStack {
                        Text("Parteien")
                        Spacer()
                        TextField("Anzahl", value: clamped, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isFocused)
                            .frame(width: 70)
                            .monospacedDigit()
                        Stepper("", value: clamped, in: 2...100)
                            .labelsHidden()
                    }
                    // Deutsches Label „Anzahl" plus 44pt-Treffläche für A11y.
                    .frame(minHeight: 44)
                } footer: {
                    if let currentCount, count < currentCount {
                        Text("\(currentCount - count) Türen am Ende der Liste werden mitsamt ihren Ergebnissen entfernt.")
                            .foregroundStyle(.red)
                    } else {
                        Text(message)
                    }
                }
                .glassRows()
            }
            .glassForm()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        isFocused = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") {
                        isFocused = false
                        let finalCount = min(max(count, 2), 100)
                        onApply(finalCount)
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
        }
    }
}
