import SwiftData
import SwiftUI

@main
struct NachbesuchApp: App {
    @State private var notices = AppNoticeCenter()
    private let store = AppStore.load()

    /// The standing "send the list" reminder. Mirrored into `AppStorage` by the
    /// settings sheet; read here so the schedule is re-applied on every launch,
    /// which is also what repairs it after a restore to a new device.
    @AppStorage(ReminderSettings.dailyListKey) private var dailyListRemindersEnabled = true

    init() {
        // Exports from previous launches are dead weight in `tmp`.
        ExportScratch.sweep()
        // Must be set before any scene connects, or a reminder arriving in the
        // first seconds of a launch is swallowed.
        ReminderPresenter.install()
        // Same timing requirement: `UITabBar.appearance()` is read when the bar is
        // first created, so a scene that connects before this call keeps the
        // transparent default. No-op on iOS 26.
        LegacyBarAppearance.applyIfNeeded()
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
            .task(id: dailyListRemindersEnabled) {
                await ReminderService.applyDailyListReminders(enabled: dailyListRemindersEnabled)
            }
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
