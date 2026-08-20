import Observation
import SwiftData
import SwiftUI

/// Transient user-facing messages.
///
/// `@Observable` rather than `ObservableObject`: as an `@EnvironmentObject` this
/// invalidated every view that declared it — including `RootView`, whose body holds
/// the entire `TabView`. A single transient banner re-evaluated the whole tab tree.
/// Observation scopes invalidation to the views that actually read `current`.
@MainActor
@Observable
final class AppNoticeCenter {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    private(set) var current: Notice?
    /// Errors queue instead of overwriting each other — a backup import that hits
    /// several problems used to show only the last one.
    private var queue: [Notice] = []
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String) {
        enqueue(Notice(message: message, isError: false))
    }

    func report(_ error: any Error, context: String) {
        enqueue(Notice(message: "\(context): \(error.localizedDescription)", isError: true))
    }

    private func enqueue(_ notice: Notice) {
        guard current != nil else {
            present(notice)
            return
        }
        queue.append(notice)
    }

    private func present(_ notice: Notice) {
        dismissTask?.cancel()
        current = notice
        // Errors stay until dismissed; informational notices time out.
        guard !notice.isError else { return }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        if queue.isEmpty {
            current = nil
        } else {
            current = nil
            present(queue.removeFirst())
        }
    }
}

extension ModelContext {
    /// Saves, reporting any failure instead of letting it vanish.
    @MainActor
    @discardableResult
    func save(
        reporting notices: AppNoticeCenter,
        context: String = "Änderungen konnten nicht gespeichert werden"
    ) -> Bool {
        guard hasChanges else { return true }
        do {
            try save()
            return true
        } catch {
            // Leaving a failed change live in the context means the next unrelated
            // save commits it silently, after the user was told it failed.
            rollback()
            notices.report(error, context: context)
            return false
        }
    }
}

struct AppNoticeBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppNoticeCenter.self) private var notices

    var body: some View {
        if let notice = notices.current {
            HStack(spacing: AppSpacing.snug) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(notice.isError ? .red : .orange)
                    .symbolEffect(.bounce, value: notice.id)
                Text(notice.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    notices.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .tappable(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hinweis schließen")
            }
            .padding(12)
            // Floats above content, so it is navigation layer and gets glass.
            .mapChrome(cornerRadius: AppRadius.card)
            .padding(.horizontal, AppSpacing.regular)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .animation(.appFeedback(reduceMotion: reduceMotion), value: notice.id)
        }
    }
}
