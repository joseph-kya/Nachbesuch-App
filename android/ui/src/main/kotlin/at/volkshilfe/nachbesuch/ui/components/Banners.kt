package at.volkshilfe.nachbesuch.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.text.style.TextOverflow
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
        BannerSurface(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
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
                Icon(
                    Icons.Default.Close,
                    contentDescription = "Hinweis schließen",
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .clickable(onClick = onDismiss)
                        .padding(11.dp)
                )
            }
        }
    }
}

/**
 * The shared banner material.
 *
 * Opaque, unlike the map's [ChromePanel]: these float over list rows and cards,
 * and at the chrome's 94% the text underneath showed straight through the
 * message — exactly when the user most needs to read it.
 */
@Composable
private fun BannerSurface(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        modifier
            .shadow(8.dp, RoundedCornerShape(RadiusCard), clip = false)
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(RadiusCard))
            .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(RadiusCard))
            .padding(horizontal = 14.dp, vertical = 10.dp)
    ) { content() }
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
        BannerSurface(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    shown,
                    style = MaterialTheme.typography.bodyMedium,
                    // One line: the label is "<address>: <status>", and letting a
                    // long address wrap doubled the banner's height over the list.
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
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
