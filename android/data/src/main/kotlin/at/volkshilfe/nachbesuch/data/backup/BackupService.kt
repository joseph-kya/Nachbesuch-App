package at.volkshilfe.nachbesuch.data.backup

import androidx.room.withTransaction
import at.volkshilfe.nachbesuch.data.json.AppBackup
import at.volkshilfe.nachbesuch.data.json.AppJson
import at.volkshilfe.nachbesuch.data.json.BackupCodec
import at.volkshilfe.nachbesuch.data.json.toBackup
import at.volkshilfe.nachbesuch.data.local.AppDatabase
import at.volkshilfe.nachbesuch.data.local.toDomain
import at.volkshilfe.nachbesuch.data.local.toEntity
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class BackupImportResult(val insertedGebiete: Int, val insertedHouses: Int, val skippedHouses: Int)

/** Raised instead of silently exporting a house whose doors cannot be decoded. */
class UnreadableHouseException(val address: String) :
    IllegalStateException("Unlesbares Haus: $address")

class BackupService(private val database: AppDatabase) {
    /** Export a consistent persisted snapshot, independent of UI subscriptions. */
    suspend fun export(): String {
        val snapshot = database.withTransaction {
            val territories = database.gebietDao().readAll().map {
                requireNotNull(it.toDomain()) { "Ein Gebiet kann nicht gelesen werden; Sicherung abgebrochen." }
            }
            val houses = database.houseDao().readAll().map {
                requireNotNull(it.toDomain()) { "Ein Haus kann nicht gelesen werden; Sicherung abgebrochen." }
            }
            territories to houses
        }
        return export(snapshot.first, snapshot.second)
    }

    /**
     * Strict like the iOS exporter: one damaged house aborts the whole backup,
     * because a backup that quietly drops door data is worse than no backup.
     */
    suspend fun export(gebiete: List<Gebiet>, houses: List<House>): String = withContext(Dispatchers.Default) {
        val damaged = houses.firstOrNull { it.isDamaged }
            ?: houses.firstOrNull { it.units.isEmpty() }
        if (damaged != null) throw UnreadableHouseException(damaged.address)
        BackupCodec.encode(
            AppBackup(
                exportedAt = AppJson.isoNow(),
                gebiete = gebiete.map(Gebiet::toBackup),
                houses = houses.map(House::toBackup)
            )
        )
    }

    suspend fun import(raw: String): BackupImportResult = withContext(Dispatchers.IO) {
        val backup = BackupCodec.decode(raw)
        var territoryCount = 0
        var houseCount = 0
        var skipped = 0
        database.withTransaction {
            backup.gebiete.forEach { candidate ->
                val id = candidate.id.uppercase()
                val existing = database.gebietDao().find(id)
                if (existing == null) {
                    runCatching { candidate.toDomain().toEntity() }.getOrNull()?.let {
                        database.gebietDao().upsert(it)
                        territoryCount++
                    } ?: run { skipped++ }
                } else {
                    // Merge semantics from the iOS importer: backfill what the
                    // existing territory is missing instead of skipping outright.
                    runCatching { candidate.toDomain() }.getOrNull()?.let { incoming ->
                        val current = existing.toDomain() ?: return@let
                        val needsBoundary = current.boundary.isEmpty() && incoming.boundary.isNotEmpty()
                        val needsName = current.name.isBlank() && incoming.name.isNotBlank()
                        if (needsBoundary || needsName) {
                            database.gebietDao().upsert(
                                current.copy(
                                    boundary = if (needsBoundary) incoming.boundary else current.boundary,
                                    name = if (needsName) incoming.name else current.name
                                ).touch().toEntity()
                            )
                        }
                    }
                }
            }
            backup.houses.forEach { candidate ->
                val id = candidate.id.uppercase()
                val territory = candidate.gebietID?.uppercase() ?: candidate.dayID?.uppercase()
                if (territory == null || database.gebietDao().find(territory) == null) {
                    skipped++
                } else if (database.houseDao().find(id) == null) {
                    runCatching { candidate.toDomain(territory).toEntity() }.getOrNull()?.let {
                        database.houseDao().upsert(it)
                        houseCount++
                    } ?: run { skipped++ }
                }
            }
        }
        BackupImportResult(territoryCount, houseCount, skipped)
    }
}
