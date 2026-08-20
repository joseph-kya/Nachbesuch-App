import CoreLocation
import Foundation

/// A walkable street graph, built from OpenStreetMap ways.
///
/// Straight lines between houses are useless for a route you have to walk: they cut
/// through buildings, across railway lines and over walls. This is the same data
/// source the house import already uses, so it needs no new service and no API key.
nonisolated struct WalkingGraph: Sendable {
    /// Node positions, indexed by node id.
    let nodes: [CLLocationCoordinate2D]
    /// `adjacency[i]` = the neighbours of node `i` with their edge length in metres.
    let adjacency: [[Edge]]

    struct Edge: Sendable {
        let node: Int
        let metres: Double
    }

    var isEmpty: Bool { nodes.isEmpty }

    /// Inserts every requested coordinate at its nearest point *on an edge*.
    /// OSM vertices describe bends and junctions, not every front door. Snapping a
    /// house to the nearest vertex can move it hundreds of metres to the end of a
    /// straight street and makes a simple route zig-zag.
    func insertingSnappedPoints(
        _ coordinates: [CLLocationCoordinate2D],
        within limit: Double = 120
    ) -> (graph: WalkingGraph, nodeIndices: [Int?]) {
        guard !isEmpty else { return (self, Array(repeating: nil, count: coordinates.count)) }

        struct Projection {
            let coordinateIndex: Int
            let first: Int
            let second: Int
            let fraction: Double
            let coordinate: CLLocationCoordinate2D
            let squaredDistance: Double
        }

        var best = [Projection?](repeating: nil, count: coordinates.count)
        let limitSquared = limit * limit
        for first in adjacency.indices {
            for edge in adjacency[first] where first < edge.node {
                let second = edge.node
                let a = nodes[first]
                let b = nodes[second]
                for (coordinateIndex, point) in coordinates.enumerated() {
                    let projection = Self.project(point, onto: a, b)
                    guard projection.squaredDistance <= limitSquared,
                          projection.squaredDistance < (best[coordinateIndex]?.squaredDistance ?? .infinity)
                    else { continue }
                    best[coordinateIndex] = Projection(
                        coordinateIndex: coordinateIndex,
                        first: first,
                        second: second,
                        fraction: projection.fraction,
                        coordinate: projection.coordinate,
                        squaredDistance: projection.squaredDistance
                    )
                }
            }
        }

        var newNodes = nodes
        var newAdjacency = adjacency
        var nodeIndices = [Int?](repeating: nil, count: coordinates.count)
        var projectionsByEdge: [EdgeKey: [Projection]] = [:]
        for projection in best.compactMap({ $0 }) {
            projectionsByEdge[EdgeKey(projection.first, projection.second), default: []].append(projection)
        }

        for (key, projections) in projectionsByEdge {
            newAdjacency[key.first].removeAll { $0.node == key.second }
            newAdjacency[key.second].removeAll { $0.node == key.first }

            let ordered = projections.sorted {
                if $0.fraction != $1.fraction { return $0.fraction < $1.fraction }
                return $0.coordinateIndex < $1.coordinateIndex
            }
            var chain = [key.first]
            for projection in ordered {
                let node = newNodes.count
                newNodes.append(projection.coordinate)
                newAdjacency.append([])
                nodeIndices[projection.coordinateIndex] = node
                chain.append(node)
            }
            chain.append(key.second)

            for index in 1..<chain.count {
                let a = chain[index - 1]
                let b = chain[index]
                let metres = Geo.metres(newNodes[a], newNodes[b])
                newAdjacency[a].append(.init(node: b, metres: metres))
                newAdjacency[b].append(.init(node: a, metres: metres))
            }
        }

        // Retain nearest-node recovery for malformed graphs with isolated nodes.
        for index in nodeIndices.indices where nodeIndices[index] == nil {
            nodeIndices[index] = nearestNode(to: coordinates[index], within: limit)
        }
        return (WalkingGraph(nodes: newNodes, adjacency: newAdjacency), nodeIndices)
    }

    private struct EdgeKey: Hashable {
        let first: Int
        let second: Int

        init(_ a: Int, _ b: Int) {
            first = min(a, b)
            second = max(a, b)
        }
    }

    private static func project(
        _ point: CLLocationCoordinate2D,
        onto a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> (fraction: Double, coordinate: CLLocationCoordinate2D, squaredDistance: Double) {
        let latitudeScale = 110_540.0
        let longitudeScale = 111_320.0 * cos(a.latitude * .pi / 180)
        let bx = (b.longitude - a.longitude) * longitudeScale
        let by = (b.latitude - a.latitude) * latitudeScale
        let px = (point.longitude - a.longitude) * longitudeScale
        let py = (point.latitude - a.latitude) * latitudeScale
        let denominator = bx * bx + by * by
        let fraction = denominator > 0 ? min(max((px * bx + py * by) / denominator, 0), 1) : 0
        let projected = CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * fraction,
            longitude: a.longitude + (b.longitude - a.longitude) * fraction
        )
        return (fraction, projected, Geo.squaredMetres(point, projected))
    }

    /// The graph node closest to a coordinate, within `limit` metres.
    ///
    /// A house sits beside the street, not on it, so every stop has to be snapped
    /// onto the network first. The limit rejects houses that ended up far from any
    /// mapped way — better to fall back to a straight line for one address than to
    /// route the whole round through an unrelated street.
    func nearestNode(to coordinate: CLLocationCoordinate2D, within limit: Double = 120) -> Int? {
        var best: Int?
        var bestDistance = limit * limit
        for (index, node) in nodes.enumerated() {
            let distance = Geo.squaredMetres(coordinate, node)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Dijkstra from one node to everywhere, with predecessors so a path can be
    /// reconstructed afterwards.
    func shortestPaths(from source: Int) -> (distances: [Double], previous: [Int]) {
        var distances = [Double](repeating: .infinity, count: nodes.count)
        var previous = [Int](repeating: -1, count: nodes.count)
        var visited = [Bool](repeating: false, count: nodes.count)
        distances[source] = 0

        var heap = MinHeap()
        heap.push(node: source, cost: 0)

        while let current = heap.pop() {
            if visited[current.node] { continue }
            visited[current.node] = true
            for edge in adjacency[current.node] {
                let candidate = distances[current.node] + edge.metres
                if candidate < distances[edge.node] {
                    distances[edge.node] = candidate
                    previous[edge.node] = current.node
                    heap.push(node: edge.node, cost: candidate)
                }
            }
        }
        return (distances, previous)
    }

    /// Walks the predecessor chain back from `target`.
    func path(to target: Int, previous: [Int], from source: Int) -> [CLLocationCoordinate2D] {
        guard target != source else { return [nodes[source]] }
        var chain: [Int] = []
        var cursor = target
        // Bounded: a corrupt predecessor chain must not loop forever.
        var guardCounter = 0
        while cursor != -1, cursor != source, guardCounter <= nodes.count {
            chain.append(cursor)
            cursor = previous[cursor]
            guardCounter += 1
        }
        guard cursor == source else { return [] }
        chain.append(source)
        return chain.reversed().map { nodes[$0] }
    }
}

/// Binary heap keyed on cost. `Array.min()` per step would make Dijkstra O(n²) and
/// a city district has thousands of nodes.
private nonisolated struct MinHeap {
    private var storage: [(node: Int, cost: Double)] = []

    var isEmpty: Bool { storage.isEmpty }

    mutating func push(node: Int, cost: Double) {
        storage.append((node, cost))
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard storage[child].cost < storage[parent].cost else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (node: Int, cost: Double)? {
        guard !storage.isEmpty else { return nil }
        storage.swapAt(0, storage.count - 1)
        let smallest = storage.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent
            if left < storage.count, storage[left].cost < storage[candidate].cost { candidate = left }
            if right < storage.count, storage[right].cost < storage[candidate].cost { candidate = right }
            if candidate == parent { break }
            storage.swapAt(parent, candidate)
            parent = candidate
        }
        return smallest
    }
}

nonisolated enum Geo {
    /// Equirectangular metres — centimetre-accurate at city scale, allocation free.
    static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        squaredMetres(a, b).squareRoot()
    }

    static func squaredMetres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let latitudeScale = 110_540.0
        let longitudeScale = 111_320.0 * cos(a.latitude * .pi / 180)
        let dLat = (a.latitude - b.latitude) * latitudeScale
        let dLon = (a.longitude - b.longitude) * longitudeScale
        return dLat * dLat + dLon * dLon
    }
}

