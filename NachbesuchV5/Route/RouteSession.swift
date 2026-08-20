import CoreLocation
import Foundation
import Observation

/// The live state of a recommended route.
///
/// Keeps the planned order and works out what is still ahead of you. The order
/// itself never changes as you work — re-planning after every door would move the
/// route under your feet — but visited houses drop out of the remaining path.
@MainActor
@Observable
final class RouteSession {
    private(set) var start: CLLocationCoordinate2D?
    /// The full planned order, including houses already done.
    private(set) var plannedOrder: [UUID] = []
    private(set) var plannedDistance: Double = 0
    private(set) var isPlanning = false
    /// The line to draw — along streets when the network was reachable.
    private(set) var path: [CLLocationCoordinate2D] = []
    /// The path split per house, so the drawing survives skips and out-of-order work.
    private(set) var legsByHouse: [UUID: [CLLocationCoordinate2D]] = [:]
    private(set) var coordinatesByHouse: [UUID: CLLocationCoordinate2D] = [:]
    private(set) var followsStreets = false
    /// Set when the network could not be loaded, so the UI can say why the line is
    /// a straight one instead of leaving the user to wonder.
    private(set) var fellBackToStraightLines = false
    /// Older builds stored only one long polyline. Such a route cannot be trimmed
    /// reliably as doors are completed, so it is rebuilt once after restoration.
    private(set) var requiresReplan = false
    /// Houses you chose to leave for later, in the order you skipped them. They are
    /// not dropped — they move to the back of the queue, so nobody is lost.
    private(set) var skipped: [UUID] = []
    private var planningID: UUID?

    var isActive: Bool { !plannedOrder.isEmpty }

    private let store = RouteStore()

    func restore(for gebietID: UUID) {
        guard let saved = store.load(for: gebietID) else {
            clearInMemory()
            return
        }
        start = saved.start
        plannedOrder = saved.houseIDs
        plannedDistance = saved.distance
        path = saved.path
        followsStreets = saved.followsStreets
        // A restored crow-flight route is still crow-flight: without this the
        // warning vanished on relaunch while the line still cut through buildings.
        fellBackToStraightLines = !saved.followsStreets
        skipped = saved.skipped
        legsByHouse = Dictionary(
            uniqueKeysWithValues: zip(saved.houseIDs, saved.legs)
        )
        coordinatesByHouse = Dictionary(
            uniqueKeysWithValues: zip(saved.houseIDs, saved.stops)
        )
        requiresReplan = saved.legs.count != saved.houseIDs.count
            || saved.stops.count != saved.houseIDs.count
    }

    /// Drops houses that no longer exist from a restored route.
    ///
    /// A saved route outlives the houses in it — deleting a house left its id in the
    /// order forever, which made the counter read past the total and could leave a
    /// route that could never be finished.
    func prune(livingHouseIDs: Set<UUID>, for gebietID: UUID) {
        guard !plannedOrder.isEmpty else { return }
        let survivors = plannedOrder.filter { livingHouseIDs.contains($0) }
        guard survivors.count != plannedOrder.count else { return }
        plannedOrder = survivors
        skipped = skipped.filter { livingHouseIDs.contains($0) }
        legsByHouse = legsByHouse.filter { livingHouseIDs.contains($0.key) }
        coordinatesByHouse = coordinatesByHouse.filter { livingHouseIDs.contains($0.key) }
        // A pruned in-memory route must not restore the deleted houses on the next
        // launch. Marking it for a clean rebuild also fixes its distance summary.
        requiresReplan = true
        store.clear(for: gebietID)
    }

    @discardableResult
    func plan(
        start: CLLocationCoordinate2D,
        stops: [RouteStop],
        for gebietID: UUID
    ) async -> Bool {
        // A newer request supersedes an older one. A plain `isPlanning` guard made
        // “Route neu planen” cancel the old task and reject the replacement.
        let requestID = UUID()
        planningID = requestID
        isPlanning = true
        defer {
            if planningID == requestID {
                isPlanning = false
                planningID = nil
            }
        }

        // The street network is what makes the route walkable. If it cannot be
        // fetched the route is still produced, just as straight lines — better a
        // usable order than no route at all.
        let graph = try? await WalkingNetworkService.load(
            around: [start] + stops.map(\.coordinate)
        )
        guard !Task.isCancelled, planningID == requestID else { return false }

        let planned = await Task.detached(priority: .userInitiated) {
            if let graph, !graph.isEmpty {
                return RoutePlanner.plan(start: start, stops: stops, graph: graph)
            }
            return RoutePlanner.plan(start: start, stops: stops)
        }.value
        guard !Task.isCancelled, planningID == requestID else { return false }

        // Everything is committed together, after the last cancellation check —
        // clearing state up front left a cancelled plan with half the old route.
        self.start = planned.start
        plannedOrder = planned.houseIDs
        plannedDistance = planned.distance
        path = planned.path
        legsByHouse = Dictionary(uniqueKeysWithValues: zip(planned.houseIDs, planned.legs))
        coordinatesByHouse = Dictionary(
            uniqueKeysWithValues: planned.stops.map { ($0.houseID, $0.coordinate) }
        )
        followsStreets = planned.followsStreets
        fellBackToStraightLines = !planned.followsStreets
        requiresReplan = false
        skipped = []
        store.save(planned, skipped: [], for: gebietID)
        return true
    }

