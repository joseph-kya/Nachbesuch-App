import CoreLocation
import Foundation

/// A stop on a recommended walking route.
nonisolated struct RouteStop: Sendable, Hashable {
    let houseID: UUID
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated struct PlannedRoute: Sendable {
    let start: CLLocationCoordinate2D
    let stops: [RouteStop]
    /// Walking length in metres — along streets when the network was available.
    let distance: Double
    /// The line to draw: the actual path, not a chain of straight hops.
    let path: [CLLocationCoordinate2D]
    /// The path split per stop, aligned with `stops`: the points to append *after*
    /// the previous position to reach that stop, ending on the stop itself.
    ///
    /// Kept separately because the drawn line has to survive the order changing
    /// under it. Trimming one long polyline to the nearest point breaks the moment
    /// a house is skipped or finished out of order — the line then runs backwards
    /// through doors already done.
    let legs: [[CLLocationCoordinate2D]]
    /// False when the street network could not be used and this is crow-flight.
    let followsStreets: Bool

    var isEmpty: Bool { stops.isEmpty }
    var houseIDs: [UUID] { stops.map(\.houseID) }
}

/// Builds a short walking order through every house.
///
/// This is the travelling-salesman problem, which has no exact answer at this size,
/// so it uses the standard practical pair: **nearest neighbour** for a first guess,
/// then **2-opt** to pull out the crossings greedy construction always leaves behind.
///
/// Costs come from a real walking graph when one is available. That matters for both
/// halves of the job: the drawn line follows pavements instead of cutting through
/// buildings, and the *ordering* stops treating two addresses either side of a
/// railway as neighbours just because they are close in a straight line.
nonisolated enum RoutePlanner {
    /// Above this many stops, 2-opt is skipped — the pass is O(n²) per sweep.
    private static let refinementLimit = 400
    private static let maximumPasses = 6
    /// Network routing runs one Dijkstra per stop, twice. Beyond this the straight
    /// line ordering is used instead, and only the drawn path follows streets.
    private static let networkOrderingLimit = 150

    // MARK: Entry points

    /// Straight-line planning. Used when no street network could be loaded.
    static func plan(start: CLLocationCoordinate2D, stops: [RouteStop]) -> PlannedRoute {
        guard !stops.isEmpty else {
            return PlannedRoute(
                start: start, stops: [], distance: 0, path: [], legs: [], followsStreets: false
            )
        }
        let ordered = order(
            stops: stops,
            cost: { a, b in Geo.metres(coordinate(a, start: start, stops: stops), coordinate(b, start: start, stops: stops)) }
        )
        let distance = length(start: start, stops: ordered)
        return PlannedRoute(
            start: start,
            stops: ordered,
            distance: distance,
            path: [start] + ordered.map(\.coordinate),
            legs: ordered.map { [$0.coordinate] },
            followsStreets: false
        )
    }

    /// Planning on a walking graph.
    static func plan(
        start: CLLocationCoordinate2D,
        stops: [RouteStop],
        graph: WalkingGraph
    ) -> PlannedRoute {
        guard !stops.isEmpty else {
            return PlannedRoute(
                start: start, stops: [], distance: 0, path: [], legs: [], followsStreets: false
            )
        }
        guard !graph.isEmpty else { return plan(start: start, stops: stops) }

        // Snap everything onto the network. A house sits beside the street, so this
        // step is what connects the data to the graph at all.
        let points = [start] + stops.map(\.coordinate)
        let snappedResult = graph.insertingSnappedPoints(points)
        let routingGraph = snappedResult.graph
        let snapped = snappedResult.nodeIndices
        guard snapped[0] != nil, snapped.dropFirst().contains(where: { $0 != nil }) else {
            return plan(start: start, stops: stops)
        }

        let ordered: [RouteStop]
        if stops.count <= networkOrderingLimit,
           let matrix = distanceMatrix(graph: routingGraph, snapped: snapped, points: points) {
            // Index 0 is the start; stop `i` is matrix index `i + 1`.
            var indexByStop: [UUID: Int] = [:]
            for (offset, stop) in stops.enumerated() { indexByStop[stop.houseID] = offset + 1 }
            ordered = order(stops: stops) { a, b in
                let i = a.map { indexByStop[$0.houseID] ?? 0 } ?? 0
                let j = b.map { indexByStop[$0.houseID] ?? 0 } ?? 0
                return matrix[i][j]
            }
        } else {
            ordered = order(stops: stops) { a, b in
                Geo.metres(
                    a?.coordinate ?? start,
                    b?.coordinate ?? start
                )
            }
        }

        // Draw the real thing: the shortest path along streets between each pair.
        // The snap from the first pass is reused — re-snapping here meant a second
        // linear scan of every graph node per stop for no new information.
        var nodeByStop: [UUID: Int] = [:]
        for (offset, stop) in stops.enumerated() {
            if let node = snapped[offset + 1] { nodeByStop[stop.houseID] = node }
        }

        var path: [CLLocationCoordinate2D] = [start]
        var legs: [[CLLocationCoordinate2D]] = []
        legs.reserveCapacity(ordered.count)
        var total = 0.0
        var cursor = start
        var cursorNode = snapped[0]
        var everyLegFollowsStreets = true

        for stop in ordered {
            let targetNode = nodeByStop[stop.houseID]
            var leg: [CLLocationCoordinate2D]?
            if let from = cursorNode, let to = targetNode, from != to {
                let (distances, previous) = routingGraph.shortestPaths(from: from)
                let walked = routingGraph.path(to: to, previous: previous, from: from)
                if !walked.isEmpty, distances[to].isFinite {
                    total += Geo.metres(cursor, routingGraph.nodes[from])
                        + distances[to]
                        + Geo.metres(routingGraph.nodes[to], stop.coordinate)
                    leg = walked + [stop.coordinate]
                    cursorNode = to
                }
            }
            // No usable path: keep going with a straight hop rather than dropping
            // the stop from the route entirely.
            let resolved = leg ?? [stop.coordinate]
            if leg == nil {
                total += Geo.metres(cursor, stop.coordinate)
                // `from == to` is a short door-to-door connector at one snapped
                // point, not a failed street route.
                if cursorNode == nil || targetNode == nil || cursorNode != targetNode {
                    everyLegFollowsStreets = false
                }
                cursorNode = targetNode
            }
            legs.append(resolved)
            path.append(contentsOf: resolved)
            cursor = stop.coordinate
        }

        return PlannedRoute(
            start: start,
            stops: ordered,
            distance: total,
            path: path,
            legs: legs,
            followsStreets: everyLegFollowsStreets
        )
    }

    // MARK: Cost matrix

    /// One Dijkstra per snapped point. Predecessors are discarded here — the paths
    /// are recomputed for the handful of consecutive pairs that end up in the final
    /// order, which keeps peak memory at O(nodes) instead of O(stops × nodes).
    private static func distanceMatrix(
        graph: WalkingGraph,
        snapped: [Int?],
        points: [CLLocationCoordinate2D]
    ) -> [[Double]]? {
        let count = points.count
        var matrix = [[Double]](repeating: [Double](repeating: .infinity, count: count), count: count)

        var pathsBySource: [Int: [Double]] = [:]
        for i in 0..<count {
            guard let source = snapped[i] else {
                // Unsnappable point: fall back to straight lines for its whole row.
                for j in 0..<count { matrix[i][j] = Geo.metres(points[i], points[j]) }
                continue
            }
            let distances: [Double]
            if let cached = pathsBySource[source] {
                distances = cached
            } else {
                distances = graph.shortestPaths(from: source).distances
                pathsBySource[source] = distances
            }
            // The walk from the door to the pavement counts at **both** ends. Without
            // it every house snapping to the same street vertex — normal on a long
            // straight street, where OSM gives two vertices hundreds of metres
            // apart — costs zero, and the order between them becomes arbitrary.
            let departure = Geo.metres(points[i], graph.nodes[source])
            for j in 0..<count {
                guard let target = snapped[j], distances[target].isFinite else {
                    matrix[i][j] = Geo.metres(points[i], points[j])
                    continue
                }
                matrix[i][j] = departure + distances[target]
                    + Geo.metres(graph.nodes[target], points[j])
            }
        }
        return matrix
    }

    // MARK: Ordering

    /// `nil` means "the start". Keeps nearest-neighbour and 2-opt working the same
    /// way whether the cost comes from a matrix or from coordinates.
    private static func order(
        stops: [RouteStop],
        cost: (RouteStop?, RouteStop?) -> Double
    ) -> [RouteStop] {
        var remaining = stops
        var ordered: [RouteStop] = []
        ordered.reserveCapacity(stops.count)
        var current: RouteStop?

        while !remaining.isEmpty {
            var bestIndex = 0
            var bestCost = Double.greatestFiniteMagnitude
            for (index, stop) in remaining.enumerated() {
                let candidate = cost(current, stop)
                if candidate < bestCost {
                    bestCost = candidate
                    bestIndex = index
                }
            }
            let next = remaining.remove(at: bestIndex)
            ordered.append(next)
            current = next
        }

        guard ordered.count > 3, ordered.count <= refinementLimit else { return ordered }
        return twoOpt(ordered, cost: cost)
    }

    /// Reverses a segment whenever doing so shortens the total — which is exactly
    /// what removes the long back-and-forth legs greedy construction strands at the
    /// end of a route.
    private static func twoOpt(
        _ stops: [RouteStop],
        cost: (RouteStop?, RouteStop?) -> Double
    ) -> [RouteStop] {
        var route = stops
        var passes = 0
        var improved = true

        while improved, passes < maximumPasses {
            improved = false
            passes += 1
            for i in 0..<(route.count - 1) {
                let before: RouteStop? = i == 0 ? nil : route[i - 1]
                for j in (i + 1)..<route.count {
                    let after: RouteStop? = j + 1 < route.count ? route[j + 1] : nil
                    let current = cost(before, route[i]) + (after.map { cost(route[j], $0) } ?? 0)
                    let swapped = cost(before, route[j]) + (after.map { cost(route[i], $0) } ?? 0)
                    if swapped + 0.5 < current {
                        route[i...j].reverse()
                        improved = true
                    }
                }
            }
        }
        return route
    }

    // MARK: Geometry

    static func length(start: CLLocationCoordinate2D, stops: [RouteStop]) -> Double {
        guard let first = stops.first else { return 0 }
        var total = Geo.metres(start, first.coordinate)
        for index in 1..<stops.count {
            total += Geo.metres(stops[index - 1].coordinate, stops[index].coordinate)
        }
        return total
    }

    static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        Geo.metres(a, b)
    }

    private static func coordinate(
        _ stop: RouteStop?,
        start: CLLocationCoordinate2D,
        stops: [RouteStop]
    ) -> CLLocationCoordinate2D {
        stop?.coordinate ?? start
    }
}
