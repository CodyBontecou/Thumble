package expo.modules.tappinglink

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import okhttp3.*
import java.net.Socket
import java.net.InetAddress
import java.net.URI
import android.util.Base64
import javax.net.SocketFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.*
import java.util.concurrent.TimeUnit
import java.util.UUID
import android.os.SystemClock

class TappingLinkModule : Module() {
  private var datagram: SecureDatagram? = null
  private var host: String? = null
  private var socket: WebSocket? = null
  private var client: OkHttpClient? = null
  private var connectionId: String? = null
  override fun definition() = ModuleDefinition {
    Name("TappingLink")
    Events("status", "message")
    Function("connect") { url: String, pin: String -> connect(url, pin) }
    Function("send") { text: String -> send(text) }
    Function("canSendInput") { transport: String ->
      synchronized(this@TappingLinkModule) {
        if (transport == "udp") datagram?.canSend == true
        else socket?.let { it.queueSize() < 2048 } ?: false
      }
    }
    Function("sendTimed") { text: String ->
      val sentAt = SystemClock.elapsedRealtimeNanos() / 1_000_000.0
      if (send(text)) sentAt else -1.0
    }
    Function("configureDatagram") { port: Int, key: String -> configureDatagram(port, key) }
    Function("sendDatagram") { text: String ->
      val sentAt = SystemClock.elapsedRealtimeNanos() / 1_000_000.0
      if (datagram?.send(text) == true) sentAt else -1.0
    }
    Function("disconnect") { close() }
    OnDestroy { close() }
  }
  @Synchronized private fun configureDatagram(port: Int, encoded: String): Boolean {
    datagram?.close(); datagram = null
    val address = host ?: return false
    val id = connectionId ?: return false
    if (port !in 1..65535) return false
    return runCatching {
      val udp = SecureDatagram(address, port, Base64.decode(encoded, Base64.NO_WRAP)) { text, receivedAt ->
        synchronized(this@TappingLinkModule) {
          if (connectionId == id) sendEvent("message", mapOf("value" to text, "id" to id, "receivedAt" to receivedAt, "transport" to "udp"))
        }
      }
      datagram = udp; udp.start(); true
    }.getOrDefault(false)
  }
  @Synchronized private fun send(text: String): Boolean {
    val current = socket
    if (text.toByteArray().size > 65536 || current == null || current.queueSize() > 262144) {
      val id = connectionId
      close()
      if (id != null) sendEvent("status", mapOf("value" to "Connection stalled", "id" to id))
      return false
    }
    return current.send(text)
  }
  @Synchronized private fun close() { datagram?.close(); datagram = null; host = null; connectionId = null; socket?.cancel(); socket = null; client?.dispatcher?.cancelAll(); client?.connectionPool?.evictAll(); client = null }
  @Synchronized private fun connect(url: String, pin: String): String {
    close()
    require(url.startsWith("wss://") && pin.matches(Regex("[a-f0-9]{64}"))) { "Invalid pairing link" }
    host = URI(url).host
    val id = UUID.randomUUID().toString()
    connectionId = id
    val trust = object : X509TrustManager {
      override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
      override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) { throw CertificateException("Client trust is unsupported") }
      override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
        if (chain.isEmpty()) throw CertificateException("Missing Mac certificate")
        val hash = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded).joinToString("") { "%02x".format(it.toInt() and 255) }
        if (hash != pin) throw CertificateException("Mac certificate does not match the QR code")
        chain[0].checkValidity()
      }
    }
    val tls = SSLContext.getInstance("TLS"); tls.init(null, arrayOf(trust), SecureRandom())
    // Exact leaf-certificate pin is the authority for this isolated client (the QR uses a LAN IP).
    val local = OkHttpClient.Builder().socketFactory(NoDelaySocketFactory()).sslSocketFactory(tls.socketFactory, trust)
      .hostnameVerifier { _, _ -> true }.connectTimeout(5, TimeUnit.SECONDS).readTimeout(0, TimeUnit.MILLISECONDS).build()
    client = local
    socket = local.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
      override fun onOpen(webSocket: WebSocket, response: Response) = synchronized(this@TappingLinkModule) { if (client === local) sendEvent("status", mapOf("value" to "open", "id" to id)) }
      override fun onMessage(webSocket: WebSocket, text: String) = synchronized(this@TappingLinkModule) {
        if (client !== local) return@synchronized
        if (text.toByteArray().size > 65536) { close(); sendEvent("status", mapOf("value" to "Receiver message too large", "id" to id)) }
        else sendEvent("message", mapOf("value" to text, "id" to id, "receivedAt" to SystemClock.elapsedRealtimeNanos() / 1_000_000.0))
      }
      override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = synchronized(this@TappingLinkModule) { if (client === local) { close(); sendEvent("status", mapOf("value" to "Mac disconnected", "id" to id)) } }
      override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = synchronized(this@TappingLinkModule) { if (client === local) { close(); sendEvent("status", mapOf("value" to (t.message ?: "Connection failed"), "id" to id)) } }
    })
    return id
  }
}

// Send small controller reports immediately instead of waiting for Nagle coalescing.
private class NoDelaySocketFactory : SocketFactory() {
  private val delegate = SocketFactory.getDefault()
  private fun immediate(socket: Socket): Socket = socket.apply { tcpNoDelay = true }
  override fun createSocket(): Socket = immediate(delegate.createSocket())
  override fun createSocket(host: String, port: Int): Socket = immediate(delegate.createSocket(host, port))
  override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket = immediate(delegate.createSocket(host, port, local, localPort))
  override fun createSocket(host: InetAddress, port: Int): Socket = immediate(delegate.createSocket(host, port))
  override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int): Socket = immediate(delegate.createSocket(host, port, local, localPort))
}
