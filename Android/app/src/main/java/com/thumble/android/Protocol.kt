package com.thumble.android

import org.json.JSONObject
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/** Existing pocketpad-pair QR format; pairing codes remain transient and never enter logs. */
data class PairingTarget(val urls: List<String>, val code: String?, val serverID: String?, val serviceName: String? = null) {
    override fun toString() = "PairingTarget([redacted])"
    companion object {
        fun parse(text: String): PairingTarget {
            require(text.length <= 32_768) { "Pairing code is too large." }
            val json = runCatching { JSONObject(text) }.getOrElse { error("This is not a Thumble pairing QR code.") }
            require(json.optString("type") == "pocketpad-pair") { "This is not a Thumble pairing QR code." }
            val raw = json.optJSONArray("urls") ?: org.json.JSONArray()
            require(raw.length() <= 16) { "QR has too many network addresses." }
            val urls = (0 until raw.length()).map { validateURL(raw.getString(it)) }.distinct()
            val code = json.optString("pairingCode").takeIf { it.isNotBlank() && it != "null" }
            require(code == null || code.matches(Regex("[0-9]{6}"))) { "Pairing code must contain six digits." }
            val serverID = json.optString("serverID").takeIf { it.isNotBlank() && it != "null" }
            val name = json.optString("bonjourServiceName").takeIf { it.isNotBlank() && it != "null" }
            val type = json.optString("bonjourServiceType", "_pocketpad._tcp").trimEnd('.')
            val domain = json.optString("bonjourServiceDomain", "local").trimEnd('.')
            require(urls.isNotEmpty() || ((serverID != null || name != null) && type == "_pocketpad._tcp" && domain == "local")) {
                "QR has no reachable address or supported nearby Mac service."
            }
            return PairingTarget(urls, code, serverID, name)
        }

        fun manual(url: String, code: String): PairingTarget {
            require(code.matches(Regex("[0-9]{6}"))) { "Enter the six-digit code shown on the Mac." }
            return PairingTarget(listOf(validateURL(url.trim())), code, null)
        }
        internal fun validateURL(raw: String): String {
            val uri = runCatching { URI(raw) }.getOrElse { error("Use a ws:// or wss:// address shown by Thumble Mac.") }
            require(uri.scheme in setOf("ws", "wss") && !uri.host.isNullOrBlank() &&
                uri.rawUserInfo == null && uri.fragment == null && (uri.port == -1 || uri.port in 1..65535)) {
                "Use a ws:// or wss:// address shown by Thumble Mac."
            }
            return uri.toASCIIString()
        }
    }
}

object WireCodec {
    const val MAX_PAYLOAD = 8 * 1024 * 1024
    fun button(id: UUID, down: Boolean, generation: Long, sequence: Long, press: Long): ByteArray =
        compactInput(id, down, generation, sequence, press, 15, 0, 1, 0)

    fun element(id: UUID, part: InputPart, down: Boolean, generation: Long, sequence: Long, press: Long): ByteArray =
        compactInput(id, down, generation, sequence, press, 15, 0, 6, part.wire)

    // UUID bytes are network order; integer payloads are little endian, as in Swift/Rust.
    internal fun compactInput(id: UUID, down: Boolean, generation: Long, sequence: Long, press: Long,
                              flags: Int, timestamp: Long, type: Int, part: Int): ByteArray {
        val data = ByteBuffer.allocate(56)
        data.put('P'.code.toByte()).put('P'.code.toByte()).put(3).put(type.toByte())
        data.putLong(id.mostSignificantBits).putLong(id.leastSignificantBits)
        data.put(part.toByte()).put(if (down) 1 else 2).put(flags.toByte()).put(0)
        data.order(ByteOrder.LITTLE_ENDIAN).putLong(generation).putLong(sequence).putLong(press).putLong(timestamp)
        return data.array()
    }
    fun message(type: String, generation: Long? = null): JSONObject = JSONObject()
        .put("type", type).put("timestamp", 0).also {
            if (generation != null) it.put("inputProtocolVersion", 3).put("inputGeneration", generation)
        }
    fun decode(data: ByteArray): JSONObject {
        require(data.size <= MAX_PAYLOAD) { "Host message is too large." }
        if (data.size == 14 && data[0] == 80.toByte() && data[1] == 80.toByte()) {
            require(data[2] == 1.toByte() && data[12] == (-1).toByte() && data[13] == (-1).toByte())
            val type = when (data[3].toInt()) { 2 -> "release_all"; 3 -> "heartbeat"; 4 -> "ping"; 5 -> "pong"; else -> error("Invalid control frame") }
            return message(type).put("timestamp", ByteBuffer.wrap(data, 4, 8).order(ByteOrder.LITTLE_ENDIAN).long)
        }
        return StrictJSON.objectValue(data)
    }
}

