import CoreLocation
import Foundation
import SwiftData

enum CampaignDuration: Int, Codable, CaseIterable, Identifiable, Sendable {
    case singleDay = 1
    case twoDays = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .singleDay: "1 Tag"
        case .twoDays: "2 Tage"
        }
    }
}

/// A canvassing territory: one round of work over one or two calendar days.
///
/// **Stored shape is frozen** — see the note on `House`.
@Model
final class Gebiet {
    @Attribute(.unique) var id: UUID
    var name: String
    var districtOrCity: String
    var notes: String
    var isTwoDay: Bool
    var day1Date: Date
    var day2Date: Date?
    var boundaryData: Data
    var createdAt: Date
    var updatedAt: Date

    /// Cached decoded boundary. Invalidated by the setter rather than by hashing the
    /// blob — `Data.hashValue` only mixes in a bounded prefix, so editing a later
    /// vertex produced an identical stamp and returned a stale polygon.
    @Transient private var cachedBoundary: [CLLocationCoordinate2D]?

    init(
        name: String = "",
        districtOrCity: String = "",
        date: Date = .now,
        isTwoDay: Bool = false,
        day2Date: Date? = nil,
        boundaryCoordinates: [CLLocationCoordinate2D] = []
    ) {
        id = UUID()
        self.name = name
        self.districtOrCity = districtOrCity
        notes = ""
        self.isTwoDay = isTwoDay
        day1Date = Self.campaignCalendar.startOfDay(for: date)
        self.day2Date = nil
        createdAt = .now
        updatedAt = .now
        boundaryData = Data()
        normalizeDays(requestedDay2: day2Date)
        if !boundaryCoordinates.isEmpty {
            self.boundaryCoordinates = boundaryCoordinates
        }
    }

    /// One calendar for every campaign-day decision in the app.
    ///
    /// Deliberately the user's current calendar, matching how existing stores were
    /// written — switching to a fixed zone now would shift every saved date by a day.
    /// The known limitation is that campaign days are interpreted in whatever
    /// timezone the device is in when they are read.
    nonisolated static var campaignCalendar: Calendar { Calendar.current }

    /// Marks the record changed. Every mutation must call this: the archive index
    /// and search key off `updatedAt`, so a rename that skips it keeps serving the
    /// old name until something unrelated happens to touch the record.
    func touch() {
        let now = Date.now
        updatedAt = now > updatedAt ? now : updatedAt.addingTimeInterval(0.001)
    }

    func rename(to newName: String, districtOrCity newPlace: String? = nil) {
        name = newName
        if let newPlace { districtOrCity = newPlace }
        touch()
    }

    var duration: CampaignDuration {
        get { isTwoDay ? .twoDays : .singleDay }
        set {
            isTwoDay = (newValue == .twoDays)
            normalizeDays(requestedDay2: day2Date)
            touch()
        }
    }

    /// Assigns both campaign days at once, keeping the invariant that a two-day
    /// territory always has a second day and that it is strictly after the first.
    func assignDays(day1: Date, day2: Date?) {
        day1Date = Self.campaignCalendar.startOfDay(for: day1)
        normalizeDays(requestedDay2: day2)
        touch()
    }

    /// The single guard for `isTwoDay ⇒ day2Date != nil, day2Date > day1Date`.
    /// Both `init` and backup import used to write past this and could leave a
    /// territory labelled "2 Tage" with no second day at all.
    private func normalizeDays(requestedDay2: Date?) {
        guard isTwoDay else {
            day2Date = nil
            return
        }
        let calendar = Self.campaignCalendar
        if let requested = requestedDay2.map({ calendar.startOfDay(for: $0) }),
           requested > day1Date {
            day2Date = requested
            return
        }
        // `byAdding: .day` can land on 23:00 across a DST boundary, which would stop
        // the result being a startOfDay and break every date-keyed lookup.
        let next = calendar.date(byAdding: .day, value: 1, to: day1Date) ?? day1Date.addingTimeInterval(86_400)
        day2Date = calendar.startOfDay(for: next)
    }

