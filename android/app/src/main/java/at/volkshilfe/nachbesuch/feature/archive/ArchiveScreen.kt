package at.volkshilfe.nachbesuch.feature.archive

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.stats.TerritorySummary
import at.volkshilfe.nachbesuch.ui.components.BalanceSection
import at.volkshilfe.nachbesuch.ui.components.FilterBar
import at.volkshilfe.nachbesuch.ui.components.FilterChipSpec
import at.volkshilfe.nachbesuch.ui.components.MinTouchTarget
import at.volkshilfe.nachbesuch.ui.status.icon
import at.volkshilfe.nachbesuch.ui.status.tint
import at.volkshilfe.nachbesuch.ui.theme.RadiusCard
import at.volkshilfe.nachbesuch.ui.theme.RadiusControl
import kotlin.math.roundToInt

/**
 * The archive, rebuilt to match the iOS `ArchiveScreen`.
 *
 * What it gained over the old `ArchiveSurface`: the active territory's balance
 * at the top, day grouping ("Heute"/"Gestern"/weekday), scored search through
 * `ArchiveSearchEngine`, filters, an edit action per territory, and a real
 * export menu instead of a row of bare text buttons.
 */
@Composable
fun ArchiveScreen(
    state: ArchiveScreenState,
    contentPadding: PaddingValues = PaddingValues(0.dp)
) {
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(horizontal = 16.dp)) {
            Spacer(Modifier.height(contentPadding.calculateTopPadding() + 8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Archiv", style = MaterialTheme.typography.headlineLarge, modifier = Modifier.weight(1f))
                ArchiveMenu(state)
            }
            Spacer(Modifier.height(10.dp))
            ArchiveSearchField(state.query, state.onQuery)
            Spacer(Modifier.height(10.dp))
            FilterBar(
                chips = state.chips,
                contextLabel = "Archivfilter",
                onSelect = { state.onFilter(ArchiveFilter.from(it)) }
            )
            Spacer(Modifier.height(10.dp))
        }

        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                bottom = 24.dp + contentPadding.calculateBottomPadding()
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            state.activeSummary?.let { active ->
                item(key = "balance") {
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(RadiusCard))
                            .border(
                                0.5.dp,
                                MaterialTheme.colorScheme.outlineVariant,
                                RoundedCornerShape(RadiusCard)
                            )
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            "Bilanz · ${active.territory.displayName}",
                            style = MaterialTheme.typography.titleMedium
                        )
                        if (active.territory.isTwoDay) {
                            ScopeSegments(state.scope, state.onScope)
                        }
                        BalanceSection(
                            tally = when (state.scope) {
                                DayScope.COMBINED -> active.bilanz.overall
                                DayScope.DAY_1 -> active.bilanz.day1
                                DayScope.DAY_2 -> active.bilanz.day2
                            },
                            snapshot = active.bilanz,
                            isTwoDay = active.territory.isTwoDay
                        )
                    }
                }
            }

            if (state.sections.isEmpty()) {
                item(key = "empty") { ArchiveEmptyState(state.query) }
            }

            state.sections.forEach { section ->
                item(key = section.id) {
                    Text(
                        section.title,
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 4.dp, top = 6.dp)
                    )
                }
                items(section.items, key = { "${section.id}-${it.territory.id}" }) { summary ->
                    TerritoryCard(
                        summary = summary,
                        isActive = summary.territory.id == state.activeID,
                        onSelect = { state.onSelect(summary.territory.id) },
                        onEdit = { state.onEdit(summary.territory.id) },
                        onDelete = { state.onDelete(summary.territory.id) }
                    )
                }
            }
        }
    }
}

@Composable
private fun ArchiveMenu(state: ArchiveScreenState) {
    var expanded by remember { mutableStateOf(false) }
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(MinTouchTarget)
                .clip(RoundedCornerShape(22.dp))
                .clickable(onClick = state.onCreate),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Default.Add, contentDescription = "Gebiet anlegen", tint = MaterialTheme.colorScheme.primary)
        }
        Box {
            Box(
                Modifier
                    .size(MinTouchTarget)
                    .clip(RoundedCornerShape(22.dp))
                    .clickable { expanded = true },
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.MoreVert, contentDescription = "Weitere Aktionen")
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                DropdownMenuItem(
                    text = { Text("Einstellungen") },
                    leadingIcon = { Icon(Icons.Default.Settings, contentDescription = null) },
                    onClick = { state.onSettings(); expanded = false }
                )
                DropdownMenuItem(
                    text = { Text("Exportieren …") },
                    leadingIcon = { Icon(Icons.Default.Archive, contentDescription = null) },
                    onClick = { state.onExport(); expanded = false }
                )
            }
        }
    }
}

