package at.volkshilfe.nachbesuch

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import at.volkshilfe.nachbesuch.data.backup.BackupImportResult
import at.volkshilfe.nachbesuch.data.backup.BackupService
import at.volkshilfe.nachbesuch.data.export.PdfExporter
import at.volkshilfe.nachbesuch.data.importing.ImportedAreaAddress
import at.volkshilfe.nachbesuch.data.local.AppDatabase
import at.volkshilfe.nachbesuch.data.local.TerritoryRepository
import at.volkshilfe.nachbesuch.data.prefs.AppSettingsStore
import at.volkshilfe.nachbesuch.domain.export.ExportDocumentBuilder
import at.volkshilfe.nachbesuch.domain.export.PlainTextExport
import at.volkshilfe.nachbesuch.domain.list.HouseListBuilder
import at.volkshilfe.nachbesuch.domain.list.HouseRow
import at.volkshilfe.nachbesuch.domain.list.ListFilter
import at.volkshilfe.nachbesuch.domain.list.StreetSection
import at.volkshilfe.nachbesuch.domain.model.CampaignDays
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.DoorResult
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.stats.TerritorySummarizer
import at.volkshilfe.nachbesuch.domain.stats.TerritorySummary
import at.volkshilfe.nachbesuch.domain.archive.ArchiveSearchEngine
import at.volkshilfe.nachbesuch.feature.archive.ArchiveFilter
import at.volkshilfe.nachbesuch.feature.archive.DaySection
import at.volkshilfe.nachbesuch.feature.archive.ArchiveSections
import at.volkshilfe.nachbesuch.feature.archive.GebietDraft
import at.volkshilfe.nachbesuch.feature.list.ListSort
import at.volkshilfe.nachbesuch.feature.shared.ExportOptions
import at.volkshilfe.nachbesuch.location.LocationService
import at.volkshilfe.nachbesuch.ui.notice.NoticeCenter
import at.volkshilfe.nachbesuch.ui.theme.AppAccent
import at.volkshilfe.nachbesuch.ui.theme.AppAppearance
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** One undoable status write. */
data class UndoEntry(val houseID: String, val previousUnits: List<DoorResult>, val label: String)

@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
class AppViewModel(application: Application) : AndroidViewModel(application) {

    private val opened = runCatching {
        AppDatabase.open(application).also { it.openHelper.writableDatabase }
    }
    private val database = opened.getOrElse { AppDatabase.openScratch(application) }
    val storeUnreadable: Boolean = opened.isFailure

    private val repository = TerritoryRepository(database)
    private val backupService = BackupService(database)
    private val settings = AppSettingsStore(application)

    val notices = NoticeCenter(viewModelScope)
    val location = LocationService(application)

    init {
        if (storeUnreadable) {
            notices.reportMessage(
                "Die Datenbank konnte nicht geöffnet werden. Die App läuft mit einem leeren Zwischenspeicher; " +
                    "vorhandene Daten wurden nicht verändert."
            )
        }
    }

    // MARK: Territories and houses

    val gebiete: StateFlow<List<Gebiet>> = repository.observeGebiete()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val _activeGebietID = MutableStateFlow<String?>(null)
    val activeGebietID: StateFlow<String?> = _activeGebietID.asStateFlow()

    val activeGebiet: StateFlow<Gebiet?> = combine(gebiete, _activeGebietID) { values, selectedID ->
        values.firstOrNull { it.id == selectedID } ?: values.firstOrNull()
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val houses: StateFlow<List<House>> = _activeGebietID.flatMapLatest { id ->
        if (id == null) emptyFlow() else repository.observeHouses(id)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val allHouses: StateFlow<List<House>> = repository.observeAllHouses()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val _scope = MutableStateFlow(DayScope.COMBINED)
    val scope: StateFlow<DayScope> = _scope.asStateFlow()

    // MARK: Appearance

    private val _appearance = MutableStateFlow(AppAppearance.SYSTEM)
    val appearance: StateFlow<AppAppearance> = _appearance.asStateFlow()

    private val _accent = MutableStateFlow(AppAccent.VOLKSHILFE)
    val accent: StateFlow<AppAccent> = _accent.asStateFlow()

    // MARK: List view state

    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    /**
     * Typing must not re-filter and re-group the whole corpus on every keystroke;
     * on a 1,500-house territory that was visible as input lag.
     */
    private val debouncedQuery: StateFlow<String> = _query
        .debounce(SEARCH_DEBOUNCE_MS)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), "")

