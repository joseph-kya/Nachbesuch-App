import Foundation
import Observation
import SwiftData
import SwiftUI

/// WAVE4: Fehler-Details öffnen die Diagnose — aber nur im DEBUG (das Blatt ist
/// DEBUG-only, im Release gibt es keine Route dorthin). Darum kein
/// Navigation-Ziel hier, sondern eine Mitteilung, die das Archiv auffängt.
extension Notification.Name {
    static let openDiagnostics = Notification.Name("nachbesuch.openDiagnostics")
}

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
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String) {
        present(Notice(message: message, isError: false))
    }

    func report(_ error: any Error, context: String) {
        present(Notice(message: "\(context): \(error.localizedDescription)", isError: true))
    }

    /// WAVE3: höchstens ein Banner — ein neues ersetzt das alte, kein Stapel.
    /// Der Wechsel morpht über `.appBanner` + `animation(value: notice.id)` in
    /// der Ansicht, daher hier kein Queue.
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
        current = nil
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
    /// WAVE2: dismiss haptic (once per tap) + swipe offset + 5s timer progress.
    @State private var dismissTaps = 0
    @State private var timerProgress: CGFloat = 1
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        if let notice = notices.current {
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.snug) {
                    Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(notice.isError ? .red : .orange)
                        .symbolEffect(
                            .bounce,
                            options: reduceMotion ? .nonRepeating : .default,
                            value: notice.id
                        )
                        .symbolEffectsRemoved(reduceMotion)
                        .accessibilityHidden(true)
                    Text(notice.message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #if DEBUG
                    // WAVE4: Fehler tragen eine Details-Aktion (Diagnoseblatt).
                    // Release kennt das Blatt nicht — dort bleibt nur Schließen.
                    if notice.isError {
                        Button {
                            dismissTaps += 1
                            notices.dismiss()
                            NotificationCenter.default.post(name: .openDiagnostics, object: nil)
                        } label: {
                            Text("Details")
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: AppTouch.minimum)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Fehlerdetails in der Diagnose öffnen")
                    }
                    #endif
                    Button {
                        dismissTaps += 1
                        notices.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .tappable(Circle())
                    }
                    // Plain on purpose: a glass button nested inside the glass
                    // panel breaks sampling (see UndoBanner). Haptic via taps.
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hinweis schließen")
                }
                // WAVE2: linear 5s timer mirrors the center's auto-dismiss.
                // Errors stay until dismissed, so no bar there. RM: opacity only.
                if !notice.isError {
                    Capsule(style: .continuous)
                        .fill(.orange.opacity(0.7))
                        .frame(height: 2)
                        .scaleEffect(x: reduceMotion ? 1 : timerProgress, anchor: .leading)
                        .opacity(reduceMotion ? timerProgress : 1)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(AppSpacing.regular)
            // Floats above content, so it is navigation layer and gets glass.
            .mapChrome(cornerRadius: AppRadius.card)
            .padding(.horizontal, AppSpacing.regular)
            // WAVE2: swipe-to-dismiss with fade. Snap-back respects RM via appFeedback.
            .offset(y: dragOffset)
            .opacity(1 - min(abs(dragOffset) / 120, 0.5))
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { dragOffset = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height < -30 || abs(value.translation.height) > 60 {
                            dismissTaps += 1
                            notices.dismiss()
                        } else {
                            withAnimation(.appFeedback(reduceMotion: reduceMotion)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .task(id: notice.id) {
                timerProgress = 1
                dragOffset = 0
                guard !notice.isError else { return }
                // Let the reset render before the linear sweep starts.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: 5)) {
                    timerProgress = 0
                }
            }
            .sensoryFeedback(.selection, trigger: dismissTaps)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(notice.isError ? "Fehlerhinweis" : "Hinweis")
            .transition(.appBanner(edge: .top, reduceMotion: reduceMotion))
            .standaloneGlassTransition(reduceMotion: reduceMotion)
            .animation(.appFeedback(reduceMotion: reduceMotion), value: notice.id)
        }
    }
}

struct ReminderCapacityBanner: View {
    let count: Int

    var body: some View {
        Label(
            "\(count) Erinnerungen konnten nicht geplant werden. Alle Termine bleiben unter „Heute fällig“ sichtbar.",
            systemImage: "bell.badge.fill"
        )
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .padding(AppSpacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mapChrome(cornerRadius: AppRadius.card)
        .padding(.horizontal, AppSpacing.regular)
        .accessibilityElement(children: .combine)
    }
}
