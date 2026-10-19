package com.thumble.android

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.net.Inet4Address
import java.net.URI

internal interface MacDiscovery {
    fun start(serverID: String?, serviceName: String?, resolved: (List<String>) -> Unit)
    fun stop()
}

/** Resolve only the QR/trusted server's existing _pocketpad._tcp advertisement. */
@Suppress("DEPRECATION")
internal class NsdMacDiscovery(context: Context) : MacDiscovery {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var generation = 0L
    private var listener: NsdManager.DiscoveryListener? = null
    private var expectedID: String? = null
    private var expectedName: String? = null
    private val pending = ArrayDeque<NsdServiceInfo>()
    private val seen = mutableSetOf<String>()
    private val retries = mutableMapOf<String, Int>()
    private var resolving = false

    @Synchronized override fun start(serverID: String?, serviceName: String?, resolved: (List<String>) -> Unit) {
        if (serverID == null && serviceName == null) return
        if (listener != null && expectedID == serverID && expectedName == serviceName) return
        stop()
        expectedID = serverID; expectedName = serviceName
        val epoch = generation
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onServiceLost(service: NsdServiceInfo) {
                synchronized(this@NsdMacDiscovery) { if (epoch == generation) seen.remove(service.serviceName) }
            }
            override fun onStartDiscoveryFailed(type: String, code: Int) { retire(epoch) }
            override fun onStopDiscoveryFailed(type: String, code: Int) { retire(epoch) }
            override fun onServiceFound(service: NsdServiceInfo) {
                synchronized(this@NsdMacDiscovery) {
                    if (epoch != generation || !service.serviceType.trimEnd('.').equals("_pocketpad._tcp", true)) return
                    if (serviceName != null && service.serviceName != serviceName) return
                    if (seen.size >= 64 || !seen.add(service.serviceName)) return
                    pending.addLast(service)
                    next(epoch, resolved)
                }
            }
        }
        listener = discovery
        runCatching { manager.discoverServices("_pocketpad._tcp.", NsdManager.PROTOCOL_DNS_SD, discovery) }
            .onFailure { retire(epoch) }
    }

    @Synchronized private fun next(epoch: Long, resolved: (List<String>) -> Unit) {
        if (epoch != generation || resolving || pending.isEmpty()) return
        val service = pending.removeFirst()
        resolving = true
        runCatching { manager.resolveService(service, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                synchronized(this@NsdMacDiscovery) {
                    if (epoch != generation) return
                    resolving = false
                    val attempts = retries.getOrDefault(service.serviceName, 0) + 1
                    retries[service.serviceName] = attempts
                    if (attempts <= 3) handler.postDelayed({
                        synchronized(this@NsdMacDiscovery) {
                            if (epoch == generation) { pending.addLast(service); next(epoch, resolved) }
                        }
                    }, 500)
                    next(epoch, resolved)
                }
            }
            override fun onServiceResolved(info: NsdServiceInfo) {
                synchronized(this@NsdMacDiscovery) {
                    if (epoch != generation) return
                    resolving = false
                    val id = info.attributes["id"]?.toString(Charsets.UTF_8)
                    if ((expectedID == null || id == expectedID) && info.port in 1..65535) {
                        val addresses = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
                        val urls = addresses.sortedBy { it !is Inet4Address }
                            .filterNot { it.isAnyLocalAddress || it.isLoopbackAddress }
                            .mapNotNull { address ->
                                runCatching { URI("ws", null, address.hostAddress, info.port, null, null, null).toASCIIString() }.getOrNull()
                            }.distinct().take(16)
                        if (urls.isNotEmpty()) resolved(urls)
                    }
                    next(epoch, resolved)
                }
            }
        }) }.onFailure { resolving = false; next(epoch, resolved) }
    }

    @Synchronized private fun retire(epoch: Long) { if (epoch == generation) stop() }
    @Synchronized override fun stop() {
        ++generation
        listener?.let { runCatching { manager.stopServiceDiscovery(it) } }
        listener = null
        pending.clear(); seen.clear(); retries.clear(); resolving = false
    }
}
