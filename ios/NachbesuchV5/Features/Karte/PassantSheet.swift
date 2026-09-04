import CoreLocation
import SwiftData
import SwiftUI
import UIKit

/// Records a street encounter at the aimed coordinate.
///
/// Leaner than the house sheet on purpose: a person has no address to suggest,
/// no duplicate radius and no doors — a note, an outcome and optionally a
/// return time. The note is required: without it the record is a dot with
/// nothing to say.
struct PassantSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices

    let coordinate: CLLocationCoordinate2D
    let gebietID: UUID
    let onCreated: (Passant) -> Void

    @State private var note = ""
    @State private var outcome: VisitOutcome?
    @State private var revisitAt: Date?
    @State private var showsTimePicker = false
    @FocusState private var noteIsFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Gespräch") {
                    TextField("Notiz — z. B. worum es ging", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($noteIsFocused)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Ergebnis (optional)") {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach([VisitOutcome.joined, .earlyNo]) { result in
                            OutcomeButton(outcome: result, isSelected: outcome == result) {
                                outcome = outcome == result ? nil : result
                                revisitAt = nil
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                        }
                    }
                    LaterButton(isSelected: outcome == .later, bookedAt: revisitAt) {
                        showsTimePicker = true
                    }
                }
            }
            .navigationTitle("Passant eintragen")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: attemptSave)
                        .fontWeight(.semibold)
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showsTimePicker) {
                RevisitTimeSheet(subject: displaySubject, existing: revisitAt) { date in
                    outcome = .later
                    revisitAt = date
                    UISelectionFeedbackGenerator().selectionChanged()
                } onClear: {
                    if outcome == .later {
                        outcome = nil
                        revisitAt = nil
                    }
                }
            }
            .task { noteIsFocused = true }
        }
    }

    private var displaySubject: String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Passant" : trimmed
    }

    private func attemptSave() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let passant = Passant(
            note: trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            gebietID: gebietID
        )
        passant.outcome = outcome
        passant.revisitAt = outcome == .later ? revisitAt : nil
        modelContext.insert(passant)
        guard modelContext.save(reporting: notices, context: "Passant konnte nicht gespeichert werden") else {
            return
        }
        if outcome == .later, let at = passant.revisitAt {
            Task {
                await ReminderService.scheduleRevisit(
                    house: passant.id,
                    door: passant.id,
                    day: 1,
                    address: passant.note,
                    doorLabel: "Gespräch",
                    isApartmentBuilding: false,
                    at: at
                )
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCreated(passant)
        dismiss()
    }
}
