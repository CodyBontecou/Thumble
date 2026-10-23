package com.thumble.rewrite.input

import java.util.ArrayDeque

/**
 * Private routing metadata only, never authentication or a new packet encoder. All methods run
 * under NativeTLSDelivery's existing gate. Eight globally dispatched input writes include the write
 * currently in progress.
 */
internal class NativeInputCredits {
    private var scope: ByteArray? = null
    private var lastWritten: ULong? = null
    private var acknowledged: ULong? = null
    private val pending = ArrayDeque<ULong>()

    private fun metadata(frame: ControlTLSFrame): Pair<ByteArray, ULong> {
        val packet = frame.payload
        if (
            frame.kind != ControlTLSFrame.Kind.INPUT ||
                packet.size != 108 ||
                !packet.copyOfRange(0, 8).contentEquals(byteArrayOf(84, 72, 73, 49, 0, 0, 0, 0))
        )
            throw ControlTLSRejected()
        var sequence = 0uL
        for (i in 0..7) sequence = sequence or ((packet[32 + i].toULong() and 255uL) shl (i * 8))
        if (sequence >= 1_048_576uL) throw ControlTLSRejected()
        return packet.copyOfRange(0, 32) to sequence
    }

    fun available(frame: ControlTLSFrame): Boolean {
        val (header, sequence) = metadata(frame)
        if (
            scope == null ||
                !header.contentEquals(scope) ||
                acknowledged?.let { sequence <= it } == true
        )
            return true
        return pending.size < 8
    }

    /** Returns false only for a coalesced state already acknowledged through UDP. */
    fun dispatch(frame: ControlTLSFrame): Boolean {
        val (header, sequence) = metadata(frame)
        if (scope == null) {
            if (sequence != 0uL || pending.isNotEmpty()) throw ControlTLSRejected()
            scope = header
        } else if (!header.contentEquals(scope)) throw ControlTLSRejected()
        if (acknowledged?.let { sequence <= it } == true) return false
        if (pending.size >= 8 || lastWritten?.let { sequence <= it } == true)
            throw ControlTLSRejected()
        pending.addLast(sequence)
        lastWritten = sequence
        return true
    }

    /**
     * Caller already validated current connection/session/map and route monotonicity. UDP shares
     * the counter and can legitimately ACK beyond the last TLS write.
     */
    fun acknowledge(header: ByteArray, sequence: ULong, highestOffered: ULong): Boolean {
        if (
            scope == null ||
                header.size != 32 ||
                !header.contentEquals(scope) ||
                sequence > highestOffered ||
                acknowledged?.let { sequence < it } == true
        )
            return false
        acknowledged = sequence
        while (pending.peekFirst()?.let { it <= sequence } == true) pending.removeFirst()
        return true
    }

    /**
     * Only a strictly validated renewal reply behind a held input/control barrier proves all old
     * input writes were consumed. New packet zero cannot reset this.
     */
    fun retireAtValidatedReply() {
        scope = null
        lastWritten = null
        acknowledged = null
        pending.clear()
    }
}
