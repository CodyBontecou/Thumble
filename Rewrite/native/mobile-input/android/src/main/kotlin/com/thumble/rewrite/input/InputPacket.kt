package com.thumble.rewrite.input

import com.thumble.rewrite.contracts.GamepadButtonV1
import com.thumble.rewrite.contracts.GamepadStateV1
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Collections
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class PacketRejected : Exception("input_packet_rejected")

/** Fresh authenticated native grant; never serialize or expose key material to React. */
class InputPacketGrant(
    key: ByteArray,
    session: ByteArray,
    noncePrefix: ByteArray,
    internal val generation: ULong,
) {
    internal val key: SecretKeySpec
    private val session: ByteArray
    private val prefix: ByteArray

    init {
        if (
            key.size != 32 ||
                session.size != 16 ||
                session.all { it == 0.toByte() } ||
                noncePrefix.size != 4 ||
                generation == 0uL
        )
            throw PacketRejected()
        this.key = SecretKeySpec(key.copyOf(), "AES")
        this.session = session.copyOf()
        prefix = noncePrefix.copyOf()
    }

    internal fun header(sequence: Long): ByteArray =
        ByteBuffer.allocate(40)
            .order(ByteOrder.LITTLE_ENDIAN)
            .put("THI1".toByteArray(Charsets.US_ASCII))
            .putInt(0)
            .put(session)
            .putLong(generation.toLong())
            .putLong(sequence)
            .array()

    internal fun nonce(sequence: Long): ByteArray =
        ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).put(prefix).putLong(sequence).array()
}

object InputPacketState {
    fun encode(state: GamepadStateV1): ByteArray {
        if (!GamepadReport.valid(state) || GamepadButtonV1.entries.size != 17)
            throw PacketRejected()
        val bytes = ByteBuffer.allocate(52).order(ByteOrder.LITTLE_ENDIAN)
        var mask = 0
        for ((i, button) in GamepadButtonV1.entries.withIndex()) if (button in state.buttons)
            mask = mask or (1 shl i)
        bytes.putInt(mask)
        for (v in
            listOf(
                state.leftStickX,
                state.leftStickY,
                state.rightStickX,
                state.rightStickY,
                state.leftTrigger,
                state.rightTrigger,
            )) bytes.putDouble(v)
        return bytes.array()
    }

    fun decode(data: ByteArray): GamepadStateV1 {
        if (data.size != 52 || GamepadButtonV1.entries.size != 17) throw PacketRejected()
        val bytes = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val mask = bytes.int
        if (mask ushr 17 != 0) throw PacketRejected()
        val state =
            GamepadStateV1(
                Collections.unmodifiableList(
                    GamepadButtonV1.entries
                        .filterIndexed { i, _ -> mask and (1 shl i) != 0 }
                        .toList()
                ),
                bytes.double,
                bytes.double,
                bytes.double,
                bytes.double,
                bytes.double,
                bytes.double,
            )
        if (!GamepadReport.valid(state)) throw PacketRejected()
        return state
    }
}

class InputPacketSender(grant: InputPacketGrant, private val packetLimit: Long = LIMIT) {
    companion object {
        const val LIMIT: Long = 1L shl 20
    }

    private val owner = Thread.currentThread()
    private var grant: InputPacketGrant? = grant
    private var next = 0L

    init {
        if (packetLimit !in 1..LIMIT) throw PacketRejected()
    }

    private fun thread() {
        check(Thread.currentThread() === owner) { "native_input_wrong_thread" }
    }

    fun close() {
        thread()
        grant = null
    }

    fun seal(state: GamepadStateV1): ByteArray {
        thread()
        val plain = InputPacketState.encode(state)
        val g = grant
        if (g == null || next >= packetLimit) {
            close()
            throw PacketRejected()
        }
        val sequence = next++
        try {
            val header = g.header(sequence)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, g.key, GCMParameterSpec(128, g.nonce(sequence)))
            cipher.updateAAD(header)
            return header + cipher.doFinal(plain)
        } catch (_: Exception) {
            close()
            throw PacketRejected()
        }
    }
}

class InputPacketReceiver(grant: InputPacketGrant) {
    private val owner = Thread.currentThread()
    private var grant: InputPacketGrant? = grant
    private var newest = -1L

    private fun thread() {
        check(Thread.currentThread() === owner) { "native_input_wrong_thread" }
    }

    fun close() {
        thread()
        grant = null
    }

    fun open(data: ByteArray): GamepadStateV1 {
        thread()
        if (data.size != 108) throw PacketRejected()
        val g = grant ?: throw PacketRejected()
        val packet = data.copyOf()
        val sequence = ByteBuffer.wrap(packet).order(ByteOrder.LITTLE_ENDIAN).getLong(32)
        if (
            sequence < 0 ||
                sequence >= InputPacketSender.LIMIT ||
                sequence <= newest ||
                !packet.copyOfRange(0, 40).contentEquals(g.header(sequence))
        )
            throw PacketRejected()
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, g.key, GCMParameterSpec(128, g.nonce(sequence)))
            cipher.updateAAD(packet, 0, 40)
            val state = InputPacketState.decode(cipher.doFinal(packet, 40, 68))
            newest = sequence
            return state
        } catch (_: Exception) {
            throw PacketRejected()
        }
    }
}

/** One bounded native packet per sample, with no JS callback or backlog. */
class InputPacketChannel(
    grant: InputPacketGrant,
    packetLimit: Long = InputPacketSender.LIMIT,
    private val send: (ByteArray) -> Boolean,
) {
    private val owner = Thread.currentThread()
    private val sender = InputPacketSender(grant, packetLimit)
    private val generation = grant.generation.toString()
    private var next = 0L
    private var available = true
    private var publishing = false

    private fun thread() {
        check(Thread.currentThread() === owner) { "native_input_wrong_thread" }
    }

    fun close() {
        thread()
        available = false
        sender.close()
    }

    fun submit(sample: InputSample): Boolean {
        thread()
        if (
            !available ||
                publishing ||
                sample.generation != generation ||
                sample.sequence != next.toString()
        ) {
            close()
            return false
        }
        publishing = true
        try {
            val packet = sender.seal(sample.state)
            next++
            if (!send(packet) || !available) {
                close()
                return false
            }
            return true
        } catch (_: Exception) {
            close()
            return false
        } finally {
            publishing = false
        }
    }
}
