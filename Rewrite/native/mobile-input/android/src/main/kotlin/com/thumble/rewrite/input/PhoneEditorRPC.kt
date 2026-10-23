package com.thumble.rewrite.input

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

internal data class EditorAuthenticatedReply(
    val scope: EditorHostScope,
    val phoneID: String,
    val credentialEpoch: Long,
    val connectionID: String,
    val reply: EditorReply,
)

internal interface EditorRPCTransport {
    fun exchange(request: EditorRequest): EditorAuthenticatedReply

    /** Close the current IO. Return does not prove the owner write was cancelled. */
    fun cancel()
}

/** Internal frame adapter. No public/default role12 network factory is enabled. */
internal class PhoneEditorRPC(
    private val endpoint: TrustedHostEndpoint,
    private val connect: () -> NativeFrameIO,
    private val load: (String, Long) -> PhoneCredential?,
    private val now: () -> Long,
) : EditorRPCTransport {
    private val busy = AtomicBoolean(false)
    private val serial = AtomicLong(0)
    private val canceled = AtomicLong(-1)
    @Volatile private var active: NativeFrameIO? = null

    override fun cancel() {
        canceled.set(serial.get())
        try {
            active?.close()
        } catch (_: Exception) {}
    }

    override fun exchange(request: EditorRequest): EditorAuthenticatedReply {
        if (
            request.scope.certificateSHA256 != endpoint.certificatePin ||
                request.scope.authorityInstanceID != endpoint.authorityInstanceID ||
                !busy.compareAndSet(false, true)
        )
            throw PhoneEditorException()
        if (serial.get() == Long.MAX_VALUE) {
            busy.set(false)
            throw PhoneEditorException()
        }
        val identity = serial.incrementAndGet()
        var highwater = 0L
        var expires: Long? = null
        fun checkpoint(): Long {
            val time = now()
            if (
                canceled.get() == identity ||
                    time < highwater ||
                    time < 0 ||
                    expires?.let { time >= it } == true
            )
                throw PhoneEditorException()
            highwater = time
            return time
        }
        try {
            checkpoint()
            val io = connect()
            active = io
            checkpoint()
            fun send(fields: Map<String, Any?>) {
                checkpoint()
                val bytes = JSONObject(fields).toString().toByteArray(Charsets.UTF_8)
                if (bytes.size > 2048) throw PhoneEditorException()
                io.send(ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, bytes))
            }
            fun receive(limit: Int): Map<String, Any?> {
                val frame = io.receive()
                checkpoint()
                if (frame.kind != ControlTLSFrame.Kind.CONTROL || frame.payload.size > limit)
                    throw PhoneEditorException()
                return EditorWire.parse(frame.payload)
            }
            send(
                mapOf(
                    "version" to 1,
                    "command" to "hello",
                    "controlVersion" to 12,
                    "role" to "management",
                    "inputVersion" to 1,
                    "documentVersion" to 1,
                    "capabilitiesVersion" to 1,
                )
            )
            val hello = receive(4096)
            if (
                hello !=
                    mapOf(
                        "version" to 1L,
                        "command" to "hello",
                        "authorityInstanceId" to endpoint.authorityInstanceID,
                        "controlVersion" to 12L,
                        "role" to "management",
                        "inputVersion" to 1L,
                        "documentVersion" to 1L,
                        "capabilitiesVersion" to 1L,
                        "inputEnabled" to false,
                    )
            )
                throw PhoneEditorException()
            val credential =
                load(endpoint.certificatePin, checkpoint()) ?: throw PhoneEditorException()
            checkpoint()
            if (
                credential.metadata.hostPin != endpoint.certificatePin ||
                    highwater >= credential.metadata.expiresAt
            )
                throw PhoneEditorException()
            io.send(credential.authenticationFrame(endpoint.authorityInstanceID))
            val admission = receive(4096)
            EditorWire.keys(
                admission,
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
                ),
            )
            val connection = admission["connectionId"] as? String ?: throw PhoneEditorException()
            val end = admission["expiresAt"] as? Long ?: throw PhoneEditorException()
            if (
                admission["version"] != 1L ||
                    admission["command"] != "authenticated" ||
                    admission["authorityInstanceId"] != endpoint.authorityInstanceID ||
                    admission["phoneId"] != credential.metadata.phoneID ||
                    admission["credentialEpoch"] != credential.metadata.epoch.toString() ||
                    admission["inputSessionAvailable"] != false ||
                    admission["inputEnabled"] != false ||
                    admission["role"] != "management" ||
                    !EditorWire.hex(connection, 32) ||
                    end <= highwater ||
                    end > credential.metadata.expiresAt
            )
                throw PhoneEditorException()
            expires =
                minOf(
                    end,
                    try {
                        Math.addExact(highwater, 60_000L)
                    } catch (_: ArithmeticException) {
                        throw PhoneEditorException()
                    },
                )
            send(request.fields(connection))
            val frame = io.receive()
            checkpoint()
            if (frame.kind != ControlTLSFrame.Kind.CONTROL || frame.payload.size > 16384)
                throw PhoneEditorException()
            val reply = EditorWire.reply(frame.payload, request, connection)
            checkpoint()
            return EditorAuthenticatedReply(
                request.scope,
                credential.metadata.phoneID,
                credential.metadata.epoch,
                connection,
                reply,
            )
        } catch (error: PhoneEditorException) {
            throw error
        } catch (_: Exception) {
            throw PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE)
        } finally {
            try {
                active?.close()
            } catch (_: Exception) {}
            active = null
            busy.set(false)
        }
    }
}
