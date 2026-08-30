import MapKit
import SwiftUI
import UIKit

// MARK: - Camera commands

/// A one-shot, programmatic camera move. The identity makes each command apply
/// exactly once, so a SwiftUI re-render can never replay an old move.
struct MapCameraCommand: Equatable {
    enum Kind {
        case region(MKCoordinateRegion, animated: Bool)
        case follow(Bool)
    }

    let id = UUID()
    let kind: Kind

    static func == (lhs: MapCameraCommand, rhs: MapCameraCommand) -> Bool { lhs.id == rhs.id }

    static func region(
        center: CLLocationCoordinate2D,
        span: MKCoordinateSpan,
        animated: Bool = true
    ) -> MapCameraCommand {
        MapCameraCommand(kind: .region(MKCoordinateRegion(center: center, span: span), animated: animated))
    }

    static func region(_ region: MKCoordinateRegion, animated: Bool = true) -> MapCameraCommand {
        MapCameraCommand(kind: .region(region, animated: animated))
    }

    static func follow(_ on: Bool) -> MapCameraCommand {
        MapCameraCommand(kind: .follow(on))
    }
}

/// `MKMapView` that defers its initial camera to the first layout pass.
///
/// MapKit fits a region to the view's aspect ratio at the moment it is applied, and
/// inside `makeUIView` the bounds are still zero — so a region set there is either
/// ignored or lands at the wrong zoom. Waiting for `layoutSubviews` is the only
/// point where the geometry is real and the camera has not yet been shown to anyone.
final class StartupRegionMapView: MKMapView {
    var pendingStartupRegion: MKCoordinateRegion?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let region = pendingStartupRegion, bounds.width > 0, bounds.height > 0 else { return }
        pendingStartupRegion = nil
        setRegion(region, animated: false)
    }
}

// MARK: - Representable

/// Hosts `MKMapView`.
///
/// `updateUIView` moves **data** only — never camera, never per-frame state. The
/// live camera lives in `MapCameraStore` outside SwiftUI, so panning and zooming
/// invalidate no SwiftUI body at all.
struct MapHost: UIViewRepresentable {
    let startupRegion: MKCoordinateRegion
    let pins: PreparedMapSnapshot
    /// Bumped when the pin SET changed (houses added/removed, territory switch).
    let structuralVersion: Int
    /// Bumped when pin CONTENT changed (a door outcome was tapped).
    let contentVersion: Int
    let changedHouseIDs: Set<UUID>
    let boundary: [CLLocationCoordinate2D]
    let draftPoints: [CLLocationCoordinate2D]
    let selectedHouseIDs: Set<UUID>?
    let isActive: Bool
    let isSatellite: Bool
    let poiPreset: POIPreset
    let reduceMotion: Bool
    let dropHouseID: UUID?
    let cameraCommand: MapCameraCommand?
    let userHeading: Double?
    let userHeadingAccuracy: Double?
    /// Space occupied by the floating chrome, handed to MapKit as `layoutMargins`
    /// so its legal attribution, scale and compass stay clear of it.
    let chromeInsets: UIEdgeInsets

    var onCameraIdle: (MKCoordinateRegion) -> Void = { _ in }
    var onCameraMoved: (MKCoordinateRegion) -> Void = { _ in }
    var onTrackingModeChanged: (Bool) -> Void = { _ in }
    var onTapHouse: (UUID) -> Void = { _ in }
    var onStackedPins: ([UUID]) -> Void = { _ in }
    var onDropConsumed: (UUID) -> Void = { _ in }
    var menuProvider: ((MapPinSnapshot) -> UIMenu)?
    var previewProvider: ((MapPinSnapshot) -> UIViewController?)?

    func makeCoordinator() -> MapCoordinator { MapCoordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = StartupRegionMapView()
        mapView.pendingStartupRegion = startupRegion.isUsable ? startupRegion : MapCameraStore.fallbackRegion
        let coordinator = context.coordinator
        mapView.delegate = coordinator
        coordinator.mapView = mapView

        mapView.register(HousePinView.self, forAnnotationViewWithReuseIdentifier: HousePinView.reuseIdentifier)
        mapView.register(DraftPointView.self, forAnnotationViewWithReuseIdentifier: DraftPointView.reuseIdentifier)
        mapView.register(UserLocationPuckView.self, forAnnotationViewWithReuseIdentifier: UserLocationPuckView.reuseIdentifier)

        mapView.showsUserLocation = isActive
        mapView.showsCompass = false      // custom compass placed clear of the chrome
        mapView.showsScale = true
        mapView.showsBuildings = true
        mapView.isPitchEnabled = false    // a canvassing map is a plan view
        mapView.isRotateEnabled = true

        coordinator.applyConfiguration(mapView, satellite: isSatellite, poi: poiPreset)
        coordinator.applyChromeInsets(mapView, insets: chromeInsets)
        // The camera is deliberately NOT set here: MapKit fits a region to the view's
        // aspect ratio at the moment it is applied, and bounds are still zero inside
        // `makeUIView`, so the first frame would land at the wrong zoom.
        return mapView
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: MapCoordinator) {
        coordinator.tearDown(mapView)
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.mapView = mapView
        coordinator.onCameraIdle = onCameraIdle
        coordinator.onCameraMoved = onCameraMoved
        coordinator.onTrackingModeChanged = onTrackingModeChanged
        coordinator.onTapHouse = onTapHouse
        coordinator.onStackedPins = onStackedPins
        coordinator.onDropConsumed = onDropConsumed
        coordinator.menuProvider = menuProvider
        coordinator.previewProvider = previewProvider
        coordinator.reduceMotionEnabled = reduceMotion
        if mapView.showsUserLocation != isActive {
            mapView.showsUserLocation = isActive
        }

        coordinator.applyConfiguration(mapView, satellite: isSatellite, poi: poiPreset)
        coordinator.applyChromeInsets(mapView, insets: chromeInsets)
        coordinator.syncBoundary(mapView, boundary: boundary)
        coordinator.syncDraftPoints(mapView, points: draftPoints)
        coordinator.applyUserHeading(userHeading, accuracy: userHeadingAccuracy)

        // Registered before the data sync: if the new pin and its drop request land
        // in the same pass, the annotation's `didAdd` has already fired by the time
        // a later request would go looking for it.
        if let dropHouseID {
            coordinator.requestDrop(for: dropHouseID)
        }

        coordinator.applyData(
            mapView,
            pins: pins,
            structuralVersion: structuralVersion,
            contentVersion: contentVersion,
            changedHouseIDs: changedHouseIDs,
            selectedHouseIDs: selectedHouseIDs
        )

        coordinator.applyCameraCommand(mapView, command: cameraCommand)
    }
}
