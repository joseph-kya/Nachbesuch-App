import CoreLocation
import Foundation
import MapKit
import SwiftData

/// Assigns a place-based name (with duplicate numbering) to a Gebiet whose current
/// name is still generic, using the boundary centroid or the centroid of its houses.
@MainActor
enum GebietAutoNamer {
    static func applyIfNeeded(
        to gebiet: Gebiet,
        allGebiete: [Gebiet],
        modelContext: ModelContext,
        notices: AppNoticeCenter,
        houseCoordinates: [CLLocationCoordinate2D] = []
    ) async {
        guard GebietNameAllocator.isGenericName(gebiet.name) else { return }

        let boundary = gebiet.boundaryCoordinates
        let coordinate: CLLocationCoordinate2D?
        if boundary.count >= 3 {
            coordinate = GebietCentroidCalculator.centroid(of: boundary)
        } else if !houseCoordinates.isEmpty {
            coordinate = GebietCentroidCalculator.centroid(ofCoordinates: houseCoordinates)
        } else {
            coordinate = nil
        }
        guard let coordinate else { return }

        // Resolve first, then re-check: the geocode is an await, and the territory
        // may have been renamed or deleted while it was in flight.
        guard let resolved = await GebietNamingService.shared.resolvePlace(at: coordinate) else {
            // Naming genuinely failed. Leave the generic name alone so a later pass
            // can retry — writing a "Gebiet" sentinel used to create a territory that
            // counted as generic forever and was re-geocoded on every launch.
            return
        }
        guard GebietNameAllocator.isGenericName(gebiet.name) else { return }

        let others = allGebiete.filter { $0.id != gebiet.id }
        let assignment = GebietNameAllocator.assignName(
            baseName: resolved.place,
            existingNames: others.map(\.name)
        )

        gebiet.rename(
            to: assignment.newName,
            districtOrCity: gebiet.districtOrCity.isEmpty && !resolved.districtOrCity.isEmpty
                ? resolved.districtOrCity
                : nil
        )

        if let rename = assignment.renameOfExisting {
            // Only rename when the old name identifies exactly one territory. With two
            // manually-identical names the old code renamed an arbitrary one and left
            // the other duplicated, quietly breaking the numbering invariant.
            let matches = others.filter {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == rename.oldName
            }
            if matches.count == 1 {
                matches[0].rename(to: rename.newName)
            }
        }

        modelContext.save(reporting: notices, context: "Gebiet konnte nicht benannt werden")
    }
}

/// Pure, testable naming rules for Gebiete: a plain place name when the place is unique,
/// sequential numbering as soon as a duplicate place appears (the existing plain Gebiet
/// is renamed to "<Ort> 1", the new one receives the next free number).
nonisolated enum GebietNameAllocator {
    struct NameAssignment: Equatable, Sendable {
        let newName: String
        let renameOfExisting: (oldName: String, newName: String)?

        static func == (lhs: NameAssignment, rhs: NameAssignment) -> Bool {
            lhs.newName == rhs.newName
                && lhs.renameOfExisting?.oldName == rhs.renameOfExisting?.oldName
                && lhs.renameOfExisting?.newName == rhs.renameOfExisting?.newName
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_AT"))
    }

    /// Placeholder names that carry no information about where the Gebiet is.
    static func isGenericName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "Tagesrunde" || trimmed == "Neues Gebiet" { return true }
        if trimmed.hasPrefix("Gebiet vom") { return true }
        if exactNumberedSuffix(base: "Gebiet", candidate: trimmed) != nil { return true }
        return false
    }

    private static func exactNumberedSuffix(base: String, candidate: String) -> Int? {
        let foldedBase = fold(base)
        let folded = fold(candidate)
        guard folded.hasPrefix(foldedBase) else { return nil }
        let remainder = folded.dropFirst(foldedBase.count)
        if remainder.isEmpty { return 1 }
        guard remainder.hasPrefix(" "), let number = Int(remainder.dropFirst()) else { return nil }
        return number
    }

    static func assignName(baseName: String, existingNames: [String]) -> NameAssignment {
        let base = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBase = base.isEmpty ? "Gebiet" : base

        var usedNumbers = Set<Int>()
        var plainMatches: [String] = []

        for name in existingNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let number = exactNumberedSuffix(base: effectiveBase, candidate: trimmed) {
                if fold(trimmed) == fold(effectiveBase) {
                    // A plain name occupies the un-numbered slot, not number 1.
                    plainMatches.append(trimmed)
                } else {
                    usedNumbers.insert(number)
                }
            }
        }

        if usedNumbers.isEmpty && plainMatches.isEmpty {
            return NameAssignment(newName: effectiveBase, renameOfExisting: nil)
        }

        guard let plainToRename = plainMatches.first else {
            let next = (usedNumbers.max() ?? 0) + 1
            return NameAssignment(newName: "\(effectiveBase) \(next)", renameOfExisting: nil)
        }

        // A plain duplicate exists: it moves to the first free slot (usually "<Ort> 1"),
        // the new Gebiet takes the number after the highest used one.
        var renameNumber = 1
        while usedNumbers.contains(renameNumber) { renameNumber += 1 }
        let renamed = "\(effectiveBase) \(renameNumber)"
        usedNumbers.insert(renameNumber)
        let next = (usedNumbers.max() ?? 0) + 1
        return NameAssignment(
            newName: "\(effectiveBase) \(next)",
            renameOfExisting: (oldName: plainToRename, newName: renamed)
        )
    }
}

/// Serialises reverse geocoding.
///
/// `CLGeocoder` rejects a request while another is in flight on the same instance
/// and Apple rate-limits the service hard. The old code looped over every generic
/// territory awaiting a shared geocoder, so the first one or two succeeded and the
/// rest silently returned a sentinel — permanently, because the migration flag had
/// already been set.
actor GebietNamingService {
    static let shared = GebietNamingService()

    struct ResolvedPlace: Sendable {
        let place: String
        let districtOrCity: String
    }

    /// Keyed by coordinate rounded to ~100 m; neighbouring houses resolve to the
    /// same place, so this collapses most of a naming pass into one request.
    private var cache: [String: ResolvedPlace] = [:]
    private var lastRequestAt: Date?

    private init() {}

    func resolvePlace(at coordinate: CLLocationCoordinate2D) async -> ResolvedPlace? {
        let key = String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
        if let cached = cache[key] { return cached }

        // Space requests out; bursts get throttled and return nothing useful.
        if let lastRequestAt {
            let elapsed = Date.now.timeIntervalSince(lastRequestAt)
            if elapsed < 1.2 {
                try? await Task.sleep(for: .seconds(1.2 - elapsed))
            }
        }
        guard !Task.isCancelled else { return nil }
        lastRequestAt = .now

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let resolved = await reverseGeocode(location) else { return nil }
        cache[key] = resolved
        return resolved
    }

    /// `MKReverseGeocodingRequest` is iOS 26-only; `CLGeocoder` is deprecated there
    /// but is the only reverse geocoder iOS 18 has. Both funnel into the same
    /// extractor, so the naming rules stay in one place.
    private func reverseGeocode(_ location: CLLocation) async -> ResolvedPlace? {
        if #available(iOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            guard let items = try? await request.mapItems, let item = items.first else { return nil }
            return GermanPlaceNameExtractor.extractPlaceName(from: item)
        }
        guard let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location),
              let placemark = placemarks.first else { return nil }
        return GermanPlaceNameExtractor.extractPlaceName(from: placemark)
    }
}
