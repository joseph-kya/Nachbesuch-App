package at.volkshilfe.nachbesuch.domain.export

import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome

data class ExportDoor(
    val label: String,
    val outcome: VisitOutcome,
    val recordedAt: Long?,
    val note: String? = null
)

data class ExportHouse(
    val address: String,
    val doors: List<ExportDoor>,
    val note: String? = null,
    val recordedAt: Long? = doors.mapNotNull(ExportDoor::recordedAt).minOrNull()
)

data class ExportSummary(val counts: Map<VisitOutcome, Int>)

data class ExportDocument(
    val title: String,
    val dayScope: DayScope,
    val houses: List<ExportHouse>,
    val summary: ExportSummary
)

object ExportDocumentBuilder {
    fun build(
        territory: Gebiet,
        houses: Iterable<House>,
        scope: DayScope,
        visitedOnly: Boolean = true,
        includeNotes: Boolean = false
    ): ExportDocument {
        val exported = houses.mapNotNull { house ->
            val doors = house.units.mapNotNull { door ->
                val outcome = door.recordedOutcome(scope) ?: return@mapNotNull null
                ExportDoor(door.label, outcome, door.timestamp(scope), house.note.takeIf { includeNotes })
            }.sortedWith(compareBy<ExportDoor> { it.recordedAt ?: Long.MAX_VALUE }.thenBy { it.label })
            if (visitedOnly && doors.isEmpty()) null else ExportHouse(
                address = house.address,
                doors = doors,
                note = house.note.takeIf { includeNotes && it.isNotBlank() }
            )
        }.sortedWith(compareBy<ExportHouse> { it.recordedAt ?: Long.MAX_VALUE }.thenBy { it.address })

        val counts = linkedMapOf<VisitOutcome, Int>()
        exported.asSequence().flatMap { it.doors.asSequence() }.forEach { door ->
            counts[door.outcome] = (counts[door.outcome] ?: 0) + 1
        }
        val dayLabel = when (scope) {
            DayScope.DAY_1 -> "Tag 1"
            DayScope.DAY_2 -> "Tag 2"
            DayScope.COMBINED -> "Gesamt"
        }
        return ExportDocument("${territory.displayName} · $dayLabel", scope, exported, ExportSummary(counts))
    }
}

object PlainTextExport {
    fun render(document: ExportDocument): String = buildString {
        appendLine(document.title)
        appendLine()
        document.houses.forEach { house ->
            appendLine(house.address)
            house.doors.forEach { door -> appendLine("  ${door.label}: ${door.outcome.germanTitle}") }
            house.note?.takeIf(String::isNotBlank)?.let { appendLine("  Notiz: $it") }
            appendLine()
        }
        if (document.summary.counts.isNotEmpty()) {
            appendLine("Zusammenfassung")
            document.summary.counts.forEach { (outcome, count) -> appendLine("${outcome.germanTitle}: $count") }
        }
    }.trimEnd()
}
