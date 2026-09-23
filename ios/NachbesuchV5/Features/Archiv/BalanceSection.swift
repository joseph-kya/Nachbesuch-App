import SwiftUI

/// A stable summary: animate values, never the surrounding scroll layout.
struct BalanceSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent

    let gebiet: Gebiet
    let entry: ArchiveEntry?
    @Binding var scope: DayScope
    var passantCount: Int = 0
    /// Fades the figures (never the card) while the territory is swapped — see
    /// `ArchiveScreen.selectGebiet`.
    var contentOpacity: Double = 1
    /// WAVE2: success fires only on false→true. A plain `trigger: isComplete`
    /// would also buzz on true→false (StreetHeader documents the same trap).
    @State private var celebrateToken = 0

    private var tally: OutcomeTally {
        guard let entry else { return .empty }
        switch scope {
        case .combined: return entry.overall
        case .day1: return entry.day1
        case .day2: return entry.day2
        }
    }

    /// WAVE2: true only at 100 %. Drives celebration (once per transition),
    /// never routine count motion which stays appFeedback.
    private var isComplete: Bool {
        tally.unitCount > 0 && tally.completionFraction >= 1.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.loose) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.tight))
                : AnyLayout(HStackLayout())
            headerLayout {
                Label("Bilanz", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if let entry {
                    Text("\(entry.houseCount) Häuser")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if gebiet.isTwoDay {
                DayScopePicker(scope: $scope)
            }
            if let entry {
                if entry.houseCount == 0 {
                    ContentUnavailableView {
                        Label("Noch keine Häuser", systemImage: "house")
                    } description: {
                        Text("Sobald du Häuser anlegst, erscheint hier deine Bilanz.")
                    }
                } else {
                    if entry.damagedHouseCount > 0 {
                        Label("\(entry.damagedHouseCount) Häuser mit beschädigten Daten — Wiederherstellung nötig",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    progressHeader
                    Divider()
                    VStack(spacing: AppSpacing.regular) {
                        // Fixed rows prevent the card jumping when Später becomes zero.
                        ForEach(VisitOutcome.allCases) { outcome in
                            outcomeRow(outcome)
                        }
                    }
                    if gebiet.isTwoDay {
                        Divider()
                        revisitSummary(entry)
                    }
                }
                if passantCount > 0 {
                    Label("\(passantCount) \(passantCount == 1 ? "Passant" : "Passanten") erfasst",
                          systemImage: "person.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: AppSpacing.snug) {
                    ProgressView()
                    Text("Bilanz wird geladen …")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .opacity(contentOpacity)
        .padding(AppSpacing.loose)
        .contentCard(cornerRadius: AppRadius.card)
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.regular) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.regular) {
                    headline
                    Spacer(minLength: AppSpacing.tight)
                    recordedCount
                }
                VStack(alignment: .leading, spacing: AppSpacing.tight) {
                    headline
                    recordedCount
                }
            }
            // Voll = grün statt Akzent — ruhige Bestätigung ohne Konfetti.
            ProgressTrack(progress: tally.completionFraction, fill: isComplete ? Color.green : accent)
            // WAVE2: completion swaps the open-count line for a checkmark badge.
            // blockSwap kept for the swap; appCelebrate ONLY on the isComplete flip.
            Group {
                if isComplete {
                    Label("Vollständig erfasst", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.doneTone)
                        .transition(.blockSwap(reduceMotion: reduceMotion))
                } else {
                    Text("\(tally.open) Türen offen")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(tally.open)))
                        .transition(.blockSwap(reduceMotion: reduceMotion))
                }
            }
            // Reserved for genuine completion — ListScreen documents the same rule.
            .animation(.appCelebrate(reduceMotion: reduceMotion), value: isComplete)
        }
        // Success nur bei false→true: Token steigt nur beim Fertigwerden, nie
        // beim Wiederöffnen (StreetHeader-Pattern).
        .sensoryFeedback(.success, trigger: celebrateToken)
        .onChange(of: isComplete) { _, done in
            guard done else { return }
            celebrateToken &+= 1
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fortschritt")
        .accessibilityValue(
            isComplete
                ? "\(tally.completed) von \(tally.unitCount) Türen erfasst, vollständig"
                : "\(tally.completed) von \(tally.unitCount) Türen erfasst, \(tally.open) Türen offen"
        )
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.tight) {
            Text(tally.completionFraction, format: .percent.precision(.fractionLength(0)))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
            Text("erfasst")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var recordedCount: some View {
        Text("\(tally.completed) / \(tally.unitCount) Türen")
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // The digits roll; nothing else moves.
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(tally.completed)))
            .animation(.appFeedback(reduceMotion: reduceMotion), value: tally.completed)
    }

    private func outcomeRow(_ outcome: VisitOutcome) -> some View {
        let value = count(for: outcome)
        let fraction = tally.unitCount > 0 ? Double(value) / Double(tally.unitCount) : 0
        return HStack(alignment: .top, spacing: AppSpacing.snug) {
            Image(systemName: outcome.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(outcome.tint)
                .frame(width: 32, height: 32)
                .background(StatusChipFill(outcome.tint), in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: AppSpacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.snug) {
                    Text(outcome.title)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text("\(value)")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(value)))
                        .animation(.appFeedback(reduceMotion: reduceMotion), value: value)
                }
                // A plain track: no chart axes, no measuring pass.
                ProgressTrack(progress: fraction, fill: outcome.tint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(outcome.title)
        .accessibilityValue("\(value) von \(tally.unitCount) Türen")
    }

    private func count(for outcome: VisitOutcome) -> Int {
        switch outcome {
        case .notHome: tally.notHome
        case .earlyNo: tally.earlyNo
        case .lateNo: tally.lateNo
        case .joined: tally.joined
        case .later: tally.later
        }
    }

    private func revisitSummary(_ entry: ArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.tight) {
            Label("Nachbesuche", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
            // A recorded result can be Niemand da; it does not mean someone was reached.
            Text("\(entry.day2.completed) von \(entry.revisitTargets) Türen für Tag 2 erfasst")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if entry.pendingRevisits > 0 {
                Text("\(entry.pendingRevisits) Türen warten auf den zweiten Besuch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
