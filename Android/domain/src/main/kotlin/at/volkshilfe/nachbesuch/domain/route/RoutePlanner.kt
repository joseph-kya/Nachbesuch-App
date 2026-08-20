package at.volkshilfe.nachbesuch.domain.route

import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import kotlin.math.cos

data class RouteStop(val id: String, val coordinate: StoredCoordinate)

data class PlannedRoute(
    val start: StoredCoordinate,
    val stops: List<RouteStop>,
    val legs: List<List<StoredCoordinate>>,
    val followsStreets: Boolean
) {
    val path: List<StoredCoordinate> get() = buildList {
        add(start)
        legs.forEach(::addAll)
    }
}

/** Deterministic, allocation-light fallback route. A walking graph can replace the distance function later. */
object RoutePlanner {
    fun plan(start: StoredCoordinate, stops: List<RouteStop>, graph: WalkingGraph? = null): PlannedRoute {
        if (graph != null) planOnGraph(start, stops, graph)?.let { return it }
        return planByAirDistance(start, stops)
    }

    private fun planByAirDistance(start: StoredCoordinate, stops: List<RouteStop>): PlannedRoute {
        if (stops.isEmpty()) return PlannedRoute(start, emptyList(), emptyList(), false)
        val remaining = stops.toMutableList()
        val ordered = ArrayList<RouteStop>(stops.size)
        var cursor = start
        while (remaining.isNotEmpty()) {
            val next = remaining.minBy { metresSquared(cursor, it.coordinate) }
            remaining.remove(next)
            ordered += next
            cursor = next.coordinate
        }
        // One 2-opt pass is enough to remove the common crossing artefact without
        // making a large territory's plan expensive.
        if (ordered.size <= 400) refineTwoOpt(start, ordered)
        val legs = ordered.mapIndexed { index, stop ->
            listOf(if (index == 0) start else ordered[index - 1].coordinate, stop.coordinate)
        }
        return PlannedRoute(start, ordered, legs, false)
    }

    private fun planOnGraph(
        start: StoredCoordinate,
        stops: List<RouteStop>,
        graph: WalkingGraph
    ): PlannedRoute? {
        if (stops.isEmpty()) return PlannedRoute(start, emptyList(), emptyList(), true)
        // Large territories still get a useful order, but avoid an O(n²) matrix.
        if (stops.size > 150) return null
        val startNode = graph.nearestNode(start) ?: return null
        val stopNodes = stops.map { graph.nearestNode(it.coordinate) ?: return null }
        val allNodes = intArrayOf(startNode, *stopNodes.toIntArray())
        val pairDistances = Array(allNodes.size) { DoubleArray(allNodes.size) { Double.POSITIVE_INFINITY } }
        val nodeOffsets = allNodes.mapIndexed { index, node ->
            val target = if (index == 0) start else stops[index - 1].coordinate
            graph.coordinate(node)?.let { metres(target, it) } ?: return null
        }
        for (from in allNodes.indices) {
            pairDistances[from][from] = 0.0
            for (to in from + 1 until allNodes.size) {
                val distance = graph.shortestDistance(allNodes[from], allNodes[to]) ?: return null
                pairDistances[from][to] = nodeOffsets[from] + distance + nodeOffsets[to]
                pairDistances[to][from] = nodeOffsets[to] + distance + nodeOffsets[from]
            }
        }
        val remaining = stops.indices.toMutableSet()
        val order = ArrayList<Int>(stops.size)
        var current = 0
        while (remaining.isNotEmpty()) {
            val next = remaining.minWithOrNull(compareBy<Int> { pairDistances[current][it + 1] }.thenBy { it }) ?: return null
            remaining.remove(next)
            order += next
            current = next + 1
        }
        refineGraphOrder(order, pairDistances)
        val orderedStops = order.map(stops::get)
        val legs = ArrayList<List<StoredCoordinate>>(orderedStops.size)
        var previousNode = startNode
        var previousCoordinate = start
        for (stop in orderedStops) {
            val stopNode = graph.nearestNode(stop.coordinate) ?: return null
            val graphPath = graph.shortestPath(previousNode, stopNode) ?: return null
            val leg = ArrayList<StoredCoordinate>(graphPath.size + 2)
            leg.add(previousCoordinate)
            graphPath.forEach { point -> if (leg.lastOrNull() != point) leg.add(point) }
            if (leg.lastOrNull() != stop.coordinate) leg.add(stop.coordinate)
            legs.add(leg)
            previousNode = stopNode
            previousCoordinate = stop.coordinate
        }
        return PlannedRoute(start, orderedStops, legs, true)
    }

    private fun refineGraphOrder(order: MutableList<Int>, distances: Array<DoubleArray>) {
        if (order.size < 3) return
        fun leg(from: Int, to: Int): Double = distances[from + 1][to + 1]
        var improved = true
        while (improved) {
            improved = false
            for (i in 0 until order.size - 2) {
                for (j in i + 1 until order.size - 1) {
                    val before = leg(if (i == 0) -1 else order[i - 1], order[i]) + leg(order[j], order[j + 1])
                    val after = leg(if (i == 0) -1 else order[i - 1], order[j]) + leg(order[i], order[j + 1])
                    if (after + 0.01 < before) {
                        order.subList(i, j + 1).reverse()
                        improved = true
                    }
                }
            }
        }
    }

    private fun refineTwoOpt(start: StoredCoordinate, route: MutableList<RouteStop>) {
        fun at(index: Int): StoredCoordinate = if (index < 0) start else route[index].coordinate
        var improved = true
        while (improved) {
            improved = false
            for (i in 0 until route.size - 2) {
                for (j in i + 1 until route.size - 1) {
                    val before = metres(at(i), at(i + 1)) + metres(at(j), at(j + 1))
                    val after = metres(at(i), at(j)) + metres(at(i + 1), at(j + 1))
                    if (after + 0.01 < before) {
                        route.subList(i + 1, j + 1).reverse()
                        improved = true
                    }
                }
            }
        }
    }

    fun metres(a: StoredCoordinate, b: StoredCoordinate): Double {
        val latScale = 110_540.0
        val lonScale = 111_320.0 * cos(Math.toRadians((a.latitude + b.latitude) / 2.0))
        return kotlin.math.hypot((a.latitude - b.latitude) * latScale, (a.longitude - b.longitude) * lonScale)
    }

    fun metresSquared(a: StoredCoordinate, b: StoredCoordinate): Double {
        val latScale = 110_540.0
        val lonScale = 111_320.0 * cos(Math.toRadians((a.latitude + b.latitude) / 2.0))
        val lat = (a.latitude - b.latitude) * latScale
        val lon = (a.longitude - b.longitude) * lonScale
        return lat * lat + lon * lon
    }
}
