package at.volkshilfe.nachbesuch.data.importing

import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.route.RoutePlanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.text.Normalizer
import kotlin.coroutines.coroutineContext
import kotlin.math.cos
import kotlin.math.floor

data class ImportedAreaAddress(
    val id: String,
    val address: String,
    val coordinate: StoredCoordinate
)

data class AreaImportSelection(
    val addresses: List<ImportedAreaAddress>,
    val skippedDuplicates: Int
)

sealed class AreaImportResult {
    data class Ready(val addresses: List<ImportedAreaAddress>) : AreaImportResult()
    data class Failed(val message: String) : AreaImportResult()
}

/** OSM address importer matching the shipping iOS polygon query and safety limits. */
class AreaHouseImportService {
    private val json = Json { ignoreUnknownKeys = true }
    private val mirrors = listOf(
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://lz4.overpass-api.de/api/interpreter"
    )

    suspend fun fetch(boundary: List<StoredCoordinate>): AreaImportResult = withContext(Dispatchers.IO) {
        if (boundary.size < 3 || boundary.any { !it.isPlausible }) {
            return@withContext AreaImportResult.Failed("Bitte zeichne zuerst ein Gebiet mit mindestens drei Punkten ein.")
        }
        if (areaExtentKilometres(boundary) > 8.0) {
            return@withContext AreaImportResult.Failed("Das Gebiet ist für einen zuverlässigen Sammelimport zu groß. Teile es bitte in Abschnitte unter acht Kilometern.")
        }
        val polygon = boundary.joinToString(" ") { "%.7f %.7f".format(java.util.Locale.US, it.latitude, it.longitude) }
        val query = """
            [out:json][timeout:35];
            nwr["addr:housenumber"](poly:"$polygon");
            out center tags qt;
        """.trimIndent()
        var lastMessage = "Die Adresssuche konnte keine gültige Antwort verarbeiten."
        for (mirror in mirrors) {
            coroutineContext.ensureActive()
            val result = runCatching { request(mirror, query) }
            val payload = result.getOrNull()
            if (payload != null) {
                return@withContext runCatching { decode(payload, boundary) }
                    .fold(
                        onSuccess = { AreaImportResult.Ready(it) },
                        onFailure = { AreaImportResult.Failed(it.message ?: lastMessage) }
                    )
            }
            lastMessage = result.exceptionOrNull()?.message ?: lastMessage
        }
        AreaImportResult.Failed(lastMessage)
    }

    fun excludingExisting(addresses: List<ImportedAreaAddress>, houses: List<House>): AreaImportSelection {
        val existingAddresses = houses.mapTo(HashSet()) { normalize(it.address) }
        val cellSize = 0.0002
        val buckets = houses.groupBy { Cell(it.latitude, it.longitude, cellSize) }
        var skipped = 0
        val filtered = addresses.filter { candidate ->
            val duplicate = normalize(candidate.address) in existingAddresses || nearby(candidate, buckets, cellSize)
            if (duplicate) skipped++
            !duplicate
        }
        return AreaImportSelection(filtered, skipped)
    }

