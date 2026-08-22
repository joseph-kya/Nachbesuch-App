import SwiftUI

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
    @State private var isPickingCustomTime = false
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
        NavigationStack {
            Form {
                Section {
                    ForEach(suggestions) { suggestion in
                        Button {
                            commit(suggestion.date)
                        } label: {
                            HStack(spacing: AppSpacing.snug) {
                                Image(systemName: iconName(for: suggestion))
                                    .foregroundStyle(VisitOutcome.later.tint)
                                    .frame(width: 24)
                                Text(suggestion.title)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: AppSpacing.tight)
                                Text(suggestion.clockText)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .frame(minHeight: AppTouch.minimum)
                        }
                        .accessibilityLabel("\(suggestion.title), \(suggestion.clockText)")
                    }
                } header: {
                    Text("Wann noch einmal hingehen?")
                } footer: {
                    Text(subject)
                }

                Section {
                    DatePicker(
                        "Genaue Zeit",
                        selection: $customTime,
                        in: now...,
                        displayedComponents: [.hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .onChange(of: customTime) { _, _ in isPickingCustomTime = true }

                    Button("Diese Zeit übernehmen") {
                        commit(customTime)
                    }
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

                if let onClear {
                    Section {
                        Button("Zeit entfernen", role: .destructive) {
                            onClear()
                            dismiss()
                        }
                        .frame(minHeight: AppTouch.minimum)
                    }
                }
            }
            .navigationTitle("Später")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func iconName(for suggestion: RevisitSuggestion) -> String {
        switch suggestion.kind {
        case .relative: "timer"
        case .clock: "clock"
        }
    }

    private func commit(_ date: Date) {
        guard date > now else { return }
        onPick(date)
        dismiss()
    }
}
