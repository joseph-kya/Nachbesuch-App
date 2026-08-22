package at.volkshilfe.nachbesuch.data.json

import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.model.CampaignDays
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.util.Base64

@Serializable
data class BackupDoor(
    val id: String,
    val label: String,
    val outcome: VisitOutcome? = null,
    val updatedAt: String? = null,
    // iOS encodes `DoorResult` straight into the backup envelope, so a booked
    // return time arrives here as an ISO string. Dropping it would silently lose
    // every "Später" on a cross-platform restore.
    val revisitAt: String? = null,
    val day2Outcome: VisitOutcome? = null,
    val day2UpdatedAt: String? = null,
    val day2RevisitAt: String? = null
) {
    fun toDomain() = DoorResult(
        id = id.uppercase(),
        label = label,
        outcome = outcome,
        updatedAt = AppJson.epochMillis(updatedAt),
        revisitAt = AppJson.epochMillis(revisitAt),
        day2Outcome = day2Outcome,
        day2UpdatedAt = AppJson.epochMillis(day2UpdatedAt),
        day2RevisitAt = AppJson.epochMillis(day2RevisitAt)
    )
}

@Serializable
data class BackupGebiet(
    val id: String,
    val name: String,
    val districtOrCity: String = "",
    val notes: String = "",
    val isTwoDay: Boolean = false,
    val day1Date: String,
    val day2Date: String? = null,
    val boundaryData: String = "",
    val createdAt: String,
    val updatedAt: String
) {
    fun toDomain(): Gebiet {
        val firstDay = CampaignDays.startOfDay(AppJson.epochMillis(day1Date) ?: 0L)
        val secondDay = if (isTwoDay) {
            AppJson.epochMillis(day2Date)?.let(CampaignDays::startOfDay)
                ?.takeIf { it > firstDay } ?: CampaignDays.addDays(firstDay, 1)
        } else null
        return Gebiet(
        id = id.uppercase(), name = name, districtOrCity = districtOrCity, notes = notes,
        isTwoDay = isTwoDay, day1Date = firstDay,
        day2Date = secondDay,
        boundary = boundaryData.takeIf(String::isNotBlank)?.let { encoded ->
            runCatching {
                AppJson.storage.decodeFromString<List<StoredCoordinate>>(
                    String(Base64.getDecoder().decode(encoded))
                )
            }.getOrDefault(emptyList())
        } ?: emptyList(),
        createdAt = AppJson.epochMillis(createdAt) ?: 0L,
        updatedAt = AppJson.epochMillis(updatedAt) ?: 0L
        )
    }
}

@Serializable
data class BackupHouse(
    val id: String,
    val address: String,
    val note: String = "",
    val latitude: Double,
    val longitude: Double,
    val isApartmentBuilding: Boolean = false,
    val gebietID: String? = null,
    val dayID: String? = null,
    val units: List<BackupDoor> = emptyList(),
    val createdAt: String,
    val updatedAt: String
) {
    fun toDomain(territoryID: String) = House(
        id = id.uppercase(), address = address, note = note,
        latitude = latitude, longitude = longitude,
        isApartmentBuilding = isApartmentBuilding,
        gebietID = territoryID, dayID = territoryID,
        units = units.map(BackupDoor::toDomain).ifEmpty { listOf(DoorResult(label = "Haushalt")) },
        createdAt = AppJson.epochMillis(createdAt) ?: 0L,
        updatedAt = AppJson.epochMillis(updatedAt) ?: 0L
    )
}

@Serializable
data class AppBackup(
    val formatVersion: Int = 2,
    val exportedAt: String,
    val gebiete: List<BackupGebiet> = emptyList(),
    val houses: List<BackupHouse> = emptyList()
)

fun Gebiet.toBackup(): BackupGebiet = BackupGebiet(
    id = id.uppercase(), name = name, districtOrCity = districtOrCity, notes = notes,
    isTwoDay = isTwoDay, day1Date = AppJson.iso(day1Date)!!,
    day2Date = AppJson.iso(day2Date),
    boundaryData = Base64.getEncoder().encodeToString(
        AppJson.storage.encodeToString(boundary).toByteArray()
    ),
    createdAt = AppJson.iso(createdAt)!!, updatedAt = AppJson.iso(updatedAt)!!
)

fun House.toBackup(): BackupHouse = BackupHouse(
    id = id.uppercase(), address = address, note = note,
    latitude = latitude, longitude = longitude,
    isApartmentBuilding = isApartmentBuilding, gebietID = gebietID, dayID = dayID,
    units = units.map {
        BackupDoor(
            id = it.id.uppercase(), label = it.label, outcome = it.outcome,
            updatedAt = AppJson.iso(it.updatedAt), revisitAt = AppJson.iso(it.revisitAt),
            day2Outcome = it.day2Outcome, day2UpdatedAt = AppJson.iso(it.day2UpdatedAt),
            day2RevisitAt = AppJson.iso(it.day2RevisitAt)
        )
    },
    createdAt = AppJson.iso(createdAt)!!, updatedAt = AppJson.iso(updatedAt)!!
)
