package com.thumble.rewrite.input

import android.annotation.TargetApi
import java.io.Closeable
import java.io.EOFException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedTrustManager

class ControlTLSRejected : Exception("control_tls_rejected")

class ControlTLSFrame(val kind: Kind, payload: ByteArray) {
    enum class Kind(val byte: Int) {
        CONTROL(1),
        INPUT(2),
    }

    private val bytes: ByteArray
    val payload: ByteArray
        get() = bytes.copyOf()

    init {
        if (
            (kind == Kind.CONTROL && payload.size !in 1..65536) ||
                (kind == Kind.INPUT && payload.size != 108)
        )
            throw ControlTLSRejected()
        bytes = payload.copyOf()
    }

    // Routing only; the independent receiver authenticates every packet.
    internal val startsInputGrant: Boolean
        get() =
            kind == Kind.INPUT &&
                bytes[0] == 84.toByte() &&
                bytes[1] == 72.toByte() &&
                bytes[2] == 73.toByte() &&
                bytes[3] == 49.toByte() &&
                (4 until 8).all { bytes[it] == 0.toByte() } &&
                (32 until 40).all { bytes[it] == 0.toByte() }

    fun encode(): ByteArray {
        val size = bytes.size + 1
        return byteArrayOf(
            (size ushr 24).toByte(),
            (size ushr 16).toByte(),
            (size ushr 8).toByte(),
            size.toByte(),
            kind.byte.toByte(),
        ) + bytes
    }

    companion object {
        fun bodyLength(prefix: ByteArray): Int {
            if (prefix.size != 4) throw ControlTLSRejected()
            var value = 0L
            for (b in prefix) value = (value shl 8) or (b.toLong() and 255)
            if (value !in 2..65537) throw ControlTLSRejected()
            return value.toInt()
        }

        fun decodeBody(body: ByteArray): ControlTLSFrame {
            val kind =
                Kind.entries.find { it.byte == body.firstOrNull()?.toInt() }
                    ?: throw ControlTLSRejected()
            return ControlTLSFrame(kind, body.copyOfRange(1, body.size))
        }
    }
}

/**
 * Host-authenticated TLS only. Blocking operations require bounded native reader/writer workers.
 * Platform TLS 1.3/ALPN requires Android API 29; input core API 26 remains independent. A fresh
 * SSLContext per connection prevents resuming an old session. No early data is sent.
 */
@TargetApi(29)
class ControlTLSClient private constructor(private val socket: SSLSocket, private val raw: Socket) :
    Closeable {
    private val sending = AtomicBoolean(false)
    private val receiving = AtomicBoolean(false)
    @Volatile private var closed = false
    private val firstFailure = AtomicReference<NativeTLSOperationFailure?>(null)
    internal val failureCategory: NativeTLSExceptionCategory?
        get() = firstFailure.get()?.category

    internal val operationFailure: NativeTLSOperationFailure?
        get() = firstFailure.get()

    private inline fun <T> operation(direction: AtomicBoolean, block: () -> T): T {
        if (!direction.compareAndSet(false, true)) throw ControlTLSRejected()
        try {
            if (closed) throw ControlTLSRejected()
            val operationDirection =
                if (direction === sending) NativeTLSOperationDirection.SEND
                else NativeTLSOperationDirection.RECEIVE
            val expiry =
                watchdog.schedule(
                    {
                        firstFailure.compareAndSet(
                            null,
                            NativeTLSOperationFailure(
                                operationDirection,
                                NativeTLSOperationFailureKind.DEADLINE,
                                NativeTLSExceptionCategory.TIMEOUT,
                            ),
                        )
                        close()
                    },
                    2,
                    TimeUnit.SECONDS,
                )
            return try {
                block()
            } catch (error: Exception) {
                firstFailure.compareAndSet(
                    null,
                    NativeTLSOperationFailure(
                        operationDirection,
                        NativeTLSOperationFailureKind.IO,
                        tlsExceptionCategory(error),
                    ),
                )
                close()
                throw ControlTLSRejected()
            } finally {
                expiry.cancel(false)
            }
        } finally {
            direction.set(false)
        }
    }

    fun send(frame: ControlTLSFrame) =
        operation(sending) {
            socket.outputStream.write(frame.encode())
            socket.outputStream.flush()
        }

    fun receive(): ControlTLSFrame =
        operation(receiving) {
            val prefix = exact(socket.inputStream, 4)
            ControlTLSFrame.decodeBody(
                exact(socket.inputStream, ControlTLSFrame.bodyLength(prefix))
            )
        }

    /** Can be called from lifecycle/watchdog threads to interrupt blocked I/O. Terminal. */
    override fun close() {
        closed = true
        // Abort TCP first so a stalled TLS writer cannot hold shutdown or the deadline watchdog.
        try {
            raw.close()
        } catch (_: Exception) {}
        try {
            socket.close()
        } catch (_: Exception) {}
    }

    companion object {
        const val SERVER_NAME = "thumble-rewrite.local"
        const val ALPN = "thumble-rewrite-control/1"
        private val watchdog =
            ScheduledThreadPoolExecutor(1) { runnable ->
                    Thread(runnable, "thumble-tls-deadline").apply { isDaemon = true }
                }
                .apply { removeOnCancelPolicy = true }

        private fun exact(input: InputStream, length: Int): ByteArray {
            val result = ByteArray(length)
            var offset = 0
            while (offset < length) {
                val count = input.read(result, offset, length - offset)
                if (count <= 0) throw EOFException()
                offset += count
            }
            return result
        }

        fun connect(address: InetSocketAddress, certificatePin: String): ControlTLSClient {
            if (
                address.isUnresolved ||
                    address.port == 0 ||
                    !Regex("[0-9a-f]{64}").matches(certificatePin)
            )
                throw ControlTLSRejected()
            val raw = Socket()
            var tls: SSLSocket? = null
            val expiry =
                watchdog.schedule(
                    {
                        try {
                            raw.close()
                        } catch (_: Exception) {}
                    },
                    3,
                    TimeUnit.SECONDS,
                )
            try {
                raw.tcpNoDelay = true
                raw.connect(address, 3000)
                val context = SSLContext.getInstance("TLS")
                context.init(null, arrayOf(PinTrust(certificatePin)), null)
                tls =
                    context.socketFactory.createSocket(raw, SERVER_NAME, address.port, true)
                        as SSLSocket
                if ("TLSv1.3" !in tls.supportedProtocols) throw ControlTLSRejected()
                tls.enabledProtocols = arrayOf("TLSv1.3")
                tls.sslParameters =
                    SSLParameters().apply {
                        protocols = arrayOf("TLSv1.3")
                        endpointIdentificationAlgorithm = "HTTPS"
                        serverNames = listOf(SNIHostName(SERVER_NAME))
                        applicationProtocols = arrayOf(ALPN)
                    }
                tls.soTimeout = 3000
                tls.startHandshake()
                if (tls.session.protocol != "TLSv1.3" || tls.applicationProtocol != ALPN)
                    throw ControlTLSRejected()
                tls.session.invalidate()
                tls.soTimeout = 2000
                return ControlTLSClient(tls, raw)
            } catch (_: Exception) {
                try {
                    tls?.close()
                } catch (_: Exception) {}
                try {
                    raw.close()
                } catch (_: Exception) {}
                throw ControlTLSRejected()
            } catch (_: LinkageError) {
                // API 26–28 providers cannot silently downgrade or skip ALPN/pin validation.
                try {
                    tls?.close()
                } catch (_: Exception) {}
                try {
                    raw.close()
                } catch (_: Exception) {}
                throw ControlTLSRejected()
            } finally {
                expiry.cancel(false)
            }
        }
    }
}

