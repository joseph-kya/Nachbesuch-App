import CoreLocation
import Testing
import UIKit
@testable import NachbesuchV5

/// Task 4 holds two pure rules with no device needed: precision follows the
/// visible map rather than the camera lock, and the puck tells the truth
/// about untrustworthy fixes with hysteresis instead of flicker.
@Suite("Standortpräzision und ehrlicher Punkt")
struct LocationPrecisionTests {
    @Test func deniedLocationDoesNotShowApproximateLocationWarning() {
        for status in [CLAuthorizationStatus.notDetermined, .denied, .restricted] {
            #expect(!LocationService.shouldExplainReducedAccuracy(authorization: status, accuracy: .reducedAccuracy))
        }
        #expect(LocationService.shouldExplainReducedAccuracy(authorization: .authorizedWhenInUse, accuracy: .reducedAccuracy))
        #expect(!LocationService.shouldExplainReducedAccuracy(authorization: .authorizedWhenInUse, accuracy: .fullAccuracy))
    }

    @Test func followingWinsOverMapVisibility() {
        let profile = AccuracyProfile.resolve(mapVisible: true, following: true)
        #expect(profile.desiredAccuracy == kCLLocationAccuracyBest)
        #expect(profile.distanceFilter == 1)
    }

    @Test func mapVisibleRaisesPrecision() {
        let profile = AccuracyProfile.resolve(mapVisible: true, following: false)
        #expect(profile.desiredAccuracy == kCLLocationAccuracyBest)
        #expect(profile.distanceFilter == 2)
    }

    @Test func listOnlyStaysCoarse() {
        let profile = AccuracyProfile.resolve(mapVisible: false, following: false)
        #expect(profile.desiredAccuracy == kCLLocationAccuracyNearestTenMeters)
        #expect(profile.distanceFilter == 3)
    }

    @Test func profileIsStableWhenNothingChanged() {
        #expect(
            AccuracyProfile.resolve(mapVisible: true, following: false)
                == AccuracyProfile.resolve(mapVisible: true, following: false)
        )
    }

    @Test func degradesAboveTwentyFiveMetres() {
        #expect(PuckConfidence.from(horizontalAccuracy: 26, current: .trusted) == .uncertain)
    }

    @Test func recoversOnlyBelowEighteen() {
        #expect(PuckConfidence.from(horizontalAccuracy: 19, current: .uncertain) == .uncertain)
        #expect(PuckConfidence.from(horizontalAccuracy: 18, current: .uncertain) == .trusted)
    }

    @Test func staysPutInsideTheBand() {
        #expect(PuckConfidence.from(horizontalAccuracy: 20, current: .trusted) == .trusted)
        #expect(PuckConfidence.from(horizontalAccuracy: 22, current: .uncertain) == .uncertain)
    }

    @Test func fakeAccuracyWinsWhenPositive() {
        #expect(MapCoordinator.effectiveAccuracy(real: 5, fakeOverride: "40") == 40)
        #expect(MapCoordinator.effectiveAccuracy(real: 5, fakeOverride: nil) == 5)
        #expect(MapCoordinator.effectiveAccuracy(real: 5, fakeOverride: "0") == 5)
        #expect(MapCoordinator.effectiveAccuracy(real: 5, fakeOverride: "unfug") == 5)
        #expect(MapCoordinator.effectiveAccuracy(real: nil, fakeOverride: nil) == nil)
    }

    /// The headless stand-in for the puck screenshots this machine cannot
    /// take: no tap can grant the simulator location permission, so the dot
    /// never draws here. This pins the presentation mapping itself — hollow
    /// and dimmed when uncertain, today's look when trusted.
    @Test @MainActor func uncertainPuckDimsAndRelabels() {
        let puck = UserLocationPuckView(annotation: nil, reuseIdentifier: "test")
        puck.apply(confidence: .uncertain)
        #expect(puck.alpha == 0.55)
        #expect(puck.accessibilityLabel == "Dein Standort, ungenau")
        puck.apply(confidence: .trusted)
        #expect(puck.alpha == 1)
        #expect(puck.accessibilityLabel == "Dein Standort")
    }
}
