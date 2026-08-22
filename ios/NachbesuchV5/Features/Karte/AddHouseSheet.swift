import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UIKit

/// Creates a house at the coordinate the user aimed at.
struct AddHouseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices

    let coordinate: CLLocationCoordinate2D
    let gebietID: UUID
    let existingHouses: [House]
    /// The campaign day an immediately-set status belongs to. Previously absent, so
    /// a house created on day 2 recorded its first result against day 1.
    let writeDay: Int
    let onCreated: (House) -> Void

    @State private var address = ""
    @State private var isApartment = false
    @State private var unitCount = 4
    @State private var initialOutcome: VisitOutcome?
    @State private var isLoadingAddress = true
    @State private var duplicateIndex: HouseDuplicateIndex?
    @State private var duplicateWarning: House?
    @State private var didOverrideDuplicate = false
    @FocusState private var addressIsFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Adresse") {
                    HStack {
                        TextField("Straße und Hausnummer", text: $address, axis: .vertical)
                            .lineLimit(1...3)
                            .focused($addressIsFocused)
                            .textInputAutocapitalization(.words)
                        if isLoadingAddress {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let clipboard = UIPasteboard.general.string,
                       !clipboard.isEmpty, clipboard.count < 120, address != clipboard {
                        Button {
                            address = clipboard
                        } label: {
                            Label("Aus Zwischenablage übernehmen", systemImage: "doc.on.clipboard")
                                .font(.footnote)
                        }
                    }
                }

                Section("Art") {
                    Picker("Art", selection: $isApartment) {
                        Text("Einzelhaus").tag(false)
                        Text("Mehrparteienhaus").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if isApartment {
                        Stepper(value: $unitCount, in: 2...100) {
                            HStack {
                                Text("Parteien")
                                Spacer()
                                Text("\(unitCount)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !isApartment {
                    Section("Status (optional)") {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            spacing: 10
                        ) {
                            // Results only. "Später" would need a return time, and
                            // a house that does not exist yet has nothing to book a
                            // reminder against — it is one tap away in the detail
                            // sheet once the pin is on the map.
                            ForEach(VisitOutcome.primary) { outcome in
                                OutcomeButton(outcome: outcome, isSelected: initialOutcome == outcome) {
                                    initialOutcome = initialOutcome == outcome ? nil : outcome
                                    UISelectionFeedbackGenerator().selectionChanged()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Haus hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: attemptSave)
                        .fontWeight(.semibold)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(
                "Dieses Haus gibt es schon",
                isPresented: Binding(
                    get: { duplicateWarning != nil },
                    set: { if !$0 { duplicateWarning = nil } }
                ),
                presenting: duplicateWarning
            ) { _ in
                Button("Trotzdem anlegen") {
                    didOverrideDuplicate = true
                    duplicateWarning = nil
                    attemptSave()
                }
                Button("Abbrechen", role: .cancel) { duplicateWarning = nil }
            } message: { house in
                Text("„\(house.address)“ ist bereits erfasst.")
            }
            .task {
                // Built BEFORE the geocode: the old order left the index nil for the
                // whole network round trip, so a fast user could save a duplicate
                // before duplicate detection had loaded.
                duplicateIndex = HouseDuplicateIndex(houses: existingHouses, coordinate: coordinate)
                await loadSuggestedAddress()
            }
        }
    }

    private func attemptSave() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !didOverrideDuplicate,
           let existing = duplicateIndex?.duplicate(for: trimmed) {
            duplicateWarning = existing
            return
        }

        let house = House(
            address: trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            gebietID: gebietID,
            isApartmentBuilding: isApartment,
            unitCount: isApartment ? unitCount : 1
        )
        modelContext.insert(house)

        if !isApartment, let initialOutcome, let door = house.units.first {
            house.setOutcome(initialOutcome, for: door.id, day: writeDay)
        }
        if isApartment {
            UserDefaults.standard.set(unitCount, forKey: "lastApartmentUnitCount")
        }

        guard modelContext.save(reporting: notices, context: "Haus konnte nicht gespeichert werden") else {
            // `save(reporting:)` rolls the context back, so the half-created house is
            // gone rather than waiting to be committed by an unrelated save later.
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCreated(house)
        dismiss()
    }

    private func loadSuggestedAddress() async {
        defer { isLoadingAddress = false }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let items = try? await request.mapItems,
              let item = items.first,
              !Task.isCancelled
        else { return }

        let suggestion = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
            ?? item.address?.shortAddress
            ?? item.address?.fullAddress
        guard let suggestion, address.isEmpty else { return }
        address = suggestion
        addressIsFocused = false
    }
}

/// Duplicate detection for a new house.
struct HouseDuplicateIndex {
    private let byNormalizedAddress: [String: House]
    private let nearby: [House]

    init(houses: [House], coordinate: CLLocationCoordinate2D) {
        var index: [String: House] = [:]
        var near: [House] = []
        // Flat equirectangular metres — no `CLLocation` object per house, which at a
        // few thousand houses was thousands of ObjC allocations while the sheet
        // animated in.
        let latitudeScale = 110_540.0
        let longitudeScale = 111_320.0 * cos(coordinate.latitude * .pi / 180)

        for house in houses {
            let key = AddressNormalizer.normalize(house.address)
            if !key.isEmpty, index[key] == nil { index[key] = house }
            let dLat = (house.latitude - coordinate.latitude) * latitudeScale
            let dLon = (house.longitude - coordinate.longitude) * longitudeScale
            if dLat * dLat + dLon * dLon <= 12 * 12 { near.append(house) }
        }
        byNormalizedAddress = index
        nearby = near
    }

    /// A different address at the same spot is a legitimate second entrance, a corner
    /// building or a neighbouring row house — the old code warned about all of them
    /// because it returned any nearby house regardless of what was typed.
    func duplicate(for address: String) -> House? {
        let key = AddressNormalizer.normalize(address)
        guard !key.isEmpty else { return nil }
        if let exact = byNormalizedAddress[key] { return exact }
        return nearby.first { AddressNormalizer.normalize($0.address) == key }
    }
}

/// One normalisation for every duplicate check in the app.
///
/// The manual sheet used to fold with `.current` locale while the bulk importer used
/// `de_AT`, so the two disagreed about what counted as the same address.
enum AddressNormalizer {
    nonisolated static func normalize(_ address: String) -> String {
        address
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_AT"))
            .replacingOccurrences(of: "straße", with: "strasse")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
