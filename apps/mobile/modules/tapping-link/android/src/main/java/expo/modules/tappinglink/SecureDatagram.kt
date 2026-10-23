package expo.modules.tappinglink

import android.os.SystemClock
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.util.concurrent.atomic.AtomicBoolean

internal class SecureDatagram(host: String, port: Int, key: ByteArray, private val event: (String, Double) -> Unit) {
  private val cipher = DatagramCipher(key, false)
  private val channel = DatagramChannel.open().apply { configureBlocking(false); connect(InetSocketAddress(host, port)) }
  private val selector = Selector.open().also { channel.register(it, SelectionKey.OP_READ) }
  private val stopped = AtomicBoolean(false)
  val canSend: Boolean get() = !stopped.get() && channel.isOpen && channel.isConnected
  fun start() {
    Thread({
      try {
        send("{\"type\":\"probe\"}")
        var probes = 1
        var confirmed = false
        val buffer = ByteBuffer.allocate(1129)
        while (!stopped.get()) {
          if (selector.select(200) == 0) {
            if (!confirmed && probes < 8) { send("{\"type\":\"probe\"}"); probes++ }
            continue
          }
          selector.selectedKeys().clear()
          buffer.clear()
          val count = channel.read(buffer)
          val receivedAt = SystemClock.elapsedRealtimeNanos() / 1_000_000.0
          if (count <= 0) continue
          val clear = runCatching { cipher.open(buffer.array().copyOf(count)) }.getOrNull() ?: continue
          confirmed = true
          event(String(clear, Charsets.UTF_8), receivedAt)
        }
      } catch (_: Exception) { /* WebSocket control and receiver watchdog remain active. */ }
    }, "Tapping-UDP").apply { isDaemon = true; start() }
  }
  @Synchronized fun send(text: String): Boolean {
    if (stopped.get()) return false
    return runCatching {
      val packet = cipher.seal(text.toByteArray(Charsets.UTF_8))
      channel.write(ByteBuffer.wrap(packet)) == packet.size
    }.getOrDefault(false)
  }
  fun close() { stopped.set(true); runCatching { selector.close() }; runCatching { channel.close() } }
}
