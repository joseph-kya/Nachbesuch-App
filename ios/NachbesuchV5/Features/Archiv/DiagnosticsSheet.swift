import SwiftUI
import UIKit

#if DEBUG
/// Hidden field diagnostics (B4): fix count, mean accuracy and the share of
/// fixes above the puck's uncertainty threshold, plus the authorization state.
/// DEBUG-only, nothing leaves the device. Opened by long-pressing the Archiv
/// overflow button — there is no visible entry point on purpose.
struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var location

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
                    LabeledContent(
                        "System",
                        value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                    )
                    LabeledContent("Modell", value: UIDevice.current.model)
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
    }
}
#endif
