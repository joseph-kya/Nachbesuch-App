package at.volkshilfe.nachbesuch.feature.list

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.ui.Modifier
import at.volkshilfe.nachbesuch.domain.list.ListFilter
import at.volkshilfe.nachbesuch.domain.list.StreetSection
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.ui.components.FilterChipSpec

/**
 * Everything [ListScreen] draws, and the callbacks it fires.
 *
 * Bundled into one value rather than fifteen parameters so the screen stays a
 * pure function of state — and so the caller, not the screen, decides where the
 * data and the sorting come from.
 */
data class ListScreenState(
    val territoryName: String,
    val isTwoDay: Boolean,
    val scope: DayScope,
    val query: String,
    val filter: ListFilter,
    val sort: ListSort,
    val canSortByDistance: Boolean,
    val sections: List<StreetSection>,
    val chips: List<FilterChipSpec>,
    val collapsedSections: Set<String>,
    /** Non-null while a quick status can still be taken back. */
    val undoLabel: String?,
    val onUndo: () -> Unit,
    val onQuery: (String) -> Unit,
    val onFilter: (ListFilter) -> Unit,
    val onScope: (DayScope) -> Unit,
    val onSort: (ListSort) -> Unit,
    val onToggleSection: (String) -> Unit
)

/**
 * `combinedClickable` behind one call site.
 *
 * It is still an experimental API; wrapping it keeps the opt-in in exactly one
 * place instead of sprinkling `@OptIn` through the screen.
 */
@OptIn(ExperimentalFoundationApi::class)
fun Modifier.combinedClickableCompat(onClick: () -> Unit, onLongClick: () -> Unit): Modifier =
    combinedClickable(onClick = onClick, onLongClick = onLongClick)
