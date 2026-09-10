import Foundation
import SwiftData
import Testing
@testable import NachbesuchV5

/// The map and the list each held a private copy of the debounced save. They
/// drifted — the list flushed what was still pending on teardown, the map cancelled
/// it — and a status recorded on the map inside the debounce window was lost. These
/// hold the shared replacement to both halves of that contract.
@MainActor
@Suite("Verzögertes Speichern")
struct PendingSaveTests {

    private func scratchContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func insertHouse(into context: ModelContext) {
        context.insert(
            House(
                address: "Teststraße 1",
                latitude: 48.2,
                longitude: 16.37,
                gebietID: UUID(),
                isApartmentBuilding: false,
                unitCount: 1
            )
        )
    }

    @Test("Ein Schwall Tipps wird zu einem Schreibvorgang zusammengezogen")
    func schedulingDefersTheWrite() throws {
        let context = try scratchContext()
        let saver = PendingSave(delay: .milliseconds(50))
        insertHouse(into: context)

        saver.schedule(in: context, reporting: AppNoticeCenter())
        // Still pending: the point of the debounce is that nothing has been written
        // yet at this instant.
        #expect(context.hasChanges)
    }

    /// The regression this whole extraction exists for.
    @Test("Abräumen schreibt, was noch aussteht")
    func flushCommitsPendingWork() throws {
        let context = try scratchContext()
        let saver = PendingSave(delay: .seconds(30))
        insertHouse(into: context)

        saver.schedule(in: context, reporting: AppNoticeCenter())
        saver.flush(in: context, reporting: AppNoticeCenter())

        // Cancelling without flushing is what dropped the door: the mutation stayed
        // live in the context, unsaved, until some unrelated write happened by.
        #expect(!context.hasChanges)
        #expect(try context.fetchCount(FetchDescriptor<House>()) == 1)
    }

    @Test("Abräumen ohne offene Änderung ist folgenlos")
    func flushIsHarmlessWhenIdle() throws {
        let context = try scratchContext()
        let saver = PendingSave()

        saver.flush(in: context, reporting: AppNoticeCenter())

        #expect(!context.hasChanges)
        #expect(try context.fetchCount(FetchDescriptor<House>()) == 0)
    }
}

/// Das Tor vor `didSave`-Refreshes (Liste/Karte/Archiv): Bulk-Import speichert
/// mehrfach pro Sekunde, das Gate faltet den Schwall zu einem Refresh.
@Suite("DidSave-Refresh-Gate")
struct DidSaveRefreshGateTests {

    @Test("Drei schnelle Signale ergeben einen Refresh")
    func burstFoldsToOneRefresh() {
        let gate = DidSaveRefreshGate()
        let now = Date()

        #expect(gate.shouldRefresh(now: now))
        #expect(!gate.shouldRefresh(now: now), "Zweites Signal im selben Burst ist Rauschen")
        #expect(!gate.shouldRefresh(now: now.addingTimeInterval(0.1)))
        #expect(gate.shouldRefresh(now: now.addingTimeInterval(0.6)), "Nach dem Ruheabstand darf wieder gelesen werden")
    }

    @Test("Reset vergisst den letzten Durchlass")
    func resetForgetsLastPass() {
        let gate = DidSaveRefreshGate()

        #expect(gate.shouldRefresh())
        #expect(!gate.shouldRefresh())
        gate.reset()
        #expect(gate.shouldRefresh(), "Z. B. bei Gebietswechsel sofort wieder lesen")
    }
}
