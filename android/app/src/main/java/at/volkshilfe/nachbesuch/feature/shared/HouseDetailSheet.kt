package at.volkshilfe.nachbesuch.feature.shared

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.Apartment
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.ui.components.MinTouchTarget
import at.volkshilfe.nachbesuch.ui.components.OutcomeButton
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl
import at.volkshilfe.nachbesuch.ui.theme.RadiusSmall
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val NoteSuggestions = listOf(
    "Abends wiederkommen", "Briefkasten", "Kein Klingelschild",
    "Hund", "Nur Wochenende", "Tür verschlossen"
)

/**
 * The house sheet, rebuilt to match the iOS `HouseDetailSheet`.
 *
 * What it gained: editable address and note with the same quick-fill chips,
 * per-door status with the shared [OutcomeButton], renameable doors, the bulk
 * "all open doors as not home" action, the last-recorded timestamp, walk-route
 * and copy-address actions, and a real delete confirmation.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun HouseDetailSheet(
    house: House,
    scope: DayScope,
    /**
     * The day writes actually land on — the visible picker is a filter only.
     * Showing status against a different day than the one being written is the
     * single most confusing thing this sheet can do.
     */
    writeScope: DayScope,
    /** One-day territories have no Tag-2 anything; see [isTwoDay] use below. */
    isTwoDay: Boolean,
    onScopeChange: (DayScope) -> Unit,
    onOutcome: (String, VisitOutcome?) -> Unit,
    onRenameUnit: (String, String) -> Unit,
    onAllOpenNotHome: () -> Unit,
    onResize: (Int) -> Unit,
    onAddressChange: (String) -> Unit,
    onNoteChange: (String) -> Unit,
    onWalkRoute: () -> Unit,
    onCopyAddress: () -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit
) {
    var confirmDelete by remember { mutableStateOf(false) }
    var showUnitCount by remember { mutableStateOf(false) }
    var draftAddress by remember(house.id) { mutableStateOf(house.address) }
    var draftNote by remember(house.id) { mutableStateOf(house.note) }
    val tally = house.tally(scope)

    ModalBottomSheet(
        onDismissRequest = {
            // Commit the free-text drafts on the way out; a sheet that silently
            // discards a typed note is the bug this replaces.
            if (draftAddress.trim() != house.address && draftAddress.isNotBlank()) onAddressChange(draftAddress.trim())
            if (draftNote != house.note) onNoteChange(draftNote)
            onDismiss()
        },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow
    ) {
        LazyColumn(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            // The drag handle sits directly above; without this the address
            // field's floating label is clipped against it.
            item(key = "top") { Spacer(Modifier.height(4.dp)) }
            if (house.isDamaged) {
                item(key = "damaged") {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .background(
                                MaterialTheme.colorScheme.errorContainer,
                                RoundedCornerShape(RadiusControl)
                            )
                            .padding(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            Icons.Default.Warning,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onErrorContainer
                        )
                        Text(
                            "Daten beschädigt – Änderungen sind gesperrt.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onErrorContainer
                        )
                    }
                }
            }

            item(key = "header") {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    OutlinedTextField(
                        value = draftAddress,
                        onValueChange = { draftAddress = it },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !house.isDamaged,
                        label = { Text("Adresse") },
                        shape = RoundedCornerShape(RadiusControl)
                    )
                    Text(
                        "${tally.completed} von ${tally.unitCount} erledigt",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    // The picker filters; the calendar decides where writes go. Only
                    // worth saying when the two can actually differ — on a one-day
                    // territory every write lands on Tag 1 and the notice is noise.
                    if (isTwoDay && writeScope != scope) {
                        Text(
                            "Einträge werden auf ${writeScope.germanLabel()} gespeichert.",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                }
            }

            if (isTwoDay) item(key = "scope") {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(RadiusControl))
                        .padding(4.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    listOf(
                        DayScope.COMBINED to "Gesamt",
                        DayScope.DAY_1 to "Tag 1",
                        DayScope.DAY_2 to "Tag 2"
                    ).forEach { (value, label) ->
                        val isSelected = value == scope
                        Box(
                            Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(12.dp))
                                .background(
                                    if (isSelected) MaterialTheme.colorScheme.surfaceContainerLowest
                                    else androidx.compose.ui.graphics.Color.Transparent,
                                    RoundedCornerShape(12.dp)
                                )
                                .clickable { onScopeChange(value) }
                                .heightIn(min = 38.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(label, style = MaterialTheme.typography.labelLarge)
                        }
                    }
                }
            }

            if (house.isApartmentBuilding) {
                item(key = "doors-header") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Türen", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        TextButton(onClick = { showUnitCount = true }, enabled = !house.isDamaged) {
                            Text("Anzahl ändern")
                        }
                    }
                }
                items(house.units, key = { it.id }) { door ->
                    ApartmentDoorRow(
                        door = door,
                        writeScope = writeScope,
                        isDisabled = house.isDamaged,
                        onSelect = { outcome -> onOutcome(door.id, outcome) },
                        onRename = { name -> onRenameUnit(door.id, name) }
                    )
                }
                item(key = "bulk") {
                    TextButton(onClick = onAllOpenNotHome, enabled = !house.isDamaged) {
                        Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("  Alle offenen Türen als „Niemand da“")
                    }
                }
            } else {
                item(key = "single") {
                    val door = house.units.firstOrNull()
                    if (door != null) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Ergebnis", style = MaterialTheme.typography.titleMedium)
                            OutcomeGrid(
                                current = door.result(writeScope),
                                isDisabled = house.isDamaged,
                                onSelect = { outcome -> onOutcome(door.id, outcome) }
                            )
                            door.timestamp(scope)?.let { stamp ->
                                Text(
                                    "Zuletzt: ${SimpleDateFormat("HH:mm", Locale.GERMAN).format(Date(stamp))}",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
                item(key = "make-apartment") {
                    TextButton(onClick = { showUnitCount = true }, enabled = !house.isDamaged) {
                        Icon(Icons.Default.Apartment, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("  Zu Mehrparteienhaus machen")
                    }
                }
            }

            item(key = "note") {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Notiz", style = MaterialTheme.typography.titleMedium)
                    OutlinedTextField(
                        value = draftNote,
                        onValueChange = { draftNote = it },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 72.dp),
                        enabled = !house.isDamaged,
                        minLines = 2,
                        maxLines = 6,
                        placeholder = { Text("Notiz") },
                        shape = RoundedCornerShape(RadiusControl)
                    )
                    // Wraps rather than scrolls horizontally: a horizontal scroller
                    // inside a vertical list fights the list's own pan.
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        NoteSuggestions.forEach { suggestion ->
                            Text(
                                suggestion,
                                style = MaterialTheme.typography.labelMedium,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(14.dp))
                                    .clickable(enabled = !house.isDamaged) {
                                        draftNote = if (draftNote.isBlank()) suggestion
                                        else "${draftNote.trimEnd()} · $suggestion"
                                    }
                                    .padding(horizontal = 11.dp, vertical = 8.dp)
                            )
                        }
                    }
                }
            }

            item(key = "actions") {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = onWalkRoute) {
                        Icon(Icons.AutoMirrored.Filled.DirectionsWalk, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("  Fußroute öffnen")
                    }
                    TextButton(onClick = onCopyAddress) {
                        Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("  Adresse kopieren")
                    }
                    TextButton(onClick = { confirmDelete = true }) {
                        Icon(
                            Icons.Default.Delete,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(18.dp)
                        )
                        Text("  Haus löschen", color = MaterialTheme.colorScheme.error)
                    }
                }
            }

            item(key = "bottom") { Spacer(Modifier.height(28.dp)) }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Haus löschen?") },
            text = { Text("„${house.address}“ und alle erfassten Türergebnisse werden entfernt.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; onDelete() }) {
                    Text("Löschen", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Abbrechen") } }
        )
    }

    if (showUnitCount) {
        UnitCountDialog(
            current = house.units.size,
            onConfirm = { count -> showUnitCount = false; onResize(count) },
            onDismiss = { showUnitCount = false }
        )
    }
}

