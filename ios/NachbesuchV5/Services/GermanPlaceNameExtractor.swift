import Foundation
import MapKit

/// Turns a geocoding result into a short, human place name for a territory.
///
/// Reads `MKAddressRepresentations` rather than `CLPlacemark`, which is deprecated
/// as of iOS 26. The structured API exposes a city but no postal code or district,
/// so the postal code is recovered from the formatted address — reliable for the
/// DACH region, where it is a leading 4- or 5-digit group.
nonisolated enum GermanPlaceNameExtractor {
    /// Cities big enough that the bare city name is useless as a territory label —
    /// canvassers there think in districts.
    private static let metropolitanCities: Set<String> = Set(
        ["wien", "berlin", "hamburg", "münchen", "köln", "frankfurt am main",
         "graz", "linz", "salzburg", "innsbruck"].map(GebietNameAllocator.fold)
    )

    private static let viennaDistrictsByPLZ: [String: String] = [
        "1010": "Innere Stadt", "1020": "Leopoldstadt", "1030": "Landstraße",
        "1040": "Wieden", "1050": "Margareten", "1060": "Mariahilf",
        "1070": "Neubau", "1080": "Josefstadt", "1090": "Alsergrund",
        "1100": "Favoriten", "1110": "Simmering", "1120": "Meidling",
        "1130": "Hietzing", "1140": "Penzing", "1150": "Rudolfsheim-Fünfhaus",
        "1160": "Ottakring", "1170": "Hernals", "1180": "Währing",
        "1190": "Döbling", "1200": "Brigittenau", "1210": "Floridsdorf",
        "1220": "Donaustadt", "1230": "Liesing"
    ]

    /// Returns `nil` when no usable place could be determined.
    ///
    /// Deliberately not a `"Gebiet"` sentinel: that string also counts as a generic
    /// name, so a failed geocode produced a territory that was classified as unnamed
    /// forever and re-geocoded on every launch.
    static func extractPlaceName(from item: MKMapItem) -> GebietNamingService.ResolvedPlace? {
        let representations = item.addressRepresentations
        let city = representations?.cityName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullAddress = item.address?.fullAddress ?? ""
        let postalCode = postalCode(in: fullAddress)

        guard let city, !city.isEmpty else {
            guard let region = representations?.regionName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !region.isEmpty else { return nil }
            let cleaned = cleanAdministrativeArea(region)
            return make(place: cleaned, postalCode: postalCode, city: cleaned)
        }

        let folded = GebietNameAllocator.fold(city)

        // Vienna: the district is what people actually name a round after.
        if folded == GebietNameAllocator.fold("Wien") {
            if let postalCode, let district = viennaDistrictsByPLZ[postalCode] {
                return make(place: district, postalCode: postalCode, city: "Wien")
            }
            return make(place: "Wien", postalCode: postalCode, city: "Wien")
        }

        if metropolitanCities.contains(folded),
           let context = representations?.cityWithContext(.short)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !context.isEmpty, GebietNameAllocator.fold(context) != folded {
            return make(place: cleanPlaceName(context), postalCode: postalCode, city: city)
        }

        return make(place: cleanPlaceName(city), postalCode: postalCode, city: city)
    }

    private static func make(
        place: String,
        postalCode: String?,
        city: String
    ) -> GebietNamingService.ResolvedPlace? {
        let trimmedPlace = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPlace.isEmpty else { return nil }
        // `compactMap` strips nil but not "", which is how a stray empty postal code
        // used to produce a leading space in " Mödling".
        let parts = [postalCode, city]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return GebietNamingService.ResolvedPlace(
            place: trimmedPlace,
            districtOrCity: parts.joined(separator: " ")
        )
    }

    /// First standalone 4–5 digit token — the DACH postal-code shape.
    private static func postalCode(in address: String) -> String? {
        for token in address.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            let digits = token.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            guard digits.count == token.count || !digits.isEmpty else { continue }
            if (4...5).contains(digits.count), digits.allSatisfy(\.isNumber), digits == token {
                return digits
            }
        }
        return nil
    }

    // Covers the standard Austrian municipality prefixes the earlier versions
    // missed. `Regex` is not `Sendable`, so these stay as patterns and the
    // (internally cached) `NSRegularExpression` path does the work.
    private static let placePrefixPattern =
        "^(Stadtteil|Ortsteil|Katastralgemeinde|Marktgemeinde|Stadtgemeinde|Gemeinde)\\s+"
    private static let adminPrefixPattern =
        "^(Politischer Bezirk|Bezirk|Landkreis|Kreis)\\s+"

    private static func stripPrefix(_ pattern: String, from name: String) -> String {
        name.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanPlaceName(_ name: String) -> String {
        stripPrefix(placePrefixPattern, from: name)
    }

    private static func cleanAdministrativeArea(_ name: String) -> String {
        stripPrefix(adminPrefixPattern, from: name)
    }
}
