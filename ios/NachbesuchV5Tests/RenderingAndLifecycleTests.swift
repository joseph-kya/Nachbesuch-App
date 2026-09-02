import MapKit
import SwiftUI
import Testing
@testable import NachbesuchV5

@Suite("Rendering nach Änderungen")
struct RenderingRegressionTests {
    private func raw(address: String = "Teststraße 1", latitude: Double = 48.2) -> RawMapHouse {
        RawMapHouse(
            id: UUID(),
            address: address,
            latitude: latitude,
            longitude: 16.37,
            unitsData: try! AppCoders.unitsEncoder().encode([DoorResult(label: "Haushalt")]),
            updatedAt: .now
        )
    }

    @Test("Ein neues Haus wird in einen bestehenden Snapshot eingefügt")
    func insertionAddsPinAndExpandsBounds() throws {
        let existing = raw(latitude: 48.2)
        let inserted = raw(address: "Teststraße 2", latitude: 48.4)
        let base = MapPinSnapshotBuilder.build(from: [existing], scope: .combined)

        let result = MapPinSnapshotBuilder.patch(base, with: [inserted], scope: .combined)

        #expect(result.pinsByID.count == 2)
        #expect(result.pinsByID[inserted.id]?.address == "Teststraße 2")
        let bounds = try #require(result.bounds)
        #expect(bounds.maxLatitude == 48.4)
    }

    @MainActor
    @Test("Ein strukturelles Update erzeugt sofort eine MapKit-Annotation")
    func coordinatorAddsAnnotationImmediately() {
        let house = raw()
        let snapshot = MapPinSnapshotBuilder.build(from: [house], scope: .combined)
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = MapCoordinator()

        coordinator.applyData(
            mapView,
            pins: snapshot,
            structuralVersion: 1,
            contentVersion: 1,
            changedHouseIDs: [house.id],
            selectedHouseIDs: nil
        )

        let renderedIDs = Set(
            mapView.annotations.compactMap { ($0 as? HouseAnnotation)?.houseID }
        )
        #expect(renderedIDs == [house.id])
    }
}

@Suite("App-Lifecycle")
struct AppLifecycleTests {
    @Test("Nur der sichtbare Tab arbeitet im Vordergrund")
    func onlySelectedTabIsActive() {
        #expect(AppTab.map.isActive(selectedTab: .map, scenePhase: .active))
        #expect(!AppTab.list.isActive(selectedTab: .map, scenePhase: .active))
        #expect(!AppTab.archive.isActive(selectedTab: .map, scenePhase: .active))
    }

    @Test("Kein Tab arbeitet im Hintergrund oder während Inaktivität")
    func backgroundStopsEveryTab() {
        for phase in [ScenePhase.inactive, .background] {
            for tab in [AppTab.map, .list, .archive] {
                #expect(!tab.isActive(selectedTab: tab, scenePhase: phase))
            }
        }
    }
}

@Suite("Performance-Fixtures")
struct PerformanceFixtureTests {
    @Test("Der Lastgenerator erzeugt auch bei Restmengen exakt genug Plätze")
    func gridFitsRequestedHouseCount() {
        let dimensions = DebugSeed.gridDimensions(for: 2_000)
        #expect(dimensions.streets * dimensions.perStreet >= 2_000)
        #expect(dimensions.streets * (dimensions.perStreet - 1) < 2_000)
    }
}
