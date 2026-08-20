package at.volkshilfe.nachbesuch.data.local

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(tableName = "Gebiet")
data class GebietEntity(
    @PrimaryKey val id: String,
    val name: String,
    val districtOrCity: String,
    val notes: String,
    val isTwoDay: Boolean,
    val day1Date: Long,
    val day2Date: Long?,
    val boundaryData: String,
    val createdAt: Long,
    val updatedAt: Long
)

@Entity(tableName = "House", indices = [Index("gebietID"), Index("updatedAt")])
data class HouseEntity(
    @PrimaryKey val id: String,
    val address: String,
    val note: String,
    val latitude: Double,
    val longitude: Double,
    val isApartmentBuilding: Boolean,
    val gebietID: String?,
    val dayID: String?,
    val unitsData: String,
    val createdAt: Long,
    val updatedAt: Long
)

@Entity(tableName = "CampaignDay")
data class CampaignDayEntity(
    @PrimaryKey val id: String,
    val date: Long,
    val boundaryData: String,
    val createdAt: Long
)
