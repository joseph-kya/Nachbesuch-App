package at.volkshilfe.nachbesuch

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import at.volkshilfe.nachbesuch.data.local.AppDatabase
import at.volkshilfe.nachbesuch.data.local.TerritoryRepository
import at.volkshilfe.nachbesuch.data.backup.BackupService
import at.volkshilfe.nachbesuch.data.backup.BackupImportResult
import at.volkshilfe.nachbesuch.data.export.PdfExporter
import at.volkshilfe.nachbesuch.data.importing.ImportedAreaAddress
import at.volkshilfe.nachbesuch.domain.stats.TerritorySummarizer
import at.volkshilfe.nachbesuch.domain.stats.TerritorySummary
import at.volkshilfe.nachbesuch.domain.export.ExportDocumentBuilder
import at.volkshilfe.nachbesuch.domain.export.PlainTextExport
import at.volkshilfe.nachbesuch.domain.export.LegacyTextExport
import at.volkshilfe.nachbesuch.domain.model.CampaignDays
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

data class ExportOptions(
    val visitedOnly: Boolean = true,
    val includeNotes: Boolean = true
)

@OptIn(ExperimentalCoroutinesApi::class)
class AppViewModel(application: Application) : AndroidViewModel(application) {
    // Room opens lazily on first query; nothing touches disk on the main thread here.
    private val database = AppDatabase.open(application)
    private val repositoryFlow = MutableStateFlow(TerritoryRepository(database))
    private val backupService = BackupService(database)

    private val _storeUnreadable = MutableStateFlow(false)
    val storeUnreadable: StateFlow<Boolean> = _storeUnreadable.asStateFlow()

