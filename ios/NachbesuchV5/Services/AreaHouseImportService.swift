import CoreLocation
import Foundation

nonisolated struct ImportedAreaAddress: Identifiable, Hashable, Sendable {
    let id: String
    let address: String
    let latitude: Double
    let longitude: Double
}

nonisolated struct ExistingHouseFingerprint: Sendable {
    let address: String
    let latitude: Double
    let longitude: Double
}

nonisolated struct AreaImportSelection: Sendable {
    let addresses: [ImportedAreaAddress]
    let skippedDuplicates: Int
}

nonisolated enum AreaHouseImportService {
    private static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://lz4.overpass-api.de/api/interpreter")!
    ]
    private static let maximumResultCount = 5_000
    private static let duplicateRadius = 12.0

    nonisolated static func fetchAddresses(
        inside boundary: [CLLocationCoordinate2D]
    ) async throws -> [ImportedAreaAddress] {
        guard boundary.count >= 3 else { throw AreaHouseImportError.invalidBoundary }
        guard areaExtentInKilometers(boundary) <= 8 else { throw AreaHouseImportError.areaTooLarge }

        let polygon = boundary
            .map { String(format: "%.7f %.7f", locale: Locale(identifier: "en_US_POSIX"), $0.latitude, $0.longitude) }
            .joined(separator: " ")
        let query = """
        [out:json][timeout:35];
        nwr["addr:housenumber"](poly:"\(polygon)");
        out center tags qt;
        """

        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let body = form.percentEncodedQuery?.data(using: .utf8) else {
            throw AreaHouseImportError.invalidRequest
        }

        var lastError: any Error = AreaHouseImportError.invalidResponse

        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 40
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("Nachbesuch-iOS/6.0", forHTTPHeaderField: "User-Agent")

            let trace = PerformanceTrace.begin("Import area addresses")
            defer { PerformanceTrace.end("Import area addresses", id: trace) }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = AreaHouseImportError.invalidResponse
                    continue
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    if httpResponse.statusCode == 429 {
                        lastError = AreaHouseImportError.serviceBusy
                    } else if httpResponse.statusCode == 504 {
                        lastError = AreaHouseImportError.requestTimedOut
                    } else {
                        lastError = AreaHouseImportError.serverError(httpResponse.statusCode)
                    }
                    continue
                }
                return try decodeAddresses(from: data, inside: boundary)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError
    }

    nonisolated static func decodeAddresses(
        from data: Data,
        inside boundary: [CLLocationCoordinate2D]
    ) throws -> [ImportedAreaAddress] {
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        var seenAddresses = Set<String>()
        var result: [ImportedAreaAddress] = []
        result.reserveCapacity(min(response.elements.count, maximumResultCount))

        for element in response.elements {
            guard let coordinate = element.coordinate,
                  point(coordinate, isInside: boundary),
                  let tags = element.tags,
                  let address = formattedAddress(from: tags) else { continue }

            let key = normalizedAddress(address)
            guard !key.isEmpty, seenAddresses.insert(key).inserted else { continue }
            result.append(ImportedAreaAddress(
                id: "\(element.type)-\(element.id)",
                address: address,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ))
            if result.count > maximumResultCount {
                throw AreaHouseImportError.tooManyResults(maximumResultCount)
            }
        }

        return result.sorted {
            $0.address.localizedStandardCompare($1.address) == .orderedAscending
        }
    }

    /// Dekodieren + Filtern + Sortieren abseits vom Main-Thread: Das Sheet hängt
    /// an MainActor, 5 000 Adressen mit lokalisiertem Sort würden sonst das
    /// Öffnen ruckeln lassen. Nur das Zuweisen bleibt auf Main.
    nonisolated static func decodeAndFilter(
        from data: Data,
        inside boundary: [CLLocationCoordinate2D],
        existing: [ExistingHouseFingerprint]
    ) async throws -> AreaImportSelection {
        let task = Task.detached(priority: .userInitiated) { () throws -> AreaImportSelection in
            let addresses = try decodeAddresses(from: data, inside: boundary)
            return excludingExistingHouses(from: addresses, existing: existing)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func excludingExistingHouses(
        from addresses: [ImportedAreaAddress],
        existing: [ExistingHouseFingerprint]
    ) -> AreaImportSelection {
        let existingAddresses = Set(existing.map { normalizedAddress($0.address) })
        let cellSize = 0.0002
        var buckets: [CoordinateCell: [ExistingHouseFingerprint]] = [:]
        for house in existing {
            buckets[CoordinateCell(latitude: house.latitude, longitude: house.longitude, cellSize: cellSize), default: []]
                .append(house)
        }

        var filtered: [ImportedAreaAddress] = []
        filtered.reserveCapacity(addresses.count)
        var skipped = 0

        for address in addresses {
            let normalized = normalizedAddress(address.address)
            if existingAddresses.contains(normalized) || isNearExistingHouse(address, buckets: buckets, cellSize: cellSize) {
                skipped += 1
            } else {
                filtered.append(address)
            }
        }
        return AreaImportSelection(addresses: filtered, skippedDuplicates: skipped)
    }

    private nonisolated static func formattedAddress(from tags: [String: String]) -> String? {
        guard let number = tags["addr:housenumber"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !number.isEmpty else { return nil }
        let street = [tags["addr:street"], tags["addr:place"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let line = street.map { "\($0) \(number)" } ?? "Hausnummer \(number)"
        let city = tags["addr:city"] ?? tags["addr:town"] ?? tags["addr:village"] ?? tags["addr:municipality"]
        let locality = [tags["addr:postcode"], city]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return locality.isEmpty ? line : "\(line), \(locality)"
    }

    /// Shared with `AddHouseSheet`. The two used to normalise differently — this one
    /// pinned to de_AT, the manual sheet to the device locale — so the bulk importer
    /// and the manual duplicate check disagreed about what counted as the same address.
    private nonisolated static func normalizedAddress(_ value: String) -> String {
        AddressNormalizer.normalize(value)
    }

    private nonisolated static func point(
        _ point: CLLocationCoordinate2D,
        isInside polygon: [CLLocationCoordinate2D]
    ) -> Bool {
        guard polygon.count >= 3 else { return false }
        var isInside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            let crossesLatitude = (a.latitude > point.latitude) != (b.latitude > point.latitude)
            if crossesLatitude {
                let crossingLongitude = (b.longitude - a.longitude)
                    * (point.latitude - a.latitude)
                    / (b.latitude - a.latitude)
                    + a.longitude
                if point.longitude < crossingLongitude { isInside.toggle() }
            }
            previous = current
        }
        return isInside
    }

    private nonisolated static func areaExtentInKilometers(_ boundary: [CLLocationCoordinate2D]) -> Double {
        guard let minimumLatitude = boundary.map(\.latitude).min(),
              let maximumLatitude = boundary.map(\.latitude).max(),
              let minimumLongitude = boundary.map(\.longitude).min(),
              let maximumLongitude = boundary.map(\.longitude).max() else { return 0 }
        let latitudeKilometers = (maximumLatitude - minimumLatitude) * 111
        let meanLatitude = (maximumLatitude + minimumLatitude) / 2 * .pi / 180
        let longitudeKilometers = (maximumLongitude - minimumLongitude) * 111 * cos(meanLatitude)
        return max(latitudeKilometers, longitudeKilometers)
    }

    private nonisolated static func isNearExistingHouse(
        _ address: ImportedAreaAddress,
        buckets: [CoordinateCell: [ExistingHouseFingerprint]],
        cellSize: Double
    ) -> Bool {
        let cell = CoordinateCell(latitude: address.latitude, longitude: address.longitude, cellSize: cellSize)
        // Equirectangular approx, not CLLocation per probe: two object allocs +
        // haversine per candidate for a 12 m radius on flat city streets is pure
        // overhead — at this range the flat-earth error is centimetres.
        let lonScale = cos(address.latitude * .pi / 180)
        for latitudeOffset in -1...1 {
            for longitudeOffset in -1...1 {
                let neighbor = CoordinateCell(latitudeIndex: cell.latitudeIndex + latitudeOffset, longitudeIndex: cell.longitudeIndex + longitudeOffset)
                if buckets[neighbor]?.contains(where: {
                    let dLat = ($0.latitude - address.latitude) * 111_320
                    let dLon = ($0.longitude - address.longitude) * 111_320 * lonScale
                    return (dLat * dLat + dLon * dLon).squareRoot() < duplicateRadius
                }) == true { return true }
            }
        }
        return false
    }
}

private nonisolated struct CoordinateCell: Hashable, Sendable {
    let latitudeIndex: Int
    let longitudeIndex: Int

    nonisolated init(latitude: Double, longitude: Double, cellSize: Double) {
        latitudeIndex = Int(floor(latitude / cellSize))
        longitudeIndex = Int(floor(longitude / cellSize))
    }

    nonisolated init(latitudeIndex: Int, longitudeIndex: Int) {
        self.latitudeIndex = latitudeIndex
        self.longitudeIndex = longitudeIndex
    }
}

private nonisolated struct OverpassResponse: Decodable, Sendable {
    let elements: [OverpassElement]
}

private nonisolated struct OverpassElement: Decodable, Sendable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let center: OverpassCenter?
    let tags: [String: String]?

    nonisolated var coordinate: CLLocationCoordinate2D? {
        if let lat, let lon { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        if let center { return CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon) }
        return nil
    }
}

private nonisolated struct OverpassCenter: Decodable, Sendable {
    let lat: Double
    let lon: Double
}

nonisolated enum AreaHouseImportError: LocalizedError {
    case invalidBoundary
    case areaTooLarge
    case invalidRequest
    case invalidResponse
    case serviceBusy
    case requestTimedOut
    case serverError(Int)
    case tooManyResults(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBoundary:
            "Bitte zeichne zuerst ein Gebiet mit mindestens drei Punkten ein."
        case .areaTooLarge:
            "Das Gebiet ist für einen zuverlässigen Sammelimport zu groß. Teile es bitte in kleinere Abschnitte unter acht Kilometern Kantenlänge."
        case .invalidRequest, .invalidResponse:
            "Die Adresssuche konnte keine gültige Antwort verarbeiten."
        case .serviceBusy:
            "Die Adresssuche ist gerade ausgelastet. Bitte versuche es in einer Minute erneut."
        case .requestTimedOut:
            "Die Adresssuche hat zu lange gedauert. Ein kleineres Gebiet funktioniert meist zuverlässiger."
        case .serverError(let status):
            "Die Adresssuche meldet einen Serverfehler (HTTP \(status))."
        case .tooManyResults(let limit):
            "Im Gebiet liegen mehr als \(limit) Adressen. Teile es bitte in kleinere Runden."
        }
    }
}
