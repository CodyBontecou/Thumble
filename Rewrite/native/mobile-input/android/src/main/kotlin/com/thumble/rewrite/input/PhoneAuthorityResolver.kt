package com.thumble.rewrite.input

import android.os.Looper
import java.io.Closeable
import java.net.InetSocketAddress
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

class PhoneAuthorityResolutionRejected : Exception("phone_authority_resolution_rejected")

/** One-shot pinned-host metadata query, with no credential or input-session access. */
class PhoneAuthorityResolver
internal constructor(
    private val endpoint: TrustedHostEndpoint,
    private val connect: () -> NativeFrameIO,
    private val requireWorker: Boolean = false,
    private val timeoutMillis: Long = 3000,
) : Closeable {
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val gate = Any()
    private var io: NativeFrameIO? = null
    private var startedAt: Long? = null

    init {
        require(timeoutMillis in 1..3000)
    }

    constructor(
        endpoint: TrustedHostEndpoint
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
        true,
    )

    private fun checkpoint() {
        if (
            closed.get() ||
                Thread.currentThread().isInterrupted ||
                startedAt?.let { System.nanoTime() - it >= timeoutMillis * 1_000_000 } == true
        )
            throw PhoneAuthorityResolutionRejected()
    }

    fun resolve(): TrustedHostEndpoint {
        if (
            (requireWorker && Looper.myLooper() == Looper.getMainLooper()) ||
                !started.compareAndSet(false, true)
        )
            throw PhoneAuthorityResolutionRejected()
        startedAt = System.nanoTime()
        val deadline = timer.schedule({ close() }, timeoutMillis, TimeUnit.MILLISECONDS)
        try {
            checkpoint()
            val channel = connect()
            val accepted =
                synchronized(gate) {
                    if (closed.get()) false
                    else {
                        io = channel
                        true
                    }
                }
            if (!accepted) {
                channel.close()
                throw PhoneAuthorityResolutionRejected()
            }
            checkpoint()
            val request =
                JSONObject()
                    .put("version", 1)
                    .put("command", "hello")
                    .put("controlVersion", 3)
                    .put("inputVersion", 1)
                    .put("documentVersion", 1)
                    .put("capabilitiesVersion", 1)
            channel.send(
                ControlTLSFrame(
                    ControlTLSFrame.Kind.CONTROL,
                    request.toString().toByteArray(Charsets.UTF_8),
                )
            )
            val frame = channel.receive()
            checkpoint()
            if (frame.kind != ControlTLSFrame.Kind.CONTROL || frame.payload.size > 4096)
                throw PhoneAuthorityResolutionRejected()
            val reply = EnrollmentJSON.parse(frame.payload)
            val authority =
                (reply["authorityInstanceId"] as? EnrollmentJSON.Value.Text)?.value
                    ?: throw PhoneAuthorityResolutionRejected()
            if (
                !EnrollmentInvitation.identity(authority) ||
                    reply !=
                        mapOf(
                            "version" to EnrollmentJSON.Value.Integer(1),
                            "command" to EnrollmentJSON.Value.Text("hello"),
                            "authorityInstanceId" to EnrollmentJSON.Value.Text(authority),
                            "controlVersion" to EnrollmentJSON.Value.Integer(3),
                            "inputVersion" to EnrollmentJSON.Value.Integer(1),
                            "documentVersion" to EnrollmentJSON.Value.Integer(1),
                            "capabilitiesVersion" to EnrollmentJSON.Value.Integer(1),
                            "inputEnabled" to EnrollmentJSON.Value.BooleanValue(false),
                        )
            )
                throw PhoneAuthorityResolutionRejected()
            checkpoint()
            return TrustedHostEndpoint(
                endpoint.host,
                endpoint.port,
                endpoint.certificatePin,
                authority,
            )
        } finally {
            deadline.cancel(false)
            close()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val channel = synchronized(gate) { io.also { io = null } }
        channel?.close()
    }

    private companion object {
        val timer =
            ScheduledThreadPoolExecutor(1) { runnable ->
                    Thread(runnable, "thumble-authority-deadline").apply { isDaemon = true }
                }
                .apply { removeOnCancelPolicy = true }
    }
}
