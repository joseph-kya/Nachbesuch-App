package at.volkshilfe.nachbesuch.data.local

import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.data.json.AppJson
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

fun GebietEntity.toDomain(): Gebiet? = runCatching {
    val normalizedDay1 = at.volkshilfe.nachbesuch.domain.model.CampaignDays.startOfDay(day1Date)
    val normalizedDay2 = if (isTwoDay) {
        val candidate = day2Date?.let(at.volkshilfe.nachbesuch.domain.model.CampaignDays::startOfDay)
        candidate?.takeIf { it > normalizedDay1 }
            ?: at.volkshilfe.nachbesuch.domain.model.CampaignDays.addDays(normalizedDay1, 1)
    } else null
    Gebiet(id, name, districtOrCity, notes, isTwoDay, normalizedDay1, normalizedDay2,
        AppJson.storage.decodeFromString<List<StoredCoordinate>>(boundaryData), createdAt, updatedAt)
}.getOrNull()

fun Gebiet.toEntity(): GebietEntity = GebietEntity(
    id, name, districtOrCity, notes, isTwoDay, day1Date, day2Date,
    AppJson.storage.encodeToString(boundary), createdAt, updatedAt
)

fun HouseEntity.toDomain(): House? = runCatching {
    val decoded = runCatching { AppJson.decodeStorageDoors(unitsData) }
    val units = decoded.getOrElse { emptyList() }
    House(
        id, address, note, latitude, longitude, isApartmentBuilding,
        gebietID ?: dayID.orEmpty(), dayID ?: gebietID.orEmpty(), units,
        createdAt, updatedAt, isDamaged = decoded.isFailure
    )
}.getOrNull()

fun House.toEntity(): HouseEntity = HouseEntity(
    id, address, note, latitude, longitude, isApartmentBuilding, gebietID, dayID,
    AppJson.encodeStorageDoors(units), createdAt, updatedAt
)
