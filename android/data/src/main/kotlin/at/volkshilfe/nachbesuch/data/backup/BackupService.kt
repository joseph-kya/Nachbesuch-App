package at.volkshilfe.nachbesuch.data.backup

import androidx.room.withTransaction
import at.volkshilfe.nachbesuch.data.json.AppBackup
import at.volkshilfe.nachbesuch.data.json.BackupCodec
import at.volkshilfe.nachbesuch.data.json.toBackup
import at.volkshilfe.nachbesuch.data.local.AppDatabase
import at.volkshilfe.nachbesuch.data.local.toEntity
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class BackupImportResult(val insertedGebiete: Int, val insertedHouses: Int, val skippedHouses: Int)

class BackupService(private val database: AppDatabase) {
    suspend fun export(gebiete: List<Gebiet>, houses: List<House>): String = withContext(Dispatchers.Default) {
        BackupCodec.encode(
            AppBackup(
                exportedAt = java.time.Instant.now().toString(),
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
                if (database.gebietDao().find(id) == null) {
                    runCatching { candidate.toDomain().toEntity() }.getOrNull()?.let {
                        database.gebietDao().upsert(it)
                        territoryCount++
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
