package at.volkshilfe.nachbesuch.domain.model

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

object CampaignDays {
    /** Existing iOS stores use the device calendar's start of day; keep that shape. */
    fun startOfDay(epochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): Long =
        Instant.ofEpochMilli(epochMillis).atZone(zone).toLocalDate()
            .atStartOfDay(zone).toInstant().toEpochMilli()

    fun epochDay(date: LocalDate, zone: ZoneId = ZoneId.systemDefault()): Long =
        date.atStartOfDay(zone).toInstant().toEpochMilli()

    fun addDays(epochMillis: Long, days: Long, zone: ZoneId = ZoneId.systemDefault()): Long =
        Instant.ofEpochMilli(epochMillis).atZone(zone).toLocalDate().plusDays(days)
            .atStartOfDay(zone).toInstant().toEpochMilli()
}
