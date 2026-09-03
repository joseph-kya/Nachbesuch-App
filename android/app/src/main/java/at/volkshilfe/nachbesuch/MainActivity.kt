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
import at.volkshilfe.nachbesuch.feature.shared.StackedPinsSheet
import at.volkshilfe.nachbesuch.reminder.ReminderScheduler
import at.volkshilfe.nachbesuch.ui.RootScaffold
import at.volkshilfe.nachbesuch.ui.components.AppearanceSettingsSheet
import at.volkshilfe.nachbesuch.ui.components.FilterChipSpec
import at.volkshilfe.nachbesuch.ui.components.NoticeBanner
import at.volkshilfe.nachbesuch.ui.components.StatusLegendSheet
import at.volkshilfe.nachbesuch.ui.status.tint
import at.volkshilfe.nachbesuch.ui.theme.NachbesuchTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Which modal is currently on screen. Exactly one, so they cannot stack. */
private sealed interface AppSheet {
    data class House(val id: String) : AppSheet
    data class EditGebiet(val id: String?) : AppSheet
    /** Several pins coincide; the user picks which house they meant. */
    data class StackedPins(val ids: List<String>) : AppSheet
    /** [houseIDs] null exports the whole active territory; a set exports a map selection. */
    data class Export(val houseIDs: Set<String>? = null) : AppSheet
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
        // Format plus the houses it covers, held across the document-picker trip.
        var pendingExport by remember { mutableStateOf<Pair<ExportFormat, Set<String>?>?>(null) }

        val houses by viewModel.houses.collectAsStateWithLifecycleCompat()
        val activeGebiet by viewModel.activeGebiet.collectAsStateWithLifecycleCompat()
        val scope by viewModel.scope.collectAsStateWithLifecycleCompat()
        val notice by viewModel.notices.current.collectAsStateWithLifecycleCompat()

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

