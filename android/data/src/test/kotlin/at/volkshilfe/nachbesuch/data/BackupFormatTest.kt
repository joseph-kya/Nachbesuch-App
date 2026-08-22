package at.volkshilfe.nachbesuch.data

import at.volkshilfe.nachbesuch.data.json.AppJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class BackupFormatTest {

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
