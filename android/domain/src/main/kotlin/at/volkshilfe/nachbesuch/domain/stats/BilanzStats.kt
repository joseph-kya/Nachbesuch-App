package at.volkshilfe.nachbesuch.domain.stats

import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.OutcomeTally
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome

/**
 * Day-comparison statistics, ported from the iOS BilanzStatsEngine.
 *
 * Strict day accessors: day 1 counts only what was recorded on day 1,
 * day 2 only what was recorded on day 2 — no fallback in either direction.
 */
data class BilanzSnapshot(
    val houseCount: Int,
    val overall: OutcomeTally,
    val day1: OutcomeTally,
    val day2: OutcomeTally,
    /** Doors still waiting for their second visit ("not home" on day 1, no day-2 result). */
    val pendingRevisits: Int,
    /** All doors that ever need a revisit: unanswered or "not home" on day 1. */
    val revisitTargets: Int
) {
    /** Share of revisit targets that received a day-2 result. */
    val day2Progress: Double get() = if (revisitTargets == 0) 0.0 else day2.completed.toDouble() / revisitTargets
}

object BilanzStats {
    fun snapshot(houses: List<House>): BilanzSnapshot {
        var overall = OutcomeTally()
        var day1 = OutcomeTally()
        var day2 = OutcomeTally()
        var pendingRevisits = 0
        var revisitTargets = 0
        for (house in houses) {
            overall += house.tally(DayScope.COMBINED)
            day1 += house.tally(DayScope.DAY_1)
            day2 += house.tally(DayScope.DAY_2)
            for (door in house.units) {
                if (door.isPendingRevisit) pendingRevisits++
                // A revisit target is any door never answered on day 1, or answered
                // with something that leaves it open — "niemand da" or "später".
                if (door.outcome == null || door.outcome.isOpenWork) revisitTargets++
            }
        }
        return BilanzSnapshot(houses.size, overall, day1, day2, pendingRevisits, revisitTargets)
    }

    /** Per-territory roll-up for the archive screen. */
    fun snapshotFor(gebietID: String, allHouses: List<House>): BilanzSnapshot =
        snapshot(allHouses.filter { it.gebietID == gebietID })

    fun doorCounts(units: List<DoorResult>, scope: DayScope): Map<VisitOutcome, Int> {
        val counts = linkedMapOf<VisitOutcome, Int>()
        units.forEach { door ->
            val outcome = door.displayOutcome(scope) ?: return@forEach
            counts[outcome] = (counts[outcome] ?: 0) + 1
        }
        return counts
    }
}

/** Everything the archive row needs about one territory, precomputed for search + display. */
data class TerritorySummary(
    val territory: Gebiet,
    val houseCount: Int,
    val bilanz: BilanzSnapshot,
    val searchText: String
)

object TerritorySummarizer {
    fun summarize(gebiete: List<Gebiet>, allHouses: List<House>): List<TerritorySummary> = gebiete.map { territory ->
        val houses = allHouses.filter { it.gebietID == territory.id }
        val bilanz = BilanzStats.snapshot(houses)
        val dateText = listOf(territory.dateLabel(), territory.formattedDateRange()).distinct().joinToString(" ")
        TerritorySummary(
            territory = territory,
            houseCount = houses.size,
            bilanz = bilanz,
            searchText = listOf(territory.displayName, territory.districtOrCity, dateText).joinToString(" ")
        )
    }
}
