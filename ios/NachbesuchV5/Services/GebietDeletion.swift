import Foundation
import SwiftData
import UIKit

/// Deletes a territory with everything hanging off it.
///
/// Extracted from `ArchiveScreen.delete` so the export sheet can offer the
/// same deletion after an export: one meaning of "delete a territory",
/// whether it starts from the archive card or from the export sheet.
@MainActor
enum GebietDeletion {
    /// Deletes the territory, its houses and their reminders. Returns false
    /// when nothing was removed — the caller keeps its own selection and
    /// sheets untouched in that case.
    @discardableResult
    static func delete(
        _ id: UUID,
        in modelContext: ModelContext,
        notices: AppNoticeCenter
    ) async -> Bool {
        // Both reads before either delete: a failed read must leave the
        // context untouched, never half-deleted objects waiting for the next
        // unrelated save to commit them.
        let dependents: [House]
        let passanten: [Passant]
        let gebiet: Gebiet
        do {
            dependents = try modelContext.fetch(
                FetchDescriptor<House>(predicate: #Predicate { $0.gebietID == id || $0.dayID == id })
            )
            passanten = try modelContext.fetch(
                FetchDescriptor<Passant>(predicate: #Predicate { $0.gebietID == id })
            )
            guard let found = try modelContext.fetch(
                FetchDescriptor<Gebiet>(predicate: #Predicate { $0.id == id })
            ).first else { return false }
            gebiet = found
        } catch {
            notices.report(error, context: "Zugehörige Häuser konnten nicht gelesen werden. Nichts wurde gelöscht")
            return false
        }
        for house in dependents { modelContext.delete(house) }
        for passant in passanten { modelContext.delete(passant) }
        modelContext.delete(gebiet)
        guard modelContext.save(reporting: notices, context: "Gebiet konnte nicht gelöscht werden") else {
            return false
        }
        for house in dependents {
            await ReminderService.cancelAllRevisits(house: house.id)
        }
        for passant in passanten {
            await ReminderService.cancelAllRevisits(house: passant.id)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }
}
