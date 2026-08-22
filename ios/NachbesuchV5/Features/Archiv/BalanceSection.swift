import Charts
import SwiftUI

/// The active territory's balance, embedded at the top of the archive.
struct BalanceSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let gebiet: Gebiet
    let entry: ArchiveEntry?
    @Binding var scope: DayScope

    private var tally: OutcomeTally {
        guard let entry else { return .empty }
        switch scope {
        case .combined: return entry.overall
        case .day1: return entry.day1
        case .day2: return entry.day2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.snug) {
            if gebiet.isTwoDay {
                DayScopePicker(scope: $scope)
            }

            if entry?.houseCount ?? 0 == 0 {
                ContentUnavailableView {
                    Label("Noch nichts erfasst", systemImage: "chart.bar")
                } description: {
                    Text("Sobald du Häuser anlegst und Status einträgst, erscheint hier die Bilanz.")
                }
                .frame(maxWidth: .infinity)
            } else {
                progressCard
                metrics
                chart

                if gebiet.isTwoDay, let entry {
                    revisitSummary(entry: entry)
                }
            }
        }
        .padding(14)
        // One card around the whole balance. The blocks inside are plain fills:
        // stacking glass inside glass just muddies both.
        .contentCard(cornerRadius: AppRadius.card)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((tally.completionFraction * 100).rounded()))")
                    .font(.largeTitle.bold())
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: tally.completionFraction * 100))
                Text("% erledigt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(tally.completed)/\(tally.unitCount)")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: tally.completionFraction)
                .tint(tally.open == 0 ? .green : .red)
                .animation(.appSettle(reduceMotion: reduceMotion), value: tally.completionFraction)
        }
        .padding(12)
        .contentPanel(cornerRadius: AppRadius.control)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: tally.completed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fortschritt")
        .accessibilityValue("\(tally.completed) von \(tally.unitCount) Türen erledigt")
    }

    private var metrics: some View {
        // Reflows to two columns at accessibility sizes instead of truncating.
        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible()), GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: AppSpacing.tight) {
            metricTile(outcome: .notHome, value: tally.notHome)
            metricTile(outcome: .joined, value: tally.joined)
            metricTile(outcome: .earlyNo, value: tally.earlyNo)
            metricTile(outcome: .lateNo, value: tally.lateNo)
            // Only when it happened: an always-visible "0 Später" would push the
            // four results the report is about onto a second row for nothing.
            if tally.later > 0 {
                metricTile(outcome: .later, value: tally.later)
            }
        }
    }

    private func metricTile(outcome: VisitOutcome, value: Int) -> some View {
        VStack(spacing: 3) {
            Image(systemName: outcome.symbolName)
                .foregroundStyle(outcome.tint)
            Text("\(value)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
            Text(outcome.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .contentPanel(cornerRadius: AppRadius.small)
        .animation(.appFeedback(reduceMotion: reduceMotion), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(outcome.title)
        .accessibilityValue("\(value)")
    }

    private var chart: some View {
        Chart(chartOutcomes) { outcome in
            BarMark(
                x: .value("Anzahl", count(for: outcome)),
                y: .value("Ergebnis", outcome.title)
            )
            .foregroundStyle(outcome.tint)
            .cornerRadius(4)
        }
        .chartXAxis { AxisMarks(position: .bottom) }
        .frame(height: 130)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ergebnisverteilung")
        .accessibilityValue(
            chartOutcomes
                .map { "\($0.title): \(count(for: $0))" }
                .joined(separator: ", ")
        )
    }

    /// The four results, plus "Später" when the territory actually used it.
    private var chartOutcomes: [VisitOutcome] {
        tally.later > 0 ? VisitOutcome.allCases : VisitOutcome.primary
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

    /// What the second day actually achieved — measured only against the doors that
    /// were eligible for a revisit, not against every door in the territory.
    private func revisitSummary(entry: ArchiveEntry) -> some View {
        let target = entry.day1.notHome
        let done = entry.day2.completed
        return VStack(alignment: .leading, spacing: 4) {
            Text("Nachbesuche")
                .font(.subheadline.weight(.semibold))
            Text("\(done) von \(target) am Tag 1 offenen Türen wurden am Tag 2 erreicht.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if entry.pendingRevisits > 0 {
                Label("\(entry.pendingRevisits) Türen warten noch auf den zweiten Besuch",
                      systemImage: VisitOutcome.notHome.symbolName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentPanel(cornerRadius: AppRadius.control)
        .accessibilityElement(children: .combine)
    }
}