@Composable
private fun ArchiveSearchField(query: String, onQuery: (String) -> Unit) {
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
                    modifier = Modifier.size(MinTouchTarget).clickable { onQuery("") }.padding(14.dp)
                )
            }
        },
        placeholder = { Text("Gebiet, Ort, „offen“, „heute“ …") },
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
private fun ScopeSegments(scope: DayScope, onScope: (DayScope) -> Unit) {
    val options = listOf(DayScope.COMBINED to "Gesamt", DayScope.DAY_1 to "Tag 1", DayScope.DAY_2 to "Tag 2")
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

@Composable
private fun TerritoryCard(
    summary: TerritorySummary,
    isActive: Boolean,
    onSelect: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit
) {
    var menuOpen by remember { mutableStateOf(false) }
    val tally = summary.bilanz.overall
    val progress by animateFloatAsState(tally.completionFraction.toFloat(), label = "territory-progress")
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(RadiusCard))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(RadiusCard))
            .border(
                width = if (isActive) 1.5.dp else 0.5.dp,
                color = if (isActive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
                shape = RoundedCornerShape(RadiusCard)
            )
            .clickable(onClick = onSelect)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (isActive) {
                        Icon(
                            Icons.Default.CheckCircle,
                            contentDescription = "Aktives Gebiet",
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                    Text(
                        summary.territory.displayName,
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Text(
                    buildString {
                        append(summary.territory.formattedDateRange())
                        if (summary.territory.districtOrCity.isNotBlank()) {
                            append(" · ").append(summary.territory.districtOrCity)
                        }
                        append(" · ").append(summary.houseCount)
                        append(if (summary.houseCount == 1) " Haus" else " Häuser")
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Box {
                Box(
                    Modifier
                        .size(MinTouchTarget)
                        .clip(RoundedCornerShape(22.dp))
                        .clickable { menuOpen = true },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Default.MoreVert, contentDescription = "Gebiet bearbeiten oder löschen")
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("Bearbeiten") },
                        leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) },
                        onClick = { onEdit(); menuOpen = false }
                    )
                    DropdownMenuItem(
                        text = { Text("Löschen") },
                        leadingIcon = { Icon(Icons.Default.Clear, contentDescription = null) },
                        onClick = { onDelete(); menuOpen = false }
                    )
                }
            }
        }

        Row(
            Modifier.fillMaxWidth().clearAndSetSemantics {
                contentDescription = "Fortschritt"
                stateDescription = "${tally.completed} von ${tally.unitCount} Türen erledigt"
            },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(
                Modifier
                    .weight(1f)
                    .height(6.dp)
                    .background(MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(3.dp))
            ) {
                Box(
                    Modifier
                        .fillMaxWidth(progress.coerceIn(0f, 1f))
                        .height(6.dp)
                        .background(
                            if (tally.open == 0 && tally.unitCount > 0) Color(0xFF2E9E5B)
                            else MaterialTheme.colorScheme.primary,
                            RoundedCornerShape(3.dp)
                        )
                )
            }
            Text(
                "${(tally.completionFraction * 100).roundToInt()} %",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatLabel(VisitOutcome.NOT_HOME, tally.notHome)
            StatLabel(VisitOutcome.JOINED, tally.joined)
            StatLabel(VisitOutcome.EARLY_NO, tally.earlyNo)
            StatLabel(VisitOutcome.LATE_NO, tally.lateNo)
        }
    }
}

@Composable
private fun StatLabel(outcome: VisitOutcome, value: Int) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier.clearAndSetSemantics {
            contentDescription = outcome.germanTitle
            stateDescription = value.toString()
        }
    ) {
        Icon(outcome.icon, contentDescription = null, tint = outcome.tint, modifier = Modifier.size(14.dp))
        Text("$value", style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun ArchiveEmptyState(query: String) {
    Column(
        Modifier.fillMaxWidth().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            Icons.Default.Archive,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(36.dp)
        )
        Spacer(Modifier.height(10.dp))
        Text(
            if (query.isBlank()) "Noch keine Gebiete" else "Nichts gefunden",
            style = MaterialTheme.typography.titleMedium
        )
        Spacer(Modifier.height(4.dp))
        Text(
            if (query.isBlank()) "Lege ein Gebiet an, um loszulegen."
            else "Kein Gebiet passt zu „$query“.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}
