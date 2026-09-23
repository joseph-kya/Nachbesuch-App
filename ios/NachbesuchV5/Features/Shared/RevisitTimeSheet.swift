import SwiftUI
import UIKit

/// Asks when to come back, after a door is marked "Später".
///
/// The shortlist comes from `RevisitPlanner` so the same offers appear on Android,
/// and the wheel below it is always available — a canvasser told "kommen Sie um
/// viertel nach sieben" must not have to pick the nearest suggestion instead.
struct RevisitTimeSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Shown above the choices so it is obvious which door is being postponed.
    let subject: String
    /// A time already booked for this door, when the sheet is re-opened to change it.
    let existing: Date?
    let onPick: (Date) -> Void
    /// Offered only when there is something to clear.
    let onClear: (() -> Void)?

    @State private var customTime: Date
    /// Frozen at presentation. Recomputing "in 30 Min" from a ticking clock while
    /// the sheet is open would move the buttons under the user's thumb.
    private let now: Date

    init(
        subject: String,
        existing: Date? = nil,
        now: Date = .now,
        onPick: @escaping (Date) -> Void,
        onClear: (() -> Void)? = nil
    ) {
        self.subject = subject
        self.existing = existing
        self.now = now
        self.onPick = onPick
        self.onClear = onClear
        _customTime = State(initialValue: existing ?? RevisitPlanner.defaultTime(now: now))
    }

    private var suggestions: [RevisitSuggestion] { RevisitPlanner.suggestions(now: now) }

    var body: some View {
        // Dringlichkeit aus einer Quelle: `RevisitGlance` entscheidet überfällig vs. gebucht,
        // rot vs. indigo folgt derselben Hilfe — keine doppelte Datumslogik.
        let existingGlance = RevisitGlance.make(at: existing, laterDoors: 1, now: now)
        let isOverdue = existingGlance?.urgency == .overdue
        return NavigationStack {
            Form {
                // Eine überfällige Buchung ist kein Vorschlag mehr — sie steht
                // rot oben, damit niemand versehentlich dieselbe Zeit behält.
                if isOverdue, let existing {
                    Section {
                        Label(
                            "Überfällig seit \(RevisitPlanner.clockFormatter.string(from: existing)) — bitte eine neue Zeit wählen.",
                            systemImage: "clock.badge.exclamationmark.fill"
                        )
                        .foregroundStyle(.red)
                    }
                    .glassRows()
                } else if let existing, !matchesExisting(existing) {
                    Section {
                        Label(
                            "Bereits gebucht für \(RevisitPlanner.clockFormatter.string(from: existing)).",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(VisitOutcome.later.tint)
                    }
                    .glassRows()
                }

                Section {
                    ForEach(suggestions) { suggestion in
                        // Die bereits gebuchte Zeit trägt Häkchen plus Tönung,
                        // damit ein erneutes Öffnen zeigt, was schon steht.
                        let isExisting = isExistingSuggestion(suggestion.date)
                        Button {
                            commit(suggestion.date)
                        } label: {
                            HStack(spacing: AppSpacing.snug) {
                                Image(systemName: iconName(for: suggestion))
                                    .foregroundStyle(VisitOutcome.later.tint)
                                    .frame(width: 24)
                                Text(suggestion.title)
                                    .foregroundStyle(.primary)
                                    .fontWeight(isExisting ? .semibold : .regular)
                                Spacer(minLength: AppSpacing.tight)
                                Text(suggestion.clockText)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                if isExisting {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(VisitOutcome.later.tint)
                                        .accessibilityLabel("Bereits gebucht")
                                }
                            }
                            .frame(minHeight: AppTouch.minimum)
                        }
                        .accessibilityLabel("\(suggestion.title), \(suggestion.clockText)")
                        .accessibilityAddTraits(isExisting ? [.isButton, .isSelected] : .isButton)
                    }
                } header: {
                    Text("Wann noch einmal hingehen?")
                } footer: {
                    Text(subject)
                }
                .glassRows()

                Section {
                    DatePicker(
                        "Genaue Zeit",
                        selection: $customTime,
                        in: now...,
                        displayedComponents: [.hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    // Deutsches Label „Genaue Zeit" plus 44pt-Treffläche für A11y.
                    .frame(minHeight: AppTouch.minimum)

                    // Bewusst Form-Stil statt Glas: Forms bleiben glasfrei,
                    // der CTA bleibt trotzdem prominent.
                    Button("Diese Zeit übernehmen") {
                        commit(customTime)
                    }
                    .disabled(customTime <= now)
                    .buttonStyle(.borderedProminent)
                    .fontWeight(.semibold)
                    .frame(minHeight: AppTouch.minimum)
                } footer: {
                    // The picker only edits hour and minute, so a time earlier than
                    // now can only mean tomorrow — say so rather than booking a
                    // reminder that has already passed.
                    if customTime <= now {
                        Text("Diese Zeit ist bereits vorbei.")
                            .foregroundStyle(.red)
                    }
                }
                .glassRows()

                if let onClear {
                    Section {
                        // Bleibt sofort und ohne Rückfrage: das Zurücknehmen
                        // einer Zeit ist kein Löschen von Daten.
                        Button("Zeit entfernen", role: .destructive) {
                            UISelectionFeedbackGenerator().selectionChanged()
                            onClear()
                            dismiss()
                        }
                        .frame(minHeight: AppTouch.minimum)
                    }
                    .glassRows()
                }
            }
            .glassForm()
            .navigationTitle("Später")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    private func iconName(for suggestion: RevisitSuggestion) -> String {
        switch suggestion.kind {
        case .relative: "timer"
        case .clock: "clock"
        }
    }

    /// Ob ein Vorschlag der bereits gebuchten Zeit entspricht (Minutentoleranz,
    /// weil Runden und Picker-Abweichungen sonst nie treffen).
    private func isExistingSuggestion(_ date: Date) -> Bool {
        guard let existing else { return false }
        return abs(existing.timeIntervalSince(date)) < 60
    }

    private func matchesExisting(_ existing: Date) -> Bool {
        suggestions.contains { abs($0.date.timeIntervalSince(existing)) < 60 }
    }

    private func commit(_ date: Date) {
        // Wächter bleibt `date > now` (kein 5-Min-Minimum: Vorschläge liegen
        // ohnehin in der Zukunft) — ungültiges Tippen meldet sich per Fehler-Haptik.
        guard date > now else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        onPick(date)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

/// Gebuchte Rückkehrzeit als Glanz-Zeile: Uhr-Icon plus relatives Label
/// ("in 25 Min") aus `RevisitGlance`, damit kein Caller die Arithmetik wiederholt.
/// Überfällig wird rot mit „Überfällig"-Label, künftig bleibt indigo — dieselbe
/// Rot/Indigo-Abbildung wie überall, aus derselben Hilfe.
///
/// Einmalig hier statt je Datei, damit Haus-Detail und beide Passanten-Sheets
/// dieselbe Zeile zeigen. Tippen öffnet den Zeit-Sheet des Callers erneut.
struct BookedTimeGlance: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bookedAt: Date
    let action: () -> Void

    var body: some View {
        let glance = RevisitGlance.make(at: bookedAt, laterDoors: 1)
        // Dringlichkeit aus der Hilfe, kein eigener Datumsvergleich.
        let isOverdue = glance?.urgency == .overdue
        let tint: Color = isOverdue ? .red : VisitOutcome.later.tint
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            HStack(spacing: AppSpacing.tight) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: glance?.systemImage ?? VisitOutcome.later.symbolName)
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(glance?.label ?? RevisitPlanner.clockFormatter.string(from: bookedAt))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tint)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    if glance?.urgency != .upcoming {
                        Text(RevisitPlanner.clockFormatter.string(from: bookedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: AppSpacing.tight)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: AppTouch.minimum, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentPanel(cornerRadius: AppRadius.control)
            .selectionRing(true, tint: tint)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        }
        .buttonStyle(PressableRowStyle())
        .animation(.appFeedback(reduceMotion: reduceMotion), value: bookedAt)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isSelected)
        .accessibilityLabel("Gebuchte Zeit, \(glance?.voiceOver ?? RevisitPlanner.clockFormatter.string(from: bookedAt))")
        .accessibilityHint("Fragt nach einer Uhrzeit")
    }
}
