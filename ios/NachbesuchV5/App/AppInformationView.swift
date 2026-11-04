import Foundation
import SwiftUI

struct AppInformationView: View {
    var body: some View {
        List {
            Section("Nachbesuch") {
                LabeledContent("Version", value: version)
            }
            .glassRows()
            Section("Datenschutz") {
                NavigationLink("Daten und Berechtigungen") { PrivacyDetailsView() }
            }
            .glassRows()
            Section("Hilfe") {
                Text("Die Anleitung findest du im Archiv über das Menü oben rechts. Sichere deine Daten vor einem Gerätewechsel über Archiv → Sicherung.")
            }
            .glassRows()
            Section("Kartendaten") {
                Text("Karte und Ortssuche: Apple Karten. Die Hinweise und Nutzungsbedingungen sind direkt in der Karte erreichbar.")
                Link("Adressimport: © OpenStreetMap-Mitwirkende",
                     destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Text("OpenStreetMap-Daten stehen unter der Open Database License (ODbL).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .glassRows()
        }
        .scrollContentBackground(.hidden)
        .background { AppBackdrop() }
        .navigationTitle("Datenschutz & Support")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "–") (\(info["CFBundleVersion"] as? String ?? "–"))"
    }
}

struct PrivacyDetailsView: View {
    private static let policy = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    var body: some View {
        ScrollView {
            Text(Self.policy ?? "Die Datenschutzinformationen konnten nicht geladen werden.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Daten und Berechtigungen")
        .navigationBarTitleDisplayMode(.inline)
    }
}
