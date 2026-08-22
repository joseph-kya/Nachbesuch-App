package at.volkshilfe.nachbesuch.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.model.OutcomeTally
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.stats.BilanzSnapshot
import at.volkshilfe.nachbesuch.ui.status.icon
import at.volkshilfe.nachbesuch.ui.status.tint
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl
import at.volkshilfe.nachbesuch.ui.theme.RadiusSmall
import kotlin.math.roundToInt

/**
 * The active territory's balance, ported from the iOS `BalanceSection`.
 *
 * One card around the whole thing; the blocks inside are plain fills. Stacking
 * elevated surfaces inside elevated surfaces just muddies both.
 */
@Composable
fun BalanceSection(
    tally: OutcomeTally,
    snapshot: BilanzSnapshot,
    isTwoDay: Boolean,
    modifier: Modifier = Modifier
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (snapshot.houseCount == 0) {
            EmptyBalance()
            return@Column
        }
        ProgressCard(tally)
        MetricGrid(tally)
        OutcomeChart(tally)
        if (isTwoDay) RevisitSummary(snapshot)
    }
}

@Composable
private fun EmptyBalance() {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Icon(
            Icons.Default.BarChart,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(30.dp)
        )
        Text("Noch nichts erfasst", style = MaterialTheme.typography.titleMedium)
        Text(
            "Sobald du Häuser anlegst und Status einträgst, erscheint hier die Bilanz.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun ProgressCard(tally: OutcomeTally) {
    val fraction by animateFloatAsState(tally.completionFraction.toFloat(), label = "completion")
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(RadiusControl))
            .padding(12.dp)
            .clearAndSetSemantics {
                contentDescription = "Fortschritt"
                stateDescription = "${tally.completed} von ${tally.unitCount} Türen erledigt"
            },
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                "${(tally.completionFraction * 100).roundToInt()}",
                style = MaterialTheme.typography.headlineLarge
            )
            Text(
                " % erledigt",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 3.dp)
            )
            Box(Modifier.weight(1f))
            Text(
                "${tally.completed}/${tally.unitCount}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 3.dp)
            )
        }
        // Drawn rather than a LinearProgressIndicator: the Material bar has its own
        // track inset and stop-indicator dot that read as a different design system.
        Box(
            Modifier
                .fillMaxWidth()
                .height(8.dp)
                .background(MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(4.dp))
        ) {
            Box(
                Modifier
                    .fillMaxWidth(fraction.coerceIn(0f, 1f))
                    .height(8.dp)
                    .background(
                        if (tally.open == 0) Color(0xFF2E9E5B) else MaterialTheme.colorScheme.primary,
                        RoundedCornerShape(4.dp)
                    )
            )
        }
    }
}

/** Four tiles, two per row — they stay readable at large font scales. */
@Composable
private fun MetricGrid(tally: OutcomeTally) {
    val tiles = listOf(
        VisitOutcome.NOT_HOME to tally.notHome,
        VisitOutcome.JOINED to tally.joined,
        VisitOutcome.EARLY_NO to tally.earlyNo,
        VisitOutcome.LATE_NO to tally.lateNo
    )
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        tiles.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { (outcome, value) ->
                    MetricTile(outcome, value, Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun MetricTile(outcome: VisitOutcome, value: Int, modifier: Modifier = Modifier) {
    Column(
        modifier
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(RadiusSmall))
            .padding(vertical = 10.dp)
            .clearAndSetSemantics {
                contentDescription = outcome.germanTitle
                stateDescription = value.toString()
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp)
    ) {
        Icon(outcome.icon, contentDescription = null, tint = outcome.tint, modifier = Modifier.size(18.dp))
        Text("$value", style = MaterialTheme.typography.titleLarge)
        Text(
            outcome.germanTitle,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 2,
            textAlign = TextAlign.Center
        )
    }
}

/**
 * The outcome distribution as horizontal bars.
 *
 * Drawn by hand rather than pulling in a charting library: four bars with a shared
 * maximum is the whole requirement, and the iOS side uses Swift Charts only because
 * it ships with the platform.
 */
@Composable
private fun OutcomeChart(tally: OutcomeTally) {
    val values = VisitOutcome.entries.map { outcome ->
        outcome to when (outcome) {
            VisitOutcome.NOT_HOME -> tally.notHome
            VisitOutcome.EARLY_NO -> tally.earlyNo
            VisitOutcome.LATE_NO -> tally.lateNo
            VisitOutcome.JOINED -> tally.joined
        }
    }
    val maximum = (values.maxOfOrNull { it.second } ?: 0).coerceAtLeast(1)
    Column(
        Modifier
            .fillMaxWidth()
            .clearAndSetSemantics {
                contentDescription = "Ergebnisverteilung"
                stateDescription = values.joinToString(", ") { "${it.first.germanTitle}: ${it.second}" }
            },
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        values.forEach { (outcome, count) ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    outcome.shortTitle,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(52.dp)
                )
                Box(
                    Modifier
                        .weight(1f)
                        .height(16.dp)
                        .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(4.dp))
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth(count.toFloat() / maximum)
                            .height(16.dp)
                            .background(outcome.tint, RoundedCornerShape(4.dp))
                    )
                }
                Text(
                    "$count",
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.width(28.dp),
                    textAlign = TextAlign.End
                )
            }
        }
    }
}

/**
 * What the second day actually achieved — measured against the doors that were
 * eligible for a revisit, not against every door in the territory.
 */
@Composable
private fun RevisitSummary(snapshot: BilanzSnapshot) {
    val target = snapshot.day1.notHome
    val done = snapshot.day2.completed
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(RadiusControl))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Text("Nachbesuche", style = MaterialTheme.typography.titleSmall)
        Text(
            "$done von $target am Tag 1 offenen Türen wurden am Tag 2 erreicht.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (snapshot.pendingRevisits > 0) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(
                    VisitOutcome.NOT_HOME.icon,
                    contentDescription = null,
                    tint = VisitOutcome.NOT_HOME.tint,
                    modifier = Modifier.size(16.dp)
                )
                Text(
                    "${snapshot.pendingRevisits} Türen warten noch auf den zweiten Besuch",
                    style = MaterialTheme.typography.labelMedium,
                    color = VisitOutcome.NOT_HOME.tint
                )
            }
        }
    }
}
