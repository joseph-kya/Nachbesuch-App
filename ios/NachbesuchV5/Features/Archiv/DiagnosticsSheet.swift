import SwiftUI
import UIKit

#if DEBUG
/// Hidden field diagnostics (B4): fix count, mean accuracy and the share of
/// fixes above the puck's uncertainty threshold, plus the authorization state.
/// DEBUG-only, nothing leaves the device. Opened by long-pressing the Archiv
/// overflow button — there is no visible entry point on purpose.
struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LocationService.self) private var location
    /// WAVE2: clipboard confirmation morph.
    @State private var copied = false
    /// Success buzz only on copy, never on the 2s reset (StreetHeader-Pattern).
    @State private var copyToken = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Standort") {
                    LabeledContent("Status", value: String(describing: location.authorization))
                    LabeledContent(
                        "Genauigkeit",
                        value: location.isReducedAccuracy ? "ungefähr" : "genau"
                    )
                    LabeledContent("Messwerte", value: location.debugDiagnostics)
                }
                Section("App") {
                    LabeledContent(
                        "Version",
                        value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
                            + " (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
                    )
                    // WAVE3: statische Welle/Schema-Zeile — trivial, kein Fetch.
                    // Gebiets-/Haus-Zähler bewusst nicht hier: das wäre ein
                    // Main-Fetch im Sheet, den wir nicht einführen.
                    LabeledContent("Welle", value: "Welle 3 · Schema V2")
                    LabeledContent(
                        "System",
                        value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                    )
                    LabeledContent("Modell", value: UIDevice.current.model)
                }
                Section("Weitergabe") {
                    Button {
                        UIPasteboard.general.string = diagnosticsText
                        copied = true
                        copyToken &+= 1
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Group {
                            if copied {
                                Label("Kopiert", systemImage: "checkmark")
                                    .transition(.blockSwap(reduceMotion: reduceMotion))
                            } else {
                                Label("Diagnose kopieren", systemImage: "doc.on.doc")
                                    .transition(.blockSwap(reduceMotion: reduceMotion))
                            }
                        }
                        .animation(.appFeedback(reduceMotion: reduceMotion), value: copied)
                    }
                    .sensoryFeedback(.success, trigger: copyToken)
                    .accessibilityLabel("Diagnose in Zwischenablage kopieren")
                    .accessibilityValue(copied ? "Kopiert" : "")
                }
            }
            .navigationTitle("Diagnose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    /// Counts only, never donor data — mirrors DiagnosticsExport.
    private var diagnosticsText: String {
        let version =
            "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
            + " (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
        return [
            "Nachbesuch-Diagnose",
            "Status: \(String(describing: location.authorization))",
            "Genauigkeit: \(location.isReducedAccuracy ? "ungefähr" : "genau")",
            "Messwerte: \(location.debugDiagnostics)",
            "Version: \(version)",
            "Welle: Welle 3 · Schema V2",
            "System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "Modell: \(UIDevice.current.model)",
        ].joined(separator: "\n")
    }
}
#endif