    private fun request(endpoint: String, query: String): String {
        val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 14_000
            readTimeout = 18_000
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
            setRequestProperty("User-Agent", "Nachbesuch-Android/1.0")
        }
        return try {
            val body = "data=" + URLEncoder.encode(query, Charsets.UTF_8.name())
            connection.outputStream.use { it.write(body.toByteArray()) }
            when (connection.responseCode) {
                in 200..299 -> connection.inputStream.bufferedReader().use { it.readText() }
                429 -> error("Die Adresssuche ist gerade ausgelastet. Bitte versuche es in einer Minute erneut.")
                504 -> error("Die Adresssuche hat zu lange gedauert. Ein kleineres Gebiet funktioniert meist zuverlässiger.")
                else -> error("Die Adresssuche meldet einen Serverfehler (HTTP ${connection.responseCode}).")
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun decode(raw: String, boundary: List<StoredCoordinate>): List<ImportedAreaAddress> {
        val seen = HashSet<String>()
        val result = ArrayList<ImportedAreaAddress>()
        val elements = json.parseToJsonElement(raw).jsonObject["elements"]?.jsonArray.orEmpty()
        for (element in elements) {
            val value = element.jsonObject
            val tags = value["tags"]?.jsonObject ?: continue
            val center = value["center"]?.jsonObject
            val latitude = value["lat"]?.jsonPrimitive?.content?.toDoubleOrNull()
                ?: center?.get("lat")?.jsonPrimitive?.content?.toDoubleOrNull() ?: continue
            val longitude = value["lon"]?.jsonPrimitive?.content?.toDoubleOrNull()
                ?: center?.get("lon")?.jsonPrimitive?.content?.toDoubleOrNull() ?: continue
            val coordinate = StoredCoordinate(latitude, longitude)
            if (!coordinate.isPlausible || !inside(coordinate, boundary)) continue
            val number = tags["addr:housenumber"]?.jsonPrimitive?.content?.trim().orEmpty()
            if (number.isEmpty()) continue
            val street = sequenceOf("addr:street", "addr:place")
                .mapNotNull { tags[it]?.jsonPrimitive?.content?.trim() }
                .firstOrNull { it.isNotEmpty() }
            val line = street?.let { "$it $number" } ?: "Hausnummer $number"
            val city = sequenceOf("addr:city", "addr:town", "addr:village", "addr:municipality")
                .mapNotNull { tags[it]?.jsonPrimitive?.content?.trim() }
                .firstOrNull { it.isNotEmpty() }
            val locality = listOfNotNull(tags["addr:postcode"]?.jsonPrimitive?.content?.trim(), city)
                .filter { it.isNotEmpty() }.joinToString(" ")
            val address = if (locality.isEmpty()) line else "$line, $locality"
            if (!seen.add(normalize(address))) continue
            result += ImportedAreaAddress(
                id = "${value["type"]?.jsonPrimitive?.content}-${value["id"]?.jsonPrimitive?.content}",
                address = address,
                coordinate = coordinate
            )
            if (result.size > 5_000) error("Im Gebiet liegen mehr als 5000 Adressen. Teile es bitte in kleinere Runden.")
        }
        return result.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.address })
    }

    private fun inside(point: StoredCoordinate, polygon: List<StoredCoordinate>): Boolean {
        var result = false
        var previous = polygon.lastIndex
        for (current in polygon.indices) {
            val a = polygon[current]
            val b = polygon[previous]
            if ((a.latitude > point.latitude) != (b.latitude > point.latitude)) {
                val crossing = (b.longitude - a.longitude) * (point.latitude - a.latitude) /
                    (b.latitude - a.latitude) + a.longitude
                if (point.longitude < crossing) result = !result
            }
            previous = current
        }
        return result
    }

    private fun areaExtentKilometres(boundary: List<StoredCoordinate>): Double {
        val lat = (boundary.maxOf { it.latitude } - boundary.minOf { it.latitude }) * 111.0
        val mean = (boundary.maxOf { it.latitude } + boundary.minOf { it.latitude }) / 2.0
        val lon = (boundary.maxOf { it.longitude } - boundary.minOf { it.longitude }) * 111.0 * cos(Math.toRadians(mean))
        return maxOf(lat, lon)
    }

    private fun nearby(candidate: ImportedAreaAddress, buckets: Map<Cell, List<House>>, cellSize: Double): Boolean {
        val cell = Cell(candidate.coordinate.latitude, candidate.coordinate.longitude, cellSize)
        for (lat in -1..1) for (lon in -1..1) {
            if (buckets[Cell(cell.latitudeIndex + lat, cell.longitudeIndex + lon)]?.any {
                    RoutePlanner.metres(candidate.coordinate, StoredCoordinate(it.latitude, it.longitude)) < 12.0
                } == true) return true
        }
        return false
    }

    private fun normalize(value: String): String = Normalizer.normalize(value.lowercase(), Normalizer.Form.NFKD)
        .replace(Regex("\\p{M}+"), "")
        .replace(Regex("[^a-z0-9]+"), " ")
        .trim()

    private data class Cell(val latitudeIndex: Int, val longitudeIndex: Int) {
        constructor(latitude: Double, longitude: Double, size: Double) : this(
            floor(latitude / size).toInt(), floor(longitude / size).toInt()
        )
    }
}