    val gebiete: StateFlow<List<Gebiet>> = repositoryFlow.flatMapLatest { it.observeGebiete() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val _activeGebietID = MutableStateFlow<String?>(null)
    val activeGebietID: StateFlow<String?> = _activeGebietID.asStateFlow()

    val activeGebiet: StateFlow<Gebiet?> = combine(gebiete, _activeGebietID) { values, selectedID ->
        values.firstOrNull { it.id == selectedID } ?: values.firstOrNull()
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val houses: StateFlow<List<House>> = combine(repositoryFlow, _activeGebietID) { repository, id -> id?.let { repository.observeHouses(it) } }
        .flatMapLatest { it ?: emptyFlow() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val allHouses: StateFlow<List<House>> = repositoryFlow.flatMapLatest { it.observeAllHouses() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    /** Precomputed per-territory statistics for the archive screen. */
    val summaries: StateFlow<List<TerritorySummary>> = combine(gebiete, allHouses) { values, houses ->
        TerritorySummarizer.summarize(values, houses)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val _scope = MutableStateFlow(DayScope.COMBINED)
    val scope: StateFlow<DayScope> = _scope.asStateFlow()

    init {
        // Fail fast if the real store cannot be opened — but off the main thread,
        // and by swapping to a scratch store instead of crashing at launch.
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { database.openHelper.writableDatabase }.onFailure {
                _storeUnreadable.value = true
                runCatching { database.close() }
                repositoryFlow.value = TerritoryRepository(AppDatabase.openScratch(application))
            }
        }
        viewModelScope.launch {
            gebiete.collect { values ->
                if (_activeGebietID.value == null || values.none { it.id == _activeGebietID.value }) {
                    _activeGebietID.value = values.firstOrNull()?.id
                }
            }
        }
    }

    fun selectGebiet(id: String) { _activeGebietID.value = id }
    fun selectScope(value: DayScope) { _scope.value = value }

    fun createGebiet(name: String, district: String = "", twoDay: Boolean = false) {
        val cleanName = name.trim().ifEmpty { "Mein Gebiet" }
        val now = System.currentTimeMillis()
        val gebied = Gebiet(
            id = UUID.randomUUID().toString().uppercase(), name = cleanName,
            districtOrCity = district.trim(), isTwoDay = twoDay,
            day1Date = CampaignDays.startOfDay(now),
            day2Date = if (twoDay) CampaignDays.addDays(CampaignDays.startOfDay(now), 1) else null,
            createdAt = now, updatedAt = now
        )
        viewModelScope.launch(Dispatchers.IO) {
            repositoryFlow.value.save(gebied)
            _activeGebietID.value = gebied.id
        }
    }

    fun deleteGebiet(id: String) {
        viewModelScope.launch(Dispatchers.IO) {
            repositoryFlow.value.deleteGebiet(id)
            if (_activeGebietID.value == id) _activeGebietID.value = null
        }
    }

    fun addHouse(address: String, coordinate: StoredCoordinate, note: String = "") {
        val territoryID = _activeGebietID.value ?: return
        if (!coordinate.isPlausible || address.trim().isEmpty()) return
        val now = System.currentTimeMillis()
        val house = House(
            id = UUID.randomUUID().toString().uppercase(), address = address.trim(), note = note.trim(),
            latitude = coordinate.latitude, longitude = coordinate.longitude,
            gebietID = territoryID, dayID = territoryID,
            createdAt = now, updatedAt = now
        )
        viewModelScope.launch(Dispatchers.IO) { repositoryFlow.value.save(house) }
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
                gebietID = territoryID,
                dayID = territoryID,
                createdAt = now + index,
                updatedAt = now + index
            )
        }
        viewModelScope.launch(Dispatchers.IO) { repositoryFlow.value.saveAll(values) }
    }

    fun deleteHouse(id: String) {
        viewModelScope.launch(Dispatchers.IO) { repositoryFlow.value.deleteHouse(id) }
    }

    fun deleteHouses(ids: Set<String>) {
        if (ids.isEmpty()) return
        viewModelScope.launch(Dispatchers.IO) {
            ids.forEach { repositoryFlow.value.deleteHouse(it) }
        }
    }

    fun updateBoundary(points: List<StoredCoordinate>) {
        val territory = activeGebiet.value ?: return
        val clean = points.filter(StoredCoordinate::isPlausible)
        if (clean.isNotEmpty() && clean.size < 3) return
        viewModelScope.launch(Dispatchers.IO) {
            repositoryFlow.value.save(territory.copy(boundary = clean).touch())
        }
    }

    fun recordOutcome(houseID: String, unitID: String, outcome: VisitOutcome?, scope: DayScope) {
        mutateHouse(houseID) { house ->
            // The visible picker is a filter only. Writes follow the territory calendar,
            // matching the iOS rule and preventing Tag-2 edits from landing in Tag 1.
            val writeScope = activeGebiet.value?.writeScope() ?: scope
            house.recordOutcome(unitID, outcome, writeScope)
        }
    }

    fun makeApartment(houseID: String, count: Int) {
        mutateHouse(houseID) { it.resizeApartment(count) }
    }

    fun renameUnit(houseID: String, unitID: String, label: String) {
        mutateHouse(houseID) { it.renameUnit(unitID, label) }
    }

    fun fillOpenDoors(houseID: String, outcome: VisitOutcome?, scope: DayScope) {
        mutateHouse(houseID) { house ->
            val writeScope = activeGebiet.value?.writeScope() ?: scope
            house.setOutcomeForOpenDoors(outcome, writeScope)
        }
    }

    private inline fun mutateHouse(houseID: String, crossinline mutation: (House) -> House?) {
        val house = houses.value.firstOrNull { it.id == houseID } ?: return
        mutation(house)?.let { updated ->
            viewModelScope.launch(Dispatchers.IO) { repositoryFlow.value.save(updated) }
        }
    }

    fun updateHouse(house: House) {
        viewModelScope.launch(Dispatchers.IO) { repositoryFlow.value.save(house) }
    }

    suspend fun exportBackupJson(): String = backupService.export(gebiete.value, allHouses.value)

    suspend fun importBackup(raw: String): BackupImportResult = backupService.import(raw)

    suspend fun exportCurrentText(options: ExportOptions): String = withContext(Dispatchers.Default) {
        val territory = activeGebiet.value ?: return@withContext ""
        PlainTextExport.render(ExportDocumentBuilder.build(territory, houses.value, scope.value, options.visitedOnly, options.includeNotes))
    }

    suspend fun exportCurrentLegacyText(): String = withContext(Dispatchers.Default) {
        val territory = activeGebiet.value ?: return@withContext ""
        val document = ExportDocumentBuilder.build(
            territory, houses.value, scope.value, visitedOnly = true, includeNotes = false
        )
        LegacyTextExport.render(document)
    }

    suspend fun exportCurrentPdf(target: File, options: ExportOptions) = withContext(Dispatchers.Default) {
        val territory = activeGebiet.value ?: return@withContext
        val document = ExportDocumentBuilder.build(territory, houses.value, scope.value, options.visitedOnly, options.includeNotes)
        PdfExporter.write(document, target)
    }

    override fun onCleared() {
        database.close()
        super.onCleared()
    }
}
