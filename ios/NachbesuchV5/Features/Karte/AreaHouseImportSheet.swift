import CoreLocation
import SwiftData
import SwiftUI
import UIKit

/// Bulk-creates every addressed building inside the drawn boundary, from
/// OpenStreetMap.
struct AreaHouseImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let boundary: [CLLocationCoordinate2D]
    let gebietID: UUID
    let onFinished: () -> Void

    @State private var addresses: [ImportedAreaAddress] = []
    @State private var skippedDuplicates = 0
    @State private var phase: Phase = .loading
    @State private var loadTask: Task<Void, Never>?
    /// Abgewählte Treffer — alles andere wird angelegt. Leer heißt: alle.
    @State private var deselectedIDs: Set<String> = []

    private enum Phase: Equatable {
        case loading
        case ready
        case saving
        case failed(String)
    }

    /// Angelegt wird nur, was noch ausgewählt ist.
    private var selectedAddresses: [ImportedAreaAddress] {
        addresses.filter { !deselectedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    // Spinner plus drei Skelett-Zeilen: Das Sheet fühlt sich
                    // sofort an, nicht erst bei der Antwort.
                    List {
                        Section {
                            HStack(spacing: AppSpacing.snug) {
                                ProgressView().controlSize(.small)
                                Text("Häuser werden gesucht …")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section {
                            ForEach(0..<3, id: \.self) { _ in
                                Text("Musterstraße 00")
                                    .font(.subheadline)
                                    .redacted(reason: .placeholder)
                            }
                        } header: {
                            Text("Adressen")
                        } footer: {
                            Text("Alle neuen Einträge entstehen als Einzelhäuser. Quelle: © OpenStreetMap-Mitwirkende.")
                        }
                    }
                    .listStyle(.insetGrouped)

                case .failed(let message):
                    ContentUnavailableView {
                        Label("Import nicht möglich", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Erneut versuchen") {
                            UISelectionFeedbackGenerator().selectionChanged()
                            startLoading()
                        }
                        .compatGlassButton(prominent: true)
                    }

                case .ready, .saving:
                    // Leeres Gebiet ist ein eigener Zustand mit Wiederholen —
                    // kein leeres Listen-Skelett ohne Ausweg.
                    if addresses.isEmpty, phase == .ready {
                        ContentUnavailableView {
                            Label("Keine Adressen im Gebiet", systemImage: "mappin.slash")
                        } description: {
                            Text(skippedDuplicates > 0
                                 ? "Alle \(skippedDuplicates) Adressen sind bereits erfasst."
                                 : "In dieser Fläche kennt OpenStreetMap keine Hausnummern.")
                        } actions: {
                            Button("Erneut versuchen") {
                                UISelectionFeedbackGenerator().selectionChanged()
                                startLoading()
                            }
                            .compatGlassButton(prominent: true)
                        }
                    } else {
                        List {
                            Section {
                                LabeledContent("Gefunden", value: "\(addresses.count)")
                                // Zähler mit Zahlen-Morph statt hartem Sprung.
                                LabeledContent("Ausgewählt", value: "\(selectedAddresses.count)")
                                    .monospacedDigit()
                                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(selectedAddresses.count)))
                                    .animation(.appFeedback(reduceMotion: reduceMotion), value: selectedAddresses.count)
                                if skippedDuplicates > 0 {
                                    LabeledContent("Bereits vorhanden", value: "\(skippedDuplicates)")
                                }
                            } footer: {
                                Text("Alle neuen Einträge entstehen als Einzelhäuser. Quelle: © OpenStreetMap-Mitwirkende.")
                            }

                            Section {
                                ForEach(addresses) { address in
                                    let isSelected = !deselectedIDs.contains(address.id)
                                    Button {
                                        toggleSelection(address.id)
                                    } label: {
                                        HStack(spacing: AppSpacing.snug) {
                                            Text(address.address)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                            Spacer(minLength: AppSpacing.tight)
                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                        }
                                        .frame(minHeight: AppTouch.minimum)
                                    }
                                    .accessibilityLabel(address.address)
                                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                                }
                            } header: {
                                HStack {
                                    Text("Adressen")
                                    Spacer()
                                    Button("Alle") { setAllSelected(true) }
                                        .font(.footnote)
                                        .tappable()
                                    Button("Keine") { setAllSelected(false) }
                                        .font(.footnote)
                                        .tappable()
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { AppBackdrop() }
            .disabled(phase == .saving)
            .navigationTitle("Häuser im Gebiet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        loadTask?.cancel()
                        dismiss()
                    }
                    .disabled(phase == .saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("\(selectedAddresses.count) anlegen") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(selectedAddresses.count)))
                    .animation(.appFeedback(reduceMotion: reduceMotion), value: selectedAddresses.count)
                    .disabled(selectedAddresses.isEmpty || phase != .ready)
                }
            }
            .overlay {
                if phase == .saving {
                    ProgressView("Wird gespeichert …").controlSize(.large)
                }
            }
        }
        .interactiveDismissDisabled(phase == .saving)
        .task { startLoading() }
        .onDisappear { loadTask?.cancel() }
    }

    private func startLoading() {
        // Guarded: the retry button and the initial `.task` could previously both run
        // and race on the results.
        loadTask?.cancel()
        phase = .loading
        deselectedIDs = []
        // The fingerprints come from the background reader inside the task, not
        // from a main-thread fetch up front: materialising the whole territory
        // before the network request even started is what stalled this sheet on
        // open. On a fetch failure the import proceeds without dedup — the same
        // fallback the old path had, which reported and read an empty territory.
        let target = gebietID
        let container = modelContext.container
        let region = boundary
        loadTask = Task {
            let reader = await HouseReadService.background(container: container)
            let fingerprints: [ExistingHouseFingerprint]
            do {
                fingerprints = try await reader.addressFingerprints(territoryID: target)
            } catch is CancellationError {
                return
            } catch {
                notices.report(error, context: "Häuser konnten nicht gelesen werden")
                fingerprints = []
            }
            guard !Task.isCancelled else { return }
            do {
                let found = try await AreaHouseImportService.fetchAddresses(inside: region)
                guard !Task.isCancelled else { return }
                let selection = AreaHouseImportService.excludingExistingHouses(from: found, existing: fingerprints)
                addresses = selection.addresses
                skippedDuplicates = selection.skippedDuplicates
                phase = .ready
            } catch is CancellationError {
                // The sheet is going away; leaving `phase` on `.loading` used to strand
                // the spinner forever with no way back.
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Einzelne Zeile an-/abwählen — leichtes Tippen, sofort sichtbar.
    private func toggleSelection(_ id: String) {
        UISelectionFeedbackGenerator().selectionChanged()
        if deselectedIDs.contains(id) {
            deselectedIDs.remove(id)
        } else {
            deselectedIDs.insert(id)
        }
    }

    /// Alle/keine mit leichtem Tippen — Masse bleibt leise bis zum Sichern.
    /// „Keine" braucht keine Bestätigung: Abwählen ist reversibel.
    private func setAllSelected(_ all: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        deselectedIDs = all ? [] : Set(addresses.map(\.id))
    }

    private func save() async {
        let payload = selectedAddresses
        guard phase == .ready, !payload.isEmpty else { return }
        phase = .saving
        let container = modelContext.container
        let target = gebietID
        do {
            let importer = BulkHouseImporter(modelContainer: container)
            let count = try await importer.insert(payload, gebietID: target)
            // The importer writes on its own context; without this the main context's
            // @Query can still be showing the pre-import state when the sheet closes,
            // which read as "340 Häuser importiert" followed by an empty map.
            modelContext.processPendingChanges()
            // Erfolg erst beim Schreiben: Masse bleibt leise bis hier.
            // Ergebnisquittung mit Übersprungenen als Prüfspur.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let skipped = skippedDuplicates
            notices.show(skipped > 0
                ? "\(count) Häuser angelegt, \(skipped) übersprungen."
                : "\(count) Häuser angelegt.")
            onFinished()
            dismiss()
        } catch {
            notices.report(error, context: "Häuser konnten nicht gespeichert werden")
            phase = .ready
        }
    }
}
