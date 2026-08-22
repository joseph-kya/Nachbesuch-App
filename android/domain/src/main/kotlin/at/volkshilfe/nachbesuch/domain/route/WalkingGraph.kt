package at.volkshilfe.nachbesuch.domain.route

import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import kotlin.math.cos

/**
 * Small, immutable walking graph built from OSM way geometries.
 *
 * It deliberately lives in :domain: the network/cache layer can be replaced without
 * changing route semantics or making the planner depend on Android classes.
 */
data class WalkingWay(val coordinates: List<StoredCoordinate>)

class WalkingGraph private constructor(
    val nodes: List<StoredCoordinate>,
    private val adjacency: Array<List<Edge>>
) {
    private data class Edge(val to: Int, val metres: Double, val path: List<StoredCoordinate>)

    fun nearestNode(coordinate: StoredCoordinate, maxMetres: Double = 120.0): Int? {
        var best: Int? = null
        var bestDistance = maxMetres * maxMetres
        nodes.forEachIndexed { index, candidate ->
            val distance = RoutePlanner.metresSquared(coordinate, candidate)
            if (distance <= bestDistance) {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /**
     * Snaps a stop onto the network like the iOS planner: the nearest point on
     * the nearest street *segment* wins over the nearest junction, so stops in
     * the middle of a long residential way still get a street route instead of
     * aborting the graph plan. Returns the (possibly enlarged) graph plus the
     * node index to route through, or null when nothing lies within [maxMetres].
     */
    fun snapped(coordinate: StoredCoordinate, maxMetres: Double = 120.0): Pair<WalkingGraph, Int>? {
        val nearestVertex = nearestNode(coordinate, maxMetres)
        val vertexMetres = nearestVertex?.let { RoutePlanner.metres(coordinate, nodes[it]) } ?: Double.MAX_VALUE

        // Best perpendicular projection across all undirected segments.
        var bestSegment: Triple<Int, Int, StoredCoordinate>? = null
        var bestSegmentMetres = maxMetres
        for (from in adjacency.indices) {
            val fromPoint = nodes[from]
            adjacency[from].forEach { edge ->
                val to = edge.to
                if (to <= from) return@forEach // one direction per undirected edge
                val projected = projectOntoSegment(coordinate, fromPoint, nodes[to]) ?: return@forEach
                val distance = RoutePlanner.metres(coordinate, projected)
                if (distance < bestSegmentMetres) {
                    bestSegmentMetres = distance
                    bestSegment = Triple(from, to, projected)
                }
            }
        }
        val segment = bestSegment
        // Only pay for a graph split when it clearly beats walking to the junction.
        if (segment == null || vertexMetres <= bestSegmentMetres + 5.0) {
            return nearestVertex?.let { this to it }
        }
        val (from, to, projected) = segment
        val newNodes = nodes + projected
        val newAdjacency = adjacency.map(List<Edge>::toMutableList)
        val halfA = RoutePlanner.metres(nodes[from], projected)
        val halfB = RoutePlanner.metres(projected, nodes[to])
        val fresh = newAdjacency[from]
        fresh.removeAll { it.to == to }
        fresh += Edge(newNodes.lastIndex, halfA, listOf(nodes[from], projected))
        val reverse = newAdjacency[to]
        reverse.removeAll { it.to == from }
        reverse += Edge(newNodes.lastIndex, halfB, listOf(nodes[to], projected))
        (newAdjacency as ArrayList).add(
            mutableListOf(
                Edge(from, halfA, listOf(projected, nodes[from])),
                Edge(to, halfB, listOf(projected, nodes[to]))
            )
        )

        return WalkingGraph(newNodes, newAdjacency.toTypedArray()) to newNodes.lastIndex
    }

    /** Perpendicular foot on the (lat/lon-scaled) segment, or an endpoint when outside. */
    private fun projectOntoSegment(point: StoredCoordinate, a: StoredCoordinate, b: StoredCoordinate): StoredCoordinate? {
        val midLat = (a.latitude + b.latitude) / 2.0
        val latScale = 110_540.0
        val lonScale = 111_320.0 * cos(Math.toRadians(midLat))
        val ax = (a.longitude - point.longitude) * lonScale
        val ay = (a.latitude - point.latitude) * latScale
        val bx = (b.longitude - point.longitude) * lonScale
        val by = (b.latitude - point.latitude) * latScale
        val dx = bx - ax
        val dy = by - ay
        val lengthSquared = dx * dx + dy * dy
        if (lengthSquared <= 0.0) return null
        val t = ((-(ax * dx + ay * dy)) / lengthSquared).coerceIn(0.0, 1.0)
        return StoredCoordinate(
            latitude = point.latitude + (ay + t * dy) / latScale,
            longitude = point.longitude + (ax + t * dx) / lonScale
        )
    }

    fun coordinate(node: Int): StoredCoordinate? = nodes.getOrNull(node)

    fun shortestDistance(from: Int, to: Int): Double? = shortest(from, to, includePath = false)?.first

    fun shortestPath(from: Int, to: Int): List<StoredCoordinate>? =
        shortest(from, to, includePath = true)?.second

    private fun shortest(
        from: Int,
        to: Int,
        includePath: Boolean
    ): Pair<Double, List<StoredCoordinate>>? {
        if (from !in nodes.indices || to !in nodes.indices) return null
        if (from == to) return 0.0 to listOf(nodes[from])
        val distances = DoubleArray(nodes.size) { Double.POSITIVE_INFINITY }
        val previousNode = IntArray(nodes.size) { -1 }
        val previousEdge = arrayOfNulls<Edge>(nodes.size)
        val queue = MinHeap()
        distances[from] = 0.0
        queue.push(from, 0.0)
        while (queue.isNotEmpty()) {
            val (current, distance) = queue.pop()
            if (distance > distances[current]) continue
            if (current == to) break
            adjacency[current].forEach { edge ->
                val candidate = distance + edge.metres
                if (candidate < distances[edge.to]) {
                    distances[edge.to] = candidate
                    previousNode[edge.to] = current
                    previousEdge[edge.to] = edge
                    queue.push(edge.to, candidate)
                }
            }
        }
        val total = distances[to]
        if (!total.isFinite()) return null
        if (!includePath) return total to emptyList()
        val edgeChain = ArrayList<Edge>()
        var current = to
        while (current != from) {
            val edge = previousEdge[current] ?: return null
            edgeChain += edge
            current = previousNode[current]
            if (current < 0) return null
        }
        val points = ArrayList<StoredCoordinate>(edgeChain.size * 2 + 1)
        points += nodes[from]
        edgeChain.asReversed().forEach { edge ->
            // The edge path includes both endpoints. Avoid duplicate vertices so the
            // rendered polyline stays small on long residential ways.
            edge.path.forEach { point -> if (points.lastOrNull() != point) points += point }
        }
        return total to points
    }

    private class MinHeap {
        private val values = ArrayList<Pair<Int, Double>>()
        fun isNotEmpty() = values.isNotEmpty()
        fun push(node: Int, distance: Double) {
            values += node to distance
            var index = values.lastIndex
            while (index > 0) {
                val parent = (index - 1) / 2
                if (values[parent].second <= values[index].second) break
                values.swap(parent, index)
                index = parent
            }
        }
        fun pop(): Pair<Int, Double> {
            val result = values[0]
            val last = values.removeAt(values.lastIndex)
            if (values.isNotEmpty()) {
                values[0] = last
                var index = 0
                while (true) {
                    val left = index * 2 + 1
                    val right = left + 1
                    var smallest = index
                    if (left < values.size && values[left].second < values[smallest].second) smallest = left
                    if (right < values.size && values[right].second < values[smallest].second) smallest = right
                    if (smallest == index) break
                    values.swap(index, smallest)
                    index = smallest
                }
            }
            return result
        }
        private fun <T> MutableList<T>.swap(a: Int, b: Int) {
            val value = this[a]
            this[a] = this[b]
            this[b] = value
        }
    }

    companion object {
        fun fromWays(ways: Iterable<WalkingWay>): WalkingGraph? {
            val nodeIndex = LinkedHashMap<NodeKey, Int>()
            val nodes = ArrayList<StoredCoordinate>()
            val edges = ArrayList<MutableList<Edge>>()
            fun indexOf(coordinate: StoredCoordinate): Int {
                val key = NodeKey(coordinate)
                return nodeIndex.getOrPut(key) {
                    nodes.add(coordinate)
                    edges.add(ArrayList())
                    nodes.lastIndex
                }
            }
            var edgeCount = 0
            ways.forEach { way ->
                val clean = way.coordinates.filter(StoredCoordinate::isPlausible)
                clean.zipWithNext().forEach { (a, b) ->
                    val from = indexOf(a)
                    val to = indexOf(b)
                    if (from == to) return@forEach
                    val metres = RoutePlanner.metres(a, b)
                    if (!metres.isFinite() || metres <= 0.0) return@forEach
                    val path = listOf(nodes[from], nodes[to])
                    edges[from] += Edge(to, metres, path)
                    edges[to] += Edge(from, metres, path.asReversed())
                    edgeCount++
                }
            }
            if (nodes.size < 2 || edgeCount == 0) return null
            return WalkingGraph(nodes, edges.map { it.toList() }.toTypedArray())
        }

        private data class NodeKey(val latitudeMicros: Long, val longitudeMicros: Long) {
            constructor(coordinate: StoredCoordinate) : this(
                (coordinate.latitude * 1_000_000.0).roundToLong(),
                (coordinate.longitude * 1_000_000.0).roundToLong()
            )
        }
    }
}

private fun Double.roundToLong(): Long = kotlin.math.round(this).toLong()
