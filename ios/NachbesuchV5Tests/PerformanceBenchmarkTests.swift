import Foundation
import XCTest
@testable import NachbesuchV5

/// Repeatable CPU-side benchmarks for the hottest map data paths.
///
/// XCTest stores wall-clock, CPU and memory values in the xcresult bundle, which
/// makes runs comparable in Xcode and through xcresulttool. Input construction and
/// warm-up stay outside the measured blocks.
nonisolated final class PerformanceBenchmarkTests: XCTestCase {
    private static let houseCount = 10_000
    private static let patchCount = 100

    func testBuildTenThousandPins() throws {
        let houses = try makeHouses()
        _ = MapPinSnapshotBuilder.build(from: houses, scope: .combined)
        var resultCount = 0

        measure(metrics: metrics, options: options) {
            resultCount = MapPinSnapshotBuilder.build(
                from: houses,
                scope: .combined
            ).pinsByID.count
        }

        XCTAssertEqual(resultCount, Self.houseCount)
        // Catastrophe gate, not the 25 % regression gate from B9: fine-grained
        // baselines live in Xcode-set .xcbaseline files, which need a UI pass
        // once CI exists. This only fails on order-of-magnitude blowups, with
        // ~50x headroom, so it never flakes on a slow machine.
        let start = Date.now
        _ = MapPinSnapshotBuilder.build(from: houses, scope: .combined)
        XCTAssertLessThan(Date.now.timeIntervalSince(start), 8)
    }

    func testPatchOneHundredOfTenThousandPins() throws {
        let houses = try makeHouses()
        let base = MapPinSnapshotBuilder.build(from: houses, scope: .combined)
        let changed = Array(houses.prefix(Self.patchCount))
        _ = MapPinSnapshotBuilder.patch(base, with: changed, scope: .combined)
        var resultCount = 0

        measure(metrics: metrics, options: options) {
            resultCount = MapPinSnapshotBuilder.patch(
                base,
                with: changed,
                scope: .combined
            ).pinsByID.count
        }

        XCTAssertEqual(resultCount, Self.houseCount)
        let start = Date.now
        _ = MapPinSnapshotBuilder.patch(base, with: changed, scope: .combined)
        XCTAssertLessThan(Date.now.timeIntervalSince(start), 8)
    }

    private var metrics: [any XCTMetric] {
        [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]
    }

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 7
        return options
    }

    private func makeHouses() throws -> [RawMapHouse] {
        let doorData = try AppCoders.unitsEncoder().encode([
            DoorResult(label: "Haushalt", outcome: .notHome)
        ])
        return (0..<Self.houseCount).map { index in
            RawMapHouse(
                id: UUID(),
                address: "Teststraße \(index + 1)",
                latitude: 48.2 + Double(index) * 0.000_001,
                longitude: 16.37 + Double(index % 25) * 0.000_001,
                unitsData: doorData,
                updatedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
    }
}
