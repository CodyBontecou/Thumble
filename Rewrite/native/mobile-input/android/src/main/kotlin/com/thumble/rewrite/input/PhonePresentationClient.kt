package com.thumble.rewrite.input

import android.annotation.TargetApi
import android.content.Context
import android.os.Looper
import java.io.Closeable
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/** Dedicated bounded presentation batch; close after metadata and referenced icons. */
class PhonePresentationClient
internal constructor(
    private val endpoint: TrustedHostEndpoint,
    private val connect: () -> NativeFrameIO,
    private val load: (String, Long) -> PhoneCredential?,
    private val now: () -> Long,
    private val requireWorker: Boolean = false,
) : Closeable {
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val busy = AtomicBoolean(false)
    private var connection: String? = null
    private var metadata: PhonePresentationMetadata? = null
    private var iconRequests = 0
    private val gate = Any()
    @Volatile private var io: NativeFrameIO? = null
    private var last = 0L
    private var expires: Long? = null

    @TargetApi(29)
    constructor(
        endpoint: TrustedHostEndpoint,
        context: Context,
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
    )

    private fun checkpoint(): Long {
        val time = now()
        if (closed.get() || time < last || expires?.let { time >= it } == true)
            throw PhonePresentationRejected()
        last = time
        return time
    }

    private fun send(value: JSONObject) {
        checkpoint()
        (io ?: throw PhonePresentationRejected()).send(
            ControlTLSFrame(
                ControlTLSFrame.Kind.CONTROL,
                value.toString().toByteArray(Charsets.UTF_8),
            )
        )
    }

    private fun receive(limit: Int = 4096): Map<String, EnrollmentJSON.Value> {
        val frame = (io ?: throw PhonePresentationRejected()).receive()
        checkpoint()
        if (frame.kind != ControlTLSFrame.Kind.CONTROL || frame.payload.size > limit)
            throw PhonePresentationRejected()
        return EnrollmentJSON.parse(frame.payload, allowNull = true)
    }

    fun read(request: PhonePresentationRequest): PhonePresentationMetadata {
        if (
            (requireWorker && Looper.myLooper() == Looper.getMainLooper()) ||
                !started.compareAndSet(false, true) ||
                !busy.compareAndSet(false, true)
        )
            throw PhonePresentationRejected()
        try {
            checkpoint()
            val channel = connect()
            synchronized(gate) {
                if (closed.get()) {
                    channel.close()
                    throw PhonePresentationRejected()
                }
                io = channel
            }
            checkpoint()
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "hello")
                    .put("controlVersion", 10)
                    .put("role", "management")
                    .put("inputVersion", 1)
                    .put("documentVersion", 1)
                    .put("capabilitiesVersion", 1)
            )
            val hello = receive()
            val expectedHello =
                mapOf(
                    "version" to EnrollmentJSON.Value.Integer(1),
                    "command" to EnrollmentJSON.Value.Text("hello"),
                    "authorityInstanceId" to
                        EnrollmentJSON.Value.Text(endpoint.authorityInstanceID),
                    "controlVersion" to EnrollmentJSON.Value.Integer(10),
                    "role" to EnrollmentJSON.Value.Text("management"),
                    "inputVersion" to EnrollmentJSON.Value.Integer(1),
                    "documentVersion" to EnrollmentJSON.Value.Integer(1),
                    "capabilitiesVersion" to EnrollmentJSON.Value.Integer(1),
                    "inputEnabled" to EnrollmentJSON.Value.BooleanValue(false),
                )
            if (hello != expectedHello) throw PhonePresentationRejected()
            val credential =
                load(endpoint.certificatePin, checkpoint()) ?: throw PhonePresentationRejected()
            checkpoint()
            if (
                credential.metadata.hostPin != endpoint.certificatePin ||
                    last >= credential.metadata.expiresAt
            )
                throw PhonePresentationRejected()
            channel.send(credential.authenticationFrame(endpoint.authorityInstanceID))
            val admission = receive()
            val keys =
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
                    "role",
                )
            val admittedConnection =
                (admission["connectionId"] as? EnrollmentJSON.Value.Text)?.value
                    ?: throw PhonePresentationRejected()
            val end =
                (admission["expiresAt"] as? EnrollmentJSON.Value.Integer)?.value
                    ?: throw PhonePresentationRejected()
            if (
                admission.keys != keys ||
                    admission["version"] != EnrollmentJSON.Value.Integer(1) ||
                    admission["command"] != EnrollmentJSON.Value.Text("authenticated") ||
                    admission["authorityInstanceId"] !=
                        EnrollmentJSON.Value.Text(endpoint.authorityInstanceID) ||
                    admission["phoneId"] !=
                        EnrollmentJSON.Value.Text(credential.metadata.phoneID) ||
                    admission["credentialEpoch"] !=
                        EnrollmentJSON.Value.Text(credential.metadata.epoch.toString()) ||
                    admission["inputSessionAvailable"] !=
                        EnrollmentJSON.Value.BooleanValue(false) ||
                    admission["inputEnabled"] != EnrollmentJSON.Value.BooleanValue(false) ||
                    admission["role"] != EnrollmentJSON.Value.Text("management") ||
                    !PhoneCatalogClient.hex(admittedConnection, 32) ||
                    end <= last ||
                    end > credential.metadata.expiresAt
            )
                throw PhonePresentationRejected()
            // Host absolute expiry and local wall time are different clock domains.
            // The host still enforces its lease; independently cap our local operation.
            val localLimit =
                try {
                    Math.addExact(last, 60_000L)
                } catch (_: ArithmeticException) {
                    throw PhonePresentationRejected()
                }
            expires = minOf(end, localLimit)
            connection = admittedConnection
            send(request.fields(admittedConnection))
            val result =
                PhonePresentationWire.metadata(
                    receive(32768),
                    request,
                    endpoint.authorityInstanceID,
                    admittedConnection,
                )
            metadata = result
            return result
        } catch (error: Exception) {
            close()
            if (error is PhonePresentationRejected || error is PhonePresentationUnavailable)
                throw error
            throw PhonePresentationUnavailable("presentation_unavailable")
        } finally {
            busy.set(false)
        }
    }

    fun icon(control: PhonePresentationControl): PhonePresentationIcon {
        if (
            (requireWorker && Looper.myLooper() == Looper.getMainLooper()) ||
                !busy.compareAndSet(false, true)
        )
            throw PhonePresentationRejected()
        try {
            checkpoint()
            val m = metadata ?: throw PhonePresentationRejected()
            val c = connection ?: throw PhonePresentationRejected()
            if (
                control.iconSHA256 == null ||
                    m.controls.none { it === control } ||
                    iconRequests >= 64
            )
                throw PhonePresentationRejected()
            iconRequests++
            send(
                m.request
                    .fields(c)
                    .put("command", "configuration-presentation-icon")
                    .put("presentationRevision", m.presentationRevision)
                    .put("presentationSourceHash", m.presentationSourceHash)
                    .put("controlId", control.id)
                    .put("iconSHA256", control.iconSHA256)
            )
            return PhonePresentationWire.icon(
                receive(16384),
                m,
                control,
                endpoint.authorityInstanceID,
                c,
            )
        } catch (error: Exception) {
            close()
            if (error is PhonePresentationRejected || error is PhonePresentationUnavailable)
                throw error
            throw PhonePresentationUnavailable("presentation_unavailable")
        } finally {
            busy.set(false)
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            synchronized(gate) {
                io?.close()
                io = null
            }
        }
    }
}
