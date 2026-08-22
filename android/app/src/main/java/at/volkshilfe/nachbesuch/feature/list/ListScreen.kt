package at.volkshilfe.nachbesuch.feature.list

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.HomeWork
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Sort
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.list.HouseRow
import at.volkshilfe.nachbesuch.domain.list.ListFilter
import at.volkshilfe.nachbesuch.domain.list.StreetSection
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.ui.components.FilterBar
import at.volkshilfe.nachbesuch.ui.components.FilterChipSpec
import at.volkshilfe.nachbesuch.ui.components.MinTouchTarget
import at.volkshilfe.nachbesuch.ui.components.OutcomeGlyph
import at.volkshilfe.nachbesuch.ui.status.icon
import at.volkshilfe.nachbesuch.ui.status.tint
import at.volkshilfe.nachbesuch.ui.theme.RadiusCard
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl
import at.volkshilfe.nachbesuch.ui.theme.RadiusRow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** How the list orders its rows. */
enum class ListSort(val title: String) {
    SMART("Offene zuerst"),
    DISTANCE("Nächste zuerst")
}

/**
 * The street list, rebuilt to match the iOS `ListScreen`.
 *
 * Everything below the search field — filtering, sorting, grouping and the
 * counts on the chips — is computed by `HouseListBuilder` in the domain module,
 * so this file is presentation only and the behaviour is unit-tested.
 */
@Composable
fun ListScreen(
    state: ListScreenState,
    onHouseSelected: (String) -> Unit,
    onQuickStatus: (HouseRow, VisitOutcome) -> Unit,
    onShowLegend: () -> Unit,
    contentPadding: PaddingValues = PaddingValues(0.dp)
) {
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(horizontal = 16.dp)) {
            Spacer(Modifier.height(contentPadding.calculateTopPadding() + 8.dp))
            Text("Nachbesuche", style = MaterialTheme.typography.headlineLarge)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    state.territoryName,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                SortMenu(state.sort, state.canSortByDistance, state.onSort)
            }
            Spacer(Modifier.height(10.dp))
            SearchField(state.query, state.onQuery)
            Spacer(Modifier.height(10.dp))
            if (state.isTwoDay) {
                DayScopeRow(state.scope, state.onScope)
                Spacer(Modifier.height(8.dp))
            }
            FilterBar(
                chips = state.chips,
                contextLabel = "Filter",
                onSelect = { state.onFilter(ListFilter.from(it)) },
                onHelp = onShowLegend
            )
            Spacer(Modifier.height(10.dp))
        }

        if (state.sections.isEmpty()) {
            EmptyState(state.filter, state.query)
        } else {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    start = 16.dp, end = 16.dp, bottom = 24.dp + contentPadding.calculateBottomPadding()
                ),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                state.sections.forEach { section ->
                    item(key = section.id) {
                        StreetHeader(
                            section = section,
                            isExpanded = section.id !in state.collapsedSections,
                            onToggle = { state.onToggleSection(section.id) }
                        )
                    }
                    if (section.id !in state.collapsedSections) {
                        items(section.rows, key = { it.id }) { row ->
                            HouseRowItem(
                                row = row,
                                onClick = { onHouseSelected(row.id) },
                                onQuickStatus = { outcome -> onQuickStatus(row, outcome) }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchField(query: String, onQuery: (String) -> Unit) {
    TextField(
        value = query,
        onValueChange = onQuery,
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
        shape = RoundedCornerShape(RadiusControl),
        leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                Icon(
                    Icons.Default.Clear,
                    contentDescription = "Suche löschen",
                    modifier = Modifier
                        .size(MinTouchTarget)
                        .clickable { onQuery("") }
                        .padding(14.dp)
                )
            }
        },
        placeholder = { Text("Adresse oder Notiz suchen") },
        // The stock TextField underline is the one Material detail that never
        // matched this app's rounded chrome.
        colors = TextFieldDefaults.colors(
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh
        )
    )
}

@Composable
private fun SortMenu(sort: ListSort, canSortByDistance: Boolean, onSort: (ListSort) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .clip(RoundedCornerShape(14.dp))
                .clickable { expanded = true }
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Icon(
                if (sort == ListSort.DISTANCE) Icons.Default.MyLocation else Icons.Default.Sort,
                contentDescription = "Sortierung ändern",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp)
            )
            Text(sort.title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            ListSort.entries.forEach { value ->
                DropdownMenuItem(
                    text = { Text(value.title) },
                    // Without a position there is nothing to measure from, so the
                    // option is shown but inert rather than silently doing nothing.
                    enabled = value != ListSort.DISTANCE || canSortByDistance,
                    onClick = { onSort(value); expanded = false }
                )
            }
        }
    }
}

