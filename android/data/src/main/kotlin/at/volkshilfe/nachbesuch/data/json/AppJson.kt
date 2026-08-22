package at.volkshilfe.nachbesuch.data.json

import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/** The two iOS date formats are intentionally separate. */
object AppJson {
    val storage = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    val backup = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = true }

    private const val APPLE_EPOCH_SECONDS = 978_307_200.0

    @Serializable
    private data class StorageDoor(
        val id: String,
        val label: String,
        val outcome: VisitOutcome? = null,
        val updatedAt: Double? = null,
        val revisitAt: Double? = null,
        val day2Outcome: VisitOutcome? = null,
        val day2UpdatedAt: Double? = null,
        val day2RevisitAt: Double? = null
    )

    fun encodeStorageDoors(doors: List<DoorResult>): String = storage.encodeToString(
        doors.map { door ->
            StorageDoor(
                id = door.id.uppercase(), label = door.label, outcome = door.outcome,
                updatedAt = door.updatedAt?.let { it / 1000.0 - APPLE_EPOCH_SECONDS },
                revisitAt = door.revisitAt?.let { it / 1000.0 - APPLE_EPOCH_SECONDS },
                day2Outcome = door.day2Outcome,
                day2UpdatedAt = door.day2UpdatedAt?.let { it / 1000.0 - APPLE_EPOCH_SECONDS },
                day2RevisitAt = door.day2RevisitAt?.let { it / 1000.0 - APPLE_EPOCH_SECONDS }
            )
        }
    )

    fun decodeStorageDoors(value: String): List<DoorResult> =
        storage.decodeFromString<List<StorageDoor>>(value).map { door ->
            DoorResult(
                id = door.id.uppercase(), label = door.label, outcome = door.outcome,
                updatedAt = door.updatedAt?.let { ((it + APPLE_EPOCH_SECONDS) * 1000.0).toLong() },
                revisitAt = door.revisitAt?.let { ((it + APPLE_EPOCH_SECONDS) * 1000.0).toLong() },
                day2Outcome = door.day2Outcome,
                day2UpdatedAt = door.day2UpdatedAt?.let { ((it + APPLE_EPOCH_SECONDS) * 1000.0).toLong() },
                day2RevisitAt = door.day2RevisitAt?.let { ((it + APPLE_EPOCH_SECONDS) * 1000.0).toLong() }
            )
        }

    /**
     * Emits whole-second ISO-8601 like Apple's `.iso8601` date strategy.
     * Fractional seconds (which Instant.toString() produces for any millis != 0)
     * are rejected by the iOS decoder, so truncating here is what keeps an
     * Android-written backup importable on iOS at all.
     */
    fun iso(epochMillis: Long?): String? = epochMillis?.let {
        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(it).truncatedTo(ChronoUnit.SECONDS))
    }

    /** Whole-second "now", used so exportedAt matches the same constraint. */
    fun isoNow(): String = iso(System.currentTimeMillis()).orEmpty()

    fun epochMillis(iso: String?): Long? = iso?.let { value ->
        // Tolerate fractional seconds and offsets that Instant.parse rejects,
        // mirroring iOS's lenient re-reads of old files. Garbage yields null.
        runCatching { Instant.parse(value).toEpochMilli() }
            .recoverCatching { OffsetDateTime.parse(value).toInstant().toEpochMilli() }
            .getOrNull()
    }
}