private class PinTrust(private val pin: String) : X509ExtendedTrustManager() {
    private fun verifier(chain: Array<out X509Certificate>?): X509ExtendedTrustManager {
        if (chain == null || chain.size != 1) throw CertificateException("host_pin_mismatch")
        val leaf = chain[0]
        val der = leaf.encoded
        if (
            der.size > 16384 ||
                MessageDigest.getInstance("SHA-256").digest(der).joinToString("") {
                    "%02x".format(it.toInt() and 255)
                } != pin
        )
            throw CertificateException("host_pin_mismatch")
        leaf.checkValidity()
        // A directly trusted leaf can bypass provider EKU checks. Retain server-auth policy
        // explicitly.
        val usages = leaf.extendedKeyUsage
        if (usages != null && "1.3.6.1.5.5.7.3.1" !in usages && "2.5.29.37.0" !in usages) {
            throw CertificateException("host_server_usage_invalid")
        }
        val store = KeyStore.getInstance(KeyStore.getDefaultType())
        store.load(null, null)
        store.setCertificateEntry("exact-pinned-host", leaf)
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(store)
        return factory.trustManagers.filterIsInstance<X509ExtendedTrustManager>().single()
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        throw CertificateException("client_trust_not_supported")
    }

    override fun checkClientTrusted(
        chain: Array<out X509Certificate>?,
        authType: String?,
        socket: Socket?,
    ) {
        throw CertificateException("client_trust_not_supported")
    }

    override fun checkClientTrusted(
        chain: Array<out X509Certificate>?,
        authType: String?,
        engine: SSLEngine?,
    ) {
        throw CertificateException("client_trust_not_supported")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        verifier(chain).checkServerTrusted(chain, authType)
    }

    override fun checkServerTrusted(
        chain: Array<out X509Certificate>?,
        authType: String?,
        socket: Socket?,
    ) {
        verifier(chain).checkServerTrusted(chain, authType, socket)
    }

    override fun checkServerTrusted(
        chain: Array<out X509Certificate>?,
        authType: String?,
        engine: SSLEngine?,
    ) {
        verifier(chain).checkServerTrusted(chain, authType, engine)
    }
}

/** Shared production adapter retains only the fixed TLS failure category. */
internal fun ControlTLSClient.nativeFrames(): NativeFrameIO =
    object : NativeFrameIO {
        override val failureCategory
            get() = this@nativeFrames.failureCategory

        override val operationFailure
            get() = this@nativeFrames.operationFailure

        override fun send(frame: ControlTLSFrame) = this@nativeFrames.send(frame)

        override fun receive() = this@nativeFrames.receive()

        override fun close() = this@nativeFrames.close()
    }