    func end(for gebietID: UUID) {
        store.clear(for: gebietID)
        clearInMemory()
    }

    private func clearInMemory() {
        start = nil
        plannedOrder = []
        plannedDistance = 0
        path = []
        legsByHouse = [:]
        coordinatesByHouse = [:]
        followsStreets = false
        fellBackToStraightLines = false
        requiresReplan = false
        skipped = []
    }

    /// The remaining line to draw, built from the per-house legs.
    ///
    /// Walked in queue order rather than trimmed off the original polyline: once a
    /// house has been skipped or finished out of order, "the tail of the planned
    /// line" and "the way still to walk" are two different things, and the old trim
    /// drew the difference — a line running backwards through finished doors.
    func remainingPath(
        queue: [UUID],
        currentLocation: CLLocationCoordinate2D? = nil
    ) -> [CLLocationCoordinate2D] {
        Self.drawnPath(
            queue: queue,
            plannedOrder: plannedOrder,
            legs: legsByHouse,
            coordinates: coordinatesByHouse,
            start: start,
            currentLocation: currentLocation
        )
    }

    /// Pure form of the drawing rule, so it can be reasoned about and tested.
    nonisolated static func drawnPath(
        queue: [UUID],
        plannedOrder: [UUID],
        legs: [UUID: [CLLocationCoordinate2D]],
        coordinates: [UUID: CLLocationCoordinate2D],
        start: CLLocationCoordinate2D? = nil,
        currentLocation: CLLocationCoordinate2D? = nil
    ) -> [CLLocationCoordinate2D] {
        guard let firstHouse = queue.first else { return [] }
        var successor: [UUID: UUID] = [:]
        for (index, houseID) in plannedOrder.enumerated() where index + 1 < plannedOrder.count {
            successor[houseID] = plannedOrder[index + 1]
        }

        var points: [CLLocationCoordinate2D] = []
        var previous: UUID?
        for houseID in queue {
            guard let coordinate = coordinates[houseID] else { continue }
            defer { previous = houseID }
            guard let previous else {
                let index = plannedOrder.firstIndex(of: firstHouse)
                if index == 0, let start, let leg = legs[houseID] {
                    points.append(start)
                    points.append(contentsOf: leg)
                } else if let index, index > 0,
                          !queue.contains(plannedOrder[index - 1]),
                          let predecessor = coordinates[plannedOrder[index - 1]],
                          let leg = legs[houseID] {
                    // Normal progression: the previous planned door has just been
                    // completed, and this is the exact stored street leg onward.
                    points.append(predecessor)
                    points.append(contentsOf: leg)
                } else if let currentLocation {
                    // A skip or out-of-order completion invalidates that stored
                    // inbound leg. Draw an honest live connector instead of an
                    // old path that runs backwards through completed doors.
                    points.append(currentLocation)
                    points.append(coordinate)
                } else {
                    points.append(coordinate)
                }
                continue
            }
            // A stored leg is only valid between the pair it was computed for.
            // Wherever the queue deviates from the plan — after a skip, or after
            // doors were worked out of order — a straight hop is drawn instead:
            // honest about being an approximation rather than inventing a detour
            // back through houses that are already done.
            if successor[previous] == houseID, let leg = legs[houseID] {
                points.append(contentsOf: leg)
            } else {
                points.append(coordinate)
            }
        }
        return points
    }

    /// House ids still to visit, in walking order — skipped ones last.
    func remaining(openHouseIDs: Set<UUID>) -> [UUID] {
        Self.queue(order: plannedOrder, skipped: skipped, open: openHouseIDs)
    }

    /// The walking queue: planned order minus what is done, with skipped houses
    /// moved to the back in the order they were skipped. Pure, so it can be
    /// reasoned about (and tested) without a route session around it.
    nonisolated static func queue(
        order: [UUID],
        skipped: [UUID],
        open: Set<UUID>
    ) -> [UUID] {
        let skippedSet = Set(skipped)
        let ahead = order.filter { open.contains($0) && !skippedSet.contains($0) }
        let later = skipped.filter { open.contains($0) }
        return ahead + later
    }

    /// The next house to walk to, or `nil` when the route is finished.
    func nextStop(openHouseIDs: Set<UUID>) -> UUID? {
        remaining(openHouseIDs: openHouseIDs).first
    }

    /// Puts the current stop aside and moves on to the one the route would pick
    /// next. Skipping the last remaining house is a no-op — there is nothing to
    /// move on to, and silently emptying the route would be worse than refusing.
    @discardableResult
    func skipNextStop(openHouseIDs: Set<UUID>, for gebietID: UUID) -> Bool {
        let queue = remaining(openHouseIDs: openHouseIDs)
        guard queue.count > 1, let current = queue.first else { return false }
        skipped.removeAll { $0 == current }
        skipped.append(current)
        store.saveSkipped(skipped, for: gebietID)
        return true
    }



    func position(of houseID: UUID) -> Int? {
        plannedOrder.firstIndex(of: houseID).map { $0 + 1 }
    }
}
