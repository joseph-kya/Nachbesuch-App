package at.volkshilfe.nachbesuch.data.json

import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.format.DateTimeFormatter

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
        val day2Outcome: VisitOutcome? = null,
        val day2UpdatedAt: Double? = null
    )

    fun encodeStorageDoors(doors: List<DoorResult>): String = storage.encodeToString(
        doors.map { door ->
            StorageDoor(
                id = door.id.uppercase(), label = door.label, outcome = door.outcome,
                updatedAt = door.updatedAt?.let { it / 1000.0 - APPLE_EPOCH_SECONDS },
                day2Outcome = door.day2Outcome,
                day2UpdatedAt = door.day2UpdatedAt?.let { it / 1000.0 - APPLE_EPOCH_SECONDS }
            )
        }
    )

    fun decodeStorageDoors(value: String): List<DoorResult> =
        storage.decodeFromString<List<StorageDoor>>(value).map { door ->
            DoorResult(
                id = door.id.uppercase(), label = door.label, outcome = door.outcome,
                updatedAt = door.updatedAt?.let { ((it + APPLE_EPOCH_SECONDS) * 1000.0).toLong() },
                day2Outcome = door.day2Outcome,
                day2UpdatedAt = door.day2UpdatedAt?.let { ((it + APPLE_EPOCH_SECONDS) * 1000.0).toLong() }
            )
        }

    fun iso(epochMillis: Long?): String? = epochMillis?.let {
        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(it))
    }

    fun epochMillis(iso: String?): Long? = iso?.let { Instant.parse(it).toEpochMilli() }
}
