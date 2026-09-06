package at.volkshilfe.nachbesuch.domain

import at.volkshilfe.nachbesuch.domain.archive.ArchiveSearchEngine
import at.volkshilfe.nachbesuch.domain.model.CampaignDays
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.stats.BilanzStats
import at.volkshilfe.nachbesuch.domain.stats.TerritorySummarizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BilanzAndSearchTest {

    private fun house(
        address: String,
        doors: List<DoorResult>,
        gebietID: String = "G1"
    ) = House(address = address, latitude = 48.2, longitude = 16.3, gebietID = gebietID, units = doors)

    @Test fun bilanzCountsDaysStrictly() {
        val settled = DoorResult("A", "Tür 1", VisitOutcome.JOINED, 1L)
        val revisit = DoorResult("B", "Tür 2", VisitOutcome.NOT_HOME, 1L)
        val untouched = DoorResult("C", "Tür 3", null, null)
        val snapshot = BilanzStats.snapshot(
            listOf(house("Hauptstraße 1", listOf(settled, revisit, untouched)))
        )
        assertEquals(3, snapshot.overall.unitCount)
        assertEquals(1, snapshot.overall.joined)
        assertEquals(1, snapshot.pendingRevisits)
        // Revisit targets: every door without a day-1 result or answered "not home".
        assertEquals(2, snapshot.revisitTargets)
        // Strict day tallies: day 1 shows the join AND the recorded "not home",
        // day 2 only what was written on day 2 (nothing yet).
        assertEquals(2, snapshot.day1.completed)
        assertEquals(0, snapshot.day2.completed)
        assertEquals(0.0, snapshot.day2Progress, 1e-9)
    }

    @Test fun territorySummariesRollUpPerTerritory() {
        val first = Gebiet(id = "G1", name = "Ottakring")
        val second = Gebiet(id = "G2", name = "Favoriten")
        val summaries = TerritorySummarizer.summarize(
            listOf(first, second),
            listOf(house("A", listOf(DoorResult("D", "Haushalt")), gebietID = "G1"))
        )
        assertEquals(2, summaries.size)
        assertEquals(1, summaries.first().houseCount)
        assertEquals(0, summaries.last().houseCount)
    }

    private fun summaryFor(name: String): at.volkshilfe.nachbesuch.domain.stats.TerritorySummary =
        TerritorySummarizer.summarize(listOf(Gebiet(id = "G", name = name)), emptyList()).first()

    @Test fun keywordSearchMatchesOutcomeWords() {
        val open = house("Offenstraße 1", listOf(DoorResult("D", "Haushalt")), gebietID = "G")
        val done = house(
            "Fertigstraße 2",
            listOf(DoorResult("D", "Haushalt", VisitOutcome.JOINED, 1L)),
            gebietID = "G"
        )
        val territories = TerritorySummarizer.summarize(
            listOf(Gebiet(id = "G", name = "Testgebiet")),
            listOf(open, done)
        )
        assertTrue(ArchiveSearchEngine.search("dabei", territories).isNotEmpty())
        assertTrue(ArchiveSearchEngine.search("offen", territories).contains(territories.first()))
        // No early "no" anywhere in this territory.
        assertFalse(ArchiveSearchEngine.search("fruh", territories).contains(territories.first()))
    }

    @Test fun scoredSearchPrefersExactWordOverPrefix() {
        val exact = summaryFor("Bahnhof")
        val prefix = summaryFor("Bahnhofstraße")
        val ranked = ArchiveSearchEngine.search("bahnhof", listOf(prefix, exact))
        assertEquals(exact, ranked.first())
    }

    @Test fun writeScopeOnlyWritesToExactSecondDay() {
        val day1 = CampaignDays.startOfDay(1_700_000_000_000L)
        val day2 = CampaignDays.addDays(day1, 1)
        val later = CampaignDays.addDays(day1, 5)
        val territory = Gebiet(id = "G", name = "T", isTwoDay = true, day1Date = day1, day2Date = day2)
        assertEquals(DayScope.DAY_1, territory.writeScope(day1))
        assertEquals(DayScope.DAY_2, territory.writeScope(day2))
        // After campaign day 2 corrections land in Tag 1 again (iOS parity).
        assertEquals(DayScope.DAY_1, territory.writeScope(later))
        assertEquals(-1, territory.dayIndex(later))
    }

    @Test fun bulkFillOnlyTouchesOpenDoorsInScope() {
        val openDoor = DoorResult("A", "Tür 1")
        val notHomeDoor = DoorResult("B", "Tür 2", VisitOutcome.NOT_HOME, 1L)
        val joinedDoor = DoorResult("C", "Tür 3", VisitOutcome.JOINED, 1L)
        val house = house("Hauptstraße 3", listOf(openDoor, notHomeDoor, joinedDoor))

        val filled = house.setOutcomeForOpenDoors(VisitOutcome.EARLY_NO, DayScope.DAY_1, now = 10L)!!
        assertEquals(VisitOutcome.EARLY_NO, filled.units.first { it.id == "A" }.outcome)
        assertEquals(VisitOutcome.EARLY_NO, filled.units.first { it.id == "B" }.outcome)
        // The already-answered door keeps its result.
        assertEquals(VisitOutcome.JOINED, filled.units.first { it.id == "C" }.outcome)

        // No open doors left → no-op.
        assertEquals(filled, filled.setOutcomeForOpenDoors(null, DayScope.DAY_1, now = 11L))
    }

    @Test fun renameUnitUpdatesLabelAndTimestamp() {
        val original = house("Hauptstraße 4", listOf(DoorResult("A", "Haushalt"), DoorResult("B", "Tür 2")))
        val renamed = original.renameUnit("B", "Hinterhaus", now = 7L)!!
        assertEquals("Hinterhaus", renamed.units.first { it.id == "B" }.label)
        assertEquals("Haushalt", renamed.units.first { it.id == "A" }.label)
        assertTrue(renamed.updatedAt > original.updatedAt)
        // Blank labels are rejected.
        assertNull(original.renameUnit("B", "   "))
    }

    @Test fun restorePutsPreviousUnitsBack() {
        val original = house("Hauptstraße 5", listOf(DoorResult("A", "Haushalt", VisitOutcome.JOINED, 1L)))
        val cleared = original.recordOutcome("A", null, DayScope.DAY_1, now = 2L)!!
        val restored = cleared.restore(original.units, now = 3L)
        assertEquals(VisitOutcome.JOINED, restored.units.single().result(DayScope.COMBINED))
    }

    @Test fun plausibilityRejectsNearNullIsland() {
        // ~5 m off (0, 0) — inside the iOS parity band, so implausible.
        assertFalse(StoredCoordinate(0.00005, 0.00005).isPlausible)
    }
}
