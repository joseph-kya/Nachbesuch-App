package at.volkshilfe.nachbesuch.feature.archive

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.model.CampaignDays
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.ui.theme.RadiusCard
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** What the editor produces. Null [existing] means "create a new territory". */
data class GebietDraft(
    val name: String,
    val districtOrCity: String,
    val notes: String,
    val isTwoDay: Boolean,
    val day1Date: Long,
    val day2Date: Long?
)

/**
 * Create and edit a territory — the Android equivalent of the iOS
 * `GebietEditorSheet`.
 *
 * Android previously had a create-only dialog with a name field: renaming a
 * territory, correcting its date, adding a district or turning a one-day round
 * into a two-day one were all impossible after creation.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GebietEditorSheet(
    existing: Gebiet?,
    onSave: (GebietDraft) -> Unit,
    onDismiss: () -> Unit
) {
    var name by remember(existing?.id) { mutableStateOf(existing?.name.orEmpty()) }
    var district by remember(existing?.id) { mutableStateOf(existing?.districtOrCity.orEmpty()) }
    var notes by remember(existing?.id) { mutableStateOf(existing?.notes.orEmpty()) }
    var isTwoDay by remember(existing?.id) { mutableStateOf(existing?.isTwoDay ?: false) }
    var day1 by remember(existing?.id) {
        mutableLongStateOf(existing?.day1Date ?: CampaignDays.startOfDay(System.currentTimeMillis()))
    }
    var day2 by remember(existing?.id) {
        mutableLongStateOf(
            existing?.day2Date ?: CampaignDays.addDays(
                CampaignDays.startOfDay(System.currentTimeMillis()), 1
            )
        )
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Text(
                if (existing == null) "Gebiet anlegen" else "Gebiet bearbeiten",
                style = MaterialTheme.typography.headlineSmall
            )

            EditorGroup("Name") {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    placeholder = { Text("z. B. Mödling") },
                    shape = RoundedCornerShape(RadiusControl)
                )
                OutlinedTextField(
                    value = district,
                    onValueChange = { district = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    placeholder = { Text("Ort oder Bezirk (optional)") },
                    shape = RoundedCornerShape(RadiusControl)
                )
            }

            EditorGroup("Zeitraum") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Zwei Tage", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "Tag 2 ist der Nachbesuchstag.",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(checked = isTwoDay, onCheckedChange = { isTwoDay = it })
                }
                DayStepperRow("Tag 1", day1) { day1 = it }
                if (isTwoDay) {
                    DayStepperRow("Tag 2", day2, minimum = CampaignDays.addDays(day1, 1)) { day2 = it }
                }
            }

            EditorGroup("Notizen") {
                OutlinedTextField(
                    value = notes,
                    onValueChange = { notes = it },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 72.dp),
                    minLines = 2,
                    maxLines = 5,
                    placeholder = { Text("Notizen") },
                    shape = RoundedCornerShape(RadiusControl)
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onDismiss, modifier = Modifier.weight(1f)) { Text("Abbrechen") }
                TextButton(
                    onClick = {
                        // Day 2 is normalised against day 1 here as well as in the
                        // model, so an impossible pair can never reach the Gebiet
                        // initialiser and throw.
                        val normalizedDay1 = CampaignDays.startOfDay(day1)
                        val normalizedDay2 =
                            if (!isTwoDay) null
                            else CampaignDays.startOfDay(day2).takeIf { it > normalizedDay1 }
                                ?: CampaignDays.addDays(normalizedDay1, 1)
                        onSave(
                            GebietDraft(
                                name = name.trim(),
                                districtOrCity = district.trim(),
                                notes = notes.trim(),
                                isTwoDay = isTwoDay,
                                day1Date = normalizedDay1,
                                day2Date = normalizedDay2
                            )
                        )
                    },
                    modifier = Modifier.weight(1f)
                ) { Text("Sichern") }
            }
        }
    }
}

@Composable
private fun EditorGroup(title: String, content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(RadiusCard))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        content()
    }
}

/**
 * A day picker built from two steppers.
 *
 * Material's `DatePicker` opens a full-screen dialog on top of a bottom sheet,
 * which on this screen means two stacked scrims; campaign days are always within
 * a few days of today, so stepping is both faster and less disruptive.
 */
@Composable
private fun DayStepperRow(label: String, value: Long, minimum: Long? = null, onChange: (Long) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyLarge)
            Text(
                formatDay(value),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        StepperButton("−", "Einen Tag früher") {
            val next = CampaignDays.addDays(value, -1)
            if (minimum == null || next >= minimum) onChange(next)
        }
        Spacer(Modifier.padding(horizontal = 3.dp))
        StepperButton("+", "Einen Tag später") { onChange(CampaignDays.addDays(value, 1)) }
    }
}

@Composable
private fun StepperButton(symbol: String, description: String, onClick: () -> Unit) {
    Box(
        Modifier
            .height(38.dp)
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp)
            // The glyph alone reads as "minus sign" to a screen reader.
            .clearAndSetSemantics { contentDescription = description },
        contentAlignment = Alignment.Center
    ) {
        Text(symbol, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
    }
}

private fun formatDay(epochMillis: Long): String = Instant.ofEpochMilli(epochMillis)
    .atZone(ZoneId.systemDefault())
    .toLocalDate()
    .format(DateTimeFormatter.ofPattern("EEEE, d. MMMM yyyy", Locale.forLanguageTag("de-AT")))