/** Confined to the transport queue. Refreshes keep each physical hold alive independently. */
class InputSession(private val send: (ByteArray) -> Unit, initialGeneration: Long = 1) {
    private data class Press(val id: UUID, val token: Long, val part: InputPart? = null)
    private val active = linkedSetOf<Press>()
    private val sticks = linkedMapOf<String, Pair<Double, Double>>()
    private val triggers = linkedMapOf<String, Double>()
    private val pointerButtons = linkedSetOf<String>()
    var generation = initialGeneration
        private set
    private var sequence = 0L
    private var analogSequence = 0L
    private var pointerSequence = 0L
    fun edge(id: UUID, down: Boolean, token: Long) = digital(Press(id, token), down)
    fun element(id: UUID, part: InputPart, down: Boolean, token: Long) = digital(Press(id, token, part), down)
    private fun digital(press: Press, down: Boolean) {
        if (if (down) !active.add(press) else !active.remove(press)) return
        emit(press, down)
    }
    fun stick(target: String, x: Double, y: Double) {
        require(target == "left" || target == "right")
        val dx = finite(x, -1.0, 1.0); val dy = finite(y, -1.0, 1.0)
        if (kotlin.math.abs(dx) < .001 && kotlin.math.abs(dy) < .001) sticks.remove(target) else sticks[target] = dx to dy
        emitStick(target, dx, dy)
    }
    fun trigger(target: String, value: Double) {
        require(target == "left" || target == "right")
        val amount = finite(value, 0.0, 1.0)
        if (amount < .001) triggers.remove(target) else triggers[target] = amount
        emitTrigger(target, amount)
    }
    fun pointer(kind: String, dx: Double = 0.0, dy: Double = 0.0, button: String? = null, down: Boolean? = null) {
        require(kind in setOf("move", "scroll", "button"))
        val message = WireCodec.message("pointer", generation).put("inputSequence", ++pointerSequence).put("pointerEvent", kind)
        if (kind == "button") {
            require(button in setOf("left", "right", "middle") && down != null)
            if (down) pointerButtons.add(button!!) else pointerButtons.remove(button)
            message.put("pointerButton", button).put("state", if (down) "down" else "up")
        } else {
            if (!dx.isFinite() || !dy.isFinite() || (kotlin.math.abs(dx) < .01 && kotlin.math.abs(dy) < .01)) return
            message.put("deltaX", dx).put("deltaY", dy)
        }
        send(message.toString().toByteArray())
    }
    fun heartbeat() {
        send(WireCodec.message("heartbeat", generation).toString().toByteArray())
        active.toList().forEach { emit(it, true) }
        sticks.toMap().forEach { (target, vector) -> emitStick(target, vector.first, vector.second) }
        triggers.toMap().forEach { (target, amount) -> emitTrigger(target, amount) }
    }
    fun releaseAll(adopting: Long? = null) {
        active.clear(); sticks.clear(); triggers.clear(); pointerButtons.clear()
        generation = adopting ?: (generation + 1)
        sequence = 0; analogSequence = 0; pointerSequence = 0
        send(WireCodec.message("release_all", generation).toString().toByteArray())
    }
    private fun emit(press: Press, down: Boolean) {
        send(if (press.part == null) WireCodec.button(press.id, down, generation, ++sequence, press.token)
            else WireCodec.element(press.id, press.part, down, generation, ++sequence, press.token))
    }
    private fun analog() = WireCodec.message("gamepad_analog", generation).put("analogSequence", ++analogSequence)
    private fun emitStick(target: String, x: Double, y: Double) = send(analog().put("analogStick", target)
        .put("analogX", x).put("analogY", y).toString().toByteArray())
    private fun emitTrigger(target: String, amount: Double) = send(analog().put("analogTrigger", target)
        .put("analogValue", amount).toString().toByteArray())
    private fun finite(value: Double, low: Double, high: Double) = if (value.isFinite()) value.coerceIn(low, high) else 0.0
}

/** Pointer identities survive moves; leaving a button releases it before entering its neighbor. */
class TouchRouter(private val edge: (UUID, Boolean, Long) -> Unit) {
    private data class Hold(val id: UUID, val token: Long)
    private val holds = mutableMapOf<Int, Hold>()
    private var nextToken = 0L
    fun move(pointer: Int, target: UUID?) {
        val previous = holds[pointer]
        if (previous?.id == target) return
        previous?.let { edge(it.id, false, it.token); holds.remove(pointer) }
        if (target != null) {
            val token = ++nextToken
            holds[pointer] = Hold(target, token)
            edge(target, true, token)
        }
    }
    fun cancel() { holds.keys.toList().forEach { move(it, null) } }
    fun target(pointer: Int): UUID? = holds[pointer]?.id
    fun pressedIDs(): Set<UUID> = holds.values.map { it.id }.toSet()
}
