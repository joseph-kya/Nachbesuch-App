import CoreLocation
import SwiftData
import SwiftUI

/// Bulk-creates every addressed building inside the drawn boundary, from
/// OpenStreetMap.
struct AreaHouseImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices

    let boundary: [CLLocationCoordinate2D]
    let gebietID: UUID
    let onFinished: () -> Void

    @State private var addresses: [ImportedAreaAddress] = []
    @State private var skippedDuplicates = 0
    @State private var phase: Phase = .loading
    @State private var loadTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case loading
        case ready
        case saving
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: AppSpacing.snug) {
                        ProgressView().controlSize(.large)
                        Text("Häuser werden gesucht …")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ContentUnavailableView {
                        Label("Import nicht möglich", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Erneut versuchen") { startLoading() }
                            .buttonStyle(.borderedProminent)
                    }

                case .ready, .saving:
                    List {
                        Section {
                            LabeledContent("Gefunden", value: "\(addresses.count)")
                            if skippedDuplicates > 0 {
                                LabeledContent("Bereits vorhanden", value: "\(skippedDuplicates)")
                            }
                        } footer: {
                            Text("Alle neuen Einträge entstehen als Einzelhäuser. Quelle: © OpenStreetMap-Mitwirkende.")
                        }

                        Section("Vorschau") {
                            ForEach(addresses.prefix(60)) { address in
                                Text(address.address)
                                    .font(.subheadline)
                            }
                            if addresses.count > 60 {
                                Text("… und \(addresses.count - 60) weitere")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Häuser im Gebiet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        loadTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("\(addresses.count) anlegen") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(addresses.isEmpty || phase != .ready)
                }
            }
            .overlay {
                if phase == .saving {
                    ProgressView("Wird gespeichert …").controlSize(.large)
                }
            }
        }
        .task { startLoading() }
        .onDisappear { loadTask?.cancel() }
    }

    private func startLoading() {
        // Guarded: the retry button and the initial `.task` could previously both run
        // and race on the results.
        loadTask?.cancel()
        phase = .loading
        // The fingerprints come from the background reader inside the task, not
        // from a main-thread fetch up front: materialising the whole territory
        // before the network request even started is what stalled this sheet on
        // open. On a fetch failure the import proceeds without dedup — the same
        // fallback the old path had, which reported and read an empty territory.
        let target = gebietID
        let container = modelContext.container
        let region = boundary
        loadTask = Task {
            let reader = HouseReadService(modelContainer: container)
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

    private func save() async {
        guard phase == .ready, !addresses.isEmpty else { return }
        phase = .saving
        let container = modelContext.container
        let payload = addresses
        let target = gebietID
        do {
            let importer = BulkHouseImporter(modelContainer: container)
            let count = try await importer.insert(payload, gebietID: target)
            // The importer writes on its own context; without this the main context's
            // @Query can still be showing the pre-import state when the sheet closes,
            // which read as "340 Häuser importiert" followed by an empty map.
            modelContext.processPendingChanges()
            notices.show("\(count) Häuser angelegt.")
            onFinished()
            dismiss()
        } catch {
            notices.report(error, context: "Häuser konnten nicht gespeichert werden")
            phase = .ready
        }
    }
}