enum WalkingNetworkError: LocalizedError {
    case areaTooLarge
    case unavailable

    var errorDescription: String? {
        switch self {
        case .areaTooLarge:
            "Das Gebiet ist zu groß, um das Wegenetz zu laden."
        case .unavailable:
            "Das Wegenetz konnte nicht geladen werden. Die Route wird als Luftlinie angezeigt."
        }
    }
}

/// On-disk cache of Overpass payloads, keyed by bounding box.
///
/// In the Caches directory on purpose: the system may reclaim it, and a miss costs
/// a network round trip rather than data.
private nonisolated enum OverpassCache {
    /// Street layouts change on a scale of years; a month is generous either way.
    private static let maximumAge: TimeInterval = 60 * 60 * 24 * 30

    private static func url(for box: String) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("WalkingNetwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The box string is a fixed-format number list, so this is a safe file name.
        let name = box.replacingOccurrences(of: ",", with: "_").replacingOccurrences(of: "-", with: "m")
        return directory.appendingPathComponent("\(name).json", isDirectory: false)
    }

    static func load(for box: String) -> Data? {
        guard let url = url(for: box),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) < maximumAge
        else { return nil }
        return try? Data(contentsOf: url)
    }

    static func store(_ data: Data, for box: String) {
        guard let url = url(for: box) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func discard(for box: String) {
        guard let url = url(for: box) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Loads walkable ways for a bounding box and turns them into a graph.
nonisolated enum WalkingNetworkService {
    private static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://lz4.overpass-api.de/api/interpreter")!
    ]

    /// Everything a person on foot may use. Motorways and their slip roads are
    /// excluded, as is anything explicitly tagged `foot=no`.
    private static let walkableHighways =
        "footway|path|pedestrian|steps|living_street|residential|unclassified|service|"
        + "tertiary|tertiary_link|secondary|secondary_link|primary|primary_link|track|cycleway|road"

    static func load(around coordinates: [CLLocationCoordinate2D]) async throws -> WalkingGraph {
        guard let bounds = boundingBox(of: coordinates) else { throw WalkingNetworkError.unavailable }
        // A padded box, so the route can leave the territory to get around a block.
        let padding = 0.0025
        let south = bounds.minLatitude - padding
        let west = bounds.minLongitude - padding
        let north = bounds.maxLatitude + padding
        let east = bounds.maxLongitude + padding

        guard (north - south) < 0.12, (east - west) < 0.16 else {
            throw WalkingNetworkError.areaTooLarge
        }

        let locale = Locale(identifier: "en_US_POSIX")
        let box = String(
            format: "%.6f,%.6f,%.6f,%.6f",
            locale: locale, south, west, north, east
        )
        let query = """
        [out:json][timeout:40];
        way["highway"~"^(\(walkableHighways))$"]["foot"!="no"]["access"!="private"](\(box));
        out geom qt;
        """

        // A canvasser walks the same streets for days. Overpass is slow, rate
        // limited and often unreachable from a stairwell, so a payload once fetched
        // is kept on disk and re-used — the difference between an instant route and
        // a 40 s wait that quietly degrades to crow-flight.
        if let cached = OverpassCache.load(for: box) {
            if let graph = try? buildGraph(from: cached), !graph.isEmpty { return graph }
            OverpassCache.discard(for: box)
        }

        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let body = form.percentEncodedQuery?.data(using: .utf8) else {
            throw WalkingNetworkError.unavailable
        }

        // A hard overall deadline. Three mirrors at 45 s each meant the user could
        // watch an empty route bar for over two minutes with nothing to cancel.
        let deadline = Date.now.addingTimeInterval(40)

        for endpoint in endpoints {
            try Task.checkCancellation()
            guard Date.now < deadline else { break }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = min(18, max(6, deadline.timeIntervalSinceNow))
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continue
                }
                let graph = try buildGraph(from: data)
                if !graph.isEmpty { OverpassCache.store(data, for: box) }
                return graph
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                // What `URLSession` actually throws when the task is cancelled. The
                // `CancellationError` case above never fires for a network hop, so
                // without this the remaining mirrors were dutifully hammered after
                // the user had already walked away from the plan.
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw WalkingNetworkError.unavailable
    }

    static func buildGraph(from data: Data) throws -> WalkingGraph {
        let trace = PerformanceTrace.begin("Build walking graph")
        defer { PerformanceTrace.end("Build walking graph", id: trace) }

        let response = try JSONDecoder().decode(WayResponse.self, from: data)
        var nodes: [CLLocationCoordinate2D] = []
        var indexByKey: [Int64: Int] = [:]
        var adjacency: [[WalkingGraph.Edge]] = []

        /// Ways share the exact coordinates of their junction nodes, so quantising
        /// to roughly 1 cm merges them into one graph node — which is what makes
        /// junctions connect instead of the network falling into disjoint strands.
        func index(for coordinate: CLLocationCoordinate2D) -> Int {
            let key = Int64(coordinate.latitude * 1_000_000) &* 1_000_000
                &+ Int64(coordinate.longitude * 1_000_000)
            if let existing = indexByKey[key] { return existing }
            let created = nodes.count
            indexByKey[key] = created
            nodes.append(coordinate)
            adjacency.append([])
            return created
        }

        for way in response.elements {
            guard let geometry = way.geometry, geometry.count >= 2 else { continue }
            var previousIndex: Int?
            for point in geometry {
                let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
                let current = index(for: coordinate)
                if let previousIndex, previousIndex != current {
                    let length = Geo.metres(nodes[previousIndex], coordinate)
                    // Undirected: a pavement can be walked either way.
                    adjacency[previousIndex].append(.init(node: current, metres: length))
                    adjacency[current].append(.init(node: previousIndex, metres: length))
                }
                previousIndex = current
            }
        }

        guard !nodes.isEmpty else { throw WalkingNetworkError.unavailable }
        return WalkingGraph(nodes: nodes, adjacency: adjacency)
    }

    private static func boundingBox(
        of coordinates: [CLLocationCoordinate2D]
    ) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)? {
        var minLatitude = Double.greatestFiniteMagnitude
        var maxLatitude = -Double.greatestFiniteMagnitude
        var minLongitude = Double.greatestFiniteMagnitude
        var maxLongitude = -Double.greatestFiniteMagnitude
        var found = false
        for coordinate in coordinates where StoredCoordinate(coordinate).isPlausible {
            found = true
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        return found ? (minLatitude, maxLatitude, minLongitude, maxLongitude) : nil
    }

    private struct WayResponse: Decodable {
        let elements: [Way]
    }

    private struct Way: Decodable {
        let geometry: [Point]?
    }

    private struct Point: Decodable {
        let lat: Double
        let lon: Double
    }
}

/// Identifies the app to the Overpass operators, who use the agent string for abuse
/// contact — a hardcoded stale version defeats that.
nonisolated enum AppInfo {
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "Nachbesuch-iOS/\(version) (+at.volkshilfe.nachbesuch)"
    }
}
