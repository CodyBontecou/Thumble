package com.thumble.rewrite.input

import com.thumble.rewrite.contracts.GamepadStateV1
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Single-use native handoff. The private grant has no bridge, serialization or secret accessors.
 */
class PhoneInputAdmission
internal constructor(
    grant: InputPacketGrant,
    map: ControlMap,
    private val client: PhoneControlClient,
) : Closeable {
    private val consumed = AtomicBoolean(false)
    private var grant: InputPacketGrant? = grant
    private val map = map

    fun bind(feedback: (GamepadStateV1) -> Unit = {}): InputEngine {
        client.inputThread()
        if (!consumed.compareAndSet(false, true)) throw PhoneControlRejected()
        try {
            client.inputCheckpoint()
            val packet = grant ?: throw PhoneControlRejected()
            grant = null
            val channel = client.bindChannel(packet)
            val engine = InputEngine(channel::submit, feedback)
            engine.onRelease = {
                channel.close()
                client.close()
            }
            engine.activate(map)
            engine.connect(map.generation)
            if (!engine.connected) throw PhoneControlRejected()
            return engine
        } catch (_: Exception) {
            client.close()
            throw PhoneControlRejected()
        }
    }

    override fun close() {
        client.close()
    }
}

/** Bound existing TLS ownership to one writer and one reader before accepting UI samples. */
internal class NativeControlDelivery(raw: NativeFrameIO) : NativeFrameIO {
    private val delivery = NativeTLSDelivery(raw)

    fun offerInput(packet: ByteArray) = delivery.offerInput(packet)

    override fun send(frame: ControlTLSFrame) {
        val ok =
            if (frame.kind == ControlTLSFrame.Kind.INPUT) delivery.offerInput(frame.payload)
            else delivery.offerControl(frame.payload)
        if (!ok) throw PhoneControlRejected()
    }

    override fun receive(): ControlTLSFrame {
        val deadline = System.nanoTime() + 2_000_000_000L
        while (delivery.state == NativeTLSDelivery.State.READY && System.nanoTime() < deadline) {
            delivery.pollControl()?.let {
                return it
            }
            Thread.sleep(1)
        }
        close()
        throw PhoneControlRejected()
    }

    override fun close() = delivery.close()
}

internal class PhoneInputGrant(
    value: Map<String, EnrollmentJSON.Value>,
    connection: String,
    map: ControlMap,
    datagrams: Boolean = false,
    outputMode: PhoneOutputMode = PhoneOutputMode.RECORDING,
) {
    val packet: InputPacketGrant
    val lifetime: Long
    val sessionID: String
    val udpPort: Int?

    init {
        val duration =
            (value["lifetimeMs"] as? EnrollmentJSON.Value.Integer)?.value
                ?: throw PhoneControlRejected()
        if (
            value.keys !=
                outputMode.fields(
                    setOf(
                        "version",
                        "command",
                        "connectionId",
                        "generation",
                        "revision",
                        "sessionId",
                        "key",
                        "noncePrefix",
                        "lifetimeMs",
                        "packetVersion",
                        "packetBytes",
                        "packetLimit",
                        "transport",
                        "inputEnabled",
                    ) + (if (datagrams) setOf("udpPort") else emptySet())
                ) ||
                value["version"] != EnrollmentJSON.Value.Integer(1) ||
                value["command"] != EnrollmentJSON.Value.Text("input-granted") ||
                value["connectionId"] != EnrollmentJSON.Value.Text(connection) ||
                value["generation"] != EnrollmentJSON.Value.Text(map.generation) ||
                value["revision"] != EnrollmentJSON.Value.Text(map.revision) ||
                value["packetVersion"] != EnrollmentJSON.Value.Integer(1) ||
                value["packetBytes"] != EnrollmentJSON.Value.Integer(108) ||
                value["packetLimit"] != EnrollmentJSON.Value.Text("1048576") ||
                value["transport"] !=
                    EnrollmentJSON.Value.Text(if (datagrams) "udp+tls" else "tls") ||
                duration !in 100..60_000
        )
            throw PhoneControlRejected()
        outputMode.validate(value, true)
        val generation = map.generation.toULongOrNull() ?: throw PhoneControlRejected()
        if (generation == 0uL || generation.toString() != map.generation)
            throw PhoneControlRejected()
        packet =
            InputPacketGrant(
                hex(value["key"], 32),
                hex(value["sessionId"], 16),
                hex(value["noncePrefix"], 4),
                generation,
            )
        lifetime = duration
        sessionID = (value["sessionId"] as EnrollmentJSON.Value.Text).value
        udpPort =
            if (datagrams) {
                val port =
                    (value["udpPort"] as? EnrollmentJSON.Value.Integer)?.value
                        ?: throw PhoneControlRejected()
                if (port !in 1..65535) throw PhoneControlRejected()
                port.toInt()
            } else null
    }

    companion object {
        fun configuration(
            value: Map<String, EnrollmentJSON.Value>,
            connection: String,
            map: ControlMap,
            outputMode: PhoneOutputMode = PhoneOutputMode.RECORDING,
        ) {
            val metadata = PhoneInputConfiguration.decode(value, connection, outputMode)
            if (
                !metadata.active ||
                    metadata.generation != map.generation ||
                    metadata.revision != map.revision
            )
                throw PhoneControlRejected()
        }

        private fun hex(value: EnrollmentJSON.Value?, bytes: Int): ByteArray {
            val text = (value as? EnrollmentJSON.Value.Text)?.value ?: throw PhoneControlRejected()
            if (!text.matches(Regex("[0-9a-f]{${bytes * 2}}"))) throw PhoneControlRejected()
            return ByteArray(bytes) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        }
    }
}
