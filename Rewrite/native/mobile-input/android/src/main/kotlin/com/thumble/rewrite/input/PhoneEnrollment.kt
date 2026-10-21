package com.thumble.rewrite.input

import android.annotation.TargetApi
import android.content.Context
import android.os.Looper
import java.io.Closeable
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.json.JSONTokener

class PhoneEnrollmentRejected : Exception("phone_enrollment_rejected")

class EnrollmentInvitation(
    val host: String,
    val port: Int,
    val certificatePin: String,
    val authorityInstanceID: String,
    val windowID: String,
    internal val proof: String,
    val expiresAt: Long,
) {
    init {
        if (
            host.isEmpty() ||
                !scalarText(host) ||
                host.toByteArray(Charsets.UTF_8).size > 253 ||
                host.contains('\u0000') ||
                port !in 1..65535 ||
                !PhoneCredential.pin(certificatePin) ||
                !PhoneCredential.pin(proof) ||
                !identity(authorityInstanceID) ||
                !identity(windowID) ||
                expiresAt <= 0
        )
            throw PhoneEnrollmentRejected()
    }

    override fun toString() = "EnrollmentInvitation([redacted])"

    companion object {
        internal fun scalarText(value: String): Boolean {
            var at = 0
            while (at < value.length) {
                val ch = value[at++]
                if (ch.isHighSurrogate()) {
                    if (at >= value.length || !value[at++].isLowSurrogate()) return false
                } else if (ch.isLowSurrogate()) return false
            }
            return true
        }

        internal fun identity(value: String) = value.matches(Regex("[A-Za-z0-9-]{1,64}"))
    }
}

/**
 * Blocking native enrollment-worker operation. close is terminal and does not wait for socket I/O.
 */
