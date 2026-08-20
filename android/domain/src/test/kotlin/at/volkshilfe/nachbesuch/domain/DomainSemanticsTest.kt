package at.volkshilfe.nachbesuch.domain

import at.volkshilfe.nachbesuch.domain.archive.ArchiveSearch
import at.volkshilfe.nachbesuch.domain.geo.Centroid
import at.volkshilfe.nachbesuch.domain.list.StreetNameParser
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.model.OutcomeTally
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DomainSemanticsTest {
    @Test fun dayTwoDoesNotFallBackForStatistics() {
        val door = DoorResult("A", "Haushalt", VisitOutcome.NOT_HOME, 1L, null, null)
        assertNull(door.result(DayScope.DAY_2))
        assertNull(door.displayOutcome(DayScope.DAY_2))
        assertTrue(door.isOpen(DayScope.DAY_2))
    }

    @Test fun settledDoorsNeedNoRevisit() {
        val door = DoorResult("A", "Haushalt", VisitOutcome.NOT_HOME, 1L, VisitOutcome.JOINED, 2L)
        assertEquals(VisitOutcome.JOINED, door.result(DayScope.DAY_2))
        assertFalse(door.isOpen(DayScope.DAY_2))
    }

    @Test fun dayTwoDisplayTallyCountsSettledDayOneDoorsButLeavesRevisitsOpen() {
        val settled = DoorResult("A", "Tür 1", VisitOutcome.JOINED, 1L)
        val revisit = DoorResult("B", "Tür 2", VisitOutcome.NOT_HOME, 1L)
        val tally = OutcomeTally.from(listOf(settled, revisit), DayScope.DAY_2)
        assertEquals(2, tally.unitCount)
        assertEquals(1, tally.completed)
        assertEquals(1, tally.joined)
        assertEquals(1, tally.open)
    }

    @Test fun searchIsDiacriticInsensitiveAndAnded() {
        assertTrue(ArchiveSearch.matches("Teststrasse 12", listOf("Teststraße 12, 9020 Klagenfurt")))
        assertFalse(ArchiveSearch.matches("Klagenfurt Bahnhof", listOf("Klagenfurt Zentrum")))
    }

    @Test fun streetParsingHandlesNonBreakingSpace() {
        assertEquals("Teststraße" to "12a", StreetNameParser.parse("Teststraße\u00A012a"))
    }

    @Test fun centroidRejectsNullIsland() {
        assertNull(Centroid.polygon(listOf(
            StoredCoordinate(0.0, 0.0), StoredCoordinate(0.0, 0.001), StoredCoordinate(0.001, 0.001)
        )))
    }
}
