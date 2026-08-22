package at.volkshilfe.nachbesuch.data.local

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import kotlinx.coroutines.flow.Flow

@Dao
interface GebietDao {
    @Query("SELECT * FROM Gebiet ORDER BY day1Date DESC")
    fun observeAll(): Flow<List<GebietEntity>>
    @Query("SELECT * FROM Gebiet WHERE id = :id LIMIT 1")
    suspend fun find(id: String): GebietEntity?
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(value: GebietEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(values: List<GebietEntity>)
    @Query("DELETE FROM Gebiet WHERE id = :id")
    suspend fun delete(id: String)
}

@Dao
interface HouseDao {
    /**
     * Stable order, deliberately **not** `updatedAt DESC`.
     *
     * Recording one door result bumps `updatedAt`, which under the old ordering
     * moved that house to the front and shifted every other row. The list
     * re-sorts itself anyway, but the map emits one marker per house in list
     * order, so a single status tap reshuffled hundreds of markers — and,
     * because a marker's position lives in a `MarkerState` that Compose retains
     * per slot while the icon comes from the parameter, the shifted markers
     * ended up wearing each other's icons.
     *
     * `createdAt` never changes after insert, so the corpus stays put and only
     * the edited house's marker updates.
     */
    @Query("SELECT * FROM House WHERE gebietID = :gebietID OR dayID = :gebietID ORDER BY createdAt ASC, id ASC")
    fun observeForGebiet(gebietID: String): Flow<List<HouseEntity>>
    @Query("SELECT * FROM House ORDER BY createdAt ASC, id ASC")
    fun observeAll(): Flow<List<HouseEntity>>
    @Query("SELECT * FROM House WHERE id = :id LIMIT 1")
    suspend fun find(id: String): HouseEntity?
    @Query("SELECT * FROM House WHERE gebietID = :gebietID ORDER BY updatedAt DESC LIMIT :limit")
    suspend fun recentlyChanged(gebietID: String, limit: Int): List<HouseEntity>
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(value: HouseEntity)
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(values: List<HouseEntity>)
    @Query("DELETE FROM House WHERE id = :id")
    suspend fun delete(id: String)
    @Query("DELETE FROM House WHERE gebietID = :gebietID OR dayID = :gebietID")
    suspend fun deleteForGebiet(gebietID: String)
}
