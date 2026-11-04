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

    @MainActor
    @Test("Ein Pin-Tap über die Gestenerkennung wird nicht durch ein verzögertes didSelect dupliziert")
    func directGestureFollowedByDelayedMapKitSelectDoesNotDuplicateTap() {
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

        var tapCount = 0
        coordinator.onTapHouse = { _ in tapCount += 1 }

        // 1. Direct gesture fires on touch up
        coordinator.houseTappedFromGesture(house.id)
        #expect(tapCount == 1)

        // 2. MapKit's delayed didSelect fires 350ms later for the same house
        let annotation = mapView.annotations.compactMap { $0 as? HouseAnnotation }.first!
        let view = HousePinView(annotation: annotation, reuseIdentifier: HousePinView.reuseIdentifier)
        coordinator.mapView(mapView, didSelect: view)

        // Must still be 1, not 2 (which would have toggled it off)
        #expect(tapCount == 1)
    }

    @MainActor
    @Test("Ein didSelect ohne vorangegangene Geste (z. B. VoiceOver) löst den Tap wie gewohnt aus")
    func voiceOverDidSelectTriggersTapWhenNoPriorGesture() {
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

        var tappedID: UUID?
        coordinator.onTapHouse = { tappedID = $0 }

        let annotation = mapView.annotations.compactMap { $0 as? HouseAnnotation }.first!
        let view = HousePinView(annotation: annotation, reuseIdentifier: HousePinView.reuseIdentifier)
        coordinator.mapView(mapView, didSelect: view)

        #expect(tappedID == house.id)
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
