package at.volkshilfe.nachbesuch.domain

import at.volkshilfe.nachbesuch.domain.list.HouseListBuilder
import at.volkshilfe.nachbesuch.domain.list.ListFilter
import at.volkshilfe.nachbesuch.domain.list.SearchText
import at.volkshilfe.nachbesuch.domain.list.StreetNameParser
import at.volkshilfe.nachbesuch.domain.map.PinScale
import at.volkshilfe.nachbesuch.domain.map.PinStacking
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.MapPinSnapshotBuilder
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HouseListBuilderTest {

    private fun house(
        address: String,
        doors: List<DoorResult>,
        createdAt: Long = 1_000L,
        lat: Double = 46.62,
        lon: Double = 14.31
    ) = House(
        address = address, latitude = lat, longitude = lon,
        gebietID = "G1", units = doors, createdAt = createdAt, updatedAt = createdAt
    )

    @Test
    fun `open work outranks a join on the same house`() {
        // The map and the list must agree: one unanswered door keeps the whole
        // house visibly open even when another door already joined.
        val rows = HouseListBuilder.rows(
            listOf(
                house(
                    "Hauptstraße 1",
                    listOf(
                        DoorResult(label = "Tür 1", outcome = VisitOutcome.JOINED, updatedAt = 5L),
                        DoorResult(label = "Tür 2", outcome = VisitOutcome.NOT_HOME, updatedAt = 6L)
                    )
                )
            ),
            DayScope.DAY_1
        )
        assertEquals(VisitOutcome.NOT_HOME, rows.single().markerOutcome)
        assertEquals(1, rows.single().openCount)
    }

    @Test
    fun `filters select the rows they name`() {
        val houses = listOf(
            house("A 1", listOf(DoorResult(label = "H", outcome = VisitOutcome.NOT_HOME, updatedAt = 1L))),
            house("B 2", listOf(DoorResult(label = "H", outcome = VisitOutcome.JOINED, updatedAt = 1L))),
            house("C 3", listOf(DoorResult(label = "H")))
        )
        val rows = HouseListBuilder.rows(houses, DayScope.DAY_1)

        assertEquals(3, HouseListBuilder.filter(rows, ListFilter.ALL, "").size)
        // "not home" and "no status yet" are both still open work.
        assertEquals(2, HouseListBuilder.filter(rows, ListFilter.OPEN, "").size)
        assertEquals(1, HouseListBuilder.filter(rows, ListFilter.UNANSWERED, "").size)
        assertEquals(1, HouseListBuilder.filter(rows, ListFilter.JOINED, "").size)
    }

    @Test
    fun `search ignores case and German diacritics`() {
        val rows = HouseListBuilder.rows(listOf(house("Färbergasse 4", listOf(DoorResult(label = "H")))), DayScope.DAY_1)
        assertEquals(1, HouseListBuilder.filter(rows, ListFilter.ALL, "farbergasse").size)
        assertEquals(1, HouseListBuilder.filter(rows, ListFilter.ALL, "FÄRBER").size)
        assertEquals(0, HouseListBuilder.filter(rows, ListFilter.ALL, "hauptstrasse").size)
    }

    @Test
    fun `sections group by street and sum their doors`() {
        val houses = listOf(
            house("Hauptstraße 1", listOf(DoorResult(label = "H", outcome = VisitOutcome.JOINED, updatedAt = 1L))),
            house("Hauptstraße 3", listOf(DoorResult(label = "H"))),
            house("Ringweg 2", listOf(DoorResult(label = "H")))
        )
        val sections = HouseListBuilder.sections(HouseListBuilder.rows(houses, DayScope.DAY_1))
        assertEquals(listOf("Hauptstraße", "Ringweg"), sections.map { it.title })
        val main = sections.first()
        assertEquals(2, main.houseCount)
        assertEquals(2, main.unitCount)
        assertEquals(1, main.completedCount)
        assertEquals(0.5, main.progress, 1e-9)
    }

    @Test
    fun `default sort puts open work first then newest`() {
        val houses = listOf(
            house("Alt 1", listOf(DoorResult(label = "H", outcome = VisitOutcome.JOINED, updatedAt = 1L)), createdAt = 10L),
            house("Neu 2", listOf(DoorResult(label = "H", outcome = VisitOutcome.JOINED, updatedAt = 1L)), createdAt = 30L),
            house("Offen 3", listOf(DoorResult(label = "H")), createdAt = 20L)
        )
        val sorted = HouseListBuilder.sort(HouseListBuilder.rows(houses, DayScope.DAY_1))
        assertEquals(listOf("Offen 3", "Neu 2", "Alt 1"), sorted.map { it.address })
    }

    @Test
    fun `distance sort measures from the given origin`() {
        val near = house("Nah 1", listOf(DoorResult(label = "H")), lat = 46.6200, lon = 14.3100)
        val far = house("Fern 2", listOf(DoorResult(label = "H")), lat = 46.6500, lon = 14.3100)
        val sorted = HouseListBuilder.sortByDistance(
            HouseListBuilder.rows(listOf(far, near), DayScope.DAY_1),
            originLat = 46.6200, originLon = 14.3100
        )
        assertEquals("Nah 1", sorted.first().address)
        // ~3.3 km for 0.03° of latitude; a wrong scale factor shows up immediately.
        assertTrue("was ${sorted.last().distance}", sorted.last().distance!! in 3_000.0..3_600.0)
        assertEquals("3,3 km", sorted.last().formattedDistance)
    }

    @Test
    fun `counts report every filter over the same corpus`() {
        val houses = listOf(
            house("A 1", listOf(DoorResult(label = "H", outcome = VisitOutcome.NOT_HOME, updatedAt = 1L))),
            house("B 2", listOf(DoorResult(label = "H", outcome = VisitOutcome.JOINED, updatedAt = 1L)))
        )
        val counts = HouseListBuilder.counts(HouseListBuilder.rows(houses, DayScope.DAY_1))
        assertEquals(2, counts[ListFilter.ALL])
        assertEquals(1, counts[ListFilter.OPEN])
        assertEquals(1, counts[ListFilter.JOINED])
        assertEquals(0, counts[ListFilter.UNANSWERED])
    }

    @Test
    fun `a pending day-2 revisit does not force a red pin in Tag-2 scope`() {
        // Day 1 said "not home"; day 2 has no result yet. In Tag-2 the door reads
        // as unrecorded, not as a fresh "not home".
        val rows = HouseListBuilder.rows(
            listOf(house("Haupt 1", listOf(DoorResult(label = "H", outcome = VisitOutcome.NOT_HOME, updatedAt = 1L)))),
            DayScope.DAY_2
        )
        assertNull(rows.single().markerOutcome)
        assertEquals(1, rows.single().openCount)
    }

    @Test
    fun `folding is stable for the eszett`() {
        assertEquals("strasse", SearchText.fold("Straße"))
    }
}

