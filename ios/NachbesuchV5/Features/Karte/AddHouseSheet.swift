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
    /// The campaign day an immediately-set status belongs to. Previously absent, so
    /// a house created on day 2 recorded its first result against day 1.
    let writeDay: Int
    let onCreated: (House) -> Void
    /// Opens the already-recorded house instead of creating a second pin (B8).
    let onOpenExisting: (House) -> Void

    @State private var address = ""
    @State private var isApartment = false
    @State private var unitCount: Int = {
        let remembered = UserDefaults.standard.integer(forKey: "lastApartmentUnitCount")
        return remembered >= 2 ? min(remembered, 100) : 4
    }()
    @State private var initialOutcome: VisitOutcome?
    @State private var isLoadingAddress = true
    @State private var duplicateIndex: HouseDuplicateIndex?
    @State private var duplicateWarning: String?
    @State private var didOverrideDuplicate = false
    @FocusState private var addressIsFocused: Bool

    private var clampedUnitCount: Binding<Int> {
        Binding(
            get: { unitCount },
            set: { unitCount = min(max($0, 2), 100) }
        )
    }

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
                        HStack {
                            Text("Parteien")
                            Spacer()
                            TextField("Anzahl", value: clampedUnitCount, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .monospacedDigit()
                            Stepper("", value: clampedUnitCount, in: 2...100)
                                .labelsHidden()
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
                Button("Öffnen") { openExisting() }
                Button("Trotzdem anlegen") {
                    didOverrideDuplicate = true
                    duplicateWarning = nil
                    attemptSave()
                }
                Button("Abbrechen", role: .cancel) { duplicateWarning = nil }
            } message: { address in
                Text("„\(address)“ ist bereits erfasst.")
            }
            .task {
                // The fingerprints come from the background reader, and the index
                // itself builds off the main thread: the old order fetched every
                // live model and normalised every address on the main actor while
                // the sheet animated in. Built BEFORE the geocode — the old order
                // left the index nil for the whole network round trip, so a fast
                // user could save a duplicate before duplicate detection had loaded.
                duplicateIndex = await buildDuplicateIndex()
                await loadSuggestedAddress()
            }
        }
    }

    /// Reads the territory's fingerprints on the background actor and builds the
    /// index off the main thread. On a fetch failure the index covers nothing —
    /// the same silent fallback the old main-thread fetch had, which reported
    /// and returned an empty territory.
    private func buildDuplicateIndex() async -> HouseDuplicateIndex {
        let empty = HouseDuplicateIndex(fingerprints: [], coordinate: coordinate)
        let reader = HouseReadService(modelContainer: modelContext.container)
        let fingerprints: [ExistingHouseFingerprint]
        do {
            fingerprints = try await reader.addressFingerprints(territoryID: gebietID)
        } catch is CancellationError {
            return empty
        } catch {
            notices.report(error, context: "Häuser konnten nicht gelesen werden")
            return empty
        }
        guard !Task.isCancelled else { return empty }
        return await offMainActor {
            HouseDuplicateIndex(fingerprints: fingerprints, coordinate: coordinate)
        }
    }

    private func attemptSave() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addressIsFocused = false

        if !didOverrideDuplicate,
           let existing = duplicateIndex?.duplicate(for: trimmed) {
            duplicateWarning = existing
            return
        }
        let safeUnitCount = min(max(unitCount, 2), 100)
        let house = House(
            address: trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            gebietID: gebietID,
            isApartmentBuilding: isApartment,
            unitCount: isApartment ? safeUnitCount : 1
        )
        modelContext.insert(house)

        if !isApartment, let initialOutcome, let door = house.units.first {
            house.setOutcome(initialOutcome, for: door.id, day: writeDay)
        }
        if isApartment {
            UserDefaults.standard.set(safeUnitCount, forKey: "lastApartmentUnitCount")
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

    /// Opens the already-recorded house the warning names, instead of creating
    /// a second pin for it. Falls back to the override path when the house
    /// vanished between the warning and the tap.
    private func openExisting() {
        guard let warned = duplicateWarning else { return }
        duplicateWarning = nil
        let key = AddressNormalizer.normalize(warned)
        let descriptor = FetchDescriptor<House>(predicate: #Predicate {
            $0.gebietID == gebietID || $0.dayID == gebietID
        })
        if let match = (try? modelContext.fetch(descriptor))?
            .first(where: { AddressNormalizer.normalize($0.address) == key }) {
            UISelectionFeedbackGenerator().selectionChanged()
            dismiss()
            onOpenExisting(match)
            return
        }
        didOverrideDuplicate = true
        attemptSave()
    }

    private func loadSuggestedAddress() async {
        defer { isLoadingAddress = false }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let suggestion = await Self.suggestedAddress(at: location), !Task.isCancelled else { return }
        guard address.isEmpty else { return }
        address = suggestion
        addressIsFocused = false
    }

    /// `MKReverseGeocodingRequest` is iOS 26-only. On iOS 18 the deprecated
    /// `CLGeocoder` is the only reverse geocoder, and its `CLPlacemark` has no
    /// single-line formatter, so the street line is assembled from its fields.
    private static func suggestedAddress(at location: CLLocation) async -> String? {
        if #available(iOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let items = try? await request.mapItems,
                  let item = items.first
            else { return nil }
            return item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                ?? item.address?.shortAddress
                ?? item.address?.fullAddress
        }
        guard let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location),
              let placemark = placemarks.first
        else { return nil }
        let street = [placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        let city = [placemark.postalCode, placemark.locality]
            .compactMap { $0 }
            .joined(separator: " ")
        let line = [street, city].filter { !$0.isEmpty }.joined(separator: ", ")
        return line.isEmpty ? placemark.name : line
    }
}

/// Duplicate detection for a new house.
///
/// Works from lightweight fingerprints, never live models: the whole territory
/// is indexed while the sheet animates in, and materialising thousands of
/// models with their door blobs on the main thread is what made that stall.
/// Only the matched address comes back out — the warning shows the address,
/// nothing else from the existing house is ever read.
struct HouseDuplicateIndex: Sendable {
    private let byNormalizedAddress: [String: String]
    private let nearby: [String]

    nonisolated init(fingerprints: [ExistingHouseFingerprint], coordinate: CLLocationCoordinate2D) {
        var index: [String: String] = [:]
        var near: [String] = []
        // Flat equirectangular metres — no `CLLocation` object per house, which at a
        // few thousand houses was thousands of ObjC allocations while the sheet
        // animated in.
        let latitudeScale = 110_540.0
        let longitudeScale = 111_320.0 * cos(coordinate.latitude * .pi / 180)

        for fingerprint in fingerprints {
            let key = AddressNormalizer.normalize(fingerprint.address)
            if !key.isEmpty, index[key] == nil { index[key] = fingerprint.address }
            let dLat = (fingerprint.latitude - coordinate.latitude) * latitudeScale
            let dLon = (fingerprint.longitude - coordinate.longitude) * longitudeScale
            if dLat * dLat + dLon * dLon <= 12 * 12 { near.append(fingerprint.address) }
        }
        byNormalizedAddress = index
        nearby = near
    }

    /// A different address at the same spot is a legitimate second entrance, a corner
    /// building or a neighbouring row house — the old code warned about all of them
    /// because it returned any nearby house regardless of what was typed.
    func duplicate(for address: String) -> String? {
        let key = AddressNormalizer.normalize(address)
        guard !key.isEmpty else { return nil }
        if let exact = byNormalizedAddress[key] { return exact }
        return nearby.first { AddressNormalizer.normalize($0) == key }
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
