package com.thumble.android

import java.net.InetAddress
import java.net.Socket
import javax.net.SocketFactory

/** Keep small WebSocket input mirrors from waiting for Nagle's algorithm, as on iOS. */
internal class NoDelaySocketFactory : SocketFactory() {
    private val delegate = getDefault()
    override fun createSocket(): Socket = delegate.createSocket().apply { tcpNoDelay = true }
    override fun createSocket(host: String, port: Int): Socket = delegate.createSocket(host, port).apply { tcpNoDelay = true }
    override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket =
        delegate.createSocket(host, port, local, localPort).apply { tcpNoDelay = true }
    override fun createSocket(host: InetAddress, port: Int): Socket = delegate.createSocket(host, port).apply { tcpNoDelay = true }
    override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int): Socket =
        delegate.createSocket(host, port, local, localPort).apply { tcpNoDelay = true }
}
