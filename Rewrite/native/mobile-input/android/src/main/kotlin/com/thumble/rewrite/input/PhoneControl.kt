package com.thumble.rewrite.input

import android.annotation.TargetApi
import android.content.Context
import android.os.Looper
import java.io.Closeable
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

class PhoneControlRejected : Exception("phone_control_rejected")

class TrustedHostEndpoint(
    val host: String,
    val port: Int,
    val certificatePin: String,
    val authorityInstanceID: String,
) {
    init {
        if (
            host.isEmpty() ||
                !EnrollmentInvitation.scalarText(host) ||
                host.toByteArray(Charsets.UTF_8).size > 253 ||
                host.contains('\u0000') ||
                port !in 1..65535 ||
                !PhoneCredential.pin(certificatePin) ||
                !EnrollmentInvitation.identity(authorityInstanceID)
        )
            throw PhoneControlRejected()
    }
}

data class PhoneControlMetadata(
    val phoneID: String,
    val credentialEpoch: Long,
    val connectionID: String,
    val expiresAt: Long,
    val inputSessionAvailable: Boolean,
)

/** Native worker API. Each reconnect is a new owner; credentials and touches are never replayed. */
class PhoneControlClient
internal constructor(
    private val endpoint: TrustedHostEndpoint,
    private val connect: () -> NativeFrameIO,
    private val load: (String, Long) -> PhoneCredential?,
    private val now: () -> Long,
    private val requireWorker: Boolean = false,
    private val controlVersion: Int = 3,
    private val elapsed: () -> Long = System::nanoTime,
) : Closeable {
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val busy = AtomicBoolean(false)
    private val owner = Any()
    private var io: NativeFrameIO? = null
    @Volatile private var admitted: PhoneControlMetadata? = null
    @Volatile private var last = 0L
    @Volatile private var deadline: Long? = null
    private val inputAttempted = AtomicBoolean(false)
    @Volatile private var inputDeadline: Long? = null
    @Volatile private var inputElapsedDeadline: Long? = null
    private var inputElapsedLast: Long? = null
    @Volatile private var inputDelivery: NativeControlDelivery? = null
    @Volatile private var heartbeat: Thread? = null

    @TargetApi(29)
    constructor(
        endpoint: TrustedHostEndpoint,
        context: Context,
        inputSessions: Boolean = false,
    ) : this(
        endpoint,
        {
            val client =
                ControlTLSClient.connect(
                    InetSocketAddress(endpoint.host, endpoint.port),
                    endpoint.certificatePin,
                )
            object : NativeFrameIO {
                override fun send(frame: ControlTLSFrame) = client.send(frame)

                override fun receive() = client.receive()

                override fun close() = client.close()
            }
        },
        PhoneCredentialVault(context)::load,
        System::currentTimeMillis,
        true,
        if (inputSessions) 4 else 3,
        android.os.SystemClock::elapsedRealtimeNanos,
    )

    private fun worker() {
        if (requireWorker && Looper.myLooper() == Looper.getMainLooper())
            throw PhoneControlRejected()
    }

    private fun checkpoint(): Long =
        synchronized(owner) {
            val time = now()
            if (
                closed.get() ||
                    Thread.currentThread().isInterrupted ||
                    time < 0 ||
                    time < last ||
                    deadline?.let { time >= it } == true ||
                    admitted?.let { time >= it.expiresAt } == true
            )
                throw PhoneControlRejected()
            last = time
            time
        }

    private fun transport(): NativeFrameIO =
        synchronized(owner) { io ?: throw PhoneControlRejected() }

    private fun send(value: JSONObject) {
        checkpoint()
        transport()
            .send(
                ControlTLSFrame(
                    ControlTLSFrame.Kind.CONTROL,
                    value.toString().toByteArray(Charsets.UTF_8),
                )
            )
    }

    private fun receive(): Map<String, EnrollmentJSON.Value> {
        val frame = transport().receive()
        checkpoint()
        if (frame.kind != ControlTLSFrame.Kind.CONTROL) throw PhoneControlRejected()
        return EnrollmentJSON.parse(frame.payload)
    }

    fun authenticate(): PhoneControlMetadata {
        worker()
        if (
            controlVersion !in 3..4 ||
                !started.compareAndSet(false, true) ||
                !busy.compareAndSet(false, true)
        )
            throw PhoneControlRejected()
        try {
            checkpoint()
            val connected = connect()
            val accepted =
                synchronized(owner) {
                    if (closed.get()) false
                    else {
                        io = connected
                        true
                    }
                }
            if (!accepted) {
                connected.close()
                throw PhoneControlRejected()
            }
            checkpoint()
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "hello")
                    .put("controlVersion", controlVersion)
                    .put("inputVersion", 1)
                    .put("documentVersion", 1)
                    .put("capabilitiesVersion", 1)
            )
            val hello =
                mapOf(
                    "version" to EnrollmentJSON.Value.Integer(1),
                    "command" to EnrollmentJSON.Value.Text("hello"),
                    "authorityInstanceId" to
                        EnrollmentJSON.Value.Text(endpoint.authorityInstanceID),
                    "controlVersion" to EnrollmentJSON.Value.Integer(controlVersion.toLong()),
                    "inputVersion" to EnrollmentJSON.Value.Integer(1),
                    "documentVersion" to EnrollmentJSON.Value.Integer(1),
                    "capabilitiesVersion" to EnrollmentJSON.Value.Integer(1),
                    "inputEnabled" to EnrollmentJSON.Value.BooleanValue(false),
                )
            if (receive() != hello) throw PhoneControlRejected()
            val credential =
                load(endpoint.certificatePin, checkpoint()) ?: throw PhoneControlRejected()
            checkpoint()
            if (
                credential.metadata.hostPin != endpoint.certificatePin ||
                    last >= credential.metadata.expiresAt
            )
                throw PhoneControlRejected()
            transport().send(credential.authenticationFrame(endpoint.authorityInstanceID))
            val receipt = decode(receive(), "authenticated", credential.metadata)
            admitted = receipt
            deadline = minOf(receipt.expiresAt, Math.addExact(last, 60_000L))
            return receipt
        } catch (_: Exception) {
            close()
            throw PhoneControlRejected()
        } finally {
            busy.set(false)
        }
    }

    private fun decode(
        value: Map<String, EnrollmentJSON.Value>,
        command: String,
        credential: PhoneCredentialMetadata? = null,
    ): PhoneControlMetadata {
        fun text(key: String) =
            (value[key] as? EnrollmentJSON.Value.Text)?.value ?: throw PhoneControlRejected()
        val phone = text("phoneId")
        val epochText = text("credentialEpoch")
        val epoch = epochText.toLongOrNull() ?: throw PhoneControlRejected()
        val connection = text("connectionId")
        val expires =
            (value["expiresAt"] as? EnrollmentJSON.Value.Integer)?.value
                ?: throw PhoneControlRejected()
        if (
            value.keys !=
                setOf(
                    "version",
                    "command",
                    "authorityInstanceId",
                    "phoneId",
                    "credentialEpoch",
                    "connectionId",
                    "expiresAt",
                    "inputSessionAvailable",
                    "inputEnabled",
                ) ||
                value["version"] != EnrollmentJSON.Value.Integer(1) ||
                text("command") != command ||
                text("authorityInstanceId") != endpoint.authorityInstanceID ||
                !EnrollmentInvitation.identity(phone) ||
                epoch <= 0 ||
                epoch.toString() != epochText ||
                !connection.matches(Regex("[0-9a-f]{32}")) ||
                expires <= last ||
                value["inputEnabled"] != EnrollmentJSON.Value.BooleanValue(false) ||
                value["inputSessionAvailable"] !=
                    EnrollmentJSON.Value.BooleanValue(controlVersion == 4) ||
                credential?.let {
                    it.phoneID != phone || it.epoch != epoch || expires > it.expiresAt
                } == true
        )
            throw PhoneControlRejected()
        val receipt = PhoneControlMetadata(phone, epoch, connection, expires, controlVersion == 4)
        if (admitted?.let { it != receipt } == true) throw PhoneControlRejected()
        return receipt
    }

    fun status(): PhoneControlMetadata = operation(false)

    fun disconnect() {
        operation(true)
    }

    private fun operation(disconnect: Boolean): PhoneControlMetadata {
        worker()
        if (!busy.compareAndSet(false, true)) throw PhoneControlRejected()
        val receipt = admitted
        if (receipt == null) {
            busy.set(false)
            throw PhoneControlRejected()
        }
        try {
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", if (disconnect) "disconnect" else "control-status")
                    .put("connectionId", receipt.connectionID)
            )
            val result = decode(receive(), if (disconnect) "disconnected" else "control-status")
            if (disconnect) close()
            return result
        } catch (_: Exception) {
            close()
            throw PhoneControlRejected()
        } finally {
            busy.set(false)
        }
    }

    /** Worker-only grant admission; bind the returned owner once on the native input/UI thread. */
    fun prepareInput(map: ControlMap): PhoneInputAdmission {
        worker()
        if (
            controlVersion != 4 ||
                admitted == null ||
                inputAttempted.get() ||
                !busy.compareAndSet(false, true)
        )
            throw PhoneControlRejected()
        try {
            if (!inputAttempted.compareAndSet(false, true)) throw PhoneControlRejected()
            map.validated()
            val connection = admitted!!.connectionID
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "input-configuration")
                    .put("connectionId", connection)
            )
            PhoneInputGrant.configuration(receive(), connection, map)
            val requested = checkpoint()
            val startedAt = elapsed()
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "input-grant")
                    .put("connectionId", connection)
                    .put("generation", map.generation)
                    .put("revision", map.revision)
            )
            val grant = PhoneInputGrant(receive(), connection, map)
            inputDeadline = minOf(deadline ?: 0, Math.addExact(requested, grant.lifetime))
            inputElapsedDeadline =
                Math.addExact(startedAt, Math.multiplyExact(grant.lifetime, 1_000_000))
            inputElapsedLast = startedAt
            inputCheckpoint()
            val raw = transport()
            val delivery = NativeControlDelivery(raw)
            synchronized(owner) {
                if (closed.get() || io !== raw) {
                    delivery.close()
                    throw PhoneControlRejected()
                }
                io = delivery
                inputDelivery = delivery
            }
            val admission = PhoneInputAdmission(grant.packet, map, this)
            heartbeat =
                Thread(
                        {
                            try {
                                while (!closed.get()) {
                                    Thread.sleep(1000)
                                    if (busy.get()) continue
                                    inputCheckpoint()
                                    status()
                                }
                            } catch (_: Exception) {
                                close()
                            }
                        },
                        "thumble-input-control",
                    )
                    .apply {
                        isDaemon = true
                        start()
                    }
            return admission
        } catch (_: Exception) {
            close()
            throw PhoneControlRejected()
        } finally {
            busy.set(false)
        }
    }

    internal fun inputThread() {
        if (requireWorker && Looper.myLooper() != Looper.getMainLooper())
            throw PhoneControlRejected()
    }

    internal fun inputCheckpoint() =
        synchronized(owner) {
            val time = checkpoint()
            val wall = inputDeadline ?: throw PhoneControlRejected()
            val continuous = inputElapsedDeadline ?: throw PhoneControlRejected()
            val current = elapsed()
            if (
                time >= wall ||
                    current >= continuous ||
                    inputElapsedLast?.let { current < it } == true
            )
                throw PhoneControlRejected()
            inputElapsedLast = current
        }

    internal fun offerInput(packet: ByteArray): Boolean =
        try {
            inputCheckpoint()
            inputDelivery?.offerInput(packet) == true
        } catch (_: Exception) {
            close()
            false
        }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        heartbeat?.interrupt()
        heartbeat = null
        val connected =
            synchronized(owner) {
                val current = io
                io = null
                current
            }
        if (connected != null)
            Thread(
                    {
                        try {
                            connected.close()
                        } catch (_: Exception) {}
                    },
                    "thumble-control-close",
                )
                .apply {
                    isDaemon = true
                    start()
                }
    }
}
