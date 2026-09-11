import CoreLocation
import SwiftData
import SwiftUI

/// Creates or edits a territory. One sheet for both, instead of two near-identical
/// ones that had drifted apart (only one checked whether the save succeeded before
/// dismissing).
struct GebietEditorSheet: View {
    enum Mode {
        case create
        case edit(Gebiet)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices
    @Query(sort: \Gebiet.createdAt, order: .reverse) private var allGebiete: [Gebiet]

    let mode: Mode
    var onCreated: ((Gebiet) -> Void)?

    @State private var name = ""
    @State private var districtOrCity = ""
    @State private var notes = ""
    @State private var duration: CampaignDuration = .singleDay
    @State private var day1 = Gebiet.campaignCalendar.startOfDay(for: .now)
    @State private var day2 = Gebiet.campaignCalendar.date(
        byAdding: .day,
        value: 1,
        to: Gebiet.campaignCalendar.startOfDay(for: .now)
    ) ?? .now
    @State private var reuseLastBoundary = false
    @State private var isSeeded = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editedGebiet: Gebiet? {
        if case .edit(let gebiet) = mode { return gebiet }
        return nil
    }

    /// "Last drawn" is a creation-time concept; the old query had no sort at all and
    /// returned whichever territory the store happened to hand back first.
    private var lastBoundary: [CLLocationCoordinate2D] {
        allGebiete.first { $0.hasBoundary }?.boundaryCoordinates ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("z. B. Mödling", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Ort oder Bezirk (optional)", text: $districtOrCity)
                        .textInputAutocapitalization(.words)
                }

                Section("Zeitraum") {
                    Picker("Dauer", selection: $duration) {
                        ForEach(CampaignDuration.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    DatePicker("Tag 1", selection: $day1, displayedComponents: .date)

                    if duration == .twoDays {
                        DatePicker(
                            "Tag 2",
                            selection: $day2,
                            in: dayAfter(day1)...,
                            displayedComponents: .date
                        )
                    }
                }

                if !isEditing, !lastBoundary.isEmpty {
                    Section {
                        Toggle("Letzte Gebietsgrenze übernehmen", isOn: $reuseLastBoundary)
                    } footer: {
                        Text("Die zuletzt gezeichnete Grenze wird übernommen. Häuser und Ergebnisse bleiben getrennt.")
                    }
                }

                Section("Notizen") {
                    TextField("Notizen", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .scrollContentBackground(.hidden)
            .background { AppBackdrop() }
            .navigationTitle(isEditing ? "Gebiet bearbeiten" : "Neues Gebiet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save).fontWeight(.semibold)
                }
            }
            .onChange(of: day1) { _, newValue in
                if day2 <= newValue { day2 = dayAfter(newValue) }
            }
            // `.task` runs once per view identity; `.onAppear` fired again on
            // re-appearance and wiped whatever the user had typed.
            .task {
                guard !isSeeded else { return }
                isSeeded = true
                seed()
            }
        }
    }

    private func dayAfter(_ date: Date) -> Date {
        let calendar = Gebiet.campaignCalendar
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        return next ?? date.addingTimeInterval(86_400)
    }

    private func seed() {
        guard let gebiet = editedGebiet else { return }
        name = gebiet.name
        districtOrCity = gebiet.districtOrCity
        notes = gebiet.notes
        duration = gebiet.duration
        day1 = gebiet.day1Date
        if let existing = gebiet.day2Date { day2 = existing }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let gebiet = editedGebiet {
            gebiet.rename(to: trimmedName, districtOrCity: districtOrCity)
            gebiet.notes = notes
            gebiet.isTwoDay = duration == .twoDays
            gebiet.assignDays(day1: day1, day2: duration == .twoDays ? day2 : nil)
            // Only dismiss on a confirmed save; the old edit sheet discarded the
            // result and closed over a persistent error banner with the edits gone.
            guard modelContext.save(reporting: notices, context: "Gebiet konnte nicht gespeichert werden")
            else { return }
            dismiss()
            return
        }

        let created = Gebiet(
            name: trimmedName,
            districtOrCity: districtOrCity,
            date: day1,
            isTwoDay: duration == .twoDays,
            day2Date: duration == .twoDays ? day2 : nil,
            boundaryCoordinates: reuseLastBoundary ? lastBoundary : []
        )
        created.notes = notes
        modelContext.insert(created)
        guard modelContext.save(reporting: notices, context: "Gebiet konnte nicht angelegt werden")
        else { return }
        onCreated?(created)
        dismiss()
    }
}
