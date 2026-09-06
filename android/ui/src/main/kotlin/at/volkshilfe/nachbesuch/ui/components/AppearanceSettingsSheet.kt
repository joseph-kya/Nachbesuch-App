package at.volkshilfe.nachbesuch.ui.components

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Brightness4
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.LightMode
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Palette
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.ui.theme.AppAccent
import at.volkshilfe.nachbesuch.ui.theme.AppAppearance
import at.volkshilfe.nachbesuch.ui.theme.RadiusCard
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl

/**
 * Appearance and accent, ported from the iOS `AppearanceSettingsSheet`.
 *
 * Android had no settings surface at all before this — the app followed the
 * system theme with no way to override it and no accent choice, both of which
 * the iOS build has shipped since v5.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppearanceSettingsSheet(
    appearance: AppAppearance,
    accent: AppAccent,
    /** The standing 14:00 / 16:00 / 18:00 "send the list" reminder. */
    dailyListReminders: Boolean,
    /** The hours that reminder fires, so the label cannot drift from the schedule. */
    reminderHours: List<Int>,
    /**
     * Whether the system will actually deliver anything. A toggle that is on but
     * muted in Android's settings must not silently lie about it.
     */
    notificationsAllowed: Boolean,
    onAppearance: (AppAppearance) -> Unit,
    onAccent: (AppAccent) -> Unit,
    onDailyListReminders: (Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text("Einstellungen", style = MaterialTheme.typography.headlineSmall)
            PrivacySupportSection()

            SettingsGroup("Darstellung", Icons.Default.Brightness4) {
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
                    AppAppearance.entries.forEach { value ->
                        SegmentButton(
                            title = value.title,
                            icon = when (value) {
                                AppAppearance.SYSTEM -> Icons.Default.Brightness4
                                AppAppearance.LIGHT -> Icons.Default.LightMode
                                AppAppearance.DARK -> Icons.Default.DarkMode
                            },
                            isSelected = value == appearance,
                            onClick = { onAppearance(value) },
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }

            SettingsGroup("Akzentfarbe", Icons.Default.Palette) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    AppAccent.entries.chunked(2).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            row.forEach { value ->
                                AccentRow(
                                    accent = value,
                                    isSelected = value == accent,
                                    onClick = { onAccent(value) },
                                    modifier = Modifier.weight(1f)
                                )
                            }
                            // Keeps a trailing odd item at half width instead of
                            // stretching it across the row.
                            if (row.size == 1) Box(Modifier.weight(1f))
                        }
                    }
                }
            }

            SettingsGroup("Erinnerungen", Icons.Default.NotificationsActive) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onDailyListReminders(!dailyListReminders) }
                        .heightIn(min = MinTouchTarget),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Liste an Teamleiter senden", style = MaterialTheme.typography.labelLarge)
                        Text(
                            reminderTimesText(reminderHours),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(checked = dailyListReminders, onCheckedChange = onDailyListReminders)
                }

                if (dailyListReminders && !notificationsAllowed) {
                    Text(
                        "Mitteilungen sind für Nachbesuch ausgeschaltet. Die Erinnerung erscheint erst, " +
                            "wenn du sie in den Android-Einstellungen erlaubst.",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }

                Text(
                    "Gilt auch für „Später“: ein Haus mit gebuchter Uhrzeit meldet sich pünktlich.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Text(
                "Die Einstellung gilt sofort für Karte, Liste und Archiv.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/** "14:00, 16:00 und 18:00", built from the schedule rather than typed out. */
private fun reminderTimesText(hours: List<Int>): String {
    val times = hours.map { String.format(java.util.Locale.GERMAN, "%02d:00", it) }
    val joined = if (times.size < 2) {
        times.joinToString()
    } else {
        "${times.dropLast(1).joinToString(", ")} und ${times.last()}"
    }
    return "Mo–Fr · $joined"
}

@Composable
private fun SettingsGroup(title: String, icon: ImageVector, content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(RadiusCard))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
            Text(title, style = MaterialTheme.typography.titleMedium)
        }
        content()
    }
}

@Composable
private fun SegmentButton(
    title: String,
    icon: ImageVector,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val background = if (isSelected) MaterialTheme.colorScheme.surfaceContainerLowest else Color.Transparent
    val foreground =
        if (isSelected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        modifier
            .background(background, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .heightIn(min = 44.dp)
            .padding(vertical = 6.dp)
            .semantics { selected = isSelected },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Icon(icon, contentDescription = null, tint = foreground, modifier = Modifier.size(18.dp))
        Text(title, style = MaterialTheme.typography.labelMedium, color = foreground)
    }
}

@Composable
private fun AccentRow(
    accent: AppAccent,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val swatch = if (dark) accent.dark else accent.light
    Row(
        modifier
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(RadiusControl))
            .border(
                width = if (isSelected) 1.5.dp else 0.dp,
                color = if (isSelected) swatch else Color.Transparent,
                shape = RoundedCornerShape(RadiusControl)
            )
            .clickable(onClick = onClick)
            .heightIn(min = MinTouchTarget)
            .padding(horizontal = 12.dp)
            .semantics { selected = isSelected },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Box(Modifier.size(18.dp).background(swatch, CircleShape))
        Text(accent.title, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
        if (isSelected) {
            Icon(Icons.Default.CheckCircle, contentDescription = null, tint = swatch, modifier = Modifier.size(18.dp))
        }
    }
}
