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
