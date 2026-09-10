import Foundation
import SwiftData
import SwiftUI

/// One debounced SwiftData write, shared by every screen that records door work.
///
/// The map and the list each grew a private copy of this, byte for byte the same.
/// Then they drifted: the list learned to commit whatever was still pending when it
/// went away, the map never got that fix. A status set on the map and followed by a
/// tab switch inside the debounce window was therefore cancelled rather than
/// written — a lost door, at a real front door. The debounce and the flush live
/// here now, so the two screens cannot disagree about them again.
@MainActor
final class PendingSave {
    private var task: Task<Void, Never>?
    private let delay: Duration
    private let failureContext: String
    private var success: (() -> Void)?

    init(
        delay: Duration = .milliseconds(350),
        failureContext: String = "Status konnte nicht gespeichert werden"
    ) {
        self.delay = delay
        self.failureContext = failureContext
    }

    /// Coalesces a burst of taps into one write.
    func schedule(
        in modelContext: ModelContext,
        reporting notices: AppNoticeCenter,
        onSuccess: @escaping () -> Void = {}
    ) {
        task?.cancel()
        success = onSuccess
        task = Task { @MainActor in
            try? await Task.sleep(for: self.delay)
            guard !Task.isCancelled else { return }
            let didSave = modelContext.save(reporting: notices, context: self.failureContext)
            self.task = nil
            let completion = self.success
            self.success = nil
            if didSave { completion?() }
        }
    }

    /// Commits what is still pending, immediately.
    ///
    /// Belongs everywhere the screen can stop running before the debounce elapses:
    /// `onDisappear`, and any scene phase that is no longer `.active`. Cancelling
    /// the task *without* this is the drift described above — the mutation stays
    /// live but unsaved in the context until some unrelated write commits it.
    func flush(in modelContext: ModelContext, reporting notices: AppNoticeCenter) {
        task?.cancel()
        task = nil
        let completion = success
        success = nil
        if modelContext.save(reporting: notices, context: failureContext) {
            completion?()
        }
    }
}

/// Torwart vor `ModelContext.didSave`-Refreshes (Liste/Karte/Archiv).
///
/// Jeder Save — auch fremder Gebiete oder der automatischen Sicherung — feuert
/// `didSave`, und jeder Empfänger las bisher voll neu. Das Gate faltet Bursts
/// (Bulk-Import speichert mehrfach pro Sekunde) zu einem Refresh zusammen.
/// Ehrliche Grenze: SwiftDatas `didSave` trägt keine geänderten IDs, eine
/// Gebiets-Schnittmenge lässt sich aus der Notification nicht ableiten — dafür
/// die Watermark-Varianten `mapSeeds(territoryID:updatedAfter:)` und
/// `listSeeds(territoryID:updatedAfter:)` nutzen. Reines Angebot, kein
/// Verhaltenswechsel: Übernahme durch die Screens ist optional.
///
/// Thread-Sicherheit: bewusst `NSLock` + `@unchecked Sendable` statt `@MainActor`.
/// `didSave` kann auf beliebigem Thread feuern, der Handler ist synchron — ein
/// MainActor-Gate zwänge jeden Aufruf in einen Hop. `lastPass` liegt nur hinter
/// dem Lock, `quietInterval` ist unveränderlich; API (`shouldRefresh`/`reset`,
/// Default 0.5 s) unverändert.
/// Sendable, da nur Lock-geschützte Dates gehalten werden.
final class DidSaveRefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPass = Date.distantPast
    private let quietInterval: TimeInterval

    /// - Parameter quietInterval: Mindestabstand zweier Refreshes in Sekunden.
    init(quietInterval: TimeInterval = 0.5) {
        self.quietInterval = quietInterval
    }

    /// `true` heißt jetzt neu lesen, `false` heißt Burst-Rauschen — Stand behalten.
    func shouldRefresh(now: Date = .now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(lastPass) >= quietInterval else { return false }
        lastPass = now
        return true
    }

    /// Vergisst den letzten Durchlass — z. B. bei Gebietswechsel.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastPass = .distantPast
    }
}
