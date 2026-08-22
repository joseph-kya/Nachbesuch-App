package at.volkshilfe.nachbesuch.feature.archive

import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.stats.TerritorySummary
import at.volkshilfe.nachbesuch.ui.components.FilterChipSpec

/** Everything [ArchiveScreen] draws, and the callbacks it fires. */
data class ArchiveScreenState(
    val query: String,
    val filter: ArchiveFilter,
    val scope: DayScope,
    val activeID: String?,
    val activeSummary: TerritorySummary?,
    val sections: List<DaySection>,
    val chips: List<FilterChipSpec>,
    val onQuery: (String) -> Unit,
    val onFilter: (ArchiveFilter) -> Unit,
    val onScope: (DayScope) -> Unit,
    val onSelect: (String) -> Unit,
    val onEdit: (String) -> Unit,
    val onDelete: (String) -> Unit,
    val onCreate: () -> Unit,
    val onExport: () -> Unit,
    val onSettings: () -> Unit
)
