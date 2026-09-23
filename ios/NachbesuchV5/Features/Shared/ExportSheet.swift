import SwiftData
import SwiftUI
import UIKit

/// Export a territory — or a hand-picked selection — as PDF or text.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let gebiet: Gebiet
    let houses: [House]
    /// Street encounters of the territory. The pin-selection export carries
    /// houses only — passanten are not selectable — the archive export passes
    /// the whole set.
    let passanten: [Passant]
    let scope: DayScope
    /// Set when the caller already picked the houses by hand, so the sheet doesn't
    /// quietly drop some of them again.
    var isPreselected = false

    @AppStorage("export.visitedOnly") private var visitedOnly = true
    @AppStorage("export.includeNotes") private var includeNotes = true
    @State private var document: ExportDocument?
    @State private var pdfURL: URL?
    @State private var isBuilding = true
    @State private var pdfFailed = false
    @State private var buildRevision = 0

    private var options: ExportOptions {
        ExportOptions(visitedOnly: visitedOnly && !isPreselected, includeNotes: includeNotes)
    }

    private struct BuildKey: Hashable {
        let gebietID: UUID
        let scope: DayScope
        let count: Int
        let visitedOnly: Bool
        let includeNotes: Bool
        let revision: Int
    }

    private var buildKey: BuildKey {
        // No max(updatedAt) scan: houses is a snapshot taken in prepareExport
        // and never mutates in place while open. The old key faulted updatedAt
        // on every house on every body eval (every toggle) — the exact
        // main-thread fault storm List/Archive already removed.
        BuildKey(
            gebietID: gebiet.id,
            scope: scope,
            count: houses.count,
            visitedOnly: options.visitedOnly,
            includeNotes: options.includeNotes,
            revision: buildRevision
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                scopeSection
                if !isPreselected { rangeSection }
                contentSection
                shareSection
            }
            .glassForm()
            .navigationTitle("Exportieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
            .task(id: buildKey) { await rebuild() }

        }
    }

    // MARK: Sections

    private var scopeSection: some View {
        Section {
            LabeledContent("Gebiet", value: gebiet.displayName)
            LabeledContent("Zeitraum", value: gebiet.formattedDateRange)
            if gebiet.isTwoDay {
                LabeledContent("Tag", value: scope.title)
            }
        }
        .glassRows()
    }

    private var rangeSection: some View {
        Section {
            Toggle("Nur besuchte Adressen", isOn: $visitedOnly)
        } header: {
            Text("Umfang")
        } footer: {
            if let document {
                Text(options.visitedOnly
                     ? "\(document.includedHouses) von \(document.totalHouses) Adressen — Häuser ohne Eintrag bleiben weg."
                     : "Alle \(document.totalHouses) Adressen, auch die ohne Eintrag.")
            } else {
                Text("Häuser ohne einen einzigen Eintrag werden weggelassen.")
            }
        }
        .glassRows()
    }

    private var contentSection: some View {
        Section {
            // „N Häuser, M Passanten" mit Zahlen-Morph — derselbe Stand, den die
            // Teilen-Buttons gleich darunter verschicken.
            HStack {
                // Not "Umfang": that is already the heading of the section above,
                // and one sheet had two different things called the same.
                Text("Im Export")
                Spacer()
                Text("\(summaryCounts.houses) Häuser, \(summaryCounts.passanten) Passanten")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(summaryTotal)))
                    .animation(.appFeedback(reduceMotion: reduceMotion), value: summaryTotal)
            }
            .accessibilityLabel("\(summaryCounts.houses) Häuser, \(summaryCounts.passanten) Passanten im Export")

            Toggle("Notizen einbeziehen", isOn: $includeNotes)

            if let document, !document.isEmpty {
                // Only the outcomes that actually occurred, so this never shows a
                // column of zeroes.
                ForEach(document.summary.lines, id: \.label) { line in
                    LabeledContent(line.label) {
                        Text("\(line.value)").monospacedDigit()
                    }
                }
            } else if isBuilding {
                LabeledContent("Haushalte", value: "—")
                    .redacted(reason: .placeholder)
            }
        } header: {
            Text("Inhalt")
        } footer: {
            Text("Notizen sind interne Stichworte und landen sonst mit im Dokument.")
        }
        .glassRows()
    }

    @ViewBuilder
    private var shareSection: some View {
        Section {
            if let failure = document?.validationFailure {
                ContentUnavailableView {
                    Label("Export nicht möglich", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Diagnosehinweis kopieren") {
                        UIPasteboard.general.string = failure
                        notices.show("Diagnosehinweis kopiert")
                    }
                }
            } else if let document, document.isEmpty {
                ContentUnavailableView {
                    Label("Nichts zu exportieren", systemImage: "tray")
                } description: {
                    Text(options.visitedOnly
                         ? "In diesem Zeitraum wurde noch keine Adresse besucht. Schalte „Nur besuchte Adressen“ aus, um die Arbeitsliste zu exportieren."
                         : "Für dieses Gebiet sind keine Adressen erfasst.")
                }
            } else {
                if let pdfURL {
                    ShareLink(item: pdfURL) {
                        exportAction(
                            title: "PDF-Bericht",
                            subtitle: "Für Ablage und Ausdruck",
                            systemImage: "doc.richtext"
                        )
                    }
                } else if pdfFailed {
                    Button {
                        buildRevision &+= 1
                    } label: {
                        Label("PDF erneut erstellen", systemImage: "arrow.clockwise")
                    }
                } else {
                    HStack {
                        Label("PDF wird erstellt …", systemImage: "doc.text")
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                    .foregroundStyle(.secondary)
                }

                if let document {
                    ShareLink(item: DayExportService.makeText(document)) {
                        exportAction(
                            title: "Textbericht",
                            subtitle: "Lesbar in Mail und Messenger",
                            systemImage: "text.alignleft"
                        )
                    }
                    ShareLink(item: DayExportService.makeLegacyText(document)) {
                        exportAction(
                            title: "Kompakte Adressliste",
                            subtitle: "Straßen, Hausnummern und Statussymbole",
                            systemImage: "list.bullet.rectangle"
                        )
                    }
                }
            }
        } header: {
            Text("Format")
        } footer: {
            Text("Die kompakte Adressliste enthält Straßen, Hausnummern und Status, ohne Notizen.")
        }
        .glassRows()
    }

    private func exportAction(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: AppSpacing.snug) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: AppTouch.minimum)
        .contentShape(Rectangle())
    }

    // MARK: Build

    /// Was im Export landet: Dokument-Stand, sonst Schnappschuss des Callers.
    private var summaryCounts: (houses: Int, passanten: Int) {
        if let document {
            (document.includedHouses, document.passanten.count)
        } else {
            (houses.count, passanten.count)
        }
    }

    private var summaryTotal: Int { summaryCounts.houses + summaryCounts.passanten }

    private func rebuild() async {
        isBuilding = true
        // The old file is stale the moment an option changes; drop it so the button
        // cannot hand out a document that no longer matches the settings.
        pdfURL = nil
        document = nil
        pdfFailed = false
        defer { isBuilding = false }

        let built = await DayExportService.makeDocument(
            gebiet: gebiet,
            houses: houses,
            scope: scope,
            options: options,
            passanten: passanten
        )
        guard !Task.isCancelled else { return }
        document = built
        guard built.isExportable, !built.isEmpty else { return }

        do {
            let url = try DayExportService.makePDF(built)
            guard !Task.isCancelled else { return }
            pdfURL = url
        } catch {
            pdfFailed = true
            notices.report(error, context: "PDF konnte nicht erstellt werden")
        }
    }
}