    /// Which campaign day (1 or 2) falls on the given calendar day, if any.
    func dayIndex(on date: Date) -> Int? {
        let calendar = Self.campaignCalendar
        if calendar.isDate(day1Date, inSameDayAs: date) { return 1 }
        if isTwoDay, let day2Date, calendar.isDate(day2Date, inSameDayAs: date) { return 2 }
        return nil
    }

    /// The scope a door edit should be written to right now — derived from the
    /// calendar, not from whatever the on-screen picker happens to show.
    func writeScope(on date: Date = .now) -> DayScope {
        dayIndex(on: date) == 2 ? .day2 : .day1
    }

    var assignedDates: [Date] {
        if isTwoDay, let day2Date { return [day1Date, day2Date] }
        return [day1Date]
    }

    var endDate: Date {
        if isTwoDay, let day2Date { return day2Date }
        return day1Date
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let place = districtOrCity.trimmingCharacters(in: .whitespacesAndNewlines)
        return place.isEmpty ? "Gebiet" : place
    }

    // MARK: - Boundary

    /// Kurzschluss ohne Decode: Leere Blobs (der Normalfall „keine Grenze",
    /// also der disabled Menü-Pfad) kosten kein JSON-Decode pro Body-Auswertung;
    /// der Rest läuft über den Cache von `boundaryCoordinates`.
    var hasBoundary: Bool {
        if let cachedBoundary { return cachedBoundary.count >= 3 }
        if boundaryData.isEmpty { return false }
        return boundaryCoordinates.count >= 3
    }

    var boundaryCoordinates: [CLLocationCoordinate2D] {
        get {
            if let cachedBoundary { return cachedBoundary }
            guard !boundaryData.isEmpty,
                  let points = try? AppCoders.boundaryDecoder()
                      .decode([StoredCoordinate].self, from: boundaryData)
            else {
                cachedBoundary = []
                return []
            }
            let coordinates = points.map(\.coordinate)
            cachedBoundary = coordinates
            return coordinates
        }
        set {
            // Bewusst synchron auf dem Aufruf-Thread: Polygone sind klein (Grenzen
            // mit wenigen Hundert Punkten), Encode kostet Mikrosekunden — ein
            // Hintergrund-Hop würde Cache (`cachedBoundary`), Blob und `touch()`
            // auseinanderreißen. Wer je riesige Polygone setzt, lagert den Aufruf
            // selbst aus; Verhalten hier bleibt absichtlich unverändert.
            guard !newValue.isEmpty else {
                boundaryData = Data()
                cachedBoundary = []
                touch()
                return
            }
            let valid = newValue.filter { StoredCoordinate($0).isPlausible }
            guard valid.count >= 3 else { return }
            // Never clobber a readable boundary with an encode failure.
            guard let encoded = try? AppCoders.boundaryEncoder()
                .encode(valid.map(StoredCoordinate.init)) else { return }
            boundaryData = encoded
            cachedBoundary = valid
            touch()
        }
    }

    // MARK: - Formatting

    private static let austrianLocale = Locale(identifier: "de_AT")
    private static let mediumDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = austrianLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    private static let monthYear = Date.FormatStyle.dateTime.month(.wide).year().locale(austrianLocale)
    private static let dayMonth = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(austrianLocale)
    private static let dayMonthYear = Date.FormatStyle.dateTime.day().month(.abbreviated).year().locale(austrianLocale)

    var formattedDateRange: String {
        guard isTwoDay, day2Date != nil else {
            return Self.mediumDate.string(from: day1Date)
        }
        let calendar = Self.campaignCalendar
        let start = calendar.dateComponents([.day, .month, .year], from: day1Date)
        let end = calendar.dateComponents([.day, .month, .year], from: endDate)
        if start.month == end.month, start.year == end.year {
            return "\(start.day ?? 1). – \(end.day ?? 2). \(day1Date.formatted(Self.monthYear))"
        }
        return "\(day1Date.formatted(Self.dayMonth)) – \(endDate.formatted(Self.dayMonthYear))"
    }
}
