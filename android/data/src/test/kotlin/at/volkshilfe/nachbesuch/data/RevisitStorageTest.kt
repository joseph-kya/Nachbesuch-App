package at.volkshilfe.nachbesuch.data

import at.volkshilfe.nachbesuch.data.json.AppJson
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The storage side of "Später". The iOS twin is `RevisitStorageTests`.
 *
 * `revisitAt` was added as a *new optional key* rather than by reshaping
 * `DoorResult`, precisely so both directions below keep working. A blob written by
 * a build that predates this feature must still decode, or the house shows up as
 * damaged and locks itself.
 */
class RevisitStorageTest {

    @Test fun legacyStorageBlobStillDecodes() {
        val legacy = """
            [{"id":"1E5F0F3E-2C4B-4C3A-9E5A-7A0A7F2B1C11","label":"Haushalt",
              "outcome":"notHome","updatedAt":760000000.0}]
        """.trimIndent()

        val doors = AppJson.decodeStorageDoors(legacy)
        assertEquals(1, doors.size)
        assertEquals(VisitOutcome.NOT_HOME, doors[0].outcome)
        assertNull(doors[0].revisitAt)
        assertNull(doors[0].day2RevisitAt)
    }

    @Test fun aBookedTimeSurvivesTheStorageRoundTrip() {
        val doors = listOf(
            DoorResult(
                id = "1E5F0F3E-2C4B-4C3A-9E5A-7A0A7F2B1C11",
                label = "Tür 1",
                outcome = VisitOutcome.LATER,
                updatedAt = 1_770_000_000_000L,
                revisitAt = 1_770_003_600_000L
            )
        )
        assertEquals(doors, AppJson.decodeStorageDoors(AppJson.encodeStorageDoors(doors)))
    }

    /**
     * The wire name is what iOS reads. A rename here silently turns every
     * postponed door on the other phone into an unreadable blob.
     */
    @Test fun theStoredValueIsSpelledLater() {
        val encoded = AppJson.encodeStorageDoors(
            listOf(DoorResult(id = "A", label = "Haushalt", outcome = VisitOutcome.LATER))
        )
        assertTrue(encoded.contains("\"later\""))
    }

    @Test fun aBookedTimeSurvivesTheBackupRoundTrip() {
        val door = DoorResult(
            id = "1E5F0F3E-2C4B-4C3A-9E5A-7A0A7F2B1C11",
            label = "Tür 1",
            outcome = VisitOutcome.LATER,
            updatedAt = 1_770_000_000_000L,
            revisitAt = 1_770_003_600_000L
        )
        val backup = at.volkshilfe.nachbesuch.data.json.BackupDoor(
            id = door.id, label = door.label, outcome = door.outcome,
            updatedAt = AppJson.iso(door.updatedAt), revisitAt = AppJson.iso(door.revisitAt)
        )
        assertEquals(door, backup.toDomain())
    }
}
