package at.volkshilfe.nachbesuch.data

import at.volkshilfe.nachbesuch.data.json.AppJson
import at.volkshilfe.nachbesuch.data.json.BackupCodec
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.Instant

class BackupFormatTest {
    @Test fun realIOSLegacyFixturePreservesRecords() {
        val raw = checkNotNull(javaClass.getResourceAsStream("/LegacyV1Fixture.json"))
            .bufferedReader().use { it.readText() }
        val backup = BackupCodec.decode(raw)
        assertEquals(2, backup.gebiete.size)
        assertEquals(3, backup.houses.size)
        assertEquals("2024-05-01T08:00:00Z", backup.gebiete[0].updatedAt)
        assertEquals(VisitOutcome.JOINED, backup.houses[0].units[0].day2Outcome)
        assertEquals("2024-05-01T09:00:00Z", backup.houses[0].createdAt)
        assertEquals("2024-05-02T11:00:00Z", backup.houses[0].updatedAt)
        assertEquals("Hund", backup.houses[1].note)
        assertEquals(backup, BackupCodec.decode(BackupCodec.encode(backup)))
    }

    @Test fun legacyApartmentAndBothAppointmentsSurvive() {
        val raw = """
            {"formatVersion":1,"exportedAt":"2024-05-03T10:00:00Z","days":[],"houses":[{
              "id":"A","address":"Teststraße 1","note":"Klingeln","isApartmentBuilding":true,
              "latitude":48.2,"longitude":16.3,"gebietID":null,"dayID":"B",
              "createdAt":"2024-05-01T09:00:00Z","updatedAt":"2024-05-02T11:00:00Z",
              "units":[{"id":"C","label":"Tür 1","outcome":"later",
                "updatedAt":"2024-05-01T09:00:00Z","revisitAt":"2024-05-01T11:00:00Z",
                "day2Outcome":"later","day2UpdatedAt":"2024-05-02T09:00:00Z",
                "day2RevisitAt":"2024-05-02T11:00:00Z"},
                {"id":"D","label":"Tür 2","outcome":null,"updatedAt":null}]}]}
        """.trimIndent()
        val house = BackupCodec.decode(raw).houses.single()
        assertTrue(house.isApartmentBuilding)
        assertEquals("Klingeln", house.note)
        assertNull(house.gebietID)
        assertEquals("B", house.dayID)
        val door = house.units.first()
        assertEquals(VisitOutcome.LATER, door.outcome)
        assertEquals(VisitOutcome.LATER, door.day2Outcome)
        assertEquals("2024-05-01T09:00:00Z", door.updatedAt)
        assertEquals("2024-05-01T11:00:00Z", door.revisitAt)
        assertEquals("2024-05-02T09:00:00Z", door.day2UpdatedAt)
        assertEquals("2024-05-02T11:00:00Z", door.day2RevisitAt)
        assertNull(house.units[1].outcome)
        assertNull(house.units[1].updatedAt)
    }

    @Test fun rejectsEncounterDataBeforeImport() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            BackupCodec.decode("""{"formatVersion":3,"exportedAt":"2024-05-03T10:00:00Z",
                "gebiete":[],"houses":[],"passanten":[{"note":"Termin"}]}""")
        }
        assertTrue(error.message.orEmpty().contains("Passanten"))
    }

    @Test fun emptyV3EncountersRemainCompatible() {
        val backup = BackupCodec.decode("""{"formatVersion":3,"exportedAt":"2024-05-03T10:00:00Z",
            "gebiete":[],"houses":[],"passanten":[]}""")
        assertEquals(3, backup.formatVersion)
        assertTrue(backup.houses.isEmpty())
    }

    @Test fun rejectsUnknownVersionsAndIncompleteEnvelopes() {
        for (raw in listOf(
            """{"formatVersion":4,"exportedAt":"2024-05-03T10:00:00Z","gebiete":[],"houses":[]}""",
            """{"formatVersion":0,"days":[],"houses":[]}""",
            """{"formatVersion":2,"exportedAt":"2024-05-03T10:00:00Z","houses":[]}""",
            """{"formatVersion":1,"days":[]}""",
            """{}"""
        )) {
            assertThrows(IllegalArgumentException::class.java) { BackupCodec.decode(raw) }
        }
    }


    /**
     * The iOS decoder uses Apple's `.iso8601` strategy, which rejects fractional
     * seconds. Android backups must therefore always emit whole-second stamps.
     */
    @Test fun isoNeverEmitsFractionalSeconds() {
        val withMillis = AppJson.iso(1_755_700_000_123L)!!
        assertFalse(withMillis.contains('.'))
        assertEquals(Instant.parse(withMillis).toEpochMilli(), 1_755_700_000_000L)

        val wholeSecond = AppJson.iso(1_755_700_000_000L)!!
        assertFalse(wholeSecond.contains('.'))
    }

    @Test fun isoNowIsWholeSecond() {
        assertFalse(AppJson.isoNow().contains('.'))
    }

    /** Old iOS files and third-party writers may include fractional seconds. */
    @Test fun epochMillisAcceptsFractionalAndOffsetForms() {
        val reference = 1_787_308_000_123L // 2026-08-21T10:26:40.123Z
        assertEquals(reference, AppJson.epochMillis("2026-08-21T10:26:40.123Z"))
        assertEquals(1_787_308_000_000L, AppJson.epochMillis("2026-08-21T10:26:40Z"))
        // +02:00 offset (no trailing Z) is tolerated on import.
        assertEquals(
            Instant.parse("2026-08-21T08:26:40Z").toEpochMilli(),
            AppJson.epochMillis("2026-08-21T10:26:40+02:00")
        )
    }

    @Test fun epochMillisReturnsNullForGarbage() {
        assertNull(AppJson.epochMillis("kein datum"))
        assertNull(AppJson.epochMillis(null))
    }

    @Test fun storageDoorCodecRoundTripsThroughAppleEpoch() {
        val doors = listOf(
            at.volkshilfe.nachbesuch.domain.model.DoorResult(
                "A", "Haushalt",
                at.volkshilfe.nachbesuch.domain.model.VisitOutcome.JOINED,
                1_700_000_000_000L
            )
        )
        val encoded = AppJson.encodeStorageDoors(doors)
        // The Apple-reference epoch conversion (−978_307_200 s) must survive a
        // round-trip byte-for-byte at the domain level.
        assertEquals(doors, AppJson.decodeStorageDoors(encoded))
    }
}
