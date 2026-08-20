import CoreLocation
import Foundation
import SwiftData

/// Legacy model from before territories existed.
///
/// It is retained **only** because removing a type from the schema is not a
/// lightweight migration and this app has no migration history yet — dropping it
/// would make existing stores fail to open. `RootView` migrates any surviving rows
/// into `Gebiet` once and then leaves them alone. Do not add features here.
@Model
final class CampaignDay {
    @Attribute(.unique) var id: UUID
    var date: Date
    var createdAt: Date
    var boundaryData: Data

    init(date: Date) {
        id = UUID()
        self.date = Gebiet.campaignCalendar.startOfDay(for: date)
        createdAt = .now
        boundaryData = Data()
    }

    var boundaryCoordinates: [CLLocationCoordinate2D] {
        guard !boundaryData.isEmpty,
              let points = try? AppCoders.boundaryDecoder()
                  .decode([StoredCoordinate].self, from: boundaryData)
        else { return [] }
        return points.map(\.coordinate)
    }
}
