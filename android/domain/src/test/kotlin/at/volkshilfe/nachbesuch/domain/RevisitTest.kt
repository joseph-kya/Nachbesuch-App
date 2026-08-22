package at.volkshilfe.nachbesuch.domain

import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.MapPinSnapshotBuilder
import at.volkshilfe.nachbesuch.domain.model.OutcomeTally
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.revisit.RevisitPlanner
import at.volkshilfe.nachbesuch.domain.revisit.RevisitSuggestion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/** The semantics of the "Später" status. Mirrors the iOS `RevisitSemanticsTests`. */
class RevisitSemanticsTest {

    private fun house(doors: Int, apartment: Boolean = false) = House(
        address = "Teststraße 1", latitude = 48.2, longitude = 16.3,
        gebietID = "G", isApartmentBuilding = apartment,
        units = (1..doors).map { DoorResult(id = "D$it", label = "Tür $it") }
    )

    @Test fun laterCountsAsOpenWork() {
        val door = DoorResult("A", "Haushalt", VisitOutcome.LATER, 1L, revisitAt = 99L)

        assertTrue(VisitOutcome.LATER.isOpenWork)
        assertTrue(door.isOpen(DayScope.DAY_1))
        assertTrue(door.isOpen(DayScope.COMBINED))
        // Same rule as "niemand da": the second day exists for exactly these doors.
        assertTrue(door.isPendingRevisit)
        assertNull(door.displayOutcome(DayScope.DAY_2))
    }

    @Test fun markerPrefersBookedTimeOverOpenNotHome() {
        val doors = listOf(
            DoorResult("A", "1", VisitOutcome.NOT_HOME, 1L),
            DoorResult("B", "2", VisitOutcome.LATER, 1L, revisitAt = 99L),
            DoorResult("C", "3", VisitOutcome.JOINED, 1L)
        )
        // The booked time is the more specific instruction, and the one with a
        // deadline — so it is what the pin shows.
        assertEquals(VisitOutcome.LATER, MapPinSnapshotBuilder.markerOutcome(doors, DayScope.COMBINED))
    }

    @Test fun tallyKeepsLaterSeparateFromNotHome() {
        val doors = listOf(
            DoorResult("A", "1", VisitOutcome.LATER, 1L, revisitAt = 99L),
            DoorResult("B", "2", VisitOutcome.NOT_HOME, 1L),
            DoorResult("C", "3", VisitOutcome.JOINED, 1L)
        )
        val tally = OutcomeTally.from(doors, DayScope.COMBINED)

        assertEquals(1, tally.later)
        assertEquals(1, tally.notHome)
        assertEquals(3, tally.completed)
        assertEquals(2, tally.open)
    }

    @Test fun answeringADoorClearsItsBookedTime() {
        val booked = house(1).recordOutcome("D1", VisitOutcome.LATER, DayScope.DAY_1, revisitAt = 5_000L)!!
        assertEquals(5_000L, booked.units[0].revisitAt)

        // Otherwise the door reads as settled while still carrying a return time —
        // and a reminder would fire for a household that already said yes.
        val answered = booked.recordOutcome("D1", VisitOutcome.JOINED, DayScope.DAY_1)!!
        assertEquals(VisitOutcome.JOINED, answered.units[0].outcome)
        assertNull(answered.units[0].revisitAt)
    }

    @Test fun theTimeLandsOnTheDayBeingWrittenTo() {
        val booked = house(1).recordOutcome("D1", VisitOutcome.LATER, DayScope.DAY_2, revisitAt = 5_000L)!!

        assertNull(booked.units[0].revisitAt)
        assertEquals(5_000L, booked.units[0].day2RevisitAt)
        assertEquals(5_000L, booked.units[0].revisitTime(DayScope.DAY_2))
    }

    @Test fun bulkBookingCoversOpenDoorsOnly() {
        val partly = house(3, apartment = true)
            .recordOutcome("D1", VisitOutcome.JOINED, DayScope.DAY_1)!!
        val booked = partly.setOutcomeForOpenDoors(VisitOutcome.LATER, DayScope.DAY_1, revisitAt = 7_000L)!!

        assertEquals(VisitOutcome.JOINED, booked.units[0].outcome)
        assertNull(booked.units[0].revisitAt)
        assertEquals(7_000L, booked.units[1].revisitAt)
        assertEquals(7_000L, booked.units[2].revisitAt)
    }

