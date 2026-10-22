package com.thumble.rewrite.input

import java.io.Closeable
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress

internal interface NativeDatagramIO : Closeable {
    fun offer(packet: ByteArray): Boolean
}

/** Construct on the native control worker; sampling never waits for DNS/socket I/O. */
internal class NativeDatagramDelivery(address: InetSocketAddress) : NativeDatagramIO {
    private val socket = DatagramSocket()
    private val gate = Object()
    private var closed = false
    private var latest: ByteArray? = null

    init {
        try {
            require(!address.isUnresolved && address.port in 1..65535)
            socket.connect(address)
            Thread({ writeLoop() }, "thumble-input-udp").apply {
                isDaemon = true
                start()
            }
        } catch (error: Exception) {
            socket.close()
            throw error
        }
    }

    override fun offer(packet: ByteArray): Boolean =
        synchronized(gate) {
            if (closed || packet.size != 108) return false
            latest = packet.copyOf()
            gate.notifyAll()
            true
        }

    private fun writeLoop() {
        try {
            while (true) {
                val packet =
                    synchronized(gate) {
                        while (!closed && latest == null) gate.wait()
                        if (closed) return
                        latest!!.also { latest = null }
                    }
                socket.send(DatagramPacket(packet, packet.size))
            }
        } catch (_: Exception) {
            close()
        }
    }

    override fun close() {
        synchronized(gate) {
            if (closed) return
            closed = true
            latest = null
            gate.notifyAll()
        }
        Thread({ socket.close() }, "thumble-input-udp-close").apply {
            isDaemon = true
            start()
        }
    }
}