@Composable
private fun DayScopeRow(scope: DayScope, onScope: (DayScope) -> Unit) {
    val options = listOf(
        DayScope.COMBINED to "Gesamt",
        DayScope.DAY_1 to "Tag 1",
        DayScope.DAY_2 to "Tag 2"
    )
    Row(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(RadiusControl))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        options.forEach { (value, label) ->
            val isSelected = value == scope
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(
                        if (isSelected) MaterialTheme.colorScheme.surfaceContainerLowest else Color.Transparent,
                        RoundedCornerShape(12.dp)
                    )
                    .clickable { onScope(value) }
                    .heightIn(min = 38.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelLarge,
                    color = if (isSelected) MaterialTheme.colorScheme.onSurface
                    else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

/**
 * A collapsible street header with its own progress.
 *
 * Collapsing matters on a real round: a territory with forty houses on six
 * streets is unusable as one flat list once you are standing on street four.
 */
@Composable
private fun StreetHeader(section: StreetSection, isExpanded: Boolean, onToggle: () -> Unit) {
    val progress by animateFloatAsState(section.progress.toFloat(), label = "street-progress")
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(RadiusControl))
            .clickable(onClick = onToggle)
            .padding(horizontal = 10.dp, vertical = 8.dp)
            .clearAndSetSemantics {
                contentDescription = section.title
                stateDescription = "${section.houseCount} ${if (section.houseCount == 1) "Haus" else "Häuser"}, " +
                    "${section.completedCount} von " +
                    "${section.unitCount} Türen erledigt, " + if (isExpanded) "ausgeklappt" else "eingeklappt"
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Icon(
            Icons.Default.HomeWork,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp)
        )
        Column(Modifier.weight(1f)) {
            Text(section.title, style = MaterialTheme.typography.titleMedium)
            Text(
                "${section.houseCount} ${if (section.houseCount == 1) "Haus" else "Häuser"} · ${section.openCount} offen",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Box(
            Modifier
                .width(46.dp)
                .height(6.dp)
                .background(MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(3.dp))
        ) {
            Box(
                Modifier
                    .fillMaxWidth(progress.coerceIn(0f, 1f))
                    .height(6.dp)
                    .background(
                        if (section.openCount == 0) Color(0xFF2E9E5B) else MaterialTheme.colorScheme.primary,
                        RoundedCornerShape(3.dp)
                    )
            )
        }
        Icon(
            if (isExpanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp)
        )
    }
}

@Composable
private fun HouseRowItem(row: HouseRow, onClick: () -> Unit, onQuickStatus: (VisitOutcome) -> Unit) {
    var showQuick by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(RadiusRow))
                .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(RadiusRow))
                .combinedClickableCompat(onClick = onClick, onLongClick = { showQuick = true })
                .padding(14.dp)
                .heightIn(min = MinTouchTarget),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            OutcomeGlyph(row.markerOutcome, size = 22.dp)
            Column(Modifier.weight(1f)) {
                Text(row.address, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    row.subtitleText(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                if (row.note.isNotBlank()) {
                    Text(
                        row.note,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                if (!row.isSingleDoor) {
                    Text(
                        "${row.completedCount}/${row.unitCount}",
                        style = MaterialTheme.typography.titleMedium
                    )
                }
                row.formattedDistance?.let { distance ->
                    Text(
                        distance,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
        // Long-press quick status, the Android-native equivalent of the iOS
        // swipe action: a swipe on a row inside a vertically scrolling list is
        // far less discoverable here, and the legend documents both.
        DropdownMenu(expanded = showQuick, onDismissRequest = { showQuick = false }) {
            VisitOutcome.entries.forEach { outcome ->
                DropdownMenuItem(
                    text = { Text(outcome.germanTitle) },
                    leadingIcon = {
                        Icon(outcome.icon, contentDescription = null, tint = outcome.tint, modifier = Modifier.size(18.dp))
                    },
                    onClick = { onQuickStatus(outcome); showQuick = false }
                )
            }
        }
    }
}

private fun HouseRow.subtitleText(): String {
    val base =
        if (isSingleDoor) (markerOutcome?.germanTitle ?: "Noch kein Status")
        else "$completedCount/$unitCount Türen · $openCount offen"
    val time = recordedAt?.let {
        SimpleDateFormat("HH:mm", Locale.GERMAN).format(Date(it))
    } ?: return base
    return "$base · $time"
}

@Composable
private fun EmptyState(filter: ListFilter, query: String) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            Icons.AutoMirrored.Filled.List,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(38.dp)
        )
        Spacer(Modifier.height(10.dp))
        Text(
            if (query.isBlank()) filter.emptyTitle else "Nichts gefunden",
            style = MaterialTheme.typography.titleMedium
        )
        Spacer(Modifier.height(4.dp))
        Text(
            if (query.isBlank()) filter.emptyMessage else "Kein Haus passt zu „$query“.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}
