package at.volkshilfe.nachbesuch.data.json

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import java.time.Instant
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome

object BackupCodec {
    fun encode(backup: AppBackup): String = AppJson.backup.encodeToString(backup)

    /** Reads known envelopes only. Unsupported records must never disappear on import. */
    fun decode(raw: String): AppBackup {
        val root = Json.parseToJsonElement(raw).jsonObject
        val version = root["formatVersion"]?.jsonPrimitive?.intOrNull
        require(version in 1..3) { "Nicht unterstützte Backup-Version: $version" }
        // iOS v3 adds encounters. Until Android can store them, stop before the
        // importer opens a transaction. Empty v3 files retain house compatibility.
        require(root["passanten"]?.jsonArray.orEmpty().isEmpty()) {
            "Dieses Backup enthält Passanten, die Android noch nicht unterstützt. Bitte auf iOS wiederherstellen. Es wurde nichts importiert."
        }
        if (version != 1) {
            require(root["gebiete"] != null && root["houses"] != null) { "Unvollständiges Backup" }
            return AppJson.backup.decodeFromString(raw)
        }
        require(root["days"] != null && root["houses"] != null) { "Unvollständiges Backup" }
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
                updatedAt = primitiveInstant((value["updatedAt"] ?: value["createdAt"])?.jsonPrimitive),
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
                    outcome = d["outcome"]?.jsonPrimitive?.contentOrNull?.let(::decodeOutcome),
                    updatedAt = d["updatedAt"]?.jsonPrimitive?.let(::optionalInstant),
                    revisitAt = d["revisitAt"]?.jsonPrimitive?.let(::optionalInstant),
                    day2Outcome = d["day2Outcome"]?.jsonPrimitive?.contentOrNull?.let(::decodeOutcome),
                    day2UpdatedAt = d["day2UpdatedAt"]?.jsonPrimitive?.let(::optionalInstant),
                    day2RevisitAt = d["day2RevisitAt"]?.jsonPrimitive?.let(::optionalInstant)
                )
            }
            BackupHouse(
                id = value["id"]?.jsonPrimitive?.content.orEmpty().uppercase(),
                address = value["address"]?.jsonPrimitive?.content.orEmpty(),
                note = value["note"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                latitude = value["latitude"]?.jsonPrimitive?.doubleOrNull ?: 0.0,
                longitude = value["longitude"]?.jsonPrimitive?.doubleOrNull ?: 0.0,
                isApartmentBuilding = value["isApartmentBuilding"]?.jsonPrimitive?.booleanOrNull ?: false,
                gebietID = value["gebietID"]?.jsonPrimitive?.contentOrNull,
                dayID = value["dayID"]?.jsonPrimitive?.contentOrNull,
                units = units,
                createdAt = value["createdAt"]?.jsonPrimitive?.let(::optionalInstant) ?: exportedAt,
                updatedAt = value["updatedAt"]?.jsonPrimitive?.let(::optionalInstant) ?: exportedAt
            )
        }
        return AppBackup(2, exportedAt, territories, houses)
    }

    private fun primitiveInstant(value: JsonPrimitive?): String =
        value?.longOrNull?.let { Instant.ofEpochMilli(it).toString() }
            ?: value?.content?.takeIf { it.contains('T') }
            ?: Instant.EPOCH.toString()

    private fun optionalInstant(value: JsonPrimitive): String? =
        value.contentOrNull?.let { primitiveInstant(value) }

    private fun encodeBoundary(value: kotlinx.serialization.json.JsonElement): String =
        java.util.Base64.getEncoder().encodeToString(value.toString().toByteArray())

    private fun decodeOutcome(raw: String): VisitOutcome? = when (raw) {
        "notHome", "NOT_HOME", "NOTHOME" -> VisitOutcome.NOT_HOME
        "earlyNo", "EARLY_NO", "EARLYNO" -> VisitOutcome.EARLY_NO
        "lateNo", "LATE_NO", "LATENO" -> VisitOutcome.LATE_NO
        "joined", "JOINED" -> VisitOutcome.JOINED
        "later", "LATER" -> VisitOutcome.LATER
        else -> throw IllegalArgumentException("Unbekanntes Ergebnis im Backup: $raw")
    }
}
