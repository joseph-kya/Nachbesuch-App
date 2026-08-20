package at.volkshilfe.nachbesuch.data.local

import androidx.room.withTransaction
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext

class TerritoryRepository(private val database: AppDatabase) {
    fun observeGebiete(): Flow<List<Gebiet>> = database.gebietDao().observeAll()
        .map { values -> withContext(Dispatchers.Default) { values.mapNotNull { it.toDomain() } } }
        .distinctUntilChanged()

    fun observeHouses(gebietID: String): Flow<List<House>> = database.houseDao().observeForGebiet(gebietID)
        .map { values -> withContext(Dispatchers.Default) { values.mapNotNull { it.toDomain() } } }
        .distinctUntilChanged()

    fun observeAllHouses(): Flow<List<House>> = database.houseDao().observeAll()
        .map { values -> withContext(Dispatchers.Default) { values.mapNotNull { it.toDomain() } } }
        .distinctUntilChanged()

    suspend fun save(gebiet: Gebiet) = database.gebietDao().upsert(gebiet.toEntity())
    suspend fun save(house: House) = database.houseDao().upsert(house.toEntity())
    suspend fun saveAll(houses: List<House>) = database.houseDao().upsertAll(houses.map(House::toEntity))
    suspend fun deleteHouse(id: String) = database.houseDao().delete(id)
    suspend fun deleteGebiet(id: String) {
        database.withTransaction {
            database.houseDao().deleteForGebiet(id)
            database.gebietDao().delete(id)
        }
    }
}