        // Notifications carry both the booked "Später" reminders and the standing
        // list prompt, so the ask happens once at startup rather than at the moment
        // a user is mid-way through booking a return time.
        var notificationsAllowed by remember { mutableStateOf(hasNotificationPermission()) }
        val notificationLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.RequestPermission()
        ) { granted -> notificationsAllowed = granted }
        LaunchedEffect(Unit) {
            if (!notificationsAllowed && android.os.Build.VERSION.SDK_INT >= 33) {
                notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        val importLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.OpenDocument()
        ) { uri -> if (uri != null) importBackup(uri) }

        val exportLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.CreateDocument("application/octet-stream")
        ) { uri ->
            val pending = pendingExport
            pendingExport = null
            if (uri != null && pending != null) writeExport(pending.first, pending.second, uri)
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
                    onStackedPins = { ids -> sheet = AppSheet.StackedPins(ids) },
                    onMapLongPress = { addCoordinate = it },
                    onBoundaryChanged = viewModel::updateBoundary,
                    onDeleteHouses = viewModel::deleteHouses,
                    onExportSelection = { ids -> sheet = AppSheet.Export(ids) },
                    onImportHouses = viewModel::addImportedHouses,
                    locationFlow = viewModel.location.location,
                    contentPadding = padding
                )
            },
            list = { padding ->
                ListTab(
                    contentPadding = padding,
                    onHouse = { sheet = AppSheet.House(it) },
                    onLegend = { sheet = AppSheet.Legend },
                    onExport = { sheet = AppSheet.Export() }
                )
            },
            archive = { padding ->
                ArchiveTab(
                    contentPadding = padding,
                    onEdit = { sheet = AppSheet.EditGebiet(it) },
                    onCreate = { sheet = AppSheet.EditGebiet(null) },
                    onExport = { sheet = AppSheet.Export() },
                    onSettings = { sheet = AppSheet.Settings }
                )
            },
            topOverlay = { NoticeBanner(notice, onDismiss = viewModel.notices::dismiss) }
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
                        isTwoDay = activeGebiet?.isTwoDay == true,
                        onScopeChange = viewModel::selectScope,
                        onOutcome = { unitID, outcome -> viewModel.recordOutcome(house.id, unitID, outcome) },
                        onLater = { unitID, atMillis ->
                            viewModel.recordOutcome(house.id, unitID, VisitOutcome.LATER, atMillis)
                        },
                        onRenameUnit = { unitID, label -> viewModel.renameUnit(house.id, unitID, label) },
                        onAllOpenNotHome = { viewModel.allOpenNotHome(house.id) },
                        onAllOpenLater = { atMillis ->
                            viewModel.quickStatus(house.id, VisitOutcome.LATER, atMillis)
                        },
                        onResize = { viewModel.makeApartment(house.id, it) },
                        onAddressChange = { viewModel.updateAddress(house.id, it) },
                        onNoteChange = { viewModel.updateNote(house.id, it) },
                        onCopyAddress = { copyToClipboard(context, house.address) },
                        onDelete = { viewModel.deleteHouse(house.id); sheet = null },
                        onDismiss = { sheet = null }
                    )
                }
            }

            is AppSheet.StackedPins -> {
                // Keep the tapped order: the pin actually under the finger first.
                val stacked = current.ids.mapNotNull { id -> houses.firstOrNull { it.id == id } }
                if (stacked.size < 2) {
                    LaunchedEffect(current) {
                        sheet = stacked.firstOrNull()?.let { AppSheet.House(it.id) }
                    }
                } else {
                    StackedPinsSheet(
                        houses = stacked,
                        scope = scope,
                        onSelect = { id -> sheet = AppSheet.House(id) },
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

            is AppSheet.Export -> {
                val options by viewModel.exportOptions.collectAsStateWithLifecycleCompat()
                ExportSheet(
                    options = options,
                    isTwoDay = activeGebiet?.isTwoDay == true,
                    houseCount = viewModel.exportHouseCount(current.houseIDs),
                    isSelection = current.houseIDs != null,
                    onOptions = viewModel::setExportOptions,
                    onExport = { format ->
                        val ids = current.houseIDs
                        sheet = null
                        pendingExport = format to ids
                        exportLauncher.launch(
                            when (format) {
                                ExportFormat.TEXT -> "nachbesuche.txt"
                                ExportFormat.LEGACY_TEXT -> "nachbesuchsliste.txt"
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
                val dailyReminders by viewModel.dailyListReminders.collectAsStateWithLifecycleCompat()
                AppearanceSettingsSheet(
                    appearance = appearance,
                    accent = accent,
                    dailyListReminders = dailyReminders,
                    reminderHours = ReminderScheduler.DAILY_LIST_HOURS,
                    notificationsAllowed = notificationsAllowed,
                    onAppearance = viewModel::setAppearance,
                    onAccent = viewModel::setAccent,
                    onDailyListReminders = { enabled ->
                        // Switching the reminder on is the one place where asking
                        // again is warranted: the user just said they want it.
                        if (enabled && !notificationsAllowed && android.os.Build.VERSION.SDK_INT >= 33) {
                            notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                        }
                        viewModel.setDailyListReminders(enabled)
                    },
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
                        "Du kannst die Karte weiterhin verwenden. Für deinen Standort und die Sortierung " +
                            "nach Entfernung kannst du den Zugriff später erlauben."
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
        onLegend: () -> Unit,
        onExport: () -> Unit
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
        val undoLabel by viewModel.undo.collectAsStateWithLifecycleCompat()

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
                undoLabel = undoLabel?.label,
                onUndo = viewModel::performUndo,
                canExport = gebiet != null,
                onExport = onExport,
                onQuery = viewModel::setQuery,
                onFilter = viewModel::setListFilter,
                onScope = viewModel::selectScope,
                onSort = viewModel::setListSort,
                onToggleSection = viewModel::toggleSection
            ),
            onHouseSelected = onHouse,
            onQuickStatus = { row, outcome -> viewModel.quickStatus(row.id, outcome) },
            onQuickLater = { row, atMillis ->
                viewModel.quickStatus(row.id, VisitOutcome.LATER, atMillis)
            },
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

    private fun writeExport(format: ExportFormat, houseIDs: Set<String>?, uri: Uri) {
        lifecycleScope.launch {
            runCatching {
                val bytes = withContext(Dispatchers.IO) {
                    when (format) {
                        // A backup is always the whole database, so it ignores any
                        // selection by definition.
                        ExportFormat.JSON -> viewModel.exportBackupJson().toByteArray()
                        ExportFormat.TEXT -> viewModel.exportCurrentText(houseIDs).toByteArray()
                        ExportFormat.LEGACY_TEXT -> viewModel.exportCurrentLegacyText(houseIDs).toByteArray()
                        ExportFormat.PDF -> {
                            val scratch = File(cacheDir, "nachbesuche-export.pdf")
                            viewModel.exportCurrentPdf(scratch, houseIDs)
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

    /**
     * Whether notifications may be posted at all.
     *
     * Below Android 13 there is no runtime permission, but the user can still mute
     * the app in system settings — `areNotificationsEnabled` answers both cases.
     */
    private fun hasNotificationPermission(): Boolean {
        val runtimeGranted = android.os.Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        return runtimeGranted &&
            getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled()
    }

    private fun copyToClipboard(context: Context, value: String) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        clipboard?.setPrimaryClip(ClipData.newPlainText("Adresse", value))
        viewModel.notices.show("Adresse kopiert.")
    }
}
