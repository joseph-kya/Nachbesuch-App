package at.volkshilfe.nachbesuch.feature.shared

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.revisit.RevisitPlanner
import at.volkshilfe.nachbesuch.domain.revisit.RevisitSuggestion
import at.volkshilfe.nachbesuch.ui.components.MinTouchTarget
import at.volkshilfe.nachbesuch.ui.status.tint
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import java.time.Instant
import java.time.ZoneId

/**
 * Asks when to come back, after a door is marked "Später".
 *
 * The shortlist comes from the shared [RevisitPlanner] so the same offers appear on
 * iOS, and the wheel below it is always available — a canvasser told "kommen Sie um
 * viertel nach sieben" must not have to pick the nearest suggestion instead.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RevisitTimeSheet(
    /** Shown under the choices so it is obvious which door is being postponed. */
    subject: String,
    /** A time already booked for this door, when the sheet is re-opened to change it. */
    existing: Long? = null,
    onPick: (Long) -> Unit,
    /** Offered only when there is something to clear. */
    onClear: (() -> Unit)? = null,
    onDismiss: () -> Unit
) {
    // Frozen at presentation. Recomputing "in 30 Min" from a ticking clock while
    // the sheet is open would move the buttons under the user's thumb.
    val now = remember { System.currentTimeMillis() }
    val zone = remember { ZoneId.systemDefault() }
    val suggestions = remember(now) { RevisitPlanner.suggestions(now, zone) }
    val initial = remember(now) {
        Instant.ofEpochMilli(existing ?: RevisitPlanner.defaultTime(now, zone)).atZone(zone)
    }
    val picker = rememberTimePickerState(
        initialHour = initial.hour,
        initialMinute = initial.minute,
        is24Hour = true
    )
    var showsPastWarning by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("Später", style = MaterialTheme.typography.headlineSmall)
            Text(
                "Wann noch einmal hingehen?",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            suggestions.forEach { suggestion ->
                SuggestionRow(suggestion, zone) { onPick(suggestion.atMillis); onDismiss() }
            }

            Text(
                subject,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Text("Genaue Zeit", style = MaterialTheme.typography.titleSmall)
            TimePicker(state = picker)

            if (showsPastWarning) {
                // The wheel only edits hour and minute, so a time earlier than now
                // can only mean tomorrow — say so rather than booking a reminder
                // that has already passed.
                Text(
                    "Diese Zeit ist bereits vorbei.",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.error
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onDismiss) { Text("Abbrechen") }
                Spacer(Modifier.weight(1f))
                if (onClear != null) {
                    TextButton(onClick = { onClear(); onDismiss() }) {
                        Text("Zeit entfernen", color = MaterialTheme.colorScheme.error)
                    }
                }
                TextButton(onClick = {
                    val booked = RevisitPlanner.instantFor(picker.hour, picker.minute, System.currentTimeMillis(), zone)
                    if (booked == null) {
                        showsPastWarning = true
                    } else {
                        onPick(booked)
                        onDismiss()
                    }
                }) { Text("Übernehmen") }
            }
        }
    }
}

@Composable
private fun SuggestionRow(suggestion: RevisitSuggestion, zone: ZoneId, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(RadiusControl))
            .clickable(onClick = onClick)
            .heightIn(min = MinTouchTarget)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Icon(
            if (suggestion.kind is RevisitSuggestion.Kind.Relative) Icons.Default.Timer else Icons.Default.Schedule,
            contentDescription = null,
            tint = VisitOutcome.LATER.tint,
            modifier = Modifier.size(20.dp)
        )
        Text(suggestion.title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Text(
            suggestion.clockText(zone),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}
