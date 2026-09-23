import SwiftData
import SwiftUI
import UIKit

@main
struct NachbesuchApp: App {
    @State private var notices = AppNoticeCenter()
    // Der Store öffnet asynchron im Hintergrund (Migration/WAL), damit der erste
    // Frame nicht wartet. Bis dahin zeigt die Szene nur den Ladehinweis.
    @State private var store: StoreLoadResult?

    /// The standing "send the list" reminder. Mirrored into `AppStorage` by the
    /// settings sheet; read here so the schedule is re-applied on every launch,
    /// which is also what repairs it after a restore to a new device.
    @AppStorage(ReminderSettings.dailyListKey) private var dailyListRemindersEnabled = false

    init() {
        // Exports from previous launches are dead weight in `tmp` — swept off
        // the critical path; process start must not do file I/O on main.
        let launchTime = Date.now
        Task.detached(priority: .background) { ExportScratch.sweep(olderThan: launchTime) }
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
                if let store {
                    if let failure = store.failure {
                        // The store exists on disk but cannot be opened. Better to say so
                        // and offer the file than to `fatalError` on every launch with the
                        // user's field work locked inside.
                        StoreRecoveryView(error: failure.error, storeURL: failure.storeURL)
                    } else {
                        RootView()
                            .modelContainer(store.container)
                    }
                } else {
                    // Logo settles 0.94→1 with a fade; RM: opacity only.
                    // Store loads async — no blocking.
                    LaunchView()
                        .transition(.opacity)
                }
            }
            .environment(notices)
            // The app is German-only; pinning the locale keeps a weekday from being
            // rendered in German next to a date rendered in the device language.
            .environment(\.locale, Locale(identifier: "de_AT"))
            .task(priority: .background) {
                guard store == nil else { return }
                let loaded = await AppStore.loadInBackground()
                // The launch screen hands over with a crossfade instead of a cut.
                withAnimation(.appSettle(reduceMotion: UIAccessibility.isReduceMotionEnabled)) {
                    store = loaded
                }
            }
            .task(id: dailyListRemindersEnabled, priority: .background) {
                // Entkoppelt vom Pin-Aufbau: Die Listen-Erinnerung fragt erst nach
                // Freigabe, wenn sie wirklich einplanen muss (Später/Settings) —
                // nicht im Wettlauf mit dem ersten Karten-Refresh.
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await ReminderService.applyDailyListReminders(enabled: dailyListRemindersEnabled)
            }
        }
    }
}

/// WAVE2: overdone launch screen — logo settles, then the store arrives.
/// Async AppStore load kept; this view never blocks, it only covers the wait.
private struct LaunchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance.accent") private var accentRaw = AppAccent.volkshilfe.rawValue
    @State private var appeared = false

    private var accent: Color {
        (AppAccent(rawValue: accentRaw) ?? .volkshilfe).color
    }

    var body: some View {
        VStack(spacing: AppSpacing.regular) {
            Image(systemName: "figure.walk")
                .font(.system(size: 44))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(accent.gradient, in: Circle())
                .overlay { GlassSheen(shape: Circle()) }
                .overlay { glossyRim(for: Circle(), colorScheme: colorScheme) }
                // RM: opacity only — no positional/scale motion.
                .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
                .opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)
            Text("Nachbesuch")
                .font(.headline)
                .opacity(appeared ? 1 : 0)
            ProgressView("Gebiete werden geladen …")
                .progressViewStyle(.circular)
                .opacity(appeared ? 1 : 0)
            // WAVE3: ruhige Versionszeile, blockiert nichts (reine Ansicht).
            // WAVE4: kein Migrations-Fortschritt — V1→V2 ist leichtgewichtig und
            // sofort fertig. Der Kreisel gehört nur zum Hintergrund-Öffnen, kein
            // gefälschter Fortschritt.
            Text("Version 5 · Schema V2")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .opacity(appeared ? 1 : 0)
                .accessibilityLabel("Version 5, Schema Version 2")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackdrop().environment(\.appAccent, accent) }
        .onAppear {
            withAnimation(.appSettle(reduceMotion: reduceMotion)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .combine)
        // WAVE3: Versionszeile ist Teil der kombinierten Ansage.
        .accessibilityLabel("Nachbesuch wird geladen, Version 5, Schema Version 2")
    }
}

