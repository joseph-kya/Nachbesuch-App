package at.volkshilfe.nachbesuch.data.json

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.doubleOrNull
import java.time.Instant
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome

object BackupCodec {
    fun encode(backup: AppBackup): String = AppJson.backup.encodeToString(backup)

    /** Reads v2 and the reduced v1 `days` envelope without silently merging records. */
    fun decode(raw: String): AppBackup {
        val root = Json.parseToJsonElement(raw).jsonObject
        val version = root["formatVersion"]?.jsonPrimitive?.intOrNull ?: 1
        if (version >= 2 && root["gebiete"] != null) {
            return AppJson.backup.decodeFromString(raw)
        }
        val exportedAt = primitiveInstant(root["exportedAt"]?.jsonPrimitive)
        val territories = root["days"]?.jsonArray.orEmpty().map { day ->
            val value = day.jsonObject
            BackupGebiet(
                id = value["id"]?.jsonPrimitive?.content.orEmpty().uppercase(),
                name = value["name"]?.jsonPrimitive?.content ?: "",
                districtOrCity = value["districtOrCity"]?.jsonPrimitive?.content ?: "",
                isTwoDay = false,
                day1Date = primitiveInstant(value["date"]?.jsonPrimitive),
                createdAt = primitiveInstant(value["createdAt"]?.jsonPrimitive),
                updatedAt = primitiveInstant(value["updatedAt"]?.jsonPrimitive),
                boundaryData = value["boundaryData"]?.jsonPrimitive?.content
                    ?: value["boundaryCoordinates"]?.let { encodeBoundary(it) }.orEmpty()
            )
        }
        val houses = root["houses"]?.jsonArray.orEmpty().map { rawHouse ->
            val value = rawHouse.jsonObject
            val units = value["units"]?.jsonArray.orEmpty().map { door ->
                val d = door.jsonObject
                BackupDoor(
                    id = d["id"]?.jsonPrimitive?.content.orEmpty().uppercase(),
                    label = d["label"]?.jsonPrimitive?.content ?: "Haushalt",
                    outcome = d["outcome"]?.jsonPrimitive?.content?.let(::decodeOutcome)
                )
            }
            BackupHouse(
                id = value["id"]?.jsonPrimitive?.content.orEmpty().uppercase(),
                address = value["address"]?.jsonPrimitive?.content.orEmpty(),
                latitude = value["latitude"]?.jsonPrimitive?.doubleOrNull ?: 0.0,
                longitude = value["longitude"]?.jsonPrimitive?.doubleOrNull ?: 0.0,
                gebietID = value["gebietID"]?.jsonPrimitive?.content,
                dayID = value["dayID"]?.jsonPrimitive?.content,
                units = units,
                createdAt = exportedAt,
                updatedAt = exportedAt
            )
        }
        return AppBackup(2, exportedAt, territories, houses)
    }

    private fun primitiveInstant(value: JsonPrimitive?): String =
        value?.longOrNull?.let { Instant.ofEpochMilli(it).toString() }
            ?: value?.content?.takeIf { it.contains('T') }
            ?: Instant.EPOCH.toString()

    private fun encodeBoundary(value: kotlinx.serialization.json.JsonElement): String =
        java.util.Base64.getEncoder().encodeToString(value.toString().toByteArray())

    private fun decodeOutcome(raw: String): VisitOutcome? = when (raw) {
        "notHome", "NOT_HOME", "NOTHOME" -> VisitOutcome.NOT_HOME
        "earlyNo", "EARLY_NO", "EARLYNO" -> VisitOutcome.EARLY_NO
        "lateNo", "LATE_NO", "LATENO" -> VisitOutcome.LATE_NO
        "joined", "JOINED" -> VisitOutcome.JOINED
        else -> null
    }
}
