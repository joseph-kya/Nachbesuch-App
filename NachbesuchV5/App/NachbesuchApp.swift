import SwiftData
import SwiftUI

@main
struct NachbesuchApp: App {
    @State private var notices = AppNoticeCenter()
    private let store = AppStore.load()

    init() {
        // Exports from previous launches are dead weight in `tmp`.
        ExportScratch.sweep()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let failure = store.failure {
                    // The store exists on disk but cannot be opened. Better to say so
                    // and offer the file than to `fatalError` on every launch with the
                    // user's field work locked inside.
                    StoreRecoveryView(error: failure.error, storeURL: failure.storeURL)
                } else {
                    RootView()
                }
            }
            .environment(notices)
            // The app is German-only; pinning the locale keeps a weekday from being
            // rendered in German next to a date rendered in the device language.
            .environment(\.locale, Locale(identifier: "de_AT"))
        }
        .modelContainer(store.container)
    }
}

/// Shown only when the database cannot be opened.
struct StoreRecoveryView: View {
    let error: any Error
    let storeURL: URL?

    var body: some View {
        VStack(spacing: AppSpacing.regular) {
            ContentUnavailableView {
                Label("Daten konnten nicht geladen werden", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("Die gespeicherten Gebiete lassen sich gerade nicht öffnen. Deine Datei wurde nicht verändert.")
            }

            if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
                ShareLink(item: storeURL) {
                    Label("Datenbank sichern", systemImage: "square.and.arrow.up")
                        .frame(minHeight: AppTouch.minimum)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }

            Text(error.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.loose)
        }
        .padding()
    }
}
