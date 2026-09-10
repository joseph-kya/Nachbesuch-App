import MapKit
import SwiftUI
import UIKit

/// Address and place search for the map.
///
/// Uses `MKLocalSearchCompleter` for as-you-type suggestions and only issues a real
/// `MKLocalSearch` once the user picks one. The previous version fired a full
/// `MKLocalSearch` every 350 ms of typing, which Apple rate-limits — normal typing
/// speed reliably tripped the limiter and surfaced a raw error alert.
struct MapSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: SearchModel
    @FocusState private var isFocused: Bool
    /// Letzte 5 Suchanfragen (UserDefaults) — Tap füllt das Feld erneut.
    @State private var recent: [String] = RecentSearches.load()

    let onSelect: (CLLocationCoordinate2D) -> Void

    init(region: MKCoordinateRegion, onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        _model = State(initialValue: SearchModel(region: region))
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.snug) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Adresse, Ort oder Gebiet", text: $model.query)
                        .focused($isFocused)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityLabel("Adresse, Ort oder Gebiet")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Suche löschen")
                    }
                }
                .padding(AppSpacing.regular)
                .navigationGlass(cornerRadius: AppRadius.control)
                .padding(.horizontal)
                .padding(.vertical, AppSpacing.snug)
                List {
                    if model.query.isEmpty {
                        // Verlauf zuerst (max. 5, ein Tap = wiederverwenden).
                        if !recent.isEmpty {
                            Section("Zuletzt gesucht") {
                                ForEach(recent, id: \.self) { item in
                                    Button {
                                        UISelectionFeedbackGenerator().selectionChanged()
                                        model.query = item
                                    } label: {
                                        Label(item, systemImage: "clock.arrow.circlepath")
                                            .lineLimit(1)
                                    }
                                    .accessibilityHint("Sucht erneut nach \(item)")
                                }
                                // Verlauf löschen: einmalige Auswahlhaptik, kein System-Alert.
                                Button(role: .destructive) {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    RecentSearches.clear()
                                    recent = []
                                } label: {
                                    Label("Zuletzt gesucht löschen", systemImage: "trash")
                                }
                                .accessibilityHint("Löscht die gespeicherten Suchanfragen")
                            }
                        }
                        ContentUnavailableView("Adresse suchen", systemImage: "mappin.and.ellipse",
                            description: Text("Suche nach einer Straße, einem Ort oder einem Gebiet."))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else if model.isResolving, model.suggestions.isEmpty {
                        // Skelettzeilen während der Auflösung: redacted + pulsierende
                        // Opazität, RM-sicher statisch. Spinner-Transition bleibt.
                        ForEach(0..<3, id: \.self) { _ in
                            HStack(spacing: AppSpacing.snug) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Musterstraße 12")
                                        .font(.body)
                                    Text("1234 Musterort")
                                        .font(.caption)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .redacted(reason: .placeholder)
                            .phaseAnimator([0.45, 0.75], trigger: model.isResolving) { content, phase in
                                content.opacity(reduceMotion ? 0.6 : phase)
                            } animation: { _ in
                                reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.8)
                            }
                            .accessibilityHidden(true)
                            .listRowSeparator(.hidden)
                        }
                    } else if model.suggestions.isEmpty, !model.isResolving {
                        ContentUnavailableView.search(text: model.query)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(model.suggestions) { suggestion in
                            Button {
                                // Einmalige Auswahlhaptik (visuell: natives List-Highlight).
                                UISelectionFeedbackGenerator().selectionChanged()
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
                                // 44 pt Zeilenhöhe für zuverlässige Treffer.
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .disabled(model.isResolving)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("Öffnet diesen Ort auf der Karte")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    ZStack {
                        if model.isResolving {
                            ProgressView().controlSize(.large)
                                .transition(.opacity)
                        }
                    }
                    // Scoped to the spinner alone: an animation on the list would
                    // also animate every suggestion row on each keystroke.
                    .animation(.appFeedback(reduceMotion: reduceMotion), value: model.isResolving)
                }
            }
            .background { AppBackdrop() }
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
        .task {
            // Let the sheet settle before presenting the keyboard. The search
            // field itself stays in place through both transitions.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isFocused = true
        }
    }

    private func resolve(_ suggestion: SearchModel.Suggestion) {
        // Anfrage merken (max. 5) — Sheet öffnet weiter an der aktuellen
        // Kamera (Region vom Caller), nicht an der Welt.
        if !model.query.isEmpty {
            RecentSearches.save(model.query)
            recent = RecentSearches.load()
        }
        Task {
            guard let coordinate = await model.coordinate(for: suggestion) else { return }
            dismiss()
            // The sheet and the keyboard get off screen before the map starts
            // streaming tiles: all three animations at once fought over the
            // render server and the flight stuttered on arrival.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            onSelect(coordinate)
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

/// Letzte 5 Suchanfragen in UserDefaults (Tap = wiederverwenden).
private enum RecentSearches {
    static let key = "map.recentSearches"
    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func save(_ q: String) {
        var list = load().filter { $0 != q }; list.insert(q, at: 0)
        UserDefaults.standard.set(Array(list.prefix(5)), forKey: key)
    }
    /// Löscht den Verlauf (Lösch-Button im Sheet).
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
