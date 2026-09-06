package at.volkshilfe.nachbesuch.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material3.ripple
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.ui.status.displayIcon
import at.volkshilfe.nachbesuch.ui.status.displayTint
import at.volkshilfe.nachbesuch.ui.status.icon
import at.volkshilfe.nachbesuch.ui.status.tint
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl

/** Minimum touch target. Anything smaller is unusable with gloves on, in the field. */
val MinTouchTarget = 48.dp

/**
 * One of the four status choices, ported from the iOS `OutcomeButton`.
 *
 * Carries the emoji *and* a distinct icon so the four outcomes stay
 * distinguishable by shape — red, orange and pink are three warm hues a
 * colour-blind user cannot reliably separate at 12sp.
 */
@Composable
fun OutcomeButton(
    outcome: VisitOutcome,
    isSelected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val interaction = remember { MutableInteractionSource() }
    val scale by animateFloatAsState(if (isSelected) 1.12f else 1f, label = "outcome-glyph")
    Column(
        modifier = modifier
            .touchMotion(interaction)
            .clip(RoundedCornerShape(RadiusControl))
            .background(
                if (isSelected) outcome.tint.copy(alpha = 0.18f)
                else MaterialTheme.colorScheme.surfaceContainerHighest,
                RoundedCornerShape(RadiusControl)
            )
            .border(
                width = if (isSelected) 2.dp else 0.dp,
                color = if (isSelected) outcome.tint else Color.Transparent,
                shape = RoundedCornerShape(RadiusControl)
            )
            .clickable(interactionSource = interaction, indication = ripple(), onClick = onClick)
            .padding(vertical = 12.dp, horizontal = 8.dp)
            .heightIn(min = MinTouchTarget)
            .clearAndSetSemantics {
                contentDescription = outcome.germanTitle
                stateDescription = outcome.explanation
                selected = isSelected
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp)
    ) {
        Text(outcome.emoji, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.scale(scale))
        Text(
            outcome.germanTitle,
            style = MaterialTheme.typography.labelLarge,
            textAlign = TextAlign.Center
        )
        Text(
            outcome.explanation,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

/**
 * The "Später" control — deliberately a single wide row under the 2×2 grid of
 * results rather than a fifth tile in it.
 *
 * Two reasons, both shared with the iOS `LaterButton`. It is not a result: the
 * door stays open, it is only moved to a later time, and grouping it with "Dabei"
 * would say otherwise. And a five-tile grid leaves an odd gap that reads as a
 * missing option.
 */
@Composable
fun LaterButton(
    isSelected: Boolean,
    /** The time already booked, shown in place of the explanation. */
    bookedAtText: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val outcome = VisitOutcome.LATER
    val detail = if (isSelected && bookedAtText != null) "Gebucht für $bookedAtText" else outcome.explanation
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(RadiusControl))
            .background(
                if (isSelected) outcome.tint.copy(alpha = 0.18f)
                else MaterialTheme.colorScheme.surfaceContainerHighest,
                RoundedCornerShape(RadiusControl)
            )
            .border(
                width = if (isSelected) 2.dp else 0.dp,
                color = if (isSelected) outcome.tint else Color.Transparent,
                shape = RoundedCornerShape(RadiusControl)
            )
            .clickable(onClick = onClick)
            .heightIn(min = MinTouchTarget)
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .clearAndSetSemantics {
                contentDescription = outcome.germanTitle
                stateDescription = detail
                selected = isSelected
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text(outcome.emoji, style = MaterialTheme.typography.titleMedium)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(outcome.germanTitle, style = MaterialTheme.typography.labelLarge)
            Text(
                detail,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Icon(
            Icons.Default.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp)
        )
    }
}

/** Compact status glyph for list rows — shape plus colour, never colour alone. */
@Composable
fun OutcomeGlyph(outcome: VisitOutcome?, modifier: Modifier = Modifier, size: androidx.compose.ui.unit.Dp = 20.dp) {
    Icon(
        outcome.displayIcon,
        contentDescription = null,
        tint = outcome.displayTint,
        modifier = modifier.size(size)
    )
}

/** One filter chip's data, mirroring the iOS `FilterChip` value type. */
data class FilterChipSpec(
    val id: String,
    val title: String,
    val icon: ImageVector,
    val tint: Color,
    val count: Int?,
    val isSelected: Boolean
)

/**
 * The app's filter bar — one implementation shared by the list and the map,
 * matching the iOS `FilterBar`.
 *
 * The selected chip carries its own tint as a filled surface; the rest are plain
 * chrome. Selection reads as a material change rather than a moving highlight,
 * which keeps it legible with animations disabled.
 */
@Composable
fun FilterBar(
    chips: List<FilterChipSpec>,
    contextLabel: String,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    onHelp: (() -> Unit)? = null
) {
    Row(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(
            Modifier.weight(1f).horizontalScroll(rememberScrollState()).padding(horizontal = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            chips.forEach { chip ->
                FilterChipButton(chip, contextLabel, onClick = { onSelect(chip.id) })
            }
        }
        if (onHelp != null) {
            Box(
                Modifier
                    .size(MinTouchTarget)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceContainerHighest, CircleShape)
                    .clickable(onClick = onHelp),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.HelpOutline,
                    contentDescription = "Erklärung der Status-Symbole",
                    modifier = Modifier.size(18.dp)
                )
            }
        }
    }
}

@Composable
private fun FilterChipButton(chip: FilterChipSpec, contextLabel: String, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val haptics = LocalHapticFeedback.current
    val background =
        if (chip.isSelected) chip.tint.copy(alpha = 0.20f) else MaterialTheme.colorScheme.surfaceContainerHighest
    val foreground =
        if (chip.isSelected) chip.tint else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        Modifier
            .touchMotion(interaction)
            .heightIn(min = MinTouchTarget)
            .clip(RoundedCornerShape(18.dp))
            .background(background, RoundedCornerShape(18.dp))
            .border(
                width = if (chip.isSelected) 1.5.dp else 0.dp,
                color = if (chip.isSelected) chip.tint else Color.Transparent,
                shape = RoundedCornerShape(18.dp)
            )
            .clickable(interactionSource = interaction, indication = ripple(), onClick = {
                if (!chip.isSelected) {
                    haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    onClick()
                }
            })
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .clearAndSetSemantics {
                contentDescription = "$contextLabel: ${chip.title}" +
                    (chip.count?.let { ", $it" } ?: "")
                selected = chip.isSelected
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Icon(chip.icon, contentDescription = null, tint = foreground, modifier = Modifier.size(16.dp))
        Text(chip.title, style = MaterialTheme.typography.labelLarge, color = foreground)
        if (chip.count != null) {
            Text(
                chip.count.toString(),
                style = MaterialTheme.typography.labelMedium,
                color = foreground.copy(alpha = 0.75f)
            )
        }
    }
}