    @Test fun aBookedTimeOnlySurfacesWhileTheStatusIsLater() {
        val door = DoorResult("A", "1", VisitOutcome.LATER, 1L, revisitAt = 99L)
        assertEquals(99L, door.displayRevisitAt(DayScope.DAY_1))

        // A stale field on an answered door must never reach a row or a pin.
        val answered = door.copy(outcome = VisitOutcome.JOINED)
        assertNull(answered.displayRevisitAt(DayScope.DAY_1))
    }
}

/** The suggested return times. Mirrors the iOS `RevisitPlannerTests` case for case. */
class RevisitPlannerTest {

    private val zone: ZoneId = ZoneId.of("Europe/Vienna")

    private fun at(hour: Int, minute: Int): Long =
        LocalDateTime.of(2026, 5, 12, hour, minute).atZone(zone).toInstant().toEpochMilli()

    @Test fun middayOffersRelativeAndClockTimes() {
        val suggestions = RevisitPlanner.suggestions(at(13, 12), zone)

        assertEquals(5, suggestions.size)
        assertTrue(suggestions.all { it.atMillis > at(13, 12) })
        // Sorted, so the row reads as a timeline rather than two shuffled groups.
        assertEquals(suggestions.map { it.atMillis }.sorted(), suggestions.map { it.atMillis })
        assertTrue(suggestions.any { it.kind == RevisitSuggestion.Kind.Clock(17, 0) })
        assertTrue(suggestions.any { it.kind == RevisitSuggestion.Kind.Clock(18, 0) })
    }

    @Test fun passedSlotsAreDropped() {
        val suggestions = RevisitPlanner.suggestions(at(18, 45), zone)

        // 17:00 and 18:00 are gone; only 19:00 is left, so this must not silently
        // roll a slot into tomorrow.
        assertFalse(suggestions.any { it.kind == RevisitSuggestion.Kind.Clock(17, 0) })
        assertFalse(suggestions.any { it.kind == RevisitSuggestion.Kind.Clock(18, 0) })
        assertTrue(suggestions.any { it.kind == RevisitSuggestion.Kind.Clock(19, 0) })
    }

    @Test fun lateEveningKeepsRelativeOnly() {
        val suggestions = RevisitPlanner.suggestions(at(21, 40), zone)

        assertEquals(RevisitPlanner.relativeOffsets.size, suggestions.size)
        assertTrue(suggestions.all { it.kind is RevisitSuggestion.Kind.Relative })
    }

    @Test fun nearDuplicateClockSlotIsDropped() {
        // 16:32 + 30 min = 17:05 after rounding, which is inside the ten-minute
        // window around 17:00 — offering both would be two buttons for one time.
        val suggestions = RevisitPlanner.suggestions(at(16, 32), zone)
        assertFalse(suggestions.any { it.kind == RevisitSuggestion.Kind.Clock(17, 0) })
    }

    @Test fun relativeOffsetsAreRoundedUpToFiveMinutes() {
        val suggestions = RevisitPlanner.suggestions(at(13, 12), zone)
        val inThirty = suggestions.first { it.kind == RevisitSuggestion.Kind.Relative(30) }

        // 13:12 + 30 = 13:42 → 13:45, a time a person would actually say.
        assertEquals("13:45", RevisitPlanner.clockText(inThirty.atMillis, zone))
    }

    @Test fun defaultTimeMatchesTheFirstSuggestion() {
        val now = at(13, 12)
        assertEquals(RevisitPlanner.suggestions(now, zone).first().atMillis, RevisitPlanner.defaultTime(now, zone))
    }

    @Test fun aPickedTimeInThePastIsRefusedRatherThanRolledToTomorrow() {
        val now = at(18, 30)
        assertNull(RevisitPlanner.instantFor(17, 0, now, zone))
        assertNotNull(RevisitPlanner.instantFor(19, 0, now, zone))
    }

    /**
     * The Android suggestions must match the iOS ones exactly: the two apps are
     * used side by side in the same team, and a slot that appears on one phone and
     * not the other reads as a bug.
     */
    @Test fun theConstantsMatchTheIosPlanner() {
        assertEquals(listOf(30, 60, 120), RevisitPlanner.relativeOffsets)
        assertEquals(listOf(17 to 0, 18 to 0, 19 to 0), RevisitPlanner.clockSlots)
        assertEquals(2, RevisitPlanner.MAXIMUM_CLOCK_SLOTS)
        assertEquals(10L * 60 * 1000, RevisitPlanner.DUPLICATE_WINDOW_MILLIS)
    }
}
