package at.volkshilfe.nachbesuch.domain

import at.volkshilfe.nachbesuch.domain.list.HouseListBuilder
import at.volkshilfe.nachbesuch.domain.model.*
import org.junit.Assert.*
import org.junit.Test

class InformationConsistencyTest {
    @Test fun `recorded return visits do not make a street finished`() {
        val house = House(address = "Testgasse 1", latitude = 48.2, longitude = 16.3,
            gebietID = "test", units = listOf(
                DoorResult(label = "1", outcome = VisitOutcome.NOT_HOME),
                DoorResult(label = "2", outcome = VisitOutcome.LATER),
                DoorResult(label = "3", outcome = VisitOutcome.JOINED)
            ))
        val row = HouseListBuilder.rows(listOf(house), DayScope.DAY_1).single()
        val section = HouseListBuilder.sections(listOf(row)).single()
        assertEquals(3, section.completedCount)
        assertEquals(2, section.openCount)
        assertEquals(1.0 / 3, section.progress, 0.00001)
    }

    @Test fun `map and list agree for every outcome and day scope`() {
        val values = listOf<VisitOutcome?>(null) + VisitOutcome.entries
        for (day1 in values) for (day2 in values) for (scope in DayScope.entries) {
            val house = House(address = "Testgasse 1", latitude = 48.2, longitude = 16.3,
                gebietID = "test", units = listOf(DoorResult(label = "1", outcome = day1, day2Outcome = day2)))
            val row = HouseListBuilder.rows(listOf(house), scope).single()
            val pin = MapPinSnapshotBuilder.build(listOf(house), scope).pinsByID.getValue(house.id)
            assertEquals("$day1/$day2/$scope", row.markerOutcome, pin.markerOutcome)
            assertEquals(row.completedCount, pin.completedCount)
            assertEquals(row.unitCount, pin.unitCount)
            assertEquals(row.openCount > 0, pin.hasOpenWork)
        }
    }

    @Test fun `large territory projection benchmark`() {
        val houses = (1..10_000).map { index ->
            House(address = "Testgasse $index", latitude = 48.2, longitude = 16.3,
                gebietID = "test", units = listOf(DoorResult(label = "1", outcome = VisitOutcome.NOT_HOME)))
        }
        repeat(2) { HouseListBuilder.rows(houses, DayScope.DAY_1) }
        val samples = (1..5).map {
            val start = System.nanoTime()
            val rows = HouseListBuilder.rows(houses, DayScope.DAY_1)
            val sections = HouseListBuilder.sections(HouseListBuilder.sort(rows))
            assertEquals(10_000, sections.sumOf { it.houseCount })
            (System.nanoTime() - start) / 1_000_000.0
        }.sorted()
        println("10,000-house projection median ms: ${samples[2]}; samples: $samples")
    }
}
