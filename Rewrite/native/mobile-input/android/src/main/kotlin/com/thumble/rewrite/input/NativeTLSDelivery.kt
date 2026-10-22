package com.thumble.rewrite.input

import java.io.Closeable
import java.net.InetSocketAddress
import java.util.ArrayDeque

internal interface NativeFrameIO : Closeable {
    fun send(frame: ControlTLSFrame)

    fun receive(): ControlTLSFrame
}

/**
 * Bounded native delivery owner, independent of React and the input/UI sampling thread. Call
 * offerInput directly from InputPacketChannel's synchronous sink. It never waits for socket I/O. A
 * ready TLS transport still needs authenticated enrollment/configuration before input admission.
 * close is terminal; a new connection and fresh packet grant are required after any failure.
 */
class NativeTLSDelivery private constructor(initial: NativeFrameIO?, connect: () -> NativeFrameIO) :
    Closeable {
    internal constructor(connect: () -> NativeFrameIO) : this(null, connect)

    internal constructor(raw: NativeFrameIO) : this(raw, { raw })

    enum class State {
        CONNECTING,
        READY,
        CLOSED,
    }

    private val gate = Object()
    private var current = if (initial == null) State.CONNECTING else State.READY
    private var io: NativeFrameIO? = initial
    private val controls = ArrayDeque<ControlTLSFrame>()
    private val received = ArrayDeque<ControlTLSFrame>()
    private var latestInput: ControlTLSFrame? = null
    val state: State
        get() = synchronized(gate) { current }

    init {
        Thread({ writeLoop { initial ?: connect() } }, "thumble-native-tls-writer")
            .apply { isDaemon = true }
            .start()
    }

    fun offerInput(packet: ByteArray): Boolean {
        val frame =
            try {
                ControlTLSFrame(ControlTLSFrame.Kind.INPUT, packet)
            } catch (_: Exception) {
                close()
                return false
            }
        synchronized(gate) {
            if (current != State.READY) return false
            latestInput = frame
            gate.notifyAll()
            return true
        }
    }

    fun offerControl(payload: ByteArray): Boolean {
        val frame =
            try {
                ControlTLSFrame(ControlTLSFrame.Kind.CONTROL, payload)
            } catch (_: Exception) {
                close()
                return false
            }
        synchronized(gate) {
            if (current != State.READY) return false
            if (controls.size < 8) {
                controls.addLast(frame)
                gate.notifyAll()
                return true
            }
        }
        close()
        return false
    }

    /** Pull from the native control owner; never expose grant payloads to a React sample queue. */
    fun pollControl(): ControlTLSFrame? =
        synchronized(gate) {
            if (current == State.READY) received.pollFirst() else null
        }

    private fun writeLoop(connect: () -> NativeFrameIO) {
        try {
            val transport = connect()
            val accepted =
                synchronized(gate) {
                    if (current == State.CLOSED) false
                    else {
                        io = transport
                        current = State.READY
                        true
                    }
                }
            if (!accepted) {
                transport.close()
                return
            }
            Thread({ readLoop(transport) }, "thumble-native-tls-reader")
                .apply { isDaemon = true }
                .start()
            while (true) {
                val frame =
                    synchronized(gate) {
                        while (
                            current == State.READY && controls.isEmpty() && latestInput == null
                        ) gate.wait()
                        if (current != State.READY) return
                        if (controls.isNotEmpty()) controls.removeFirst()
                        else latestInput!!.also { latestInput = null }
                    }
                transport.send(frame)
            }
        } catch (_: Exception) {
            close()
        }
    }

    private fun readLoop(transport: NativeFrameIO) {
        try {
            while (state == State.READY) {
                val frame = transport.receive()
                synchronized(gate) {
                    if (current != State.READY) return
                    if (frame.kind != ControlTLSFrame.Kind.CONTROL || received.size >= 8)
                        throw ControlTLSRejected()
                    received.addLast(frame)
                }
            }
        } catch (_: Exception) {
            close()
        }
    }

    override fun close() {
        val transport =
            synchronized(gate) {
                if (current == State.CLOSED) return
                current = State.CLOSED
                controls.clear()
                received.clear()
                latestInput = null
                gate.notifyAll()
                io.also { io = null }
            }
        // The UI/input caller must never wait for platform TLS shutdown or an in-flight socket
        // operation.
        // The terminal transition above permits at most one closer for this connection.
        if (transport != null)
            Thread(
                    {
                        try {
                            transport.close()
                        } catch (_: Exception) {}
                    },
                    "thumble-native-tls-close",
                )
                .apply { isDaemon = true }
                .start()
    }

    companion object {
        fun connect(address: InetSocketAddress, certificatePin: String): NativeTLSDelivery =
            NativeTLSDelivery {
                val client = ControlTLSClient.connect(address, certificatePin)
                object : NativeFrameIO {
                    override fun send(frame: ControlTLSFrame) = client.send(frame)

                    override fun receive(): ControlTLSFrame = client.receive()

                    override fun close() = client.close()
                }
            }
    }
}
