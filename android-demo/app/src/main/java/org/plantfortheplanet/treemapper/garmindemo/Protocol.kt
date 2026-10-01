package org.plantfortheplanet.treemapper.garmindemo

/**
 * The TreeMapper watch protocol, version 1.
 *
 * This mirrors PROTOCOL.md in the watch project. Keep the two in step.
 *
 * Message shape on the wire
 * -------------------------
 * The Connect IQ SDK carries a `List<Object>`. A Monkey C `Dictionary` maps to a
 * Java `Map` and a Monkey C `Array` maps to a Java `List`, so a message is sent
 * as a single-element list holding one map, and an incoming message is a list
 * whose first map element is the payload. Both directions are unwrapped
 * defensively here, because the SDK has been observed to deliver the payload
 * both bare and wrapped depending on version.
 */
object Protocol {

    /** Must match `id` in the watch project's manifest.xml. */
    const val WATCH_APP_ID = "a7f3c81e6b2d4f9ea05c73819d4e6b21"

    const val VERSION = 1

    // ---- outbound -------------------------------------------------------

    fun hello(): List<Any> = wrap(mapOf("c" to "hello"))

    fun ping(): List<Any> = wrap(mapOf("c" to "ping"))

    fun requestFix(requestId: Int): List<Any> =
        wrap(mapOf("c" to "fix", "r" to requestId))

    private fun wrap(payload: Map<String, Any?>): List<Any> = listOf(payload)

    // ---- inbound --------------------------------------------------------

    /**
     * Pull the payload map out of whatever the SDK handed us.
     *
     * Returns null when the message is not a shape we understand, which is
     * worth logging rather than swallowing: it usually means the watch and the
     * phone disagree about the protocol.
     */
    @Suppress("UNCHECKED_CAST")
    fun unwrap(messageData: List<Any?>?): Map<String, Any?>? {
        if (messageData == null) return null
        for (item in messageData) {
            when (item) {
                is Map<*, *> -> return item as Map<String, Any?>
                is List<*> -> {
                    val nested = unwrap(item)
                    if (nested != null) return nested
                }
            }
        }
        return null
    }

    sealed class Inbound {
        data class Ready(
            val version: Int,
            val quality: Int,
            val gpsRunning: Boolean,
            val multiBand: Boolean,
            val buffered: Int
        ) : Inbound()

        data class Point(
            val seq: Int,
            val requestId: Int?,
            val source: String,
            val latitude: Double,
            val longitude: Double,
            val altitude: Double?,
            val quality: Int,
            val timestamp: Long,
            val speed: Double?,
            /** The runtime class the SDK gave us for latitude. See README. */
            val latitudeType: String
        ) : Inbound()

        data class Error(val requestId: Int?, val code: String) : Inbound()

        data class Unknown(val raw: Map<String, Any?>) : Inbound()
    }

    fun parse(payload: Map<String, Any?>): Inbound {
        return when (payload["t"] as? String) {
            "ready" -> Inbound.Ready(
                version = intOf(payload["v"]) ?: 0,
                quality = intOf(payload["q"]) ?: 0,
                gpsRunning = (intOf(payload["gps"]) ?: 0) == 1,
                multiBand = (intOf(payload["mb"]) ?: 0) == 1,
                buffered = intOf(payload["buf"]) ?: 0
            )

            "pt" -> {
                val lat = payload["lat"]
                Inbound.Point(
                    seq = intOf(payload["n"]) ?: 0,
                    requestId = intOf(payload["r"]),
                    source = payload["src"] as? String ?: "?",
                    latitude = doubleOf(lat) ?: 0.0,
                    longitude = doubleOf(payload["lon"]) ?: 0.0,
                    altitude = doubleOf(payload["alt"]),
                    quality = intOf(payload["q"]) ?: 0,
                    timestamp = longOf(payload["ts"]) ?: 0L,
                    speed = doubleOf(payload["spd"]),
                    latitudeType = lat?.javaClass?.simpleName ?: "null"
                )
            }

            "err" -> Inbound.Error(
                requestId = intOf(payload["r"]),
                code = payload["code"] as? String ?: "unknown"
            )

            else -> Inbound.Unknown(payload)
        }
    }

    // ---- lenient number reading ------------------------------------------
    //
    // The SDK's boxing is not guaranteed across versions, so never cast
    // directly. A latitude arriving as a Float instead of a Double is the
    // classic silent bug here: it stays plausible and is wrong by metres.

    private fun intOf(v: Any?): Int? = when (v) {
        is Number -> v.toInt()
        is String -> v.toIntOrNull()
        else -> null
    }

    private fun longOf(v: Any?): Long? = when (v) {
        is Number -> v.toLong()
        is String -> v.toLongOrNull()
        else -> null
    }

    //! Coordinates may arrive as a Double or as text.
    //!
    //! The watch can send them as a string (SAFE_COORDS in GpsService.mc) to
    //! keep Doubles off the wire, which is a workaround for serialisation
    //! crashes on the tethered link. Text at seven decimal places is about 1 cm,
    //! so nothing is lost either way. Both forms are accepted here so the phone
    //! does not care which the watch chose.
    private fun doubleOf(v: Any?): Double? = when (v) {
        is Number -> v.toDouble()
        is String -> v.toDoubleOrNull()
        else -> null
    }

    fun qualityLabel(q: Int): String = when (q) {
        4 -> "GOOD"
        3 -> "USABLE"
        2 -> "POOR"
        1 -> "STALE"
        else -> "NO FIX"
    }
}
