package com.thumble.rewrite.input

import android.annotation.TargetApi
import android.content.Context
import android.os.Looper
import java.io.Closeable
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/** Dedicated one-page MANAGEMENT connection; has no input/session APIs. */
class SavedControllerClient
internal constructor(
    private val endpoint: TrustedHostEndpoint,
    private val connect: () -> NativeFrameIO,
    private val load: (String, Long) -> PhoneCredential?,
    private val now: () -> Long,
    private val requireWorker: Boolean = false,
) : Closeable {
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
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
            throw SavedControllerRejected()
        last = time
        return time
    }

    private fun send(value: JSONObject) {
        checkpoint()
        (io ?: throw SavedControllerRejected()).send(
            ControlTLSFrame(
                ControlTLSFrame.Kind.CONTROL,
                value.toString().toByteArray(Charsets.UTF_8),
            )
        )
    }

    private fun receive(): Map<String, EnrollmentJSON.Value> {
        val frame = (io ?: throw SavedControllerRejected()).receive()
        checkpoint()
        if (frame.kind != ControlTLSFrame.Kind.CONTROL || frame.payload.size > 65536)
            throw SavedControllerRejected()
        return EnrollmentJSON.parse(frame.payload, allowNull = true)
    }

    fun read(request: SavedControllerRequest): SavedControllerMap {
        if (
            (requireWorker && Looper.myLooper() == Looper.getMainLooper()) ||
                !started.compareAndSet(false, true)
        )
            throw SavedControllerRejected()
        try {
            checkpoint()
            val channel = connect()
            synchronized(gate) {
                if (closed.get()) {
                    channel.close()
                    throw SavedControllerRejected()
                }
                io = channel
            }
            checkpoint()
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "hello")
                    .put("controlVersion", 8)
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
                    "controlVersion" to EnrollmentJSON.Value.Integer(8),
                    "role" to EnrollmentJSON.Value.Text("management"),
                    "inputVersion" to EnrollmentJSON.Value.Integer(1),
                    "documentVersion" to EnrollmentJSON.Value.Integer(1),
                    "capabilitiesVersion" to EnrollmentJSON.Value.Integer(1),
                    "inputEnabled" to EnrollmentJSON.Value.BooleanValue(false),
                )
            if (hello != expectedHello) throw SavedControllerRejected()
            val credential =
                load(endpoint.certificatePin, checkpoint()) ?: throw SavedControllerRejected()
            checkpoint()
            if (
                credential.metadata.hostPin != endpoint.certificatePin ||
                    last >= credential.metadata.expiresAt
            )
                throw SavedControllerRejected()
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
            val connection =
                (admission["connectionId"] as? EnrollmentJSON.Value.Text)?.value
                    ?: throw SavedControllerRejected()
            val end =
                (admission["expiresAt"] as? EnrollmentJSON.Value.Integer)?.value
                    ?: throw SavedControllerRejected()
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
                    !PhoneCatalogClient.hex(connection, 32) ||
                    end <= last ||
                    end > credential.metadata.expiresAt
            )
                throw SavedControllerRejected()
            // Host absolute expiry and local wall time are different clock domains.
            // The host still enforces its lease; independently cap our local operation.
            val localLimit =
                try {
                    Math.addExact(last, 60_000L)
                } catch (_: ArithmeticException) {
                    throw SavedControllerRejected()
                }
            expires = minOf(end, localLimit)
            send(request.fields(connection))
            return SavedControllerWire.decode(
                receive(),
                request,
                endpoint.authorityInstanceID,
                connection,
            )
        } finally {
            close()
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
