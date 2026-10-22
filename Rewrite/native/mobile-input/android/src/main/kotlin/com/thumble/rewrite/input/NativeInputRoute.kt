package com.thumble.rewrite.input

/** One source/counter across transports. Never queues samples or reseals on fallback. */
internal class NativeInputRoute(
    private val now: () -> Long,
    private val udp: (ByteArray) -> Boolean,
    private val tls: (ByteArray) -> Boolean,
    initiallyReliable: Boolean = false,
) {
    private var scope: ByteArray? = null
    private var next = 0uL
    private var lastTime: Long? = null
    private val pending = java.util.ArrayDeque<Pair<ULong, Long>>()
    var lastOffered: ULong? = null
        private set

    var acknowledged: ULong? = null
        private set

    var reliable = initiallyReliable
        private set

    var closed = false
        private set

    @Synchronized
    fun close() {
        closed = true
        pending.clear()
        scope = null
    }

    private fun checkpoint(): Long? {
        val time = now()
        if (closed || lastTime?.let { time < it } == true) {
            close()
            return null
        }
        lastTime = time
        return time
    }

    @Synchronized
    fun offer(packet: ByteArray): Boolean {
        val time = checkpoint() ?: return false
        if (
            packet.size != 108 ||
                !packet.copyOfRange(0, 8).contentEquals(byteArrayOf(84, 72, 73, 49, 0, 0, 0, 0)) ||
                next >= 1_048_576uL
        ) {
            close()
            return false
        }
        val header = packet.copyOfRange(0, 32)
        if (scope?.contentEquals(header) == false) {
            close()
            return false
        }
        var sequence = 0uL
        for (i in 0..7) sequence = sequence or ((packet[32 + i].toULong() and 255uL) shl (i * 8))
        if (sequence != next) {
            close()
            return false
        }
        scope = header
        if (pending.size >= 64 || pending.peekFirst()?.let { time - it.second >= 150 } == true)
            reliable = true
        val sent =
            if (next == 0uL || reliable) tls(packet)
            else if (udp(packet)) true
            else {
                reliable = true
                tls(packet)
            }
        if (!sent || closed) {
            close()
            return false
        }
        if (reliable) pending.clear() else pending.addLast(sequence to time)
        lastOffered = sequence
        next++
        return true
    }

    @Synchronized
    fun observe(
        value: Map<String, EnrollmentJSON.Value>,
        connection: String,
        session: String,
        map: ControlMap,
    ): Boolean =
        try {
            observe(PhoneInputProgress(value, connection, session, map, lastOffered, acknowledged))
        } catch (_: Exception) {
            close()
            false
        }

    @Synchronized
    fun observe(progress: PhoneInputProgress): Boolean {
        checkpoint() ?: return false
        if (!progress.active) {
            close()
            return false
        }
        val sequence = progress.lastAccepted
        if (sequence != null) {
            if (
                lastOffered == null ||
                    sequence > lastOffered!! ||
                    acknowledged?.let { sequence < it } == true
            ) {
                close()
                return false
            }
            if (acknowledged != sequence) {
                acknowledged = sequence
                while (pending.peekFirst()?.let { it.first <= sequence } == true) pending
                    .removeFirst()
            }
        } else if (acknowledged != null) {
            close()
            return false
        }
        return true
    }
}
