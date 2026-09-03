package at.volkshilfe.nachbesuch.domain

import at.volkshilfe.nachbesuch.domain.export.ExportDocumentBuilder
import at.volkshilfe.nachbesuch.domain.export.LegacyTextExport
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportTest {
    @Test fun legacyExportGroupsStreetAndUsesOutcomeSymbols() {
        val territory = Gebiet(id = "G", name = "Test", day1Date = 1_700_000_000_000L)
        fun house(address: String, outcome: VisitOutcome) = House(
            address = address, latitude = 48.2, longitude = 16.3, gebietID = "G",
            units = listOf(DoorResult(label = "Haushalt", outcome = outcome, updatedAt = 1L))
        )
        val document = ExportDocumentBuilder.build(
            territory,
            listOf(house("Neugasse 3", VisitOutcome.EARLY_NO), house("Neugasse 7", VisitOutcome.NOT_HOME)),
            DayScope.COMBINED
        )
        assertTrue(LegacyTextExport.render(document).contains("Neugasse 3🚫 7🔴"))
    }

    @Test fun dayTwoExportDoesNotIncludeDayOneOnlyDoor() {
        val house = House(
            address = "Teststraße 1", latitude = 48.2, longitude = 16.3, gebietID = "G",
            units = listOf(DoorResult("D", "Haushalt", VisitOutcome.JOINED, 1L))
        )
        val territory = Gebiet(id = "G", name = "Test", day1Date = 1_700_000_000_000L)
        assertTrue(ExportDocumentBuilder.build(territory, listOf(house), DayScope.DAY_2).houses.isEmpty())
    }
}
