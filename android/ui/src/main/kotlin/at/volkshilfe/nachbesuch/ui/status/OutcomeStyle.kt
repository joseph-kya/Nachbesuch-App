package at.volkshilfe.nachbesuch.ui.status

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome

/**
 * Presentation for [VisitOutcome], kept out of the domain module for the same
 * reason iOS keeps it in `VisitOutcome+UI`: the enum is decoded off the main
 * thread by the map, archive and export pipelines, and the domain module has no
 * Compose dependency at all.
 *
 * Every outcome carries an [icon] as well as a [tint]. Hue alone is not a usable
 * cue — the four statuses have to stay distinguishable in greyscale and for
 * colour-blind users, which the emoji-only rows did not manage.
 */
val VisitOutcome.tint: Color
    get() = when (this) {
        VisitOutcome.NOT_HOME -> Color(0xFFE0303F)
        VisitOutcome.EARLY_NO -> Color(0xFFE8850C)
        VisitOutcome.LATE_NO -> Color(0xFF8A8A8E)
        VisitOutcome.JOINED -> Color(0xFFE0559A)
    }

val VisitOutcome.icon: ImageVector
    get() = when (this) {
        VisitOutcome.NOT_HOME -> Icons.Default.Refresh
        VisitOutcome.EARLY_NO -> Icons.Default.Block
        VisitOutcome.LATE_NO -> Icons.Default.Close
        VisitOutcome.JOINED -> Icons.Default.Favorite
    }

/** The "no status yet" tone, matching the iOS `displayTint` fallback. */
val UnsetOutcomeTint = Color(0xFF147EFB)

val VisitOutcome?.displayTint: Color get() = this?.tint ?: UnsetOutcomeTint
val VisitOutcome?.displayIcon: ImageVector get() = this?.icon ?: Icons.Default.HelpOutline
val VisitOutcome?.displayTitle: String get() = this?.germanTitle ?: "Noch kein Status"
val VisitOutcome?.displayEmoji: String get() = this?.emoji ?: "•"
