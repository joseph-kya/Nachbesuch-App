import CoreGraphics
import Foundation
import UIKit

// MARK: - Options

/// What goes into an export.
nonisolated struct ExportOptions: Sendable, Equatable {
    /// Leave out addresses where nothing was recorded.
    ///
    /// On by default: an export is a record of work done, and padding it with
    /// hundreds of untouched addresses buries the part anyone actually reads.
    var visitedOnly = true
    /// Field notes are internal shorthand ("Hund", "Abends wiederkommen") and are
    /// not always appropriate to hand on.
    var includeNotes = true

    static let `default` = ExportOptions()
}

// MARK: - Document model

/// A finished report, ready to render. Plain values, so it can be built off the
/// main actor.
nonisolated struct ExportDocument: Sendable {
    let title: String
    let place: String
    let dateRange: String
    /// Compact, numeric campaign date used by the old field-list format.
    let legacyDateLabel: String
    let scopeLabel: String
    let generatedAt: Date
    /// In the order the round actually happened.
    let houses: [ExportHouse]
    let summary: ExportSummary
    let includedHouses: Int
    let totalHouses: Int
    let visitedOnly: Bool
    /// Present when the source of truth was unreadable. Share actions are withheld;
    /// an apparently successful but incomplete export is never produced.
    let validationFailure: String?

    var isEmpty: Bool { houses.isEmpty }
    var isExportable: Bool { validationFailure == nil }

    /// "Ottakring · 1160 Wien · 19. August 2026 · Gesamt"
    var subtitle: String {
        [place, dateRange, scopeLabel].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}

nonisolated struct ExportHouse: Sendable {
    let address: String
    let note: String
    /// Drives the ordering. Deliberately **not** printed — the report reads as the
    /// sequence of the round without turning into a timesheet.
    let recordedAt: Date?
    /// "Dabei" for a single household, "3 von 8 Türen" for an apartment building.
    let result: String
    /// The compact status used by the legacy field list. Empty for apartment
    /// buildings, whose individual doors carry their own symbols.
    let symbol: String
    /// Empty for a single household — the result already says everything.
    let doors: [ExportDoor]
}

nonisolated struct ExportDoor: Sendable {
    let label: String
    let result: String
    let symbol: String
    let recordedAt: Date?
}

nonisolated struct ExportSummary: Sendable {
    var houses = 0
    var doors = 0
    var joined = 0
    var notHome = 0
    var earlyNo = 0
    var lateNo = 0
    var later = 0

    /// Only the outcomes that actually occurred, so a report never carries a column
    /// of zeroes.
    var lines: [(label: String, value: Int)] {
        var result: [(String, Int)] = [("Häuser", houses), ("Haushalte", doors)]
        if joined > 0 { result.append((VisitOutcome.joined.title, joined)) }
        if notHome > 0 { result.append((VisitOutcome.notHome.title, notHome)) }
        if earlyNo > 0 { result.append((VisitOutcome.earlyNo.title, earlyNo)) }
        if lateNo > 0 { result.append((VisitOutcome.lateNo.title, lateNo)) }
        if later > 0 { result.append((VisitOutcome.later.title, later)) }
        return result
    }
}

// MARK: - Service

@MainActor
enum DayExportService {

    private nonisolated struct RawExportHouse: Sendable {
        let address: String
        let note: String
        let createdAt: Date
        let unitsData: Data
    }

    static func makeDocument(
        gebiet: Gebiet,
        houses: [House],
        scope: DayScope,
        options: ExportOptions
    ) async -> ExportDocument {
        let title = gebiet.displayName
        let place = gebiet.districtOrCity
        let dateRange = gebiet.formattedDateRange
        let legacyDateLabel = legacyDateLabel(for: gebiet, scope: scope)
        let isTwoDay = gebiet.isTwoDay
        let raw = houses.map {
            RawExportHouse(
                address: $0.address,
                note: $0.note,
                createdAt: $0.createdAt,
                unitsData: $0.unitsData
            )
        }
        return await Task.detached(priority: .userInitiated) {
            build(
                title: title, place: place, dateRange: dateRange, legacyDateLabel: legacyDateLabel,
                isTwoDay: isTwoDay, raw: raw, scope: scope, options: options
            )
        }.value
    }

    private nonisolated static func build(
        title: String,
        place: String,
        dateRange: String,
        legacyDateLabel: String,
        isTwoDay: Bool,
        raw: [RawExportHouse],
        scope: DayScope,
        options: ExportOptions
    ) -> ExportDocument {
        let decoder = AppCoders.unitsDecoder()
        var summary = ExportSummary()
        var exported: [ExportHouse] = []
        var included = 0
        var damagedAddress: String?

        for house in raw {
            let state = HouseDataState.decode(house.unitsData, decoder: decoder)
            guard let doors = state.doors else {
                damagedAddress = house.address
                break
            }

            // Strict: what was actually recorded for this scope.
            let recorded = doors.compactMap { door -> (DoorResult, VisitOutcome)? in
                guard let outcome = door.recordedOutcome(in: scope) else { return nil }
                return (door, outcome)
            }
            if options.visitedOnly, recorded.isEmpty { continue }
            included += 1

            for (_, outcome) in recorded {
                summary.doors += 1
                switch outcome {
                case .joined: summary.joined += 1
                case .notHome: summary.notHome += 1
                case .earlyNo: summary.earlyNo += 1
                case .lateNo: summary.lateNo += 1
                case .later: summary.later += 1
                }
            }
            summary.houses += 1

            let isSingleHousehold = doors.count == 1
            let result: String
            var exportDoors: [ExportDoor] = []

            if isSingleHousehold {
                result = recorded.first.map { $0.1.label(revisitAt: $0.0.displayRevisitAt(in: scope)) } ?? "Ohne Status"
            } else {
                result = "\(recorded.count) von \(doors.count) Türen"
                // Only the doors that were actually answered — listing five "Offen"
                // rows per building is what made the old export unreadable.
                let listed = options.visitedOnly
                    ? recorded.map {
                        ExportDoor(
                            label: $0.0.label,
                            result: $0.1.label(revisitAt: $0.0.displayRevisitAt(in: scope)),
                            symbol: $0.1.emoji,
                            recordedAt: $0.0.timestamp(in: scope)
                        )
                    }
                    : doors.map {
                        ExportDoor(
                            label: $0.label,
                            result: $0.recordedOutcome(in: scope)?.label(revisitAt: $0.displayRevisitAt(in: scope)) ?? "Ohne Status",
                            symbol: $0.recordedOutcome(in: scope)?.emoji ?? "○",
                            recordedAt: $0.timestamp(in: scope)
                        )
                    }
                // Within a building, the order you worked the doors.
                exportDoors = listed.sorted {
                    ($0.recordedAt ?? .distantFuture) < ($1.recordedAt ?? .distantFuture)
                }
            }

            exported.append(
                ExportHouse(
                    address: house.address,
                    note: options.includeNotes
                        ? house.note.trimmingCharacters(in: .whitespacesAndNewlines)
                        : "",
                    // Arrival time: the first door recorded here.
                    recordedAt: recorded.compactMap { $0.0.timestamp(in: scope) }.min(),
                    result: result,
                    symbol: isSingleHousehold ? (recorded.first?.1.emoji ?? "○") : "",
                    doors: exportDoors
                )
            )
        }

        // The report follows the round. Anything without a timestamp (an address
        // carried along by "alle Adressen") sorts to the end rather than the front.
        exported.sort {
            ($0.recordedAt ?? .distantFuture, $0.address)
                < ($1.recordedAt ?? .distantFuture, $1.address)
        }

        let scopeLabel: String
        switch scope {
        case .day1: scopeLabel = "Tag 1"
        case .day2: scopeLabel = "Tag 2 · Nachbesuch"
        case .combined: scopeLabel = isTwoDay ? "Beide Tage" : ""
        }

        return ExportDocument(
            title: title,
            place: place,
            dateRange: dateRange,
            legacyDateLabel: legacyDateLabel,
            scopeLabel: scopeLabel,
            generatedAt: .now,
            houses: exported,
            summary: summary,
            includedHouses: included,
            totalHouses: raw.count,
            visitedOnly: options.visitedOnly,
            validationFailure: damagedAddress.map {
                "Daten beschädigt bei „\($0)“. Der Export wurde nicht erstellt."
            }
        )
    }

    private static func legacyDateLabel(for gebiet: Gebiet, scope: DayScope) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        formatter.dateFormat = "dd.MM.yyyy"
        switch scope {
        case .day1:
            return formatter.string(from: gebiet.day1Date)
        case .day2:
            return formatter.string(from: gebiet.day2Date ?? gebiet.day1Date)
        case .combined:
            guard gebiet.isTwoDay, let day2 = gebiet.day2Date else {
                return formatter.string(from: gebiet.day1Date)
            }
            return "\(formatter.string(from: gebiet.day1Date))–\(formatter.string(from: day2))"
        }
    }

    // MARK: - Text

    /// For pasting into mail or a messenger. No banner, no emoji, no column padding
    /// (proportional fonts make it ragged anyway).
    nonisolated static func makeText(_ document: ExportDocument) -> String {
        var lines: [String] = []
        lines.append(document.title)
        if !document.subtitle.isEmpty { lines.append(document.subtitle) }
        lines.append("")

        if document.isEmpty {
            lines.append(document.visitedOnly
                ? "In diesem Zeitraum wurde noch kein Haus besucht."
                : "Für dieses Gebiet sind keine Häuser erfasst.")
            return lines.joined(separator: "\n")
        }

        lines.append(document.summary.lines.map { "\($0.label): \($0.value)" }.joined(separator: " · "))
        lines.append("")

        for house in document.houses {
            lines.append("· \(house.address) — \(house.result)")
            for door in house.doors {
                lines.append("    \(door.label) — \(door.result)")
            }
            if !house.note.isEmpty {
                lines.append("    Notiz: \(house.note)")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compact field-list format kept for teams that still paste the old address
    /// overview into Notes or a messenger. Street order follows the actual round.
    nonisolated static func makeLegacyText(_ document: ExportDocument) -> String {
        var lines = [document.legacyDateLabel, ""]
        var groups: [(street: String, houses: [ExportHouse])] = []

        for house in document.houses {
            let street = StreetNameParser.street(from: house.address)
            if let index = groups.firstIndex(where: { $0.street == street }) {
                groups[index].houses.append(house)
            } else {
                groups.append((street, [house]))
            }
        }

        for group in groups {
            var compact = group.street
            var hasCompactHouse = false
            for house in group.houses {
                let number = legacyHouseNumber(from: house.address, street: group.street)
                if house.doors.isEmpty {
                    compact += " \(number)\(house.symbol)"
                    hasCompactHouse = true
                } else {
                    if hasCompactHouse { lines.append(compact) }
                    lines.append("\(group.street) \(number):")
                    lines.append(house.doors.map { "\(legacyDoorLabel($0.label))\($0.symbol)" }.joined(separator: " "))
                    compact = group.street
                    hasCompactHouse = false
                }
            }
            if hasCompactHouse { lines.append(compact) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func legacyHouseNumber(from address: String, street: String) -> String {
        let head = address.split(separator: ",", maxSplits: 1).first.map(String.init) ?? address
        let remainder = head.dropFirst(min(street.count, head.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? head.trimmingCharacters(in: .whitespacesAndNewlines) : remainder
    }

    private nonisolated static func legacyDoorLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("tür ") { return String(trimmed.dropFirst(4)) }
        return trimmed
    }

    // MARK: - PDF

    /// Renders the report.
    ///
    /// `@MainActor` on purpose: `NSAttributedString` drawing and `UIFont` are
    /// main-thread UIKit work. The expensive part — decoding every house — already
    /// happened in `makeDocument`, off the main actor.
    static func makePDF(_ document: ExportDocument) throws -> URL {
        let trace = PerformanceTrace.begin("Render PDF")
        defer { PerformanceTrace.end("Render PDF", id: trace) }

        // Two passes: the first counts pages so the second can print "Seite 2 von 5".
        let pageCount = PDFRenderer(document: document, totalPages: nil).render().pageCount
        let data = PDFRenderer(document: document, totalPages: pageCount).render().data

        let slug = document.title
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let stamp = document.generatedAt.formatted(.iso8601.year().month().day())
        let url = try ExportScratch.makeURL(
            fileName: "Nachbesuch-\(slug.isEmpty ? "Gebiet" : slug)-\(stamp).pdf"
        )
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - PDF renderer

/// A deliberately plain document: one typeface, a small set of sizes, hairline
/// rules, and no colour.
///
/// The previous version drew a red banner across the top, four tinted metric boxes,
/// a grey rounded card behind every address and emoji in the body text — decoration
/// that reads as a screenshot of an app rather than a report.
@MainActor
private struct PDFRenderer {
    let document: ExportDocument
    /// `nil` on the measuring pass.
    let totalPages: Int?

    private let pageSize = CGSize(width: 595.2, height: 841.8)   // A4
    private let margin: CGFloat = 56
    private let footerHeight: CGFloat = 34

    private var contentWidth: CGFloat { pageSize.width - margin * 2 }
    private var contentBottom: CGFloat { pageSize.height - footerHeight }

    private let ink = UIColor.black
    private let secondaryInk = UIColor(white: 0.38, alpha: 1)
    private let hairline = UIColor(white: 0.82, alpha: 1)

    private var resultColumnWidth: CGFloat { 128 }
    /// Addresses sit slightly inside the street heading — enough to read as a
    /// hierarchy, without the empty gutter a row-number column would leave behind.
    private var addressIndent: CGFloat { 12 }
    private var doorIndent: CGFloat { 26 }

    func render() -> (data: Data, pageCount: Int) {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: [document.title, document.dateRange]
                .filter { !$0.isEmpty }.joined(separator: " – "),
            kCGPDFContextAuthor as String: "Nachbesuch"
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize),
            format: format
        )

        var pageCount = 0
        // `pdfData`'s closure is nonisolated but runs synchronously on the calling
        // thread, which is the main actor.
        let data = renderer.pdfData { context in
            MainActor.assumeIsolated {
                pageCount = drawPages(context: context)
            }
        }
        return (data, pageCount)
    }

    private func drawPages(context: UIGraphicsPDFRendererContext) -> Int {
        var pageIndex = 0
        var y: CGFloat = 0

        func newPage() {
            if pageIndex > 0 { drawFooter(pageIndex: pageIndex) }
            context.beginPage()
            pageIndex += 1
            y = margin
            y = pageIndex == 1 ? drawTitleBlock(from: y) : drawRunningHeader(from: y)
        }

        func fits(_ height: CGFloat) -> Bool { y + height <= contentBottom }

        newPage()

        guard !document.isEmpty else {
            let message = document.visitedOnly
                ? "In diesem Zeitraum wurde noch kein Haus besucht."
                : "Für dieses Gebiet sind keine Häuser erfasst."
            _ = draw(message, at: CGRect(x: margin, y: y, width: contentWidth, height: 20),
                     size: 10.5, color: secondaryInk)
            drawFooter(pageIndex: pageIndex)
            return pageIndex
        }

        y = drawSummary(from: y)

        for house in document.houses {
            if !fits(houseHeight(house)) { newPage() }
            y = drawHouse(house, from: y)
        }

        drawFooter(pageIndex: pageIndex)
        return pageIndex
    }

    // MARK: Blocks

    private func drawTitleBlock(from top: CGFloat) -> CGFloat {
        var y = top
        y += draw(document.title, at: CGRect(x: margin, y: y, width: contentWidth, height: 26),
                  size: 18, weight: .semibold, color: ink)
        y += 3
        if !document.subtitle.isEmpty {
            y += draw(document.subtitle, at: CGRect(x: margin, y: y, width: contentWidth, height: 18),
                      size: 10, color: secondaryInk)
        }
        y += 12
        drawRule(at: y)
        return y + 16
    }

    private func drawRunningHeader(from top: CGFloat) -> CGFloat {
        var y = top
        let text = [document.title, document.scopeLabel].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        y += draw(text, at: CGRect(x: margin, y: y, width: contentWidth, height: 14),
                  size: 8.5, color: secondaryInk)
        y += 6
        drawRule(at: y)
        return y + 14
    }

    /// Counts as a row of label/value pairs — no boxes, no tints.
    private func drawSummary(from top: CGFloat) -> CGFloat {
        var y = top
        let items = document.summary.lines
        guard !items.isEmpty else { return y }

        let columnWidth = contentWidth / CGFloat(max(items.count, 1))
        for (index, item) in items.enumerated() {
            let x = margin + CGFloat(index) * columnWidth
            _ = draw("\(item.value)", at: CGRect(x: x, y: y, width: columnWidth - 8, height: 20),
                     size: 15, weight: .semibold, color: ink)
            _ = draw(item.label, at: CGRect(x: x, y: y + 19, width: columnWidth - 8, height: 14),
                     size: 8.5, color: secondaryInk)
        }
        y += 38

        if document.visitedOnly, document.totalHouses > document.includedHouses {
            y += draw(
                "Enthält nur besuchte Adressen — \(document.includedHouses) von \(document.totalHouses).",
                at: CGRect(x: margin, y: y, width: contentWidth, height: 14),
                size: 8.5, color: secondaryInk
            )
            y += 4
        }
        y += 8
        drawRule(at: y)
        return y + 14
    }

    // MARK: House rows

    private func addressColumnWidth() -> CGFloat {
        contentWidth - addressIndent - resultColumnWidth - 12
    }

    private func houseHeight(_ house: ExportHouse) -> CGFloat {
        var height = max(
            measure(house.address, width: addressColumnWidth(), size: 10.5),
            measure(house.result, width: resultColumnWidth, size: 10.5)
        ) + 6
        for door in house.doors {
            height += max(measure(door.label, width: addressColumnWidth() - doorIndent, size: 9.5), 12) + 3
        }
        if !house.note.isEmpty {
            height += measure("Notiz: " + house.note, width: addressColumnWidth() - doorIndent, size: 9) + 3
        }
        return height + 6
    }

    private func drawHouse(_ house: ExportHouse, from top: CGFloat) -> CGFloat {
        var y = top + 4
        let addressWidth = addressColumnWidth()
        let addressX = margin + addressIndent
        let resultX = pageSize.width - margin - resultColumnWidth

        let addressHeight = draw(
            house.address,
            at: CGRect(x: addressX, y: y, width: addressWidth, height: 40),
            size: 10.5, color: ink
        )
        _ = draw(
            house.result,
            at: CGRect(x: resultX, y: y, width: resultColumnWidth, height: 20),
            size: 10.5, color: secondaryInk, alignment: .right
        )
        y += max(addressHeight, 13) + 3

        for door in house.doors {
            let labelHeight = draw(
                door.label,
                at: CGRect(x: addressX + doorIndent, y: y, width: addressWidth - doorIndent, height: 20),
                size: 9.5, color: secondaryInk
            )
            _ = draw(
                door.result,
                at: CGRect(x: resultX, y: y, width: resultColumnWidth, height: 18),
                size: 9.5, color: secondaryInk, alignment: .right
            )
            y += max(labelHeight, 12) + 3
        }

        if !house.note.isEmpty {
            y += draw(
                "Notiz: " + house.note,
                at: CGRect(x: addressX + doorIndent, y: y, width: addressWidth - doorIndent, height: 60),
                size: 9, color: secondaryInk, italic: true
            ) + 3
        }

        y += 5
        drawRule(at: y, color: UIColor(white: 0.9, alpha: 1))
        return y + 1
    }

    // MARK: Chrome

    private func drawFooter(pageIndex: Int) {
        let y = pageSize.height - footerHeight + 10
        drawRule(at: y - 8, color: hairline)
        let left = "Nachbesuch · \(document.generatedAt.formatted(date: .numeric, time: .shortened))"
        _ = draw(left, at: CGRect(x: margin, y: y, width: contentWidth / 2, height: 12),
                 size: 8, color: secondaryInk)
        let right = totalPages.map { "Seite \(pageIndex) von \($0)" } ?? "Seite \(pageIndex)"
        _ = draw(right, at: CGRect(x: margin + contentWidth / 2, y: y, width: contentWidth / 2, height: 12),
                 size: 8, color: secondaryInk, alignment: .right)
    }

    private func drawRule(at y: CGFloat, color: UIColor? = nil) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
        path.lineWidth = 0.5
        (color ?? UIColor(white: 0.72, alpha: 1)).setStroke()
        path.stroke()
    }

    // MARK: Text

    private func attributes(
        size: CGFloat,
        weight: UIFont.Weight,
        color: UIColor,
        alignment: NSTextAlignment,
        italic: Bool
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let font: UIFont
        if italic, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: size)
        } else {
            font = base
        }
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    @discardableResult
    private func draw(
        _ text: String,
        at rect: CGRect,
        size: CGFloat,
        weight: UIFont.Weight = .regular,
        color: UIColor,
        alignment: NSTextAlignment = .left,
        italic: Bool = false
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let string = NSAttributedString(
            string: text,
            attributes: attributes(size: size, weight: weight, color: color, alignment: alignment, italic: italic)
        )
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(string.boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
    }

    private func measure(_ text: String, width: CGFloat, size: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let string = NSAttributedString(
            string: text,
            attributes: attributes(size: size, weight: .regular, color: ink, alignment: .left, italic: false)
        )
        return ceil(string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
    }
}

// MARK: - Scratch space

/// Each export gets its own directory so concurrent or repeated exports cannot
/// overwrite a file the share sheet is still reading, and the whole tree can be
/// swept on launch instead of growing forever in `tmp`.
nonisolated enum ExportScratch {
    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NachbesuchExports", isDirectory: true)

    static func makeURL(fileName: String) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    /// Removes exports from previous launches.
    static func sweep() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
