import SwiftData
import SwiftUI
import UIKit

/// Export a territory — or a hand-picked selection — as PDF or text.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppNoticeCenter.self) private var notices

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
    /// Pre-built retention prompt (B12), defaulted off: with the flag on, the
    /// export offers deleting the territory from the device afterwards.
    @AppStorage("export.deleteAfterExportPrompt") private var deleteAfterExportPrompt = false

    @State private var document: ExportDocument?
    @State private var pdfURL: URL?
    @State private var isBuilding = true
    @State private var showsDeleteConfirm = false

    private var options: ExportOptions {
        ExportOptions(visitedOnly: visitedOnly && !isPreselected, includeNotes: includeNotes)
    }

    private struct BuildKey: Hashable {
        let gebietID: UUID
        let scope: DayScope
        let count: Int
        let newestUpdate: Date?
        let visitedOnly: Bool
        let includeNotes: Bool
    }

    private var buildKey: BuildKey {
        BuildKey(
            gebietID: gebiet.id,
            scope: scope,
            count: houses.count,
            newestUpdate: houses.max(by: { $0.updatedAt < $1.updatedAt })?.updatedAt,
            visitedOnly: options.visitedOnly,
            includeNotes: options.includeNotes
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                scopeSection
                if !isPreselected { rangeSection }
                contentSection
                shareSection
                if deleteAfterExportPrompt, !isPreselected { cleanupSection }
            }
            .navigationTitle("Exportieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
            .task(id: buildKey) { await rebuild() }
            .alert(
                "„\(gebiet.displayName)“ löschen?",
                isPresented: $showsDeleteConfirm,
                actions: {
                    Button("Löschen", role: .destructive) { Task { await deleteGebiet() } }
                    Button("Behalten", role: .cancel) {}
                },
                message: {
                    Text("Der Export bleibt bestehen. Alle Häuser und Ergebnisse werden vom Gerät entfernt.")
                }
            )
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
    }

    private var rangeSection: some View {
        Section {
            Toggle("Nur besuchte Adressen", isOn: $visitedOnly)
        } header: {
            Text("Umfang")
        } footer: {
            if let document {
                Text(visitedOnly
                     ? "\(document.includedHouses) von \(document.totalHouses) Adressen — Häuser ohne Eintrag bleiben weg."
                     : "Alle \(document.totalHouses) Adressen, auch die ohne Eintrag.")
            } else {
                Text("Häuser ohne einen einzigen Eintrag werden weggelassen.")
            }
        }
    }

    private var contentSection: some View {
        Section {
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
                    Text(visitedOnly
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
                            title: "Legacy-Adressliste",
                            subtitle: "Straßen, Hausnummern und Statussymbole",
                            systemImage: "list.bullet.rectangle"
                        )
                    }
                }
            }
        } header: {
            Text("Format")
        } footer: {
            Text("Die Legacy-Liste entspricht dem früheren kompakten Adressschema und enthält keine Notizen.")
        }
    }

    private func exportAction(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
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

    private var cleanupSection: some View {
        Section {
            if let document, document.isExportable, !document.isEmpty {
                Button(role: .destructive) { showsDeleteConfirm = true } label: {
                    Label("Gebiet exportiert. Jetzt vom Gerät löschen?", systemImage: "trash")
                }
            }
        } header: {
            Text("Aufräumen")
        } footer: {
            Text("Erst exportieren, dann löschen — nie umgekehrt.")
        }
    }

    private func deleteGebiet() async {
        guard await GebietDeletion.delete(gebiet.id, in: modelContext, notices: notices) else { return }
        dismiss()
    }

    private func rebuild() async {
        isBuilding = true
        // The old file is stale the moment an option changes; drop it so the button
        // cannot hand out a document that no longer matches the settings.
        pdfURL = nil
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
            notices.report(error, context: "PDF konnte nicht erstellt werden")
        }
    }
}
