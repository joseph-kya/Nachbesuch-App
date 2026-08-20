import Foundation
import SwiftData

/// Inserts many houses at once on a background context.
@ModelActor
actor BulkHouseImporter {
    /// Batched so a 5 000-house import neither holds one enormous transaction nor
    /// retains every inserted object in the context at once, and so cancellation is
    /// actually honoured partway through.
    private static let batchSize = 400

    func insert(_ addresses: [ImportedAreaAddress], gebietID: UUID) throws -> Int {
        let trace = PerformanceTrace.begin("Bulk insert houses")
        defer { PerformanceTrace.end("Bulk insert houses", id: trace) }

        modelContext.autosaveEnabled = false
        var inserted = 0

        for chunk in addresses.chunked(into: Self.batchSize) {
            try Task.checkCancellation()
            for address in chunk {
                modelContext.insert(House(
                    address: address.address,
                    latitude: address.latitude,
                    longitude: address.longitude,
                    gebietID: gebietID,
                    isApartmentBuilding: false,
                    unitCount: 1
                ))
                inserted += 1
            }
            try modelContext.save()
        }
        return inserted
    }
}

nonisolated extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
