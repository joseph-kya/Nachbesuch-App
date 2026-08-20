package at.volkshilfe.nachbesuch.data.local

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [GebietEntity::class, HouseEntity::class, CampaignDayEntity::class],
    version = 1,
    exportSchema = true
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun gebietDao(): GebietDao
    abstract fun houseDao(): HouseDao

    companion object {
        fun open(context: Context): AppDatabase = Room.databaseBuilder(
            context, AppDatabase::class.java, "nachbesuch.sqlite"
        ).build()

        fun openScratch(context: Context): AppDatabase = Room.inMemoryDatabaseBuilder(
            context, AppDatabase::class.java
        ).build()
    }
}
