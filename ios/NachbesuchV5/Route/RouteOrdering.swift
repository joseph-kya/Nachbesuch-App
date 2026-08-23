import CoreLocation
import Foundation

/// The *shape* of a recommended route, as opposed to its length.
///
/// The planner used to hand the whole territory to nearest-neighbour and 2-opt in
/// one flat pass. That produces a mathematically short route and a useless one: it
/// takes three houses from one street, crosses to the next, comes back for the
/// fourth, and is impossible to hold in your head while you are standing at a door
/// with a clipboard. Short is not the same as walkable.
///
/// So the order is built the way the work is actually done — **street by street**:
///
/// 1. Houses are grouped into *runs*: one continuous stretch of one street.
/// 2. Inside a run the order is the walk itself — along the street's own axis, one
///    direction, no doubling back.
/// 3. Only the runs are then arranged against each other, each free to be entered
///    from either end.
///
/// The optimisation therefore happens between streets, where it saves real metres,
/// and never inside one, where it only ever produced the zig-zag.
nonisolated enum RouteOrdering {

    /// Two houses of the same street further apart than this belong to separate
    /// runs. Streets repeat their names across a city, and a long one can be split
    /// by a park or a railway; joining those into one run would invent a stretch
    /// nobody walks.
    static let runSplitDistance: Double = 220

    /// Above this many runs the quadratic refinements are skipped. Well past any
    /// real territory — a day's work is tens of streets, not hundreds.
    private static let refinementLimit = 90
    /// Relocation is the cubic pass; it stops well before the others do.
    private static let relocationLimit = 45
    private static let maximumPasses = 6

    /// One continuous stretch of one street, in walking order.
    ///
    /// `isReversed` is the only degree of freedom left after construction: a street
    /// can be walked from either end, and which end you enter from is exactly what
    /// the between-street optimisation gets to decide.
    struct Run: Sendable {
        var stops: [RouteStop]
        var isReversed = false

        var entry: RouteStop { isReversed ? stops[stops.count - 1] : stops[0] }
        var exit: RouteStop { isReversed ? stops[0] : stops[stops.count - 1] }
        var walked: [RouteStop] { isReversed ? stops.reversed() : stops }
    }

    // MARK: Entry point

    /// The walking order for one route.
    ///
    /// `cost` is the distance model — straight line, or metres along the walking
    /// graph. `nil` stands for the starting point, so the first leg is costed like
    /// every other one.
    static func order(
        stops: [RouteStop],
        now: Date = .now,
        cost: (RouteStop?, RouteStop?) -> Double
    ) -> [RouteStop] {
        guard stops.count > 1 else { return stops }
        let sequence = arrange(runs(from: stops), cost: cost)
        let walked = sequence.flatMap(\.walked)
        return RouteSchedule.placingAppointments(walked, now: now, cost: cost)
    }

    // MARK: Runs

    /// Splits the stops into street runs, each already in walking order.
    static func runs(from stops: [RouteStop]) -> [Run] {
        var grouped: [String: [RouteStop]] = [:]
        var order: [String] = []
        // A house with no street name is its own run. Lumping the nameless together
        // would invent a street that does not exist and drag houses from opposite
        // ends of the territory into one "stretch".
        var unnamed: [Run] = []

        for stop in stops {
            let key = stop.street.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                unnamed.append(Run(stops: [stop]))
                continue
            }
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(stop)
        }

        var result: [Run] = []
        for key in order {
            guard let group = grouped[key] else { continue }
            result.append(contentsOf: split(alongStreet(group)))
        }
        return result + unnamed
    }

    /// Orders one street's houses along the street itself.
    ///
    /// The street's direction is taken from its two most distant houses, and every
    /// house is sorted by its position on that line. House *numbers* would be the
    /// obvious alternative and are a trap: they run odd on one side and even on the
    /// other, skip, and carry letters, so sorting by them zig-zags across the road.
    static func alongStreet(_ stops: [RouteStop]) -> [RouteStop] {
        guard stops.count > 2 else { return stops }
        let points = stops.map { local($0.coordinate, origin: stops[0].coordinate) }

        // Farthest pair, approximated the standard cheap way: the point farthest
        // from an arbitrary one, then the point farthest from *that*.
        var a = 0
        var best = -1.0
        for (index, point) in points.enumerated() {
            let d = hypot(point.x - points[0].x, point.y - points[0].y)
            if d > best { best = d; a = index }
        }
        var b = a
        best = -1.0
        for (index, point) in points.enumerated() {
            let d = hypot(point.x - points[a].x, point.y - points[a].y)
            if d > best { best = d; b = index }
        }

        let axis = (x: points[b].x - points[a].x, y: points[b].y - points[a].y)
        let length = hypot(axis.x, axis.y)
        guard length > 1 else { return stops }
        let unit = (x: axis.x / length, y: axis.y / length)

        return zip(stops, points)
            .map { (stop: $0, position: $1.x * unit.x + $1.y * unit.y) }
            .sorted { $0.position < $1.position }
            .map(\.stop)
    }

    /// Cuts a street's ordered houses wherever the gap is too big to be one stretch.
    static func split(_ ordered: [RouteStop]) -> [Run] {
        guard !ordered.isEmpty else { return [] }
        var runs: [Run] = []
        var current: [RouteStop] = [ordered[0]]
        for stop in ordered.dropFirst() {
            if Geo.metres(current[current.count - 1].coordinate, stop.coordinate) > runSplitDistance {
                runs.append(Run(stops: current))
                current = [stop]
            } else {
                current.append(stop)
            }
        }
        runs.append(Run(stops: current))
        return runs
    }

    // MARK: Arranging the runs

    /// Nearest-neighbour over runs, then refinement — the same pair as before, but
    /// applied to streets instead of doors, so an improvement can never break a
    /// street apart.
    static func arrange(_ runs: [Run], cost: (RouteStop?, RouteStop?) -> Double) -> [Run] {
        guard runs.count > 1 else { return runs }
        var pending = runs
        var sequence: [Run] = []
        sequence.reserveCapacity(runs.count)
        var current: RouteStop?

        while !pending.isEmpty {
            var bestIndex = 0
            var bestReversed = false
            var best = Double.greatestFiniteMagnitude
            for (index, run) in pending.enumerated() {
                // Both ends are candidates: entering a street at the far end is
                // often what saves the walk back along it.
                let forward = cost(current, run.stops.first)
                if forward < best { best = forward; bestIndex = index; bestReversed = false }
                let backward = cost(current, run.stops.last)
                if backward < best { best = backward; bestIndex = index; bestReversed = true }
            }
            var run = pending.remove(at: bestIndex)
            run.isReversed = bestReversed
            sequence.append(run)
            current = run.exit
        }

        guard sequence.count <= refinementLimit else { return sequence }
        return refine(sequence, cost: cost)
    }

    /// Three cheap improvements, run until nothing changes:
    ///
    /// * **flip** — walk one street from its other end,
    /// * **2-opt** — reverse a stretch of streets, undoing the crossings greedy
    ///   construction always strands at the end,
    /// * **or-opt** — move a single street elsewhere, which is what rescues the one
    ///   forgotten side street that 2-opt cannot reach on its own.
    ///
    /// Only the *connections between* runs are scored: what happens inside a run is
    /// the same walk however the runs are arranged.
    static func refine(_ runs: [Run], cost: (RouteStop?, RouteStop?) -> Double) -> [Run] {
        var sequence = runs
        // Scored once and carried, not recomputed per comparison: the same length
        // was being measured tens of thousands of times per pass.
        var currentCost = connections(sequence, cost: cost)
        var passes = 0
        var improved = true

        func adopt(_ candidate: [Run]) -> Bool {
            let candidateCost = connections(candidate, cost: cost)
            // Half a metre of slack, so floating-point noise cannot make two equal
            // arrangements swap forever.
            guard candidateCost + 0.5 < currentCost else { return false }
            sequence = candidate
            currentCost = candidateCost
            return true
        }

        while improved, passes < maximumPasses {
            improved = false
            passes += 1

            for index in sequence.indices {
                var candidate = sequence
                candidate[index].isReversed.toggle()
                if adopt(candidate) { improved = true }
            }

            for i in 0..<(sequence.count - 1) {
                for j in (i + 1)..<sequence.count {
                    var candidate = sequence
                    candidate[i...j].reverse()
                    for k in i...j { candidate[k].isReversed.toggle() }
                    if adopt(candidate) { improved = true }
                }
            }

            // The one cubic pass, so it keeps a tighter budget than the others.
            guard sequence.count <= relocationLimit else { continue }
            for from in sequence.indices {
                for to in sequence.indices where to != from {
                    for reversed in [false, true] {
                        var candidate = sequence
                        var moved = candidate.remove(at: from)
                        if reversed { moved.isReversed.toggle() }
                        candidate.insert(moved, at: to)
                        if adopt(candidate) { improved = true }
                    }
                }
            }
        }
        return sequence
    }

    /// The walk *between* streets: the start leg plus every hand-off from one
    /// street's exit to the next one's entry.
    static func connections(_ runs: [Run], cost: (RouteStop?, RouteStop?) -> Double) -> Double {
        guard let first = runs.first else { return 0 }
        var total = cost(nil, first.entry)
        for index in 1..<runs.count {
            total += cost(runs[index - 1].exit, runs[index].entry)
        }
        return total
    }

    // MARK: Geometry

    /// Metres east/north of an origin. Equirectangular: at the scale of one
    /// territory the error is centimetres, and it needs no trigonometry per point.
    private static func local(
        _ coordinate: CLLocationCoordinate2D,
        origin: CLLocationCoordinate2D
    ) -> (x: Double, y: Double) {
        let latitudeScale = 110_540.0
        let longitudeScale = 111_320.0 * cos(origin.latitude * .pi / 180)
        return (
            x: (coordinate.longitude - origin.longitude) * longitudeScale,
            y: (coordinate.latitude - origin.latitude) * latitudeScale
        )
    }
}

