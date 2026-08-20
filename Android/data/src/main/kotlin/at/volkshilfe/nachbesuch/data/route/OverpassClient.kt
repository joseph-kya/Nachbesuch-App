package at.volkshilfe.nachbesuch.data.route

import android.content.Context
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.route.WalkingGraph
import at.volkshilfe.nachbesuch.domain.route.WalkingWay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.Locale
import kotlin.coroutines.coroutineContext

data class NetworkBounds(
    val south: Double,
    val west: Double,
    val north: Double,
    val east: Double
) {
    val latitudeSpan: Double get() = north - south
    val longitudeSpan: Double get() = east - west
    val cacheKey: String get() = "%.5f_%.5f_%.5f_%.5f".format(Locale.US, south, west, north, east)

    fun padded(amount: Double = 0.0025): NetworkBounds = copy(
        south = south - amount,
        west = west - amount,
        north = north + amount,
        east = east + amount
    )

    companion object {
        fun from(points: Iterable<StoredCoordinate>): NetworkBounds? {
            val valid = points.filter(StoredCoordinate::isPlausible).toList()
            if (valid.isEmpty()) return null
            return NetworkBounds(
                south = valid.minOf { it.latitude },
                west = valid.minOf { it.longitude },
                north = valid.maxOf { it.latitude },
                east = valid.maxOf { it.longitude }
            )
        }
    }
}

sealed class WalkingNetworkResult {
    data class Ready(val graph: WalkingGraph) : WalkingNetworkResult()
    data object Unavailable : WalkingNetworkResult()
    data object AreaTooLarge : WalkingNetworkResult()
}

/** Fetches and caches only the small OSM walking graph needed by a territory. */
class OverpassClient(
    context: Context,
    private val appVersion: String = "1.0"
) {
    private val cacheDirectory = File(context.cacheDir, "walking-network").apply { mkdirs() }
    private val parser = Json { ignoreUnknownKeys = true }
    private val mirrors = listOf(
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://lz4.overpass-api.de/api/interpreter"
    )

    suspend fun load(points: Iterable<StoredCoordinate>): WalkingNetworkResult = withContext(Dispatchers.IO) {
        val rawBounds = NetworkBounds.from(points) ?: return@withContext WalkingNetworkResult.Unavailable
        if (rawBounds.latitudeSpan > 0.12 || rawBounds.longitudeSpan > 0.16) {
            return@withContext WalkingNetworkResult.AreaTooLarge
        }
        val bounds = rawBounds.padded()
        val cacheFile = File(cacheDirectory, "${sha256(bounds.cacheKey)}.json")
        val cached = cacheFile.takeIf { it.isFile && System.currentTimeMillis() - it.lastModified() < CACHE_TTL }
            ?.runCatching { readText() }?.getOrNull()
        val raw = cached ?: fetch(bounds)?.also { payload ->
            runCatching {
                val temporary = File(cacheDirectory, "${cacheFile.name}.tmp")
                temporary.writeText(payload)
                if (!temporary.renameTo(cacheFile)) temporary.delete()
            }
        }
        coroutineContext.ensureActive()
        raw?.let { parse(it) } ?: WalkingNetworkResult.Unavailable
    }

    private suspend fun fetch(bounds: NetworkBounds): String? {
        val query = """
            [out:json][timeout:40];
            way["highway"~"^(footway|path|pedestrian|steps|living_street|residential|unclassified|service|tertiary|tertiary_link|secondary|secondary_link|primary|primary_link|track|cycleway|road)$"]["foot"!="no"]["access"!="private"](${bounds.south},${bounds.west},${bounds.north},${bounds.east});
            out geom qt;
        """.trimIndent()
        val deadline = System.nanoTime() + REQUEST_DEADLINE_NANOS
        for (mirror in mirrors) {
            if (System.nanoTime() >= deadline) break
            val remainingMillis = ((deadline - System.nanoTime()) / 1_000_000L).coerceAtLeast(1L)
            val timeout = remainingMillis.coerceAtMost(18_000L).toInt()
            runCatching {
                val connection = (URL(mirror).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    doOutput = true
                    connectTimeout = timeout
                    readTimeout = timeout
                    setRequestProperty("User-Agent", "Nachbesuch-Android/$appVersion")
                    setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
                }
                try {
                    val body = "data=" + URLEncoder.encode(query, Charsets.UTF_8.name())
                    connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                    if (connection.responseCode in 200..299) {
                        return connection.inputStream.bufferedReader().use { it.readText() }
                    }
                } finally {
                    connection.disconnect()
                }
            }
            if (!coroutineContext.isActive) return null
        }
        return null
    }

    private fun parse(raw: String): WalkingNetworkResult {
        val ways = runCatching {
            parser.parseToJsonElement(raw).jsonObject["elements"]?.jsonArray.orEmpty().mapNotNull { element ->
                val json = element.jsonObject
                if (json["type"]?.jsonPrimitive?.content != "way") return@mapNotNull null
                val points = json["geometry"]?.jsonArray.orEmpty().mapNotNull { point ->
                    val value = point.jsonObject
                    val latitude = value["lat"]?.jsonPrimitive?.content?.toDoubleOrNull()
                    val longitude = value["lon"]?.jsonPrimitive?.content?.toDoubleOrNull()
                    if (latitude != null && longitude != null) StoredCoordinate(latitude, longitude) else null
                }
                WalkingWay(points).takeIf { it.coordinates.size >= 2 }
            }
        }.getOrNull() ?: return WalkingNetworkResult.Unavailable
        return WalkingGraph.fromWays(ways)?.let(WalkingNetworkResult::Ready) ?: WalkingNetworkResult.Unavailable
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { byte -> "%02x".format(byte) }

    private companion object {
        const val CACHE_TTL = 30L * 24L * 60L * 60L * 1_000L
        const val REQUEST_DEADLINE_NANOS = 40L * 1_000_000_000L
    }
}