    private val _listFilter = MutableStateFlow(ListFilter.ALL)
    val listFilter: StateFlow<ListFilter> = _listFilter.asStateFlow()

    private val _listSort = MutableStateFlow(ListSort.SMART)
    val listSort: StateFlow<ListSort> = _listSort.asStateFlow()

    private val _collapsedSections = MutableStateFlow<Set<String>>(emptySet())
    val collapsedSections: StateFlow<Set<String>> = _collapsedSections.asStateFlow()

    private val _undo = MutableStateFlow<UndoEntry?>(null)
    val undo: StateFlow<UndoEntry?> = _undo.asStateFlow()
    private var undoJob: Job? = null

    /**
     * Shows the undo affordance for a few seconds, then drops it.
     *
     * It used to have no expiry at all, so a single quick status left a banner
     * sitting over the list until it was tapped. iOS gives it five seconds and
     * then forgets: undo is a rescue for the tap you just made, not a permanent
     * strip of chrome.
     */
    private fun offerUndo(entry: UndoEntry) {
        undoJob?.cancel()
        _undo.value = entry
        undoJob = viewModelScope.launch {
            delay(UNDO_TIMEOUT_MS)
            _undo.value = null
        }
    }

    /** The unfiltered corpus for the active territory, rebuilt off the main thread. */
    private val corpus: StateFlow<List<HouseRow>> = combine(houses, _scope) { values, scope ->
        withContext(Dispatchers.Default) { HouseListBuilder.rows(values, scope) }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val filterCounts: StateFlow<Map<ListFilter, Int>> = corpus
        .map { rows -> withContext(Dispatchers.Default) { HouseListBuilder.counts(rows) } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    val listSections: StateFlow<List<StreetSection>> = combine(
        corpus, debouncedQuery, _listFilter, _listSort, location.location
    ) { rows, query, filter, sort, fix ->
        withContext(Dispatchers.Default) {
            val matched = HouseListBuilder.filter(rows, filter, query)
            val ordered = when {
                sort == ListSort.DISTANCE && fix != null ->
                    HouseListBuilder.sortByDistance(matched, fix.latitude, fix.longitude)
                else -> HouseListBuilder.sort(matched)
            }
            HouseListBuilder.sections(ordered)
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    // MARK: Archive view state

    private val _archiveFilter = MutableStateFlow(ArchiveFilter.ALL)
    val archiveFilter: StateFlow<ArchiveFilter> = _archiveFilter.asStateFlow()

    private val summaries: StateFlow<List<TerritorySummary>> = combine(gebiete, allHouses) { values, houses ->
        withContext(Dispatchers.Default) { TerritorySummarizer.summarize(values, houses) }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val activeSummary: StateFlow<TerritorySummary?> = combine(summaries, activeGebiet) { values, active ->
        values.firstOrNull { it.territory.id == active?.id }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val archiveSections: StateFlow<List<DaySection>> = combine(
        summaries, debouncedQuery, _archiveFilter
    ) { values, query, filter ->
        withContext(Dispatchers.Default) {
            val matched = values.filter(filter::matches)
            val results = if (query.isBlank()) matched else ArchiveSearchEngine.search(query, matched)
            ArchiveSections.sections(results, isSearching = query.isNotBlank())
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val archiveOpenCount: StateFlow<Int> = summaries
        .map { values -> values.count { it.bilanz.overall.open > 0 } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), 0)

    // MARK: Export options

    private val _exportOptions = MutableStateFlow(
        ExportOptions(scope = DayScope.COMBINED, visitedOnly = true, includeNotes = true)
    )
    val exportOptions: StateFlow<ExportOptions> = _exportOptions.asStateFlow()

    init {
        viewModelScope.launch {
            val stored = runCatching { settings.restore() }.getOrNull()
            if (stored != null) {
                _appearance.value = AppAppearance.from(stored.appearance)
                _accent.value = AppAccent.from(stored.accent)
                _exportOptions.value = _exportOptions.value.copy(
                    visitedOnly = stored.exportVisitedOnly,
                    includeNotes = stored.exportIncludeNotes
                )
                // Restore before the first territory list arrives, so the persisted
                // choice wins over "whichever territory sorted first".
                stored.selectedGebietID?.let { _activeGebietID.value = it }
            }
            gebiete.collect { values ->
                val current = _activeGebietID.value
                if (current == null || values.none { it.id == current }) {
                    selectGebiet(values.firstOrNull()?.id, persist = current != null)
                }
            }
        }
    }

    // MARK: Selection

    fun selectGebiet(id: String?, persist: Boolean = true) {
        _activeGebietID.value = id
        // A two-day picker left on Tag 2 would be unreachable in a one-day
        // territory, and every status tap would write to a day that does not exist.
        if (gebiete.value.firstOrNull { it.id == id }?.isTwoDay != true && _scope.value == DayScope.DAY_2) {
            _scope.value = DayScope.COMBINED
        }
        if (persist) viewModelScope.launch { runCatching { settings.recordSelectedGebiet(id) } }
    }

    fun selectScope(value: DayScope) { _scope.value = value }
    fun setQuery(value: String) { _query.value = value }
    fun setListFilter(value: ListFilter) { _listFilter.value = value }
    fun setListSort(value: ListSort) { _listSort.value = value }
    fun setArchiveFilter(value: ArchiveFilter) { _archiveFilter.value = value }

    fun toggleSection(id: String) {
        _collapsedSections.value =
            if (id in _collapsedSections.value) _collapsedSections.value - id
            else _collapsedSections.value + id
    }

    fun setAppearance(value: AppAppearance) {
        _appearance.value = value
        viewModelScope.launch {
            runCatching { settings.recordAppearance(value.storageValue, _accent.value.storageValue) }
                .onFailure { notices.report(it, "Einstellung konnte nicht gespeichert werden") }
        }
    }

    fun setAccent(value: AppAccent) {
        _accent.value = value
        viewModelScope.launch {
            runCatching { settings.recordAppearance(_appearance.value.storageValue, value.storageValue) }
                .onFailure { notices.report(it, "Einstellung konnte nicht gespeichert werden") }
        }
    }

    fun setExportOptions(value: ExportOptions) { _exportOptions.value = value }

    // MARK: Territory writes

    fun saveGebiet(existingID: String?, draft: GebietDraft) {
        val now = System.currentTimeMillis()
        viewModelScope.launch(Dispatchers.IO) {
            runCatching {
                val existing = gebiete.value.firstOrNull { it.id == existingID }
                val gebiet = existing?.copy(
                    name = draft.name,
                    districtOrCity = draft.districtOrCity,
                    notes = draft.notes,
                    isTwoDay = draft.isTwoDay,
                    day1Date = draft.day1Date,
                    day2Date = draft.day2Date
                )?.touch(now) ?: Gebiet(
                    id = UUID.randomUUID().toString().uppercase(),
                    name = draft.name.ifEmpty { "Mein Gebiet" },
                    districtOrCity = draft.districtOrCity,
                    notes = draft.notes,
                    isTwoDay = draft.isTwoDay,
                    day1Date = draft.day1Date,
                    day2Date = draft.day2Date,
                    createdAt = now,
                    updatedAt = now
                )
                repository.save(gebiet)
                gebiet.id
            }.onSuccess { id ->
                if (existingID == null) selectGebiet(id)
            }.onFailure {
                notices.report(it, "Gebiet konnte nicht gespeichert werden")
            }
        }
    }

    fun deleteGebiet(id: String) {
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { repository.deleteGebiet(id) }
                .onSuccess { if (_activeGebietID.value == id) selectGebiet(gebiete.value.firstOrNull { it.id != id }?.id) }
                .onFailure { notices.report(it, "Gebiet konnte nicht gelöscht werden") }
        }
    }

    // MARK: House writes

    fun addHouse(address: String, coordinate: StoredCoordinate, note: String = "") {
        val territoryID = _activeGebietID.value ?: run {
            notices.reportMessage("Kein Gebiet ausgewählt.")
            return
        }
        if (!coordinate.isPlausible || address.trim().isEmpty()) {
            notices.reportMessage("Adresse und Position müssen gültig sein.")
            return
        }
        val now = System.currentTimeMillis()
        val house = House(
            id = UUID.randomUUID().toString().uppercase(), address = address.trim(), note = note.trim(),
            latitude = coordinate.latitude, longitude = coordinate.longitude,
            gebietID = territoryID, dayID = territoryID, createdAt = now, updatedAt = now
        )
        write(house, "Haus konnte nicht gespeichert werden")
    }

    fun addImportedHouses(addresses: List<ImportedAreaAddress>) {
        val territoryID = _activeGebietID.value ?: return
        if (addresses.isEmpty()) return
        val now = System.currentTimeMillis()
        val values = addresses.mapIndexed { index, candidate ->
            House(
                id = UUID.randomUUID().toString().uppercase(),
                address = candidate.address,
                latitude = candidate.coordinate.latitude,
                longitude = candidate.coordinate.longitude,
                gebietID = territoryID, dayID = territoryID,
                createdAt = now + index, updatedAt = now + index
            )
        }
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { repository.saveAll(values) }
                .onSuccess { notices.show("${values.size} Adressen übernommen.") }
                .onFailure { notices.report(it, "Adressen konnten nicht übernommen werden") }
        }
    }

    fun deleteHouse(id: String) {
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { repository.deleteHouse(id) }
                .onFailure { notices.report(it, "Haus konnte nicht gelöscht werden") }
        }
    }

    fun deleteHouses(ids: Set<String>) {
        if (ids.isEmpty()) return
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { ids.forEach { repository.deleteHouse(it) } }
                .onFailure { notices.report(it, "Häuser konnten nicht gelöscht werden") }
        }
    }

    fun updateBoundary(points: List<StoredCoordinate>) {
        val territory = activeGebiet.value ?: return
        val clean = points.filter(StoredCoordinate::isPlausible)
        if (clean.isNotEmpty() && clean.size < 3) return
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { repository.save(territory.copy(boundary = clean).touch()) }
                .onFailure { notices.report(it, "Gebietsgrenze konnte nicht gespeichert werden") }
        }
    }

    /**
     * Records one door result.
     *
     * The visible picker is a filter only. Writes follow the territory calendar,
     * matching the iOS rule and preventing Tag-2 edits from landing in Tag 1.
     */
    fun recordOutcome(houseID: String, unitID: String, outcome: VisitOutcome?) {
        val house = houses.value.firstOrNull { it.id == houseID } ?: return
        val writeScope = activeGebiet.value?.writeScope() ?: DayScope.DAY_1
        val updated = house.recordOutcome(unitID, outcome, writeScope) ?: run {
            if (house.isDamaged) notices.reportMessage("Dieses Haus ist beschädigt und kann nicht geändert werden.")
            return
        }
        // Deliberately no undo here. The sheet shows the choice you just made,
        // with the tapped option marked and one tap to clear it — an undo banner
        // on top of that is a second way to say the same thing. iOS offers undo
        // only where the row moves out from under you: the list's quick status.
        write(updated, "Status konnte nicht gespeichert werden")
    }

    /** Applies one status to every open door of a house — the list's quick action. */
    fun quickStatus(houseID: String, outcome: VisitOutcome) {
        val house = houses.value.firstOrNull { it.id == houseID } ?: return
        val writeScope = activeGebiet.value?.writeScope() ?: DayScope.DAY_1
        val updated = house.setOutcomeForOpenDoors(outcome, writeScope) ?: run {
            if (house.isDamaged) notices.reportMessage("Dieses Haus ist beschädigt und kann nicht geändert werden.")
            return
        }
        // Concrete, so it is clear what is being undone after the list re-sorts
        // and the row has moved.
        offerUndo(UndoEntry(house.id, house.units, "${house.address} → ${outcome.germanTitle}"))
        write(updated, "Status konnte nicht gespeichert werden")
    }

    fun allOpenNotHome(houseID: String) = quickStatus(houseID, VisitOutcome.NOT_HOME)

    fun performUndo() {
        val entry = _undo.value ?: return
        undoJob?.cancel()
        _undo.value = null
        val house = houses.value.firstOrNull { it.id == entry.houseID } ?: return
        write(house.restore(entry.previousUnits), "Rückgängig fehlgeschlagen")
    }

    fun dismissUndo() {
        undoJob?.cancel()
        _undo.value = null
    }

    fun makeApartment(houseID: String, count: Int) {
        val house = houses.value.firstOrNull { it.id == houseID } ?: return
        val updated = house.resizeApartment(count) ?: return
        write(updated, "Anzahl konnte nicht gespeichert werden")
    }

    fun renameUnit(houseID: String, unitID: String, label: String) {
        val house = houses.value.firstOrNull { it.id == houseID } ?: return
        val updated = house.renameUnit(unitID, label) ?: return
        write(updated, "Bezeichnung konnte nicht gespeichert werden")
    }

    fun updateAddress(houseID: String, address: String) {
        val house = houses.value.firstOrNull { it.id == houseID } ?: return
        if (address.isBlank() || address == house.address) return
        write(house.copy(address = address, updatedAt = System.currentTimeMillis()), "Adresse konnte nicht gespeichert werden")
    }

    fun updateNote(houseID: String, note: String) {
        val house = houses.value.firstOrNull { it.id == houseID } ?: return
        if (note == house.note) return
        write(house.copy(note = note, updatedAt = System.currentTimeMillis()), "Notiz konnte nicht gespeichert werden")
    }

    fun updateHouse(house: House) = write(house, "Haus konnte nicht gespeichert werden")

    private fun write(house: House, failureContext: String) {
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { repository.save(house) }
                .onFailure { notices.report(it, failureContext) }
        }
    }

    // MARK: Export

    suspend fun exportBackupJson(): String = backupService.export(gebiete.value, allHouses.value)

    suspend fun importBackup(raw: String): BackupImportResult = backupService.import(raw)

    suspend fun exportCurrentText(): String = withContext(Dispatchers.Default) {
        val territory = activeGebiet.value ?: return@withContext ""
        val options = _exportOptions.value
        PlainTextExport.render(
            ExportDocumentBuilder.build(
                territory, houses.value, options.scope,
                visitedOnly = options.visitedOnly, includeNotes = options.includeNotes
            )
        )
    }

    suspend fun exportCurrentPdf(target: File) = withContext(Dispatchers.Default) {
        val territory = activeGebiet.value ?: return@withContext
        val options = _exportOptions.value
        PdfExporter.write(
            ExportDocumentBuilder.build(
                territory, houses.value, options.scope,
                visitedOnly = options.visitedOnly, includeNotes = options.includeNotes
            ),
            target
        )
    }

    override fun onCleared() {
        database.close()
        super.onCleared()
    }

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 180L
        /** Matches the iOS undo window. */
        const val UNDO_TIMEOUT_MS = 5_000L
    }
}