/// Fitting the booked "Später" times into a walking order.
///
/// A route that ignores appointments walks you past the 18:00 house at 15:00 and
/// sends you back across the territory later — the single most expensive mistake
/// the old planner made, because it costs a whole return trip that no amount of
/// 2-opt can win back.
nonisolated enum RouteSchedule {
    /// Walking pace with a bag, about 4,5 km/h.
    static let walkingSpeed: Double = 1.25
    /// Time spent at one house: ringing, waiting, the conversation, the form.
    static let dwellSeconds: Double = 180

    /// Arriving late risks an empty flat; arriving early only costs waiting. Both
    /// are counted, lateness twice as heavily.
    private static let latenessWeight: Double = 3
    private static let earlinessWeight: Double = 1.5

    /// Estimated arrival at each stop, in order.
    static func arrivals(
        _ stops: [RouteStop],
        now: Date,
        cost: (RouteStop?, RouteStop?) -> Double
    ) -> [Date] {
        var result: [Date] = []
        result.reserveCapacity(stops.count)
        var elapsed: TimeInterval = 0
        var previous: RouteStop?
        for stop in stops {
            elapsed += cost(previous, stop) / walkingSpeed
            result.append(now.addingTimeInterval(elapsed))
            elapsed += dwellSeconds
            previous = stop
        }
        return result
    }

    /// Re-places every house that has a booked time, leaving the rest of the street
    /// order untouched.
    ///
    /// Greedy insertion in time order: each appointment goes wherever the total of
    /// "extra walking" and "wrong time" is smallest. An overdue appointment scores
    /// best at the very front, which is exactly where it belongs.
    static func placingAppointments(
        _ stops: [RouteStop],
        now: Date,
        cost: (RouteStop?, RouteStop?) -> Double
    ) -> [RouteStop] {
        let appointments = stops
            .filter { $0.dueAt != nil }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        guard !appointments.isEmpty else { return stops }

        var sequence = stops.filter { $0.dueAt == nil }
        for appointment in appointments {
            var bestIndex = sequence.count
            var bestScore = Double.greatestFiniteMagnitude
            for index in 0...sequence.count {
                var candidate = sequence
                candidate.insert(appointment, at: index)
                let score = penalty(candidate, now: now, cost: cost)
                if score < bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            sequence.insert(appointment, at: bestIndex)
        }
        return sequence
    }

    /// Walking time plus the appointment error, both in seconds so they can be
    /// weighed against each other at all.
    static func penalty(
        _ stops: [RouteStop],
        now: Date,
        cost: (RouteStop?, RouteStop?) -> Double
    ) -> Double {
        let times = arrivals(stops, now: now, cost: cost)
        var total: Double = 0
        var previous: RouteStop?
        for stop in stops {
            total += cost(previous, stop) / walkingSpeed
            previous = stop
        }
        for (stop, arrival) in zip(stops, times) {
            guard let dueAt = stop.dueAt else { continue }
            let difference = arrival.timeIntervalSince(dueAt)
            total += difference >= 0
                ? difference * latenessWeight
                : -difference * earlinessWeight
        }
        return total
    }
}
