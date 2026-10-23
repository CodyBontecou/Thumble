package com.thumble.rewrite.input

import android.annotation.TargetApi
import android.content.Context
import android.os.Looper
import java.io.Closeable
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

class PhoneControlRejected : Exception("phone_control_rejected")

/** Fixed first-failure taxonomy only; never carries an endpoint, payload or exception. */
enum class PhoneCheckpointFailure {
    CLOSED,
    INTERRUPTED,
    INVALID_TIME,
    CLOCK_ROLLBACK,
    LOCAL_DEADLINE,
    AUTHORITY_EXPIRY,
}

enum class PhoneInputFailureStage {
    CHECKPOINT,
    HEARTBEAT_STATUS,
    PROGRESS_SEND,
    PROGRESS_RECEIVE,
    PROGRESS_RECEIPT,
    PROGRESS_CHECKPOINT,
    PROGRESS_PARSE,
    RENEWAL,
    INPUT_SUBMIT,
    INPUT_OFFER,
}

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
    val outputMode: PhoneOutputMode = PhoneOutputMode.RECORDING,
    val inputEnabled: Boolean = false,
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
    private val datagramFactory: (String, Int) -> NativeDatagramIO = { host, port ->
        NativeDatagramDelivery(InetSocketAddress(host, port))
    },
    private val outputMode: PhoneOutputMode = PhoneOutputMode.RECORDING,
) : Closeable {
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val busy = AtomicBoolean(false)
    private val owner = Any()
    private val firstInputFailure = AtomicReference<PhoneInputFailureStage?>(null)
    private val firstCheckpointFailure = AtomicReference<PhoneCheckpointFailure?>(null)
    val checkpointFailure: PhoneCheckpointFailure?
        get() = firstCheckpointFailure.get()

    val inputFailureStage: PhoneInputFailureStage?
        get() = firstInputFailure.get()

    val inputTransportDiagnostic: NativeTLSTerminalDiagnostic?
        get() = inputDelivery?.terminalDiagnostic

    val inputTransportWaitOutcome: String?
        get() = inputDelivery?.waitOutcome?.name

    private fun recordInputFailure(stage: PhoneInputFailureStage) {
        if (!closed.get()) firstInputFailure.compareAndSet(null, stage)
    }

    private var io: NativeFrameIO? = null
    @Volatile private var admitted: PhoneControlMetadata? = null
    @Volatile private var credentialExpiresAt: Long? = null
    @Volatile private var inputSessionID: String? = null
    @Volatile private var inputUDPPort: Int? = null
    @Volatile private var inputRenewalDue: Long? = null

    private class PendingRenewal(
        val value: PhoneInputRenewal,
        val previous: String,
        val requested: Long,
        val started: Long,
    ) {
        var committed = false
    }

    private var pendingRenewal: PendingRenewal? = null
    @Volatile private var last = 0L
    @Volatile private var deadline: Long? = null
    private val inputAttempted = AtomicBoolean(false)
    @Volatile private var inputDeadline: Long? = null
    @Volatile private var inputElapsedDeadline: Long? = null
    private var inputElapsedLast: Long? = null
    @Volatile private var inputDelivery: NativeControlDelivery? = null
    @Volatile private var heartbeat: Thread? = null
    @Volatile private var datagram: NativeDatagramIO? = null
    @Volatile private var route: NativeInputRoute? = null

    @TargetApi(29)
    constructor(
        endpoint: TrustedHostEndpoint,
        context: Context,
        inputSessions: Boolean = false,
        datagrams: Boolean = false,
        renewals: Boolean = false,
        outputMode: PhoneOutputMode = PhoneOutputMode.RECORDING,
    ) : this(
        endpoint,
        {
            val client =
                ControlTLSClient.connect(
                    InetSocketAddress(endpoint.host, endpoint.port),
                    endpoint.certificatePin,
                )
            client.nativeFrames()
        },
        PhoneCredentialVault(context)::load,
        System::currentTimeMillis,
        true,
        if (outputMode == PhoneOutputMode.MACOS_HID) {
            if (!inputSessions || !datagrams || !renewals) throw PhoneControlRejected()
            9
        } else if (renewals) {
            if (!inputSessions || !datagrams) throw PhoneControlRejected()
            6
        } else if (datagrams) {
            if (!inputSessions) throw PhoneControlRejected()
            5
        } else if (inputSessions) 4 else 3,
        android.os.SystemClock::elapsedRealtimeNanos,
        outputMode = outputMode,
    )

    private fun worker() {
        if (requireWorker && Looper.myLooper() == Looper.getMainLooper())
            throw PhoneControlRejected()
    }

    private fun checkpoint(): Long =
        synchronized(owner) {
            val time = now()
            val failure =
                when {
                    closed.get() -> PhoneCheckpointFailure.CLOSED
                    Thread.currentThread().isInterrupted -> PhoneCheckpointFailure.INTERRUPTED
                    time < 0 -> PhoneCheckpointFailure.INVALID_TIME
                    time < last -> PhoneCheckpointFailure.CLOCK_ROLLBACK
                    deadline?.let { time >= it } == true -> PhoneCheckpointFailure.LOCAL_DEADLINE
                    admitted?.let { time >= it.expiresAt } == true ->
                        PhoneCheckpointFailure.AUTHORITY_EXPIRY
                    else -> null
                }
            if (failure != null) {
                firstCheckpointFailure.compareAndSet(null, failure)
                throw PhoneControlRejected()
            }
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

    private fun receive(progress: Boolean = false): Map<String, EnrollmentJSON.Value> {
        val frame = transport().receive()
        try {
            checkpoint()
        } catch (error: Exception) {
            if (progress) recordInputFailure(PhoneInputFailureStage.PROGRESS_CHECKPOINT)
            throw error
        }
        try {
            if (frame.kind != ControlTLSFrame.Kind.CONTROL) throw PhoneControlRejected()
            return EnrollmentJSON.parse(frame.payload, allowNull = controlVersion >= 5)
        } catch (error: Exception) {
            if (progress) recordInputFailure(PhoneInputFailureStage.PROGRESS_PARSE)
            throw error
        }
    }

    fun authenticate(): PhoneControlMetadata {
        worker()
        if (
            (controlVersion !in 3..6 && controlVersion != 9) ||
                ((controlVersion == 9) != (outputMode == PhoneOutputMode.MACOS_HID)) ||
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
            val request =
                JSONObject()
                    .put("version", 1)
                    .put("command", "hello")
                    .put("controlVersion", controlVersion)
                    .put("inputVersion", 1)
                    .put("documentVersion", 1)
                    .put("capabilitiesVersion", 1)
            val hello =
                mutableMapOf<String, EnrollmentJSON.Value>(
                    "version" to EnrollmentJSON.Value.Integer(1),
                    "command" to EnrollmentJSON.Value.Text("hello"),
                    "authorityInstanceId" to
                        EnrollmentJSON.Value.Text(endpoint.authorityInstanceID),
                    "controlVersion" to EnrollmentJSON.Value.Integer(controlVersion.toLong()),
                    "inputVersion" to EnrollmentJSON.Value.Integer(1),
                    "documentVersion" to EnrollmentJSON.Value.Integer(1),
                    "capabilitiesVersion" to EnrollmentJSON.Value.Integer(1),
                )
            if (outputMode == PhoneOutputMode.MACOS_HID) {
                request.put("role", "physical-input").put("requiredOutputBackend", "macos-hid")
                hello["role"] = EnrollmentJSON.Value.Text("physical-input")
                hello["requiredOutputBackend"] = EnrollmentJSON.Value.Text("macos-hid")
            } else {
                hello["inputEnabled"] = EnrollmentJSON.Value.BooleanValue(false)
            }
            send(request)
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
            credentialExpiresAt = credential.metadata.expiresAt
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
                outputMode.fields(
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
                    )
                ) ||
                value["version"] != EnrollmentJSON.Value.Integer(1) ||
                text("command") != command ||
                text("authorityInstanceId") != endpoint.authorityInstanceID ||
                !EnrollmentInvitation.identity(phone) ||
                epoch <= 0 ||
                epoch.toString() != epochText ||
                !connection.matches(Regex("[0-9a-f]{32}")) ||
                expires <= last ||
                value["inputSessionAvailable"] !=
                    EnrollmentJSON.Value.BooleanValue(controlVersion >= 4) ||
                credential?.let {
                    it.phoneID != phone || it.epoch != epoch || expires > it.expiresAt
                } == true
        )
            throw PhoneControlRejected()
        val receipt =
            PhoneControlMetadata(
                phone,
                epoch,
                connection,
                expires,
                controlVersion >= 4,
                outputMode,
                outputMode.validate(value),
            )
        if (admitted?.let { it.copy(inputEnabled = receipt.inputEnabled) != receipt } == true)
            throw PhoneControlRejected()
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
            if (!disconnect && inputAttempted.get())
                recordInputFailure(PhoneInputFailureStage.HEARTBEAT_STATUS)
            close()
            throw PhoneControlRejected()
        } finally {
            busy.set(false)
        }
    }

    /** Worker-only bootstrap metadata; inspection never admits a grant or touch owner. */
    fun inputConfiguration(): PhoneInputConfiguration {
        worker()
        if (
            (controlVersion !in 4..6 && controlVersion != 9) ||
                admitted == null ||
                inputAttempted.get() ||
                !busy.compareAndSet(false, true)
        )
            throw PhoneControlRejected()
        try {
            if (inputAttempted.get()) throw PhoneControlRejected()
            val connection = admitted!!.connectionID
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "input-configuration")
                    .put("connectionId", connection)
            )
            return PhoneInputConfiguration.decode(receive(), connection, outputMode)
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
            (controlVersion !in 4..6 && controlVersion != 9) ||
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
            PhoneInputGrant.configuration(receive(), connection, map, outputMode)
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
            val grant =
                PhoneInputGrant(
                    receive(),
                    connection,
                    map,
                    datagrams = controlVersion >= 5,
                    outputMode = outputMode,
                )
            inputDeadline = minOf(deadline ?: 0, Math.addExact(requested, grant.lifetime))
            inputElapsedDeadline =
                Math.addExact(startedAt, Math.multiplyExact(grant.lifetime, 1_000_000))
            inputElapsedLast = startedAt
            inputRenewalDue =
                Math.addExact(
                    startedAt,
                    Math.multiplyExact(maxOf(0, grant.lifetime - 25_000), 1_000_000),
                )
            inputSessionID = grant.sessionID
            inputUDPPort = grant.udpPort
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
            val udpPort = grant.udpPort
            if (controlVersion >= 5) {
                route =
                    NativeInputRoute(
                        { elapsed() / 1_000_000 },
                        { datagram?.offer(it) ?: false },
                        delivery::offerInput,
                    )
                // DNS/socket setup runs independently. The UI can immediately
                // start neutral and use TLS even if UDP setup never completes.
                Thread(
                        {
                            val udp =
                                try {
                                    udpPort?.let { datagramFactory(endpoint.host, it) }
                                } catch (_: Exception) {
                                    null
                                }
                            val keep =
                                synchronized(owner) {
                                    if (closed.get()) false
                                    else {
                                        datagram = udp
                                        true
                                    }
                                }
                            if (!keep) udp?.close()
                        },
                        "thumble-input-udp-open",
                    )
                    .apply {
                        isDaemon = true
                        start()
                    }
                inputCheckpoint()
            }
            val admission = PhoneInputAdmission(grant.packet, map, this)
            heartbeat =
                Thread(
                        {
                            var stage = PhoneInputFailureStage.CHECKPOINT
                            try {
                                while (!closed.get()) {
                                    Thread.sleep(if (controlVersion >= 5) 100 else 1000)
                                    if (busy.get()) continue
                                    stage = PhoneInputFailureStage.CHECKPOINT
                                    inputCheckpoint()
                                    if (controlVersion >= 5) {
                                        if (renewalDue()) {
                                            stage = PhoneInputFailureStage.RENEWAL
                                            renewInput(map)
                                        } else
                                            progress(
                                                inputSessionID ?: throw PhoneControlRejected(),
                                                map,
                                            )
                                    } else {
                                        stage = PhoneInputFailureStage.HEARTBEAT_STATUS
                                        status()
                                    }
                                }
                            } catch (_: Exception) {
                                recordInputFailure(stage)
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

    private fun renewalDue(): Boolean =
        (controlVersion == 6 || controlVersion == 9) &&
            inputRenewalDue?.let { elapsed() >= it } == true &&
            (credentialExpiresAt ?: 0) > (admitted?.expiresAt ?: Long.MAX_VALUE)

    private fun renewInput(map: ControlMap) {
        if (!busy.compareAndSet(false, true)) return
        try {
            inputCheckpoint()
            val receipt = admitted ?: throw PhoneControlRejected()
            val session = inputSessionID ?: throw PhoneControlRejected()
            val port = inputUDPPort ?: throw PhoneControlRejected()
            val credentialExpiry = credentialExpiresAt ?: throw PhoneControlRejected()
            val requested = checkpoint()
            val startedAt = elapsed()
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "input-renew")
                    .put("connectionId", receipt.connectionID)
                    .put("sessionId", session)
                    .put("generation", map.generation)
                    .put("revision", map.revision)
            )
            val reply = receive()
            inputCheckpoint()
            val renewal =
                PhoneInputRenewal(
                    reply,
                    receipt.connectionID,
                    map,
                    PhoneInputRenewalScope(session, port, receipt.expiresAt, credentialExpiry),
                    checkpoint(),
                    outputMode,
                )
            val pending = PendingRenewal(renewal, session, requested, startedAt)
            synchronized(owner) {
                inputCheckpoint()
                if (pendingRenewal != null || inputSessionID != session)
                    throw PhoneControlRejected()
                pendingRenewal = pending
            }
            // UI-owned frames commit the handoff. Network work never calls the engine.
            val commitDeadline = Math.addExact(startedAt, 2_000_000_000L)
            while (true) {
                inputCheckpoint()
                if (synchronized(owner) { pending.committed }) break
                if (elapsed() >= commitDeadline) throw PhoneControlRejected()
                Thread.sleep(1)
            }
            requestProgress(renewal.grant.sessionID, map)
            if (route?.acknowledged == null) throw PhoneControlRejected()
        } finally {
            busy.set(false)
        }
    }

    internal inner class BoundInput(grant: InputPacketGrant) {
        private var channel = InputPacketChannel(grant, 65_536, this@PhoneControlClient::offerInput)

        fun submit(sample: InputSample): Boolean {
            try {
                inputThread()
                val pending =
                    synchronized(owner) {
                        inputCheckpoint()
                        pendingRenewal?.also { next ->
                            if (next.previous != inputSessionID || next.committed)
                                throw PhoneControlRejected()
                            val receipt = admitted ?: throw PhoneControlRejected()
                            val delivery = inputDelivery ?: throw PhoneControlRejected()
                            val renewed = next.value
                            val grant = renewed.grant
                            channel =
                                channel.continued(grant.packet, this@PhoneControlClient::offerInput)
                            admitted =
                                PhoneControlMetadata(
                                    receipt.phoneID,
                                    receipt.credentialEpoch,
                                    receipt.connectionID,
                                    renewed.authorizationExpiresAt,
                                    receipt.inputSessionAvailable,
                                    outputMode,
                                    outputMode == PhoneOutputMode.MACOS_HID,
                                )
                            deadline =
                                minOf(
                                    renewed.authorizationExpiresAt,
                                    Math.addExact(next.requested, 60_000),
                                )
                            inputDeadline =
                                minOf(deadline ?: 0, Math.addExact(next.requested, grant.lifetime))
                            inputElapsedDeadline =
                                Math.addExact(
                                    next.started,
                                    Math.multiplyExact(grant.lifetime, 1_000_000),
                                )
                            inputRenewalDue =
                                Math.addExact(
                                    next.started,
                                    Math.multiplyExact(
                                        maxOf(0, grant.lifetime - 25_000),
                                        1_000_000,
                                    ),
                                )
                            inputSessionID = grant.sessionID
                            val reliable = route?.reliable ?: false
                            route?.close()
                            route =
                                NativeInputRoute(
                                    { elapsed() / 1_000_000 },
                                    { datagram?.offer(it) ?: false },
                                    delivery::offerInput,
                                    initiallyReliable = reliable,
                                )
                            inputCheckpoint()
                        }
                    }
                val accepted = channel.submit(sample)
                if (!accepted) throw PhoneControlRejected()
                synchronized(owner) {
                    if (closed.get()) throw PhoneControlRejected()
                    if (pending != null) {
                        if (pendingRenewal !== pending) throw PhoneControlRejected()
                        // Packet zero is already in the ordered writer before the worker may ask
                        // for progress.
                        pending.committed = true
                        pendingRenewal = null
                    }
                }
                return true
            } catch (_: Exception) {
                recordInputFailure(PhoneInputFailureStage.INPUT_SUBMIT)
                this@PhoneControlClient.close()
                channel.close()
                return false
            }
        }

        fun close() = channel.close()
    }

    internal fun bindChannel(grant: InputPacketGrant): BoundInput {
        inputThread()
        inputCheckpoint()
        return BoundInput(grant)
    }

    private fun progress(session: String, map: ControlMap) {
        if (!busy.compareAndSet(false, true)) return
        try {
            requestProgress(session, map)
        } finally {
            busy.set(false)
        }
    }

    private fun requestProgress(session: String, map: ControlMap) {
        var stage = PhoneInputFailureStage.PROGRESS_SEND
        try {
            val connection = admitted?.connectionID ?: throw PhoneControlRejected()
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "input-status")
                    .put("connectionId", connection)
                    .put("sessionId", session)
            )
            stage = PhoneInputFailureStage.PROGRESS_RECEIVE
            val value = receive(progress = true)
            stage = PhoneInputFailureStage.PROGRESS_RECEIPT
            inputCheckpoint()
            if (route?.observe(value, connection, session, map, outputMode) != true)
                throw PhoneControlRejected()
        } catch (error: Exception) {
            recordInputFailure(stage)
            throw error
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
            route?.offer(packet) ?: (inputDelivery?.offerInput(packet) == true)
        } catch (_: Exception) {
            recordInputFailure(PhoneInputFailureStage.INPUT_OFFER)
            close()
            false
        }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        route?.close()
        datagram?.close()
        heartbeat?.interrupt()
        heartbeat = null
        val connected =
            synchronized(owner) {
                val current = io
                io = null
                pendingRenewal = null
                credentialExpiresAt = null
                inputSessionID = null
                inputUDPPort = null
                inputRenewalDue = null
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