class PhoneEnrollmentClient
internal constructor(
    private val invitation: EnrollmentInvitation,
    private val connect: () -> NativeFrameIO,
    private val save: (PhoneCredential) -> Unit,
    private val now: () -> Long,
    private val requireWorker: Boolean = false,
) : Closeable {
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val owner = Any()
    private var io: NativeFrameIO? = null
    private var last = 0L

    @TargetApi(29)
    constructor(
        invitation: EnrollmentInvitation,
        context: Context,
    ) : this(
        invitation,
        {
            val client =
                ControlTLSClient.connect(
                    InetSocketAddress(invitation.host, invitation.port),
                    invitation.certificatePin,
                )
            object : NativeFrameIO {
                override fun send(frame: ControlTLSFrame) = client.send(frame)

                override fun receive() = client.receive()

                override fun close() = client.close()
            }
        },
        PhoneCredentialVault(context)::save,
        System::currentTimeMillis,
        true,
    )

    private fun checkpoint(invitationRequired: Boolean = false): Long {
        val time = now()
        if (
            closed.get() ||
                Thread.currentThread().isInterrupted ||
                time < 0 ||
                time < last ||
                (invitationRequired && time >= invitation.expiresAt)
        )
            throw PhoneEnrollmentRejected()
        last = time
        return time
    }

    fun enroll(phoneID: String, label: String): PhoneCredentialMetadata {
        if (requireWorker && Looper.myLooper() == Looper.getMainLooper())
            throw PhoneEnrollmentRejected()
        if (
            !EnrollmentInvitation.identity(phoneID) ||
                label.isEmpty() ||
                !EnrollmentInvitation.scalarText(label) ||
                label.toByteArray(Charsets.UTF_8).size > 128 ||
                label.any { it.isISOControl() } ||
                !started.compareAndSet(false, true)
        )
            throw PhoneEnrollmentRejected()
        try {
            checkpoint(true)
            val transport = connect()
            val accepted =
                synchronized(owner) {
                    if (closed.get()) false
                    else {
                        io = transport
                        true
                    }
                }
            if (!accepted) {
                transport.close()
                throw PhoneEnrollmentRejected()
            }
            checkpoint(true)
            fun send(value: JSONObject) {
                checkpoint()
                transport.send(
                    ControlTLSFrame(
                        ControlTLSFrame.Kind.CONTROL,
                        value.toString().toByteArray(Charsets.UTF_8),
                    )
                )
            }
            fun receive(): Map<String, EnrollmentJSON.Value> {
                val frame = transport.receive()
                checkpoint()
                if (frame.kind != ControlTLSFrame.Kind.CONTROL) throw PhoneEnrollmentRejected()
                return EnrollmentJSON.parse(frame.payload)
            }
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "hello")
                    .put("controlVersion", 2)
                    .put("inputVersion", 1)
                    .put("documentVersion", 1)
                    .put("capabilitiesVersion", 1)
            )
            val expected =
                mapOf(
                    "version" to EnrollmentJSON.Value.Integer(1),
                    "command" to EnrollmentJSON.Value.Text("hello"),
                    "authorityInstanceId" to
                        EnrollmentJSON.Value.Text(invitation.authorityInstanceID),
                    "controlVersion" to EnrollmentJSON.Value.Integer(2),
                    "inputVersion" to EnrollmentJSON.Value.Integer(1),
                    "documentVersion" to EnrollmentJSON.Value.Integer(1),
                    "capabilitiesVersion" to EnrollmentJSON.Value.Integer(1),
                    "inputEnabled" to EnrollmentJSON.Value.BooleanValue(false),
                )
            if (receive() != expected) throw PhoneEnrollmentRejected()
            checkpoint(true)
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "enroll")
                    .put("authorityInstanceId", invitation.authorityInstanceID)
                    .put("windowId", invitation.windowID)
                    .put("proof", invitation.proof)
                    .put("phoneId", phoneID)
                    .put("label", label)
            )
            val reply = receive()
            if (
                reply.keys !=
                    setOf(
                        "version",
                        "command",
                        "phoneId",
                        "credentialEpoch",
                        "expiresAt",
                        "credential",
                    ) ||
                    reply["version"] != EnrollmentJSON.Value.Integer(1) ||
                    reply["command"] != EnrollmentJSON.Value.Text("enrolled") ||
                    reply["phoneId"] != EnrollmentJSON.Value.Text(phoneID)
            )
                throw PhoneEnrollmentRejected()
            val epochText =
                (reply["credentialEpoch"] as? EnrollmentJSON.Value.Text)?.value
                    ?: throw PhoneEnrollmentRejected()
            val epoch = epochText.toLongOrNull() ?: throw PhoneEnrollmentRejected()
            val expires =
                (reply["expiresAt"] as? EnrollmentJSON.Value.Integer)?.value
                    ?: throw PhoneEnrollmentRejected()
            val token =
                (reply["credential"] as? EnrollmentJSON.Value.Text)?.value
                    ?: throw PhoneEnrollmentRejected()
            if (
                epoch <= 0 ||
                    epoch.toString() != epochText ||
                    expires <= last ||
                    !PhoneCredential.pin(token)
            )
                throw PhoneEnrollmentRejected()
            val credential =
                PhoneCredential(
                    PhoneCredentialMetadata(invitation.certificatePin, phoneID, epoch, expires),
                    token.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
                )
            save(credential)
            if (checkpoint() >= expires) throw PhoneEnrollmentRejected()
            send(
                JSONObject()
                    .put("version", 1)
                    .put("command", "enrollment-stored")
                    .put("phoneId", phoneID)
                    .put("credentialEpoch", epochText)
            )
            val complete = receive()
            if (
                complete !=
                    mapOf(
                        "version" to EnrollmentJSON.Value.Integer(1),
                        "command" to EnrollmentJSON.Value.Text("enrollment-complete"),
                        "phoneId" to EnrollmentJSON.Value.Text(phoneID),
                        "credentialEpoch" to EnrollmentJSON.Value.Text(epochText),
                        "inputEnabled" to EnrollmentJSON.Value.BooleanValue(false),
                    ) || last >= expires
            )
                throw PhoneEnrollmentRejected()
            return credential.metadata
        } catch (_: Exception) {
            close()
            throw PhoneEnrollmentRejected()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val transport =
            synchronized(owner) {
                val value = io
                io = null
                value
            }
        if (transport != null)
            Thread(
                    {
                        try {
                            transport.close()
                        } catch (_: Exception) {}
                    },
                    "thumble-enrollment-close",
                )
                .apply {
                    isDaemon = true
                    start()
                }
    }
}

