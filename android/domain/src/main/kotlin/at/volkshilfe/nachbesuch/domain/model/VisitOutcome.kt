package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Raw values are part of the cross-platform storage format. */
@Serializable
enum class VisitOutcome {
    @SerialName("notHome") NOT_HOME,
    @SerialName("earlyNo") EARLY_NO,
    @SerialName("lateNo") LATE_NO,
    @SerialName("joined") JOINED,

    /**
     * Nobody answered *now*, but a concrete return time was agreed or chosen.
     *
     * The time itself lives on the door (`DoorResult.revisitAt`), not here — an
     * enum entry cannot carry one without changing the storage format.
     */
    @SerialName("later") LATER;

    val emoji: String get() = when (this) {
        NOT_HOME -> "\uD83D\uDD34"
        EARLY_NO -> "\uD83D\uDEAB"
        LATE_NO -> "\u274C"
        JOINED -> "\u2764\uFE0F\u200D\uD83D\uDD25"
        LATER -> "\u23F0"
    }

    val germanTitle: String get() = when (this) {
        NOT_HOME -> "Niemand da"
        EARLY_NO -> "Frühes Nein"
        LATE_NO -> "Spätes Nein"
        JOINED -> "Dabei"
        LATER -> "Später"
    }

    /** Compact form for chips and tight rows. */
    val shortTitle: String get() = when (this) {
        NOT_HOME -> "Niemand"
        EARLY_NO -> "Früh"
        LATE_NO -> "Spät"
        JOINED -> "Dabei"
        LATER -> "Später"
    }

    /** The one-line "what does this mean" shown under the title in the picker. */
    val explanation: String get() = when (this) {
        NOT_HOME -> "Noch einmal hingehen"
        EARLY_NO -> "Vor dem Formular abgelehnt"
        LATE_NO -> "Beim Formular abgelehnt"
        JOINED -> "Langfristig aufgenommen"
        LATER -> "Zu einer bestimmten Zeit wiederkommen"
    }

    /** True when this door still needs another visit. */
    val isOpenWork: Boolean get() = this == NOT_HOME || this == LATER

    /** True when recording this outcome asks the user for a return time. */
    val needsRevisitTime: Boolean get() = this == LATER

    companion object {
        /**
         * The four results that end a visit, in the order the pickers show them.
         *
         * [entries] deliberately still contains [LATER] so tallies, legends and
         * exports cannot forget it; this is only the grid layout. Adding it to the
         * 2×2 grid would shrink the primary choices on every screen, and it is not
         * a result — it is a postponement.
         */
        val primary: List<VisitOutcome> = listOf(NOT_HOME, EARLY_NO, LATE_NO, JOINED)
    }
}
