package at.volkshilfe.nachbesuch.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.ui.notice.NoticeCenter
import at.volkshilfe.nachbesuch.ui.theme.ChromeIconButton
import at.volkshilfe.nachbesuch.ui.theme.ChromePanel
import at.volkshilfe.nachbesuch.ui.theme.RadiusCard

/**
 * The transient message banner, mirroring the iOS `AppNoticeBanner`.
 *
 * Rendered in the same chrome material as the map panels, because like them it
 * floats above content rather than sitting in it.
 */
@Composable
fun NoticeBanner(notice: NoticeCenter.Notice?, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    AnimatedVisibility(
        visible = notice != null,
        enter = slideInVertically { -it } + fadeIn(),
        exit = slideOutVertically { -it } + fadeOut(),
        modifier = modifier
    ) {
        // Held so the text does not blank out mid-exit-animation.
        val shown = notice ?: return@AnimatedVisibility
        ChromePanel(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            cornerRadius = RadiusCard,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(
                    if (shown.isError) Icons.Default.ErrorOutline else Icons.Default.Info,
                    contentDescription = null,
                    tint = if (shown.isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.tertiary,
                    modifier = Modifier.size(22.dp)
                )
                Text(
                    shown.message,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f)
                )
                ChromeIconButton(onClick = onDismiss, size = 34.dp) {
                    Icon(
                        Icons.Default.Close,
                        contentDescription = "Hinweis schließen",
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
        }
    }
}

/**
 * The undo affordance for a status tap, mirroring the iOS `UndoBanner`.
 *
 * A status is one tap to set and, without this, impossible to take back except by
 * reopening the door and re-picking — the single most common field mistake.
 */
@Composable
fun UndoBanner(
    label: String?,
    onUndo: () -> Unit,
    modifier: Modifier = Modifier
) {
    AnimatedVisibility(
        visible = label != null,
        enter = slideInVertically { it } + fadeIn(),
        exit = slideOutVertically { it } + fadeOut(),
        modifier = modifier
    ) {
        val shown = label ?: return@AnimatedVisibility
        ChromePanel(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 8.dp)
        ) {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    shown,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f)
                )
                TextButton(onClick = onUndo) {
                    Icon(Icons.Default.Undo, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Rückgängig")
                }
            }
        }
    }
}
