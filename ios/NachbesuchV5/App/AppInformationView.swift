import Foundation
import SwiftUI

/// Publishing details live in one bundled resource, checked before submission.
nonisolated struct AppStoreMetadata: Decodable {
    let developerName: String
    let supportEmail: String
    let supportURL: String
    let privacyPolicyURL: String

    enum CodingKeys: String, CodingKey {
        case developerName = "DeveloperName"
        case supportEmail = "SupportEmail"
        case supportURL = "SupportURL"
        case privacyPolicyURL = "PrivacyPolicyURL"
    }

    static let current: AppStoreMetadata? = {
        guard let url = Bundle.main.url(forResource: "AppStoreMetadata", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(AppStoreMetadata.self, from: data)
    }()

    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

struct AppInformationView: View {
    private let metadata = AppStoreMetadata.current

    var body: some View {
        List {
            Section("Nachbesuch") {
                LabeledContent("Version", value: version)
                if let name = metadata?.developerName, !name.isEmpty {
                    LabeledContent("Anbieter", value: name)
                }
            }
            Section("Datenschutz") {
                NavigationLink("Daten und Berechtigungen") { PrivacyDetailsView() }
                if let url = metadata.flatMap({ AppStoreMetadata.webURL($0.privacyPolicyURL) }) {
                    Link("Datenschutzerklärung im Web", destination: url)
                }
            }
            Section("Hilfe") {
                Text("Die Anleitung findest du im Archiv über das Menü oben rechts. Sichere deine Daten vor einem Gerätewechsel über Archiv → Sicherung.")
                if let url = metadata.flatMap({ AppStoreMetadata.webURL($0.supportURL) }) {
                    Link("Support öffnen", destination: url)
                }
                if let email = metadata?.supportEmail, !email.isEmpty,
                   let url = URL(string: "mailto:\(email)") {
                    Link("Support per E-Mail", destination: url)
                }
                Text("Teile bei Support-Anfragen keine Adressen oder Gesprächsnotizen. Unter Archiv → Sicherung kannst du einen Diagnosebericht ohne diese Inhalte erstellen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Kartendaten") {
                Text("Karte und Ortssuche: Apple Karten. Die Hinweise und Nutzungsbedingungen sind direkt in der Karte erreichbar.")
                Link("Adressimport: © OpenStreetMap-Mitwirkende",
                     destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Text("OpenStreetMap-Daten stehen unter der Open Database License (ODbL).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
