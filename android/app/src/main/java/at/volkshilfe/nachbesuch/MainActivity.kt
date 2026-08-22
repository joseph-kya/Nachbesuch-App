package at.volkshilfe.nachbesuch

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import at.volkshilfe.nachbesuch.domain.list.ListFilter
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.feature.archive.ArchiveFilter
import at.volkshilfe.nachbesuch.feature.archive.ArchiveScreen
import at.volkshilfe.nachbesuch.feature.archive.ArchiveScreenState
import at.volkshilfe.nachbesuch.feature.archive.GebietEditorSheet
import at.volkshilfe.nachbesuch.feature.list.ListScreen
import at.volkshilfe.nachbesuch.feature.list.ListScreenState
import at.volkshilfe.nachbesuch.feature.shared.ExportFormat
import at.volkshilfe.nachbesuch.feature.shared.ExportSheet
import at.volkshilfe.nachbesuch.feature.shared.HouseDetailSheet
import at.volkshilfe.nachbesuch.ui.RootScaffold
import at.volkshilfe.nachbesuch.ui.components.AppearanceSettingsSheet
import at.volkshilfe.nachbesuch.ui.components.FilterChipSpec
import at.volkshilfe.nachbesuch.ui.components.NoticeBanner
import at.volkshilfe.nachbesuch.ui.components.StatusLegendSheet
import at.volkshilfe.nachbesuch.ui.components.UndoBanner
import at.volkshilfe.nachbesuch.ui.status.tint
import at.volkshilfe.nachbesuch.ui.theme.NachbesuchTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Which modal is currently on screen. Exactly one, so they cannot stack. */
private sealed interface AppSheet {
    data class House(val id: String) : AppSheet
    data class EditGebiet(val id: String?) : AppSheet
    data object Export : AppSheet
    data object Settings : AppSheet
    data object Legend : AppSheet
}

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<AppViewModel>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val appearance by viewModel.appearance.collectAsStateWithLifecycleCompat()
            val accent by viewModel.accent.collectAsStateWithLifecycleCompat()
            NachbesuchTheme(appearance = appearance, accent = accent) {
                AppContent()
            }
        }
    }

    @Composable
    private fun AppContent() {
        val context = LocalContext.current
        var sheet by remember { mutableStateOf<AppSheet?>(null) }
        var addCoordinate by remember { mutableStateOf<StoredCoordinate?>(null) }
        var locationDenied by remember { mutableStateOf(false) }
        var pendingExport by remember { mutableStateOf<ExportFormat?>(null) }

        val houses by viewModel.houses.collectAsStateWithLifecycleCompat()
        val activeGebiet by viewModel.activeGebiet.collectAsStateWithLifecycleCompat()
        val scope by viewModel.scope.collectAsStateWithLifecycleCompat()
        val notice by viewModel.notices.current.collectAsStateWithLifecycleCompat()
        val undo by viewModel.undo.collectAsStateWithLifecycleCompat()

        // One shared position source for the whole app; the list needs it for
        // "nearest first" and the map for the location puck.
        DisposableEffect(Unit) {
            viewModel.location.start()
            onDispose { viewModel.location.stop() }
        }

        val locationLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.RequestMultiplePermissions()
        ) { grants ->
            locationDenied = grants.values.none { it }
            if (!locationDenied) viewModel.location.start()
        }
        LaunchedEffect(Unit) {
            if (!viewModel.location.hasPermission) {
                locationLauncher.launch(
                    arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                )
            }
        }

        val importLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.OpenDocument()
        ) { uri -> if (uri != null) importBackup(uri) }

        val exportLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.CreateDocument("application/octet-stream")
        ) { uri ->
            val format = pendingExport
            pendingExport = null
            if (uri != null && format != null) writeExport(format, uri)
        }

        RootScaffold(
            map = { padding ->
                MapSurface(
                    houses = houses,
                    gebiet = activeGebiet,
                    boundary = activeGebiet?.boundary.orEmpty(),
                    scope = scope,
                    onScopeChanged = viewModel::selectScope,
                    onHouseSelected = { sheet = AppSheet.House(it.id) },
                    onMapLongPress = { addCoordinate = it },
                    onBoundaryChanged = viewModel::updateBoundary,
                    onDeleteHouses = viewModel::deleteHouses,
                    onImportHouses = viewModel::addImportedHouses,
                    locationFlow = viewModel.location.location,
                    contentPadding = padding
                )
            },
            list = { padding ->
                ListTab(
                    contentPadding = padding,
                    onHouse = { sheet = AppSheet.House(it) },
                    onLegend = { sheet = AppSheet.Legend }
                )
            },
            archive = { padding ->
                ArchiveTab(
                    contentPadding = padding,
                    onEdit = { sheet = AppSheet.EditGebiet(it) },
                    onCreate = { sheet = AppSheet.EditGebiet(null) },
                    onExport = { sheet = AppSheet.Export },
                    onSettings = { sheet = AppSheet.Settings }
                )
            },
            topOverlay = { NoticeBanner(notice, onDismiss = viewModel.notices::dismiss) },
            bottomOverlay = { UndoBanner(undo?.label, onUndo = viewModel::performUndo) }
        )

        when (val current = sheet) {
            is AppSheet.House -> {
                val house = houses.firstOrNull { it.id == current.id }
                if (house == null) {
                    // The house was deleted underneath the sheet.
                    LaunchedEffect(current.id) { sheet = null }
                } else {
                    HouseDetailSheet(
                        house = house,
                        scope = scope,
                        writeScope = activeGebiet?.writeScope() ?: DayScope.DAY_1,
                        onScopeChange = viewModel::selectScope,
                        onOutcome = { unitID, outcome -> viewModel.recordOutcome(house.id, unitID, outcome) },
                        onRenameUnit = { unitID, label -> viewModel.renameUnit(house.id, unitID, label) },
                        onAllOpenNotHome = { viewModel.allOpenNotHome(house.id) },
                        onResize = { viewModel.makeApartment(house.id, it) },
                        onAddressChange = { viewModel.updateAddress(house.id, it) },
                        onNoteChange = { viewModel.updateNote(house.id, it) },
                        onWalkRoute = { openWalkingRoute(house.latitude, house.longitude, house.address) },
                        onCopyAddress = { copyToClipboard(context, house.address) },
                        onDelete = { viewModel.deleteHouse(house.id); sheet = null },
                        onDismiss = { sheet = null }
                    )
                }
            }

            is AppSheet.EditGebiet -> {
                val gebiete by viewModel.gebiete.collectAsStateWithLifecycleCompat()
                GebietEditorSheet(
                    existing = current.id?.let { id -> gebiete.firstOrNull { it.id == id } },
                    onSave = { draft -> viewModel.saveGebiet(current.id, draft); sheet = null },
                    onDismiss = { sheet = null }
                )
            }

            AppSheet.Export -> {
                val options by viewModel.exportOptions.collectAsStateWithLifecycleCompat()
                ExportSheet(
                    options = options,
                    isTwoDay = activeGebiet?.isTwoDay == true,
                    houseCount = houses.size,
                    onOptions = viewModel::setExportOptions,
                    onExport = { format ->
                        sheet = null
                        pendingExport = format
                        exportLauncher.launch(
                            when (format) {
                                ExportFormat.TEXT -> "nachbesuche.txt"
                                ExportFormat.PDF -> "nachbesuche.pdf"
                                ExportFormat.JSON -> "nachbesuch-backup.json"
                            }
                        )
                    },
                    onImport = {
                        sheet = null
                        importLauncher.launch(
                            arrayOf("application/json", "text/*", "application/octet-stream")
                        )
                    },
                    onDismiss = { sheet = null }
                )
            }

            AppSheet.Settings -> {
                val appearance by viewModel.appearance.collectAsStateWithLifecycleCompat()
                val accent by viewModel.accent.collectAsStateWithLifecycleCompat()
                AppearanceSettingsSheet(
                    appearance = appearance,
                    accent = accent,
                    onAppearance = viewModel::setAppearance,
                    onAccent = viewModel::setAccent,
                    onDismiss = { sheet = null }
                )
            }

            AppSheet.Legend -> StatusLegendSheet(onDismiss = { sheet = null })
            null -> Unit
        }

        addCoordinate?.let { coordinate ->
            AddHouseDialog(
                coordinate = coordinate,
                onAdd = { address, value -> viewModel.addHouse(address, value); addCoordinate = null },
                onDismiss = { addCoordinate = null }
            )
        }

        if (locationDenied) {
            AlertDialog(
                onDismissRequest = { locationDenied = false },
                title = { Text("Standortzugriff ist deaktiviert") },
                text = {
                    Text(
                        "Du kannst die Karte weiterhin verwenden. Für deinen Standort, die Sortierung " +
                            "nach Entfernung und die empfohlene Route kannst du den Zugriff später erlauben."
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        locationDenied = false
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName"))
                        )
                    }) { Text("Einstellungen") }
                },
                dismissButton = { TextButton(onClick = { locationDenied = false }) { Text("Später") } }
            )
        }
    }

    @Composable
    private fun ListTab(
        contentPadding: androidx.compose.foundation.layout.PaddingValues,
        onHouse: (String) -> Unit,
        onLegend: () -> Unit
    ) {
        val sections by viewModel.listSections.collectAsStateWithLifecycleCompat()
        val counts by viewModel.filterCounts.collectAsStateWithLifecycleCompat()
        val filter by viewModel.listFilter.collectAsStateWithLifecycleCompat()
        val sort by viewModel.listSort.collectAsStateWithLifecycleCompat()
        val query by viewModel.query.collectAsStateWithLifecycleCompat()
        val scope by viewModel.scope.collectAsStateWithLifecycleCompat()
        val collapsed by viewModel.collapsedSections.collectAsStateWithLifecycleCompat()
        val gebiet by viewModel.activeGebiet.collectAsStateWithLifecycleCompat()
        val fix by viewModel.location.location.collectAsStateWithLifecycleCompat()

        ListScreen(
            state = ListScreenState(
                territoryName = gebiet?.displayName ?: "Kein Gebiet",
                isTwoDay = gebiet?.isTwoDay == true,
                scope = scope,
                query = query,
                filter = filter,
                sort = sort,
                canSortByDistance = fix != null,
                sections = sections,
                chips = ListFilter.entries.map { value ->
                    FilterChipSpec(
                        id = value.id,
                        title = value.title,
                        icon = when (value) {
                            ListFilter.ALL -> Icons.AutoMirrored.Filled.List
                            ListFilter.OPEN -> Icons.Default.Refresh
                            ListFilter.UNANSWERED -> Icons.Default.HelpOutline
                            ListFilter.JOINED -> Icons.Default.Favorite
                        },
                        tint = when (value) {
                            ListFilter.ALL -> MaterialTheme.colorScheme.primary
                            ListFilter.OPEN -> VisitOutcome.NOT_HOME.tint
                            ListFilter.UNANSWERED -> VisitOutcome.EARLY_NO.tint
                            ListFilter.JOINED -> VisitOutcome.JOINED.tint
                        },
                        count = counts[value],
                        isSelected = filter == value
                    )
                },
                collapsedSections = collapsed,
                onQuery = viewModel::setQuery,
                onFilter = viewModel::setListFilter,
                onScope = viewModel::selectScope,
                onSort = viewModel::setListSort,
                onToggleSection = viewModel::toggleSection
            ),
            onHouseSelected = onHouse,
            onQuickStatus = { row, outcome -> viewModel.quickStatus(row.id, outcome) },
            onShowLegend = onLegend,
            contentPadding = contentPadding
        )
    }

    @Composable
    private fun ArchiveTab(
        contentPadding: androidx.compose.foundation.layout.PaddingValues,
        onEdit: (String) -> Unit,
        onCreate: () -> Unit,
        onExport: () -> Unit,
        onSettings: () -> Unit
    ) {
        val sections by viewModel.archiveSections.collectAsStateWithLifecycleCompat()
        val filter by viewModel.archiveFilter.collectAsStateWithLifecycleCompat()
        val query by viewModel.query.collectAsStateWithLifecycleCompat()
        val scope by viewModel.scope.collectAsStateWithLifecycleCompat()
        val activeID by viewModel.activeGebietID.collectAsStateWithLifecycleCompat()
        val activeSummary by viewModel.activeSummary.collectAsStateWithLifecycleCompat()
        val gebiete by viewModel.gebiete.collectAsStateWithLifecycleCompat()
        val openCount by viewModel.archiveOpenCount.collectAsStateWithLifecycleCompat()

        ArchiveScreen(
            state = ArchiveScreenState(
                query = query,
                filter = filter,
                scope = scope,
                activeID = activeID,
                activeSummary = activeSummary,
                sections = sections,
                chips = ArchiveFilter.entries.map { value ->
                    FilterChipSpec(
                        id = value.id,
                        title = value.title,
                        icon = if (value == ArchiveFilter.ALL) Icons.Default.Archive else Icons.Default.Refresh,
                        tint = if (value == ArchiveFilter.ALL) MaterialTheme.colorScheme.primary
                        else VisitOutcome.NOT_HOME.tint,
                        count = if (value == ArchiveFilter.ALL) gebiete.size else openCount,
                        isSelected = filter == value
                    )
                },
                onQuery = viewModel::setQuery,
                onFilter = viewModel::setArchiveFilter,
                onScope = viewModel::selectScope,
                onSelect = { viewModel.selectGebiet(it) },
                onEdit = onEdit,
                onDelete = viewModel::deleteGebiet,
                onCreate = onCreate,
                onExport = onExport,
                onSettings = onSettings
            ),
            contentPadding = contentPadding
        )
    }

    // MARK: Side effects

    private fun importBackup(uri: Uri) {
        lifecycleScope.launch {
            runCatching {
                val raw = withContext(Dispatchers.IO) {
                    contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                } ?: error("Die Datei konnte nicht gelesen werden.")
                viewModel.importBackup(raw)
            }.onSuccess { result ->
                viewModel.notices.show(
                    "${result.insertedGebiete} Gebiete und ${result.insertedHouses} Häuser übernommen" +
                        if (result.skippedHouses > 0) ", ${result.skippedHouses} übersprungen." else "."
                )
            }.onFailure {
                viewModel.notices.report(it, "Backup konnte nicht eingelesen werden")
            }
        }
    }

    private fun writeExport(format: ExportFormat, uri: Uri) {
        lifecycleScope.launch {
            runCatching {
                val bytes = withContext(Dispatchers.IO) {
                    when (format) {
                        ExportFormat.JSON -> viewModel.exportBackupJson().toByteArray()
                        ExportFormat.TEXT -> viewModel.exportCurrentText().toByteArray()
                        ExportFormat.PDF -> {
                            val scratch = File(cacheDir, "nachbesuche-export.pdf")
                            viewModel.exportCurrentPdf(scratch)
                            scratch.readBytes().also { scratch.delete() }
                        }
                    }
                }
                withContext(Dispatchers.IO) {
                    contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                        ?: error("Das Ziel konnte nicht beschrieben werden.")
                }
            }.onSuccess {
                viewModel.notices.show("Export gespeichert.")
            }.onFailure {
                viewModel.notices.report(it, "Export fehlgeschlagen")
            }
        }
    }

    private fun openWalkingRoute(latitude: Double, longitude: Double, label: String) {
        val uri = Uri.parse("google.navigation:q=$latitude,$longitude&mode=w")
        val intent = Intent(Intent.ACTION_VIEW, uri).setPackage("com.google.android.apps.maps")
        // Falls back to whatever maps app is installed rather than crashing when
        // Google Maps is absent, which is common on de-Googled devices.
        val fallback = Intent(Intent.ACTION_VIEW, Uri.parse("geo:$latitude,$longitude?q=$latitude,$longitude($label)"))
        runCatching { startActivity(intent) }
            .recoverCatching { startActivity(fallback) }
            .onFailure { viewModel.notices.reportMessage("Keine Karten-App gefunden.") }
    }

    private fun copyToClipboard(context: Context, value: String) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        clipboard?.setPrimaryClip(ClipData.newPlainText("Adresse", value))
        viewModel.notices.show("Adresse kopiert.")
    }
}