class StreetNameParserTest {

    @Test
    fun `a house number followed by a comma does not become part of the street`() {
        // The OSM importer emits exactly this shape. The old regex required the
        // number to end at whitespace, so it matched the postal code instead and
        // every house number became its own list section.
        assertEquals("Am Hof" to "1", StreetNameParser.parse("Am Hof 1, 1010 Wien"))
        assertEquals("Am Hof" to "11", StreetNameParser.parse("Am Hof 11, 1010 Wien"))
    }

    @Test
    fun `an address with no house number keeps the whole street`() {
        assertEquals("Am Hof" to null, StreetNameParser.parse("Am Hof, 1010 Wien"))
    }

    @Test
    fun `non-breaking spaces are treated as separators`() {
        assertEquals("Teststraße" to "12a", StreetNameParser.parse("Teststraße 12a"))
    }

    @Test
    fun `a leading number is not mistaken for a house number`() {
        assertEquals("12 Hauptstraße" to null, StreetNameParser.parse("12 Hauptstraße"))
    }

    @Test
    fun `multi-word streets survive`() {
        assertEquals("Maria-Theresien-Straße" to "8", StreetNameParser.parse("Maria-Theresien-Straße 8/3"))
        assertEquals("Am Augarten" to "3", StreetNameParser.parse("Am Augarten 3"))
    }
}

class PinScaleTest {

