package at.volkshilfe.nachbesuch.domain.export

import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.list.StreetNameParser
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

data class ExportDoor(
    val label: String,
    val outcome: VisitOutcome,
    val recordedAt: Long?,
    val note: String? = null
)

data class ExportHouse(
    val address: String,
    val doors: List<ExportDoor>,
    val totalDoors: Int,
    val note: String? = null,
    val recordedAt: Long? = doors.mapNotNull(ExportDoor::recordedAt).minOrNull()
)

data class ExportSummary(val counts: Map<VisitOutcome, Int>)

data class ExportDocument(
    val title: String,
    /** Subtitle line: place · date range · scope label (iOS parity). */
    val subtitle: String,
    val legacyDateLabel: String,
    val dayScope: DayScope,
    val houses: List<ExportHouse>,
    val summary: ExportSummary,
    val totalHouses: Int,
    val visitedOnly: Boolean
)

object ExportDocumentBuilder {
    fun build(
        territory: Gebiet,
        houses: Iterable<House>,
        scope: DayScope,
        visitedOnly: Boolean = true,
        includeNotes: Boolean = true
    ): ExportDocument {
        val exported = houses.mapNotNull { house ->
            val doors = house.units.mapNotNull { door ->
                val outcome = door.recordedOutcome(scope) ?: return@mapNotNull null
                ExportDoor(door.label, outcome, door.timestamp(scope), house.note.takeIf { includeNotes })
            }.sortedWith(compareBy<ExportDoor> { it.recordedAt ?: Long.MAX_VALUE }.thenBy { it.label })
            if (visitedOnly && doors.isEmpty()) null else ExportHouse(
                address = house.address,
                doors = doors,
                totalDoors = house.units.size,
                note = house.note.takeIf { includeNotes && it.isNotBlank() }
            )
        }.sortedWith(compareBy<ExportHouse> { it.recordedAt ?: Long.MAX_VALUE }.thenBy { it.address })

        val counts = linkedMapOf<VisitOutcome, Int>()
        exported.asSequence().flatMap { it.doors.asSequence() }.forEach { door ->
            counts[door.outcome] = (counts[door.outcome] ?: 0) + 1
        }
        // Scope wording matches the iOS exporter.
        val scopeLabel = when (scope) {
            DayScope.DAY_1 -> "Tag 1"
            DayScope.DAY_2 -> "Tag 2 · Nachbesuch"
            DayScope.COMBINED -> if (territory.isTwoDay) "Beide Tage" else ""
        }
        val subtitle = listOf(territory.districtOrCity.trim(), territory.formattedDateRange(), scopeLabel)
            .filter(String::isNotBlank)
            .joinToString(" · ")
        return ExportDocument(
            territory.displayName,
            subtitle,
            legacyDateLabel(territory, scope),
            scope,
            exported,
            ExportSummary(counts),
            houses.count(),
            visitedOnly
        )
    }

    private fun legacyDateLabel(territory: Gebiet, scope: DayScope): String {
        val formatter = DateTimeFormatter.ofPattern("dd.MM.yyyy", Locale.forLanguageTag("de-AT"))
        fun format(value: Long) = Instant.ofEpochMilli(value).atZone(ZoneId.systemDefault()).toLocalDate().format(formatter)
        return when (scope) {
            DayScope.DAY_1 -> format(territory.day1Date)
            DayScope.DAY_2 -> format(territory.day2Date ?: territory.day1Date)
            DayScope.COMBINED -> if (territory.isTwoDay && territory.day2Date != null) {
                "${format(territory.day1Date)}–${format(territory.day2Date)}"
            } else format(territory.day1Date)
        }
    }
}

object PlainTextExport {
    fun render(document: ExportDocument): String = buildString {
        appendLine(document.title)
        if (document.subtitle.isNotBlank()) appendLine(document.subtitle)
        appendLine()
        if (document.houses.isEmpty()) {
            appendLine("Keine besuchten Häuser in diesem Zeitraum.")
        } else {
            document.houses.forEach { house ->
                appendLine("· ${house.address}")
                house.doors.forEach { door -> appendLine("    ${door.label}: ${door.outcome.germanTitle}") }
                house.note?.takeIf(String::isNotBlank)?.let { appendLine("    Notiz: $it") }
            }
            if (document.summary.counts.isNotEmpty()) {
                appendLine()
                appendLine(document.summary.counts.entries.joinToString(" · ") { "${it.key.germanTitle}: ${it.value}" })
            }
        }
    }.trimEnd()
}

/** The compact, emoji-based address list used by the original field workflow. */
object LegacyTextExport {
    fun render(document: ExportDocument): String = buildString {
        appendLine(document.legacyDateLabel)
        appendLine()

        val groups = linkedMapOf<String, MutableList<ExportHouse>>()
        document.houses.forEach { house ->
            val street = StreetNameParser.parse(house.address).first
            groups.getOrPut(street) { mutableListOf() } += house
        }
        groups.forEach { (street, houses) ->
            var compact = StringBuilder(street)
            var hasCompactHouse = false
            houses.forEach { house ->
                val number = StreetNameParser.parse(house.address).second ?: house.address
                if (house.totalDoors <= 1) {
                    val symbol = house.doors.firstOrNull()?.outcome?.emoji ?: "○"
                    compact.append(" ").append(number).append(symbol)
                    hasCompactHouse = true
                } else {
                    if (hasCompactHouse) appendLine(compact.toString())
                    appendLine("$street $number:")
                    appendLine(house.doors.joinToString(" ") { door ->
                        "${door.label.removePrefix("Tür ")}${door.outcome.emoji}"
                    })
                    compact = StringBuilder(street)
                    hasCompactHouse = false
                }
            }
            if (hasCompactHouse) appendLine(compact.toString())
        }
    }.trimEnd()
}
