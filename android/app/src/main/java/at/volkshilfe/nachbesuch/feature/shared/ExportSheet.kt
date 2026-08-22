package at.volkshilfe.nachbesuch.feature.shared

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.DataObject
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.ui.components.MinTouchTarget
import at.volkshilfe.nachbesuch.ui.theme.RadiusCard
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl

/** Which document the user asked for. */
enum class ExportFormat { TEXT, PDF, JSON }

/** The export options, mirroring the iOS `ExportSheet` toggles. */
data class ExportOptions(
    val scope: DayScope,
    val visitedOnly: Boolean,
    val includeNotes: Boolean
)

/**
 * Export, rebuilt to match the iOS `ExportSheet`.
 *
 * The old archive offered `Backup JSON · PDF · Text · Importieren` as four bare
 * text buttons with no options at all — the scope, "visited only" and "include
 * notes" settings that iOS has always had were simply unavailable on Android,
 * so a shared document always carried every internal note in it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportSheet(
    options: ExportOptions,
    isTwoDay: Boolean,
    houseCount: Int,
    onOptions: (ExportOptions) -> Unit,
    onExport: (ExportFormat) -> Unit,
    onImport: () -> Unit,
    onDismiss: () -> Unit
) {
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
            Text("Exportieren", style = MaterialTheme.typography.headlineSmall)

            if (isTwoDay) {
                ExportGroup("Zeitraum") {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .background(
                                MaterialTheme.colorScheme.surfaceContainerHighest,
                                RoundedCornerShape(RadiusControl)
                            )
                            .padding(4.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        listOf(
                            DayScope.COMBINED to "Gesamt",
                            DayScope.DAY_1 to "Tag 1",
                            DayScope.DAY_2 to "Tag 2"
                        ).forEach { (value, label) ->
                            val isSelected = value == options.scope
                            Box(
                                Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(
                                        if (isSelected) MaterialTheme.colorScheme.surfaceContainerLowest
                                        else Color.Transparent,
                                        RoundedCornerShape(12.dp)
                                    )
                                    .clickable { onOptions(options.copy(scope = value)) }
                                    .heightIn(min = 38.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(label, style = MaterialTheme.typography.labelLarge)
                            }
                        }
                    }
                }
            }

            ExportGroup("Umfang") {
                ToggleRow(
                    title = "Nur besuchte Adressen",
                    subtitle = "Häuser ohne einen einzigen Eintrag werden weggelassen.",
                    checked = options.visitedOnly,
                    onChange = { onOptions(options.copy(visitedOnly = it)) }
                )
                Text(
                    "$houseCount Häuser im aktiven Gebiet",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            ExportGroup("Inhalt") {
                ToggleRow(
                    title = "Notizen einbeziehen",
                    subtitle = "Notizen sind interne Stichworte und landen sonst mit im Dokument.",
                    checked = options.includeNotes,
                    onChange = { onOptions(options.copy(includeNotes = it)) }
                )
            }

            ExportGroup("Format") {
                ExportAction(Icons.Default.Description, "Textliste", "Zum Weitergeben per Nachricht") {
                    onExport(ExportFormat.TEXT)
                }
                ExportAction(Icons.Default.PictureAsPdf, "PDF", "Zum Ausdrucken oder Archivieren") {
                    onExport(ExportFormat.PDF)
                }
                ExportAction(Icons.Default.DataObject, "Backup (JSON)", "Vollständige Sicherung aller Gebiete") {
                    onExport(ExportFormat.JSON)
                }
                ExportAction(Icons.Default.Upload, "Backup einlesen", "Fügt fehlende Datensätze hinzu, überschreibt nichts") {
                    onImport()
                }
            }
        }
    }
}

@Composable
private fun ExportGroup(title: String, content: @Composable () -> Unit) {
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

@Composable
private fun ToggleRow(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                subtitle,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun ExportAction(icon: ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(RadiusControl))
            .clickable(onClick = onClick)
            .heightIn(min = MinTouchTarget)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                subtitle,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