@Composable
private fun OutcomeGrid(current: VisitOutcome?, isDisabled: Boolean, onSelect: (VisitOutcome?) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        VisitOutcome.entries.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { outcome ->
                    OutcomeButton(
                        outcome = outcome,
                        isSelected = current == outcome,
                        // Tapping the active status clears it, matching iOS.
                        onClick = { if (!isDisabled) onSelect(if (current == outcome) null else outcome) },
                        modifier = Modifier.weight(1f)
                    )
                }
            }
        }
    }
}

@Composable
private fun ApartmentDoorRow(
    door: DoorResult,
    writeScope: DayScope,
    isDisabled: Boolean,
    onSelect: (VisitOutcome?) -> Unit,
    onRename: (String) -> Unit
) {
    var renaming by remember(door.id) { mutableStateOf(false) }
    var draftLabel by remember(door.id) { mutableStateOf(door.label) }
    val current = door.result(writeScope)
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(RadiusControl))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        if (renaming) {
            OutlinedTextField(
                value = draftLabel,
                onValueChange = { draftLabel = it },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                label = { Text("Bezeichnung") },
                shape = RoundedCornerShape(RadiusSmall)
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { renaming = false; draftLabel = door.label }) { Text("Abbrechen") }
                TextButton(onClick = { renaming = false; onRename(draftLabel) }) { Text("Sichern") }
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(door.label, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                TextButton(onClick = { renaming = true }, enabled = !isDisabled) { Text("Umbenennen") }
            }
        }
        OutcomeGrid(current = current, isDisabled = isDisabled, onSelect = onSelect)
    }
}

@Composable
private fun UnitCountDialog(current: Int, onConfirm: (Int) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(current.coerceAtLeast(2).toString()) }
    val parsed = text.toIntOrNull()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Anzahl der Parteien") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it.filter(Char::isDigit).take(3) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    label = { Text("Türen") },
                    isError = parsed == null || parsed !in 2..100
                )
                Text(
                    "Zwischen 2 und 100. Bestehende Ergebnisse bleiben erhalten; " +
                        "beim Verkleinern entfallen die letzten Türen.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { parsed?.let(onConfirm) },
                enabled = parsed != null && parsed in 2..100
            ) { Text("Sichern") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } }
    )
}

private fun DayScope.germanLabel(): String = when (this) {
    DayScope.DAY_1 -> "Tag 1"
    DayScope.DAY_2 -> "Tag 2"
    DayScope.COMBINED -> "Gesamt"
}
