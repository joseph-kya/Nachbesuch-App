import SwiftData
import SwiftUI
import UIKit

/// Everything about one street encounter: note, outcome, return time, delete.
///
/// Edits commit explicitly (Fertig) or when the sheet goes away — never per
/// keystroke. Outcome taps apply immediately like the list's quick statuses,
/// so the pin repaints under the opening sheet.
struct PassantDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices

    @Bindable var passant: Passant
    let onDelete: (UUID) -> Void

    @State private var draftNote: String
    @State private var showsTimePicker = false
    @State private var showDeleteConfirmation = false

    init(passant: Passant, onDelete: @escaping (UUID) -> Void = { _ in }) {
        self.passant = passant
        self.onDelete = onDelete
        _draftNote = State(initialValue: passant.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gespräch") {
                    TextField("Notiz", text: $draftNote, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.sentences)
                    LabeledContent("Erfasst", value: passant.createdAt.formatted(date: .abbreviated, time: .omitted))
                }

                Section("Ergebnis") {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach([VisitOutcome.joined, .earlyNo]) { result in
                            OutcomeButton(outcome: result, isSelected: passant.outcome == result) {
                                applyOutcome(passant.outcome == result ? nil : result)
                            }
                        }
                    }
                    LaterButton(isSelected: passant.outcome == .later, bookedAt: passant.revisitAt) {
                        showsTimePicker = true
                    }
                }

                Section {
                    Button(role: .destructive) { showDeleteConfirmation = true } label: {
                        Label("Passant löschen", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Begegnung")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        commitDrafts()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showsTimePicker) {
                RevisitTimeSheet(subject: displaySubject, existing: passant.revisitAt) { date in
                    applyOutcome(.later, revisitAt: date)
                } onClear: {
                    if passant.outcome == .later { applyOutcome(nil) }
                }
            }
            .confirmationDialog(
                "Passant wirklich löschen?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Passant löschen", role: .destructive) {
                    let passantID = passant.id
                    Task { await ReminderService.cancelAllRevisits(house: passantID) }
                    modelContext.delete(passant)
                    if modelContext.save(reporting: notices, context: "Passant konnte nicht gelöscht werden") {
                        onDelete(passantID)
                        dismiss()
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            }
            .onDisappear { commitDrafts() }
        }
    }

    private var displaySubject: String {
        passant.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Passant" : passant.note
    }

    private func applyOutcome(_ outcome: VisitOutcome?, revisitAt: Date? = nil) {
        let id = passant.id
        let previous = passant.outcome
        passant.outcome = outcome
        passant.revisitAt = outcome == .later ? revisitAt : nil
        passant.touch()
        guard modelContext.save(reporting: notices, context: "Ergebnis konnte nicht gespeichert werden") else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if outcome == .later, let at = passant.revisitAt {
            Task {
                await ReminderService.scheduleRevisit(
                    house: id, door: id, day: 1,
                    address: passant.note, doorLabel: "Gespräch",
                    isApartmentBuilding: false, at: at
                )
            }
        } else if previous == .later {
            Task { await ReminderService.cancelRevisit(house: id, door: id, day: 1) }
        }
    }

    private func commitDrafts() {
        let trimmed = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != passant.note else { return }
        passant.note = trimmed
        passant.touch()
        _ = modelContext.save(reporting: notices, context: "Notiz konnte nicht gespeichert werden")
    }
}
