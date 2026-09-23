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
    /// Geocode und Dublettenindex laufen still ins Leere — beide bekommen einen
    /// sichtbaren Fehler plus Wiederholen statt schweigendem Nichts.
    @State private var geocodeFailed = false
    @State private var indexFailed = false
    /// Spinner während der Index-Wiederholung — Geocode hat dafür `isLoadingAddress`.
    @State private var isRetryingIndex = false
    @FocusState private var addressIsFocused: Bool

    private var clampedUnitCount: Binding<Int> {
        Binding(
            get: { unitCount },
            set: { unitCount = min(max($0, 2), 100) }
        )
    }

    /// Leer heißt: Sichern bleibt aus. Kein Alert — die Fußnote sagt es leise.
    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Warnung vom Sichern-Versuch oder Treffer beim Tippen — was zuerst da ist.
    /// So sieht man die Dublette schon vor dem ersten Sichern-Tippen.
    private var visibleDuplicate: String? {
        if let duplicateWarning { return duplicateWarning }
        guard !didOverrideDuplicate, !trimmedAddress.isEmpty else { return nil }
        return duplicateIndex?.duplicate(for: trimmedAddress)
    }

    /// „8 m entfernt" zum Banner, falls der Index eine Nah-Distanz kennt —
    /// sonst bleibt das Banner bei der Adresse allein.
    private var visibleDuplicateDistanceText: String? {
        guard let duplicate = visibleDuplicate else { return nil }
        return duplicateIndex?.distanceText(for: duplicate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                    // Geocode ging leer aus und das Feld ist noch leer: Fehler
                    // zeigen plus Wiederholen statt schweigendem Nichts.
                    if geocodeFailed, !isLoadingAddress, trimmedAddress.isEmpty {
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            Task { await loadSuggestedAddress() }
                        } label: {
                            Label("Adresse konnte nicht ermittelt werden — erneut versuchen", systemImage: "arrow.clockwise")
                                .font(.footnote)
                        }
                        .frame(minHeight: 44)
                    }
                } header: {
                    Text("Adresse")
                } footer: {
                    // Leeres Feld: rote Fußnote statt Alert, Sichern bleibt aus.
                    if trimmedAddress.isEmpty, !isLoadingAddress {
                        Text("Bitte eine Adresse eingeben.")
                            .foregroundStyle(.red)
                    }
                }
                .glassRows()

                // Dublette als Banner im Sheet statt Alert: Öffnen ist der
                // Hauptweg, Trotzdem-anlegen die bewusste Ausnahme.
                if let duplicate = visibleDuplicate {
                    Section {
                        Label("„\(duplicate)“ ist bereits erfasst.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        // Nah-Distanz aus dem Index („8 m entfernt") — sonst nur Adresse.
                        if let distanceText = visibleDuplicateDistanceText {
                            Text(distanceText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Button {
                            openExisting()
                        } label: {
                            Label("Vorhanden – öffnen", systemImage: "arrow.up.right.circle")
                        }
                        .frame(minHeight: 44)
                        Button("Trotzdem anlegen") {
                            UISelectionFeedbackGenerator().selectionChanged()
                            didOverrideDuplicate = true
                            duplicateWarning = nil
                        }
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                    }
                    .glassRows()
                }

                // Dublettenindex defekt: melden plus Wiederholen — ohne ihn
                // würde das Sheet Duplikate still durchlassen.
                if indexFailed {
                    Section {
                        Label("Dublettenprüfung fehlgeschlagen.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            Task {
                                isRetryingIndex = true
                                defer { isRetryingIndex = false }
                                indexFailed = false
                                duplicateIndex = await buildDuplicateIndex()
                            }
                        } label: {
                            HStack {
                                Label("Erneut versuchen", systemImage: "arrow.clockwise")
                                if isRetryingIndex {
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                        .disabled(isRetryingIndex)
                    }
                    .glassRows()
                }

                Section {
                    // Deutsches Label „Art" plus 44pt-Treffläche für A11y.
                    Picker("Art", selection: $isApartment) {
                        Text("Einzelhaus").tag(false)
                        Text("Mehrparteienhaus").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)

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
                        // Deutsches Label „Anzahl" plus 44pt-Treffläche für A11y.
                        .frame(minHeight: 44)
                    }
                } header: {
                    Text("Art")
                }
                .glassRows()

                if !isApartment {
                    Section("Status (optional)") {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: AppSpacing.snug), GridItem(.flexible(), spacing: AppSpacing.snug)],
                            spacing: AppSpacing.snug
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
                    .glassRows()
                }
            }
            .glassForm()
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
                        .disabled(trimmedAddress.isEmpty)
                        .opacity(trimmedAddress.isEmpty ? 0.4 : 1)
                }
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
        let reader = await HouseReadService.background(container: modelContext.container)
        let fingerprints: [ExistingHouseFingerprint]
        do {
            fingerprints = try await reader.addressFingerprints(territoryID: gebietID)
        } catch is CancellationError {
            return empty
        } catch {
            notices.report(error, context: "Häuser konnten nicht gelesen werden")
            indexFailed = true
            return empty
        }
        guard !Task.isCancelled else { return empty }
        return await offMainActor {
            HouseDuplicateIndex(fingerprints: fingerprints, coordinate: coordinate)
        }
    }

    private func attemptSave() {
        let trimmed = trimmedAddress
        guard !trimmed.isEmpty else { return }
        addressIsFocused = false

        // Dublette: Banner zeigen statt Alert — der Button bleibt, ein zweites
        // Tippen nach "Trotzdem anlegen" legt wirklich an.
        if !didOverrideDuplicate,
           let existing = duplicateIndex?.duplicate(for: trimmed) {
            duplicateWarning = existing
            UISelectionFeedbackGenerator().selectionChanged()
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
        // Prüfspur: Wer die Dublettenwarnung bewusst überstimmt, sieht es als Quittung.
        if didOverrideDuplicate {
            notices.show("Trotz Dublette angelegt")
        }
        onCreated(house)
        dismiss()
    }

    /// Opens the already-recorded house the warning names, instead of creating
    /// a second pin for it. Falls back to the override path when the house
    /// vanished between the warning and the tap.
    private func openExisting() {
        guard let warned = visibleDuplicate else { return }
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
        // Spinner auch beim Wiederholen: Button setzt Haptik, hier läuft der Indikator.
        isLoadingAddress = true
        defer { isLoadingAddress = false }
        geocodeFailed = false
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let suggestion = await Self.suggestedAddress(at: location), !Task.isCancelled else {
            // Abgebrochen ist kein Fehler; nur leeres Ergebnis bei lebendigem
            // Task meldet sich — mit Wiederholen im Adress-Abschnitt.
            if !Task.isCancelled { geocodeFailed = true }
            return
        }
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
    /// Kürzeste Entfernung je normalisierter Adresse im Nahbereich, für „8 m entfernt".
    private let nearbyDistances: [String: Double]

    nonisolated init(fingerprints: [ExistingHouseFingerprint], coordinate: CLLocationCoordinate2D) {
        var index: [String: String] = [:]
        var near: [String] = []
        var distances: [String: Double] = [:]
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
            let distance = (dLat * dLat + dLon * dLon).squareRoot()
            if distance <= 12 {
                near.append(fingerprint.address)
                // Kürzeste Distanz je Adresse behalten — mehrere Treffer am Spot.
                if let known = distances[key] {
                    distances[key] = min(known, distance)
                } else if !key.isEmpty {
                    distances[key] = distance
                }
            }
        }
        byNormalizedAddress = index
        nearby = near
        nearbyDistances = distances
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

    /// „8 m entfernt" zum Banner, falls der Treffer im Nahbereich liegt —
    /// sonst nil und das Banner bleibt bei der Adresse allein.
    func distanceText(for address: String) -> String? {
        let key = AddressNormalizer.normalize(address)
        guard !key.isEmpty, let distance = nearbyDistances[key] else { return nil }
        return "\(Int(distance.rounded())) m entfernt"
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