/// Shown only when the database cannot be opened.
/// WAVE4: zeigt Dateipfad + Kopie + „Neu anfangen" (destruktiv, mit Bestätigung).
/// Schema V2 steht im Text, damit eine Support-Anfrage ohne Nachfragen
/// einordbar ist. Die Diagnose hängt an der Kopie (nur Zähler-freier Text:
/// Pfad + Fehler + Schema, keine Adressen — die stehen nie im Store-Fehler).
struct StoreRecoveryView: View {
    let error: any Error
    let storeURL: URL?

    /// Zweite Stufe der destruktiven Bestätigung („Neu anfangen").
    @State private var showsResetConfirm = false
    /// Nach dem Löschen ist nur der Scratch-Store offen — erst ein Neustart
    /// öffnet einen frischen Store.
    @State private var didReset = false
    /// Kopie-Bestätigung (still, kein Banner nötig).
    @State private var copied = false

    var body: some View {
        // Scrollbar statt Abschneiden: Die Ansicht wuchs um Pfad + Kopie +
        // Neustart — auf kleinen Geräten läuft sie sonst über.
        ScrollView {
            VStack(spacing: AppSpacing.regular) {
            ContentUnavailableView {
                Label("Daten konnten nicht geladen werden", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("Die gespeicherten Gebiete lassen sich gerade nicht öffnen. Deine Datei wurde nicht verändert. Schema V2.")
            }

            if let storeURL {
                // Der Pfad ist der einzige Weg zur Datei ohne Finder — als Text,
                // damit er auch ohne Teilen lesbar bleibt.
                Text(storeURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .accessibilityLabel("Speicherort der Datenbank")
                    .accessibilityValue(storeURL.path)
            }

            if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
                ShareLink(item: storeURL) {
                    Label("Datenbank sichern", systemImage: "square.and.arrow.up")
                        .frame(minHeight: AppTouch.minimum)
                }
                .compatGlassButton(prominent: true)
                .buttonBorderShape(.capsule)
            }

            // Kopie für die Support-Anfrage: Pfad + Fehler + Schema, nie Inhalte.
            Button {
                UIPasteboard.general.string = diagnoseText
                copied = true
            } label: {
                Label(copied ? "Kopiert" : "Dateipfad und Fehler kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(minHeight: AppTouch.minimum)
            }
            .compatGlassButton()
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Dateipfad und Fehler in Zwischenablage kopieren")
            .accessibilityValue(copied ? "Kopiert" : "")

            // Destruktiv mit klarer Folge + zweiter Stufe (Alert unten).
            Button(role: .destructive) {
                showsResetConfirm = true
            } label: {
                Label("Neu anfangen", systemImage: "trash")
                    .frame(minHeight: AppTouch.minimum)
            }
            .compatGlassButton()
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Neu anfangen, gespeicherte Gebiete verwerfen")
            .accessibilityHint("Löscht die lokale Datenbank. Sichere sie vorher über „Datenbank sichern“.")

            if didReset {
                Text("Die Datenbank wurde entfernt. Starte die App neu, um mit einem leeren Bestand zu beginnen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(error.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.loose)
            }
            .padding()
        }
        .alert(
            "Wirklich neu anfangen?",
            isPresented: $showsResetConfirm,
            actions: {
                Button("Abbrechen", role: .cancel) {}
                // Destruktiv + Folge im Titel der Aktion: löscht Datei + WAL.
                Button("Alles löschen und neu anfangen", role: .destructive) {
                    resetStore()
                }
            },
            message: {
                Text("Die gespeicherte Datenbank wird vom Gerät gelöscht. Sichere sie vorher über „Datenbank sichern“, wenn du sie noch brauchst.")
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daten konnten nicht geladen werden, Schema Version 2")
    }

    /// Kopiertext: absichtlich ohne Zähler — der Store ist nicht lesbar,
    /// also wäre jede Zahl gelogen. Nur Ort + Fehler + Schema.
    private var diagnoseText: String {
        [
            "Nachbesuch-Diagnose (Store defekt)",
            "Schema: V2",
            "Pfad: \(storeURL?.path ?? "unbekannt")",
            "Fehler: \(error.localizedDescription)",
        ].joined(separator: "\n")
    }

    /// Entfernt Store + WAL/shm-Nebenstellen. Schlägt still fehl → dann bleibt
    /// alles wie es ist, der Fehlertext unten erklärt weiter.
    private func resetStore() {
        guard let storeURL else { return }
        let manager = FileManager.default
        let companions = ["-wal", "-shm"].map { storeURL.path + $0 }
        try? manager.removeItem(at: storeURL)
        for extra in companions {
            try? manager.removeItem(atPath: extra)
        }
        didReset = true
    }
}
