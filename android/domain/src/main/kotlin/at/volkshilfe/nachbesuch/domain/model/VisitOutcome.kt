package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Raw values are part of the cross-platform storage format. */
@Serializable
enum class VisitOutcome {
    @SerialName("notHome") NOT_HOME,
    @SerialName("earlyNo") EARLY_NO,
    @SerialName("lateNo") LATE_NO,
    @SerialName("joined") JOINED;

    val emoji: String get() = when (this) {
        NOT_HOME -> "🔴"
        EARLY_NO -> "🚫"
        LATE_NO -> "❌"
        JOINED -> "❤️‍🔥"
    }

    val germanTitle: String get() = when (this) {
        NOT_HOME -> "Niemand da"
        EARLY_NO -> "Frühes Nein"
        LATE_NO -> "Spätes Nein"
        JOINED -> "Dabei"
    }

    /** Compact form for chips and tight rows. */
    val shortTitle: String get() = when (this) {
        NOT_HOME -> "Niemand"
        EARLY_NO -> "Früh"
        LATE_NO -> "Spät"
        JOINED -> "Dabei"
    }
}
