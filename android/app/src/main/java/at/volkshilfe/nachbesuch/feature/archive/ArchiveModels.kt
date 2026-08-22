package at.volkshilfe.nachbesuch.feature.archive

import at.volkshilfe.nachbesuch.domain.stats.TerritorySummary
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** The archive's own filters, mirroring the iOS `ArchiveFilter`. */
enum class ArchiveFilter(val id: String, val title: String) {
    ALL("all", "Alle"),
    OPEN("open", "Mit offenen Türen");

    fun matches(summary: TerritorySummary): Boolean = when (this) {
        ALL -> true
        OPEN -> summary.bilanz.overall.open > 0
    }

    companion object {
        fun from(id: String?): ArchiveFilter = entries.firstOrNull { it.id == id } ?: ALL
    }
}

/** Territories grouped under the campaign day they are assigned to. */
data class DaySection(val id: String, val title: String, val items: List<TerritorySummary>)

object ArchiveSections {

    /**
     * Groups territories by campaign day, newest first.
     *
     * A two-day territory appears under both of its days — the same territory is
     * genuinely on the schedule twice, and hiding it from the second day is what
     * made day-2 work hard to find on the old screen.
     */
    fun sections(results: List<TerritorySummary>, isSearching: Boolean, now: Long = System.currentTimeMillis()): List<DaySection> {
        if (isSearching) {
            return if (results.isEmpty()) emptyList()
            else listOf(DaySection("results", "Beste Treffer", results))
        }
        val grouped = linkedMapOf<LocalDate, MutableList<TerritorySummary>>()
        results.forEach { summary ->
            assignedDates(summary).forEach { date ->
                grouped.getOrPut(date) { mutableListOf() }.add(summary)
            }
        }
        return grouped.entries
            .sortedByDescending { it.key }
            .map { (date, items) -> DaySection("day-$date", title(date, now), items) }
    }

    private fun assignedDates(summary: TerritorySummary): List<LocalDate> {
        val zone = ZoneId.systemDefault()
        val day1 = Instant.ofEpochMilli(summary.territory.day1Date).atZone(zone).toLocalDate()
        val day2 = summary.territory.day2Date
            ?.takeIf { summary.territory.isTwoDay }
            ?.let { Instant.ofEpochMilli(it).atZone(zone).toLocalDate() }
        return listOfNotNull(day1, day2).distinct()
    }

    private fun title(date: LocalDate, now: Long): String {
        val today = Instant.ofEpochMilli(now).atZone(ZoneId.systemDefault()).toLocalDate()
        return when (date) {
            today -> "Heute"
            today.minusDays(1) -> "Gestern"
            today.plusDays(1) -> "Morgen"
            else -> date.format(DateTimeFormatter.ofPattern("EEEE, d. MMMM yyyy", Locale.forLanguageTag("de-AT")))
        }
    }
}
