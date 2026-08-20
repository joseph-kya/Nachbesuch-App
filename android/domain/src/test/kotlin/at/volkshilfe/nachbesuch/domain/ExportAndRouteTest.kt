package at.volkshilfe.nachbesuch.domain

import at.volkshilfe.nachbesuch.domain.export.ExportDocumentBuilder
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.route.RoutePlanner
import at.volkshilfe.nachbesuch.domain.route.RouteStop
import at.volkshilfe.nachbesuch.domain.route.WalkingGraph
import at.volkshilfe.nachbesuch.domain.route.WalkingWay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportAndRouteTest {
    @Test fun dayTwoExportDoesNotIncludeDayOneOnlyDoor() {
        val house = House(
            address = "Teststraße 1", latitude = 48.2, longitude = 16.3, gebietID = "G",
            units = listOf(DoorResult("D", "Haushalt", VisitOutcome.JOINED, 1L))
        )
        val territory = Gebiet(id = "G", name = "Test", day1Date = 1_700_000_000_000L)
        assertTrue(ExportDocumentBuilder.build(territory, listOf(house), DayScope.DAY_2).houses.isEmpty())
    }

    @Test fun routeIsDeterministicAndContainsEveryStop() {
        val start = StoredCoordinate(48.2, 16.3)
        val stops = listOf(
            RouteStop("A", StoredCoordinate(48.201, 16.301)),
            RouteStop("B", StoredCoordinate(48.202, 16.302)),
            RouteStop("C", StoredCoordinate(48.203, 16.303))
        )
        val first = RoutePlanner.plan(start, stops)
        val second = RoutePlanner.plan(start, stops)
        assertEquals(second.stops.map { it.id }, first.stops.map { it.id })
        assertEquals(listOf("A", "B", "C"), first.stops.map { it.id })
    }

    @Test fun walkingGraphJoinsSharedNodesAndReturnsStreetLegs() {
        val a = StoredCoordinate(48.2000, 16.3000)
        val b = StoredCoordinate(48.2010, 16.3000)
        val c = StoredCoordinate(48.2020, 16.3000)
        val graph = requireNotNull(WalkingGraph.fromWays(listOf(WalkingWay(listOf(a, b)), WalkingWay(listOf(b, c)))))
        val route = RoutePlanner.plan(a, listOf(RouteStop("C", c)), graph)
        assertTrue(route.followsStreets)
        assertEquals(listOf("C"), route.stops.map { it.id })
        assertTrue(route.path.containsAll(listOf(a, b, c)))
    }
}
