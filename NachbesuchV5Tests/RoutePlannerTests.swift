import CoreLocation
import Foundation
import Testing
@testable import NachbesuchV5

@Suite("Empfohlene Route")
struct RoutePlannerTests {

    /// Metres offset from a Vienna origin, so the numbers stay readable.
    private func stop(east: Double, north: Double) -> RouteStop {
        let originLatitude = 48.2100
        let originLongitude = 16.3100
        return RouteStop(
            houseID: UUID(),
            latitude: originLatitude + north / 110_540,
            longitude: originLongitude + east / (111_320 * cos(originLatitude * .pi / 180))
        )
    }

    private var origin: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 48.2100, longitude: 16.3100)
    }

    @Test("Jedes Haus kommt genau einmal vor")
    func visitsEveryHouseOnce() {
        let stops = (0..<25).map { stop(east: Double($0 % 5) * 40, north: Double($0 / 5) * 40) }
        let route = RoutePlanner.plan(start: origin, stops: stops)
        #expect(route.stops.count == stops.count)
        #expect(Set(route.houseIDs).count == stops.count, "Keine Dopplungen, keine Auslassungen")
        #expect(Set(route.houseIDs) == Set(stops.map(\.houseID)))
    }

    @Test("Bei einer Straße entsteht die naheliegende Reihenfolge")
    func walksAStraightStreetInOrder() throws {
        // Fünf Häuser in einer Reihe, absichtlich verwürfelt übergeben.
        let a = stop(east: 0, north: 0)
        let b = stop(east: 40, north: 0)
        let c = stop(east: 80, north: 0)
        let d = stop(east: 120, north: 0)
        let e = stop(east: 160, north: 0)

        let route = RoutePlanner.plan(start: origin, stops: [d, b, e, a, c])
        #expect(route.houseIDs == [a, b, c, d, e].map(\.houseID))
    }

    /// The whole point of the 2-opt pass: greedy nearest-neighbour leaves long
    /// crossing legs behind, and the refinement is what removes them.
    @Test("Die Verfeinerung ist nie schlechter als der reine Greedy-Weg")
    func refinementNeverMakesItWorse() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<12 {
            let stops = (0..<30).map { _ in
                stop(
                    east: Double.random(in: 0...400, using: &generator),
                    north: Double.random(in: 0...400, using: &generator)
                )
            }
            let route = RoutePlanner.plan(start: origin, stops: stops)
            // Rebuild the naive order by planning over a single-pass construction:
            // the planner's own length function measures both the same way.
            let greedyLength = greedyOnly(start: origin, stops: stops)
            #expect(route.distance <= greedyLength + 0.5)
        }
    }

    private func greedyOnly(start: CLLocationCoordinate2D, stops: [RouteStop]) -> Double {
        var remaining = stops
        var current = start
        var ordered: [RouteStop] = []
        while !remaining.isEmpty {
            var bestIndex = 0
            var best = Double.greatestFiniteMagnitude
            for (index, stop) in remaining.enumerated() {
                let distance = RoutePlanner.metres(current, stop.coordinate)
                if distance < best { best = distance; bestIndex = index }
            }
            let next = remaining.remove(at: bestIndex)
            ordered.append(next)
            current = next.coordinate
        }
        return RoutePlanner.length(start: start, stops: ordered)
    }

    @Test("Ein Kreuzungsfall wird tatsächlich entwirrt")
    func untanglesACrossing() {
        // Vier Ecken eines Quadrats. Nearest-neighbour vom Startpunkt aus erzeugt
        // hier gern eine gekreuzte Achterschleife; die kurze Route ist der Umlauf.
        let corners = [
            stop(east: 0, north: 0),
            stop(east: 200, north: 0),
            stop(east: 200, north: 200),
            stop(east: 0, north: 200)
        ]
        let route = RoutePlanner.plan(start: origin, stops: corners)
        // Der Umlauf ist 200+200+200 plus Anfahrt; alles darüber wäre eine Kreuzung.
        #expect(route.distance < 700)
    }

    // MARK: Straßennetz

    /// A tiny graph: two parallel streets joined only at one end. Two houses on
    /// opposite streets are close in a straight line but a long way apart on foot —
    /// exactly the case that made the old route cut through buildings.
    private func parallelStreets() -> WalkingGraph {
        func node(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: 48.2100 + north / 110_540,
                longitude: 16.3100 + east / (111_320 * cos(48.21 * .pi / 180))
            )
        }
        // 0..2 = untere Straße, 3..5 = obere Straße, verbunden nur bei Osten 200.
        let nodes = [
            node(0, 0), node(100, 0), node(200, 0),
            node(0, 60), node(100, 60), node(200, 60)
        ]
        func edge(_ a: Int, _ b: Int) -> WalkingGraph.Edge {
            .init(node: b, metres: Geo.metres(nodes[a], nodes[b]))
        }
        var adjacency: [[WalkingGraph.Edge]] = Array(repeating: [], count: 6)
        for (a, b) in [(0, 1), (1, 2), (3, 4), (4, 5), (2, 5)] {
            adjacency[a].append(edge(a, b))
            adjacency[b].append(edge(b, a))
        }
        return WalkingGraph(nodes: nodes, adjacency: adjacency)
    }

    @Test("Der gezeichnete Weg folgt dem Straßennetz")
    func pathFollowsTheNetwork() {
        let graph = parallelStreets()
        // Ein Haus unten links, eines oben links — Luftlinie 60 m, zu Fuß 460 m.
        let bottomLeft = RouteStop(
            houseID: UUID(),
            latitude: graph.nodes[0].latitude,
            longitude: graph.nodes[0].longitude
        )
        let topLeft = RouteStop(
            houseID: UUID(),
            latitude: graph.nodes[3].latitude,
            longitude: graph.nodes[3].longitude
        )
        let route = RoutePlanner.plan(
            start: graph.nodes[0],
            stops: [bottomLeft, topLeft],
            graph: graph
        )
        #expect(route.followsStreets)
        // Der Weg muss über die Verbindung im Osten laufen, also deutlich mehr als
        // die 60 m Luftlinie.
        #expect(route.distance > 400)
        #expect(route.path.count > 3, "Ein Linienzug über mehrere Knoten, keine Gerade")
    }

    @Test("Ohne Netz bleibt die Luftlinie als Rückfall")
    func fallsBackWithoutNetwork() {
        let empty = WalkingGraph(nodes: [], adjacency: [])
        let stops = [stop(east: 0, north: 0), stop(east: 100, north: 0)]
        let route = RoutePlanner.plan(start: origin, stops: stops, graph: empty)
        #expect(!route.followsStreets)
        #expect(route.stops.count == 2, "Die Route entsteht trotzdem")
    }

    @Test("Der Graph verbindet Wege an gemeinsamen Knoten")
    func graphJoinsSharedNodes() throws {
        // Zwei Wege, die sich einen Punkt teilen, müssen zu einem Netz werden.
        let json = """
        {"elements":[
          {"geometry":[{"lat":48.2100,"lon":16.3100},{"lat":48.2100,"lon":16.3110}]},
          {"geometry":[{"lat":48.2100,"lon":16.3110},{"lat":48.2110,"lon":16.3110}]}
        ]}
        """
        let graph = try WalkingNetworkService.buildGraph(from: Data(json.utf8))
        #expect(graph.nodes.count == 3, "Der geteilte Punkt darf nicht doppelt entstehen")
        let (distances, _) = graph.shortestPaths(from: 0)
        #expect(distances[2].isFinite, "Beide Wege hängen zusammen")
    }

    @Test("Ohne Häuser gibt es keine Route")
    func emptyInput() {
        let route = RoutePlanner.plan(start: origin, stops: [])
        #expect(route.isEmpty)
        #expect(route.distance == 0)
    }

    @Test("Ein einzelnes Haus ergibt die direkte Strecke")
    func singleStop() {
        let only = stop(east: 100, north: 0)
        let route = RoutePlanner.plan(start: origin, stops: [only])
        #expect(route.stops.count == 1)
        #expect(abs(route.distance - 100) < 2)
    }

    /// A whole territory must still plan without stalling the app.
    @Test("Auch 400 Häuser bleiben berechenbar")
    func handlesAFullTerritory() {
        let stops = (0..<400).map { index in
            stop(east: Double(index % 20) * 30, north: Double(index / 20) * 30)
        }
        let started = Date.now
        let route = RoutePlanner.plan(start: origin, stops: stops)
        #expect(route.stops.count == 400)
        #expect(Date.now.timeIntervalSince(started) < 10)
    }

    // MARK: - Skipping

    @Test("Ein übersprungenes Haus rutscht ans Ende der Warteschlange")
    func skippingMovesToTheBack() {
        let ids = (0..<4).map { _ in UUID() }
        let queue = RouteSession.queue(order: ids, skipped: [ids[0]], open: Set(ids))
        #expect(queue == [ids[1], ids[2], ids[3], ids[0]])
    }

    @Test("Erledigte Häuser fallen aus der Warteschlange, übersprungene nicht")
    func doneHousesLeaveTheQueue() {
        let ids = (0..<4).map { _ in UUID() }
        let open: Set<UUID> = [ids[1], ids[2]]
        let queue = RouteSession.queue(order: ids, skipped: [ids[1]], open: open)
        #expect(queue == [ids[2], ids[1]])
    }

    @Test("Mehrfaches Überspringen behält die Reihenfolge der Übersprungenen")
    func repeatedSkipsKeepTheirOrder() {
        let ids = (0..<3).map { _ in UUID() }
        let queue = RouteSession.queue(order: ids, skipped: [ids[1], ids[0]], open: Set(ids))
        #expect(queue == [ids[2], ids[1], ids[0]])
    }

    // MARK: - Drawing

    /// The bug this replaced: the drawn line was the planned polyline trimmed to the
    /// nearest vertex, so a skipped house dragged the line backwards through doors
    /// that were already finished.
    @Test("Nach einem Übersprung führt die Linie nicht zurück")
    func drawnLineNeverRunsBackwards() {
        let ids = (0..<3).map { _ in UUID() }
        let coordinates: [UUID: CLLocationCoordinate2D] = [
            ids[0]: CLLocationCoordinate2D(latitude: 48.20, longitude: 16.30),
            ids[1]: CLLocationCoordinate2D(latitude: 48.21, longitude: 16.30),
            ids[2]: CLLocationCoordinate2D(latitude: 48.22, longitude: 16.30)
        ]
        let legs: [UUID: [CLLocationCoordinate2D]] = [
            ids[1]: [coordinates[ids[1]]!],
            ids[2]: [coordinates[ids[2]]!]
        ]
        // Queue after skipping the first house: 2, 3, then 1 at the back.
        let queue = [ids[1], ids[2], ids[0]]
        let path = RouteSession.drawnPath(
            queue: queue,
            plannedOrder: ids,
            legs: legs,
            coordinates: coordinates
        )
        #expect(path.count == 3)
        #expect(path.first?.latitude == 48.21)
        #expect(path.last?.latitude == 48.20)
    }

    @Test("Die Linie beginnt beim nächsten Haus, nicht beim Startpunkt")
    func drawnLineStartsAtTheNextHouse() {
        let ids = (0..<2).map { _ in UUID() }
        let coordinates: [UUID: CLLocationCoordinate2D] = [
            ids[0]: CLLocationCoordinate2D(latitude: 48.20, longitude: 16.30),
            ids[1]: CLLocationCoordinate2D(latitude: 48.21, longitude: 16.30)
        ]
        // A long leg into house 2; only the leg is drawn, never house 1's own leg.
        let legs: [UUID: [CLLocationCoordinate2D]] = [
            ids[0]: [CLLocationCoordinate2D(latitude: 48.10, longitude: 16.30)],
            ids[1]: [
                CLLocationCoordinate2D(latitude: 48.205, longitude: 16.30),
                coordinates[ids[1]]!
            ]
        ]
        let path = RouteSession.drawnPath(
            queue: ids,
            plannedOrder: ids,
            legs: legs,
            coordinates: coordinates
        )
        #expect(path.count == 3)
        #expect(path.first?.latitude == 48.20)
    }

    /// Houses on a long straight street snap to the same OSM vertex. Without the
    /// door-to-pavement hops in the cost matrix every pair costs zero and the order
    /// becomes arbitrary — the exact zig-zag this feature exists to prevent.
    @Test("Häuser am selben Straßenknoten werden trotzdem der Reihe nach besucht")
    func housesOnOneLongStreetKeepTheirOrder() {
        // Two graph nodes 400 m apart; six houses strung along between them.
        let west = CLLocationCoordinate2D(latitude: 48.2000, longitude: 16.3000)
        let east = CLLocationCoordinate2D(latitude: 48.2000, longitude: 16.3054)
        let graph = WalkingGraph(
            nodes: [west, east],
            adjacency: [
                [WalkingGraph.Edge(node: 1, metres: Geo.metres(west, east))],
                [WalkingGraph.Edge(node: 0, metres: Geo.metres(west, east))]
            ]
        )
        let stops = (0..<6).map { index in
            RouteStop(
                houseID: UUID(),
                latitude: 48.2001,
                longitude: 16.3000 + Double(index) * 0.0009
            )
        }
        let route = RoutePlanner.plan(start: west, stops: stops.shuffled(), graph: graph)
        let longitudes = route.stops.map(\.longitude)
        #expect(longitudes == longitudes.sorted())
    }

    @Test("Häuser werden auf die Straße projiziert, nicht an deren entferntes Ende")
    func snapsToStreetSegmentInsteadOfVertex() {
        let west = CLLocationCoordinate2D(latitude: 48.2000, longitude: 16.3000)
        let east = CLLocationCoordinate2D(latitude: 48.2000, longitude: 16.3054)
        let graph = WalkingGraph(
            nodes: [west, east],
            adjacency: [
                [.init(node: 1, metres: Geo.metres(west, east))],
                [.init(node: 0, metres: Geo.metres(west, east))]
            ]
        )
        let first = RouteStop(
            houseID: UUID(),
            latitude: 48.2001,
            longitude: 16.30135
        )
        let second = RouteStop(
            houseID: UUID(),
            latitude: 48.2001,
            longitude: 16.30270
        )

        let route = RoutePlanner.plan(start: first.coordinate, stops: [second], graph: graph)
        // Roughly 100 m along the street plus two ~11 m door connectors. Nearest-
        // vertex snapping produced a detour of several hundred metres here.
        #expect(route.distance > 110)
        #expect(route.distance < 140)
        #expect(route.path.count >= 4)
    }

    @Test("Die gezeichnete Route enthält den Weg vom Start zum ersten Haus")
    func remainingPathIncludesInitialLeg() {
        let first = UUID()
        let second = UUID()
        let start = CLLocationCoordinate2D(latitude: 48.2000, longitude: 16.3000)
        let firstCoordinate = CLLocationCoordinate2D(latitude: 48.2010, longitude: 16.3000)
        let secondCoordinate = CLLocationCoordinate2D(latitude: 48.2020, longitude: 16.3000)
        let firstMidpoint = CLLocationCoordinate2D(latitude: 48.2005, longitude: 16.3000)
        let path = RouteSession.drawnPath(
            queue: [first, second],
            plannedOrder: [first, second],
            legs: [
                first: [firstMidpoint, firstCoordinate],
                second: [secondCoordinate]
            ],
            coordinates: [first: firstCoordinate, second: secondCoordinate],
            start: start
        )

        #expect(path.first?.latitude == start.latitude)
        #expect(path.first?.longitude == start.longitude)
        #expect(path.contains {
            $0.latitude == firstMidpoint.latitude && $0.longitude == firstMidpoint.longitude
        })
        #expect(path.last?.latitude == secondCoordinate.latitude)
        #expect(path.last?.longitude == secondCoordinate.longitude)
    }

    @Test("Auch zum letzten verbleibenden Haus bleibt die Linie sichtbar")
    func finalRemainingHouseKeepsItsInboundLeg() {
        let first = UUID()
        let last = UUID()
        let firstCoordinate = CLLocationCoordinate2D(latitude: 48.2000, longitude: 16.3000)
        let midpoint = CLLocationCoordinate2D(latitude: 48.2005, longitude: 16.3000)
        let lastCoordinate = CLLocationCoordinate2D(latitude: 48.2010, longitude: 16.3000)

        let path = RouteSession.drawnPath(
            queue: [last],
            plannedOrder: [first, last],
            legs: [last: [midpoint, lastCoordinate]],
            coordinates: [first: firstCoordinate, last: lastCoordinate]
        )

        #expect(path.count == 3)
        #expect(path.first?.latitude == firstCoordinate.latitude)
        #expect(path.contains { $0.latitude == midpoint.latitude })
        #expect(path.last?.latitude == lastCoordinate.latitude)
    }

    @Test("Nach einem Übersprung beginnt die Linie am aktuellen Standort")
    func skippedFirstStopUsesLiveConnector() {
        let ids = (0..<3).map { _ in UUID() }
        let current = CLLocationCoordinate2D(latitude: 48.2090, longitude: 16.3090)
        let coordinates = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CLLocationCoordinate2D(latitude: 48.2100 + Double(index) * 0.001, longitude: 16.3100))
        })

        let path = RouteSession.drawnPath(
            queue: [ids[1], ids[2], ids[0]],
            plannedOrder: ids,
            legs: [ids[2]: [coordinates[ids[2]]!]],
            coordinates: coordinates,
            currentLocation: current
        )

        #expect(path.first?.latitude == current.latitude)
        #expect(path.first?.longitude == current.longitude)
        #expect(path[1].latitude == coordinates[ids[1]]?.latitude)
    }
}