    @Test
    fun `every pin scale carries the head diameter the painter draws`() {
        // The hit test that decides whether two pins are stacked and the painter
        // that draws the head must agree; these were two separate numbers before.
        assertEquals(34f, PinScale.FULL.headDiameterDp)
        assertEquals(25f, PinScale.COMPACT.headDiameterDp)
        assertEquals(15f, PinScale.DOT.headDiameterDp)
    }
}

class PinStackingTest {

    private fun points(vararg entries: Pair<String, Pair<Float, Float>>) =
        entries.associate { (id, xy) -> id to PinStacking.Point(xy.first, xy.second) }

    @Test
    fun `a pin whose centre is under another's head counts as stacked`() {
        // The real case from the field data: two OSM addresses a few metres
        // apart whose pins coincide once you zoom out.
        val radius = PinStacking.radiusPx(PinScale.FULL, density = 2.75f)
        val ids = PinStacking.idsAt(
            "a",
            points("a" to (100f to 100f), "b" to (110f to 105f)),
            radius
        )
        assertEquals(listOf("a", "b"), ids)
    }

    @Test
    fun `merely adjacent pins are not stacked`() {
        // Deliberate: overlapping pins are still individually tappable, and
        // popping a chooser for them would be noise on every dense street.
        val radius = PinStacking.radiusPx(PinScale.FULL, density = 2.75f)
        val ids = PinStacking.idsAt(
            "a",
            points("a" to (100f to 100f), "b" to (160f to 100f)),
            radius
        )
        assertEquals(listOf("a"), ids)
    }

    @Test
    fun `the tapped pin is always first`() {
        val radius = PinStacking.radiusPx(PinScale.FULL, density = 2.75f)
        val ids = PinStacking.idsAt(
            "m",
            points("a" to (100f to 100f), "m" to (101f to 101f), "z" to (99f to 99f)),
            radius
        )
        assertEquals("m", ids.first())
        assertEquals(setOf("a", "m", "z"), ids.toSet())
    }

    @Test
    fun `an unknown id yields only itself`() {
        assertEquals(listOf("ghost"), PinStacking.idsAt("ghost", points("a" to (0f to 0f)), 50f))
    }

    @Test
    fun `the radius scales with the pin size`() {
        // A DOT pin is smaller, so pins must be closer before they count as stacked.
        assertTrue(
            PinStacking.radiusPx(PinScale.DOT, 2f) < PinStacking.radiusPx(PinScale.FULL, 2f)
        )
    }
}

class MarkerOutcomeParityTest {

    private fun house(doors: List<DoorResult>) =
        House(address = "Teststraße 1", latitude = 46.62, longitude = 14.31, gebietID = "G1", units = doors)

    @Test
    fun `the map and the list agree on every scope`() {
        // The map's bitmap cache used to carry its own copy of this rule, and it
        // had drifted from the shared one. Anything that can render a house must
        // reach the same verdict, or a pin and its row contradict each other.
        val cases = listOf(
            listOf(DoorResult(label = "H", outcome = VisitOutcome.NOT_HOME, updatedAt = 1L)),
            listOf(DoorResult(label = "H", outcome = VisitOutcome.JOINED, updatedAt = 1L)),
            listOf(
                DoorResult(label = "1", outcome = VisitOutcome.JOINED, updatedAt = 1L),
                DoorResult(label = "2", outcome = VisitOutcome.NOT_HOME, updatedAt = 2L)
            ),
            listOf(DoorResult(label = "H"))
        )
        for (doors in cases) {
            for (scope in DayScope.entries) {
                val fromList = HouseListBuilder.rows(listOf(house(doors)), scope).single().markerOutcome
                val fromMap = MapPinSnapshotBuilder.markerOutcome(doors, scope)
                assertEquals("scope=$scope doors=$doors", fromMap, fromList)
            }
        }
    }

    @Test
    fun `a pending revisit is unrecorded in Tag 2, not a fresh red pin`() {
        // The deleted copy returned NOT_HOME here, so the pin stayed red in Tag 2
        // while the list showed the door as still to do.
        val doors = listOf(DoorResult(label = "H", outcome = VisitOutcome.NOT_HOME, updatedAt = 1L))
        assertNull(MapPinSnapshotBuilder.markerOutcome(doors, DayScope.DAY_2))
        assertEquals(VisitOutcome.NOT_HOME, MapPinSnapshotBuilder.markerOutcome(doors, DayScope.DAY_1))
    }
}
