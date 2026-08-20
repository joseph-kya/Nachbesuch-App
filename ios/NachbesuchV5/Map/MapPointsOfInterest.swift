import MapKit

/// Which real-world landmarks the map draws underneath the house pins.
///
/// Canvassers orient themselves by shops, bank branches and bus stops, so the map
/// has to show them. The old build hid every POI (`pointOfInterestFilter =
/// .excludingAll`), which left an anonymous grey street grid.
enum POIPreset: String, CaseIterable, Identifiable, Sendable {
    /// Nothing but streets — for when a dense area needs a clean canvas.
    case off
    /// Curated set: the landmarks people actually navigate by.
    case orientation
    /// Everything MapKit is willing to draw.
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Aus"
        case .orientation: "Orientierung"
        case .everything: "Alle Orte"
        }
    }

    var subtitle: String {
        switch self {
        case .off: "Nur Straßen und Hausnummern"
        case .orientation: "Geschäfte, Banken, Haltestellen, Ämter"
        case .everything: "Jeder Ort, den Apple Karten kennt"
        }
    }

    var systemImage: String {
        switch self {
        case .off: "map"
        case .orientation: "storefront"
        case .everything: "mappin.and.ellipse"
        }
    }

    var filter: MKPointOfInterestFilter? {
        switch self {
        case .off:
            return .excludingAll
        case .orientation:
            return MKPointOfInterestFilter(including: Self.orientationCategories)
        case .everything:
            return .includingAll
        }
    }

    /// Deliberately curated rather than "everything": leisure categories (ski lifts,
    /// mini golf, wineries) add clutter without helping anyone find house number 14.
    static let orientationCategories: [MKPointOfInterestCategory] = [
        // Getting around
        .publicTransport, .parking, .gasStation, .evCharger,
        // Errands people recognise from the street
        .bank, .atm, .pharmacy, .postOffice, .mailbox,
        .foodMarket, .bakery, .cafe, .restaurant, .store, .laundry, .beauty,
        // Civic anchors
        .hospital, .police, .fireStation, .school, .university, .library,
        // Landmarks that make a block identifiable
        .park, .landmark, .nationalMonument, .museum, .theater, .movieTheater,
        .stadium, .hotel, .fitnessCenter
    ]
}
