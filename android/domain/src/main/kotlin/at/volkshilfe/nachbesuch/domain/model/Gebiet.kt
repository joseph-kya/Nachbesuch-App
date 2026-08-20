package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID

@Serializable
data class Gebiet(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String = "",
    val districtOrCity: String = "",
    val notes: String = "",
    val isTwoDay: Boolean = false,
    val day1Date: Long = CampaignDays.startOfDay(System.currentTimeMillis()),
    val day2Date: Long? = null,
    val boundary: List<StoredCoordinate> = emptyList(),
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis()
) {
    init {
        require(!isTwoDay || (day2Date != null && day2Date > day1Date)) {
            "A two-day Gebiet needs a later second date"
        }
    }

    val displayName: String get() = name.trim().ifEmpty { districtOrCity.trim().ifEmpty { "Gebiet" } }

    fun normalizedForEdit(twoDay: Boolean, requestedDay2: Long?): Gebiet {
        val normalizedDay1 = CampaignDays.startOfDay(day1Date)
        val normalizedDay2 = if (!twoDay) null else {
            val candidate = requestedDay2?.let(CampaignDays::startOfDay)
            candidate?.takeIf { it > normalizedDay1 } ?: CampaignDays.addDays(normalizedDay1, 1)
        }
        return copy(isTwoDay = twoDay, day1Date = normalizedDay1, day2Date = normalizedDay2)
            .touch()
    }

    /** The write day follows today's calendar, not the currently visible picker. */
    fun writeScope(now: Long = System.currentTimeMillis()): DayScope {
        val today = CampaignDays.startOfDay(now)
        return if (isTwoDay && day2Date != null && today >= CampaignDays.startOfDay(day2Date)) {
            DayScope.DAY_2
        } else DayScope.DAY_1
    }

    fun touch(now: Long = System.currentTimeMillis()): Gebiet =
        copy(updatedAt = maxOf(now, updatedAt + 1L))

    fun dateLabel(): String {
        val zone = ZoneId.systemDefault()
        val locale = Locale.forLanguageTag("de-AT")
        val formatter = DateTimeFormatter.ofPattern("d. MMMM yyyy", locale)
        return Instant.ofEpochMilli(day1Date).atZone(zone).toLocalDate().format(formatter)
    }
}
