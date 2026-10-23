package com.thumble.rewrite.input

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import org.junit.Assert.*
import org.junit.Test

class NativeDatagramTest {
    @Test
    fun nativeUdpDeliversExactPacketAndClosesTerminally() {
        DatagramSocket(0, InetAddress.getLoopbackAddress()).use { server ->
            server.soTimeout = 2000
            val client =
                NativeDatagramDelivery(
                    InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort)
                )
            try {
                val packet = ByteArray(108) { it.toByte() }
                assertTrue(client.offer(packet))
                val received = DatagramPacket(ByteArray(109), 109)
                server.receive(received)
                assertEquals(108, received.length)
                assertArrayEquals(packet, received.data.copyOf(received.length))
                assertFalse(client.offer(ByteArray(109)))
                client.close()
                assertFalse(client.offer(packet))
            } finally {
                client.close()
            }
        }
    }
}
