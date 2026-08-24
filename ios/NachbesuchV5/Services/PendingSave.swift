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

    init(
        delay: Duration = .milliseconds(350),
        failureContext: String = "Status konnte nicht gespeichert werden"
    ) {
        self.delay = delay
        self.failureContext = failureContext
    }

    /// Coalesces a burst of taps into one write.
    func schedule(in modelContext: ModelContext, reporting notices: AppNoticeCenter) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: self.delay)
            guard !Task.isCancelled else { return }
            modelContext.save(reporting: notices, context: self.failureContext)
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
        modelContext.save(reporting: notices, context: failureContext)
    }
}