/** Strict bounded flat JSON; duplicate decoded keys, unsupported shapes and lossy UTF-8 fail. */
internal object EnrollmentJSON {
    sealed class Value {
        data class Text(val value: String) : Value()

        data class Integer(val value: Long) : Value()

        data class BooleanValue(val value: Boolean) : Value()
    }

    fun parse(bytes: ByteArray): Map<String, Value> {
        if (bytes.size !in 2..65536) throw PhoneEnrollmentRejected()
        val text =
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        var at = 0
        fun space() {
            while (at < text.length && text[at] in "\t\n\r ") at++
        }
        fun string(): String {
            if (at >= text.length || text[at] != '"') throw PhoneEnrollmentRejected()
            val start = at++
            while (at < text.length) {
                val c = text[at++]
                if (c == '\\') {
                    if (at >= text.length) throw PhoneEnrollmentRejected()
                    val escape = text[at++]
                    if (escape == 'u') {
                        if (
                            at + 4 > text.length ||
                                !text.substring(at, at + 4).all {
                                    it in '0'..'9' || it in 'A'..'F' || it in 'a'..'f'
                                }
                        )
                            throw PhoneEnrollmentRejected()
                        at += 4
                    } else if (escape !in "\"\\/bfnrt") throw PhoneEnrollmentRejected()
                } else if (c == '"') {
                    val decoded =
                        JSONTokener(text.substring(start, at)).nextValue() as? String
                            ?: throw PhoneEnrollmentRejected()
                    var index = 0
                    while (index < decoded.length) {
                        val ch = decoded[index++]
                        if (ch.isHighSurrogate()) {
                            if (index >= decoded.length || !decoded[index++].isLowSurrogate())
                                throw PhoneEnrollmentRejected()
                        } else if (ch.isLowSurrogate()) throw PhoneEnrollmentRejected()
                    }
                    return decoded
                } else if (c.code < 32) throw PhoneEnrollmentRejected()
            }
            throw PhoneEnrollmentRejected()
        }
        space()
        if (at >= text.length || text[at++] != '{') throw PhoneEnrollmentRejected()
        space()
        val out = linkedMapOf<String, Value>()
        if (at < text.length && text[at] == '}') {
            at++
            space()
            if (at != text.length) throw PhoneEnrollmentRejected()
            return out
        }
        while (at < text.length) {
            val key = string()
            if (out.containsKey(key)) throw PhoneEnrollmentRejected()
            space()
            if (at >= text.length || text[at++] != ':') throw PhoneEnrollmentRejected()
            space()
            if (at >= text.length) throw PhoneEnrollmentRejected()
            val value =
                if (text[at] == '"') Value.Text(string())
                else {
                    val start = at
                    while (at < text.length && text[at] !in "\t\n\r ,}") at++
                    val token = text.substring(start, at)
                    when (token) {
                        "true" -> Value.BooleanValue(true)
                        "false" -> Value.BooleanValue(false)
                        else -> {
                            if (
                                token.isEmpty() ||
                                    !token.all { it in '0'..'9' } ||
                                    (token.length > 1 && token[0] == '0')
                            )
                                throw PhoneEnrollmentRejected()
                            Value.Integer(token.toLongOrNull() ?: throw PhoneEnrollmentRejected())
                        }
                    }
                }
            out[key] = value
            space()
            if (at >= text.length) throw PhoneEnrollmentRejected()
            if (text[at] == '}') {
                at++
                space()
                if (at != text.length) throw PhoneEnrollmentRejected()
                return out
            }
            if (text[at++] != ',') throw PhoneEnrollmentRejected()
            space()
        }
        throw PhoneEnrollmentRejected()
    }
}
