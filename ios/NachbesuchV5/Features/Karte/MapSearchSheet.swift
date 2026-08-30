import MapKit
import SwiftUI

/// Address and place search for the map.
///
/// Uses `MKLocalSearchCompleter` for as-you-type suggestions and only issues a real
/// `MKLocalSearch` once the user picks one. The previous version fired a full
/// `MKLocalSearch` every 350 ms of typing, which Apple rate-limits — normal typing
/// speed reliably tripped the limiter and surfaced a raw error alert.
struct MapSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SearchModel
    @FocusState private var isFocused: Bool

    let onSelect: (CLLocationCoordinate2D) -> Void

    init(region: MKCoordinateRegion, onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        _model = State(initialValue: SearchModel(region: region))
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List {
                if model.suggestions.isEmpty, !model.query.isEmpty, !model.isResolving {
                    ContentUnavailableView.search(text: model.query)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(model.suggestions) { suggestion in
                        Button {
                            resolve(suggestion)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .disabled(model.isResolving)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Öffnet diesen Ort auf der Karte")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $model.query, prompt: "Adresse, Ort oder Gebiet")
            .searchFocused($isFocused)
            .overlay {
                if model.isResolving {
                    ProgressView().controlSize(.large)
                }
            }
            .navigationTitle("Suchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .alert("Ort nicht gefunden", isPresented: $model.showsError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Zu dieser Auswahl konnte kein Kartenpunkt geladen werden.")
            }
        }
        .task { isFocused = true }
    }

    private func resolve(_ suggestion: SearchModel.Suggestion) {
        Task {
            guard let coordinate = await model.coordinate(for: suggestion) else { return }
            onSelect(coordinate)
            dismiss()
        }
    }
}

@MainActor
@Observable
final class SearchModel: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        fileprivate let completion: MKLocalSearchCompletion

        init(title: String, subtitle: String, completion: MKLocalSearchCompletion) {
            id = "\(title)\u{1F}\(subtitle)"
            self.title = title
            self.subtitle = subtitle
            self.completion = completion
        }
    }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            completer.queryFragment = query
            if query.isEmpty { suggestions = [] }
        }
    }
    private(set) var suggestions: [Suggestion] = []
    var isResolving = false
    var showsError = false

    private let completer = MKLocalSearchCompleter()
    private let region: MKCoordinateRegion
    private var activeSearch: MKLocalSearch?
    private var resolutionID: UUID?

    init(region: MKCoordinateRegion) {
        self.region = region
        super.init()
        completer.delegate = self
        completer.region = region
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results.prefix(25).map {
            Suggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        suggestions = []
    }

    func coordinate(for suggestion: Suggestion) async -> CLLocationCoordinate2D? {
        activeSearch?.cancel()
        let id = UUID()
        resolutionID = id
        isResolving = true
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        request.region = region
        let search = MKLocalSearch(request: request)
        activeSearch = search
        let response = try? await search.start()
        guard resolutionID == id else { return nil }
        isResolving = false
        activeSearch = nil
        resolutionID = nil
        guard let item = response?.mapItems.first else {
            showsError = true
            return nil
        }
        if #available(iOS 26, *) { return item.location.coordinate }
        return item.placemark.coordinate
    }
}
