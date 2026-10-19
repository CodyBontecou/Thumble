package com.thumble.android

import android.os.Build
import android.os.Handler
import android.os.Looper
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.URI
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

internal data class ClientState(
    val status: String = "Ready to connect",
    val connecting: Boolean = false,
    val paired: Boolean = false,
    val needsCode: Boolean = false,
    val error: String? = null,
    val snapshot: ProfileSnapshot = ProfileSnapshot(),
    val udpEnabled: Boolean = true,
    val udpAvailable: Boolean = false,
    val udpFrames: Long = 0,
    val webSocketFrames: Long = 0,
    val canReconnect: Boolean = false,
    val practiceMode: Boolean = false,
    val hapticIntensity: Double = 1.0,
    val preferencesError: String? = null,
    val viewingSaved: Boolean = false,
    val virtualGamepadStatus: JSONObject? = null,
    val capabilities: Set<String> = emptySet(),
    val pendingSkinChanges: Int = 0,
    val surfaceRevision: Long = 0
)

/** All session state, socket writes, hold refreshes, and touch edges run on one queue. */
internal class ControllerClient(private val store: SessionStore = MemorySessionStore(), private val discovery: MacDiscovery? = null, private val skinArchive: (SkinReference) -> ByteArray? = { null }, private val incomingSkins: (IncomingSkinPackages) -> Boolean = { true }, private val publish: (ClientState) -> Unit) {
    private val queue = Executors.newSingleThreadScheduledExecutor { task -> Thread(task, "Thumble input") }
    private val main = Handler(Looper.getMainLooper())
    private val http = OkHttpClient.Builder().socketFactory(NoDelaySocketFactory()).connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS).pingInterval(5, TimeUnit.SECONDS).build()
    private var state = ClientState()
    private var socket: WebSocket? = null
    private var udp: DatagramSocket? = null
    private var heartbeat: ScheduledFuture<*>? = null
    private var deadline: ScheduledFuture<*>? = null
    private var inputs: InputSession? = null
    private var target: PairingTarget? = null
    private var addressIndex = 0
    @Volatile private var revision = 0L
    private var epoch = 0L
    private var udpFrames = 0L
    private var wsFrames = 0L
    private var trusted: TrustedMac? = null
    private var preferences = ClientPreferences()
    private var pendingSkins = emptyList<PendingSkinSelection>()
    private var pendingSkinsLoaded = true
    private sealed class Analog(val key: String) {
        class Stick(val target: String, val x: Double, val y: Double) : Analog("stick.$target")
        class Trigger(val target: String, val amount: Double) : Analog("trigger.$target")
    }
    private val pendingAnalog = mutableMapOf<String, Analog>()
    private val analogTasks = mutableMapOf<String, ScheduledFuture<*>>()
    private val lastAnalogAt = mutableMapOf<String, Long>()
    private fun clearAnalogQueue() {
        analogTasks.values.forEach { it.cancel(false) }
        analogTasks.clear(); pendingAnalog.clear(); lastAnalogAt.clear()
    }
    private fun acceptsInput(expectedRevision: Long) = expectedRevision == revision && state.paired && !state.practiceMode
    private fun emitAnalog(value: Analog) {
        when (value) {
            is Analog.Stick -> inputs?.stick(value.target, value.x, value.y)
            is Analog.Trigger -> inputs?.trigger(value.target, value.amount)
        }
        lastAnalogAt[value.key] = System.nanoTime()
    }
    private fun queueAnalog(value: Analog, final: Boolean, expectedRevision: Long) {
        if (!acceptsInput(expectedRevision)) return
        val remaining = 16_000_000L - (System.nanoTime() - (lastAnalogAt[value.key] ?: 0L))
        if (final || remaining <= 0) {
            analogTasks.remove(value.key)?.cancel(false)
            pendingAnalog.remove(value.key)
            emitAnalog(value)
        } else {
            pendingAnalog[value.key] = value
            if (analogTasks[value.key] == null) {
                val generation = inputs?.generation
                analogTasks[value.key] = queue.schedule({
                    analogTasks.remove(value.key)
                    val latest = pendingAnalog.remove(value.key)
                    if (latest != null && acceptsInput(expectedRevision) && inputs?.generation == generation) emitAnalog(latest)
                }, remaining, TimeUnit.NANOSECONDS)
            }
        }
    }

    private var trustedAttempt = false
    private var foreground = true
    private var wantsConnection = true
    private var disposed = false
    private var retry: ScheduledFuture<*>? = null
    private var retryAttempt = 0
    private var discoveryEpoch = 0L
    private var discovering = false
    private var discoveryDeadline: ScheduledFuture<*>? = null

    private fun stopDiscovery() {
        ++discoveryEpoch
        discovering = false
        discoveryDeadline?.cancel(false); discoveryDeadline = null
        discovery?.stop()
    }
    private fun startDiscovery() {
        val value = target ?: return
        val browser = discovery ?: return
        if (value.serverID == null && value.serviceName == null) return
        discovering = true
        val expected = discoveryEpoch
        browser.start(value.serverID, value.serviceName) { urls -> enqueue {
            if (expected != discoveryEpoch || !foreground || !wantsConnection || state.paired) return@enqueue
            val current = target ?: return@enqueue
            val fresh = urls.map { if (current.urls.firstOrNull()?.startsWith("wss://") == true) it.replaceFirst("ws://", "wss://") else it }
                .filterNot { it in current.urls }
            if (fresh.isEmpty()) return@enqueue
            if (trustedAttempt) {
                val mac = trusted ?: return@enqueue
                trusted = TrustedMac(mac.serverID, mac.authToken, (fresh + mac.urls).distinct().take(16))
                cancelRetry()
                connectRemembered()
            } else {
                target = PairingTarget((current.urls.take(addressIndex) + fresh + current.urls.drop(addressIndex)).distinct().take(16),
                    current.code, current.serverID, current.serviceName)
                if (socket == null) { deadline?.cancel(false); openNextAddress() }
            }
        } }
        if (!trustedAttempt && discoveryDeadline == null) {
            discoveryDeadline = queue.schedule({
                if (expected == discoveryEpoch && !state.paired) fail("Could not find your Mac nearby. Check Wi-Fi and the Mac’s pairing screen.", false)
            }, 30, TimeUnit.SECONDS)
        }
    }

    fun networkAvailable() = enqueue {
        if (wantsConnection && foreground && trusted != null && !state.paired) {
            cancelRetry()
            stopDiscovery()
            if (state.connecting) startDiscovery() else connectRemembered()
        }
    }

    init { enqueue {
        trusted = store.loadMac()
        preferences = store.loadPreferences().normalized()
        var skinError: String? = null
        pendingSkins = runCatching { store.loadPendingSkinSelections() }.getOrElse {
            pendingSkinsLoaded=false;skinError="Could not restore pending skin changes. Your saved data has been kept.";emptyList()
        }
        state = state.copy(error=skinError,pendingSkinChanges=pendingSkins.size,snapshot = store.loadSnapshot(), canReconnect = trusted != null, practiceMode = preferences.practiceMode,
            hapticIntensity=preferences.hapticIntensity)
        publishState()
    } }

    fun resume() = enqueue {
        foreground = true
        if (wantsConnection && !state.paired && !state.connecting && trusted != null) connectRemembered()
    }
    fun suspend() = enqueue {
        foreground = false
        stopDiscovery()
        cancelRetry()
        closeSession()
        state = state.copy(paired = false, connecting = false, needsCode = false, udpAvailable = false, status = "Disconnected", surfaceRevision = revision)
        publishState()
    }
    fun reconnect() = enqueue {
        wantsConnection = true
        retryAttempt = 0
        cancelRetry()
        if (!state.paired && trusted != null) connectRemembered()
    }
    fun forgetMac() = enqueue {
        wantsConnection = false
        stopDiscovery()
        cancelRetry()
        closeSession()
        store.forgetMac()
        trusted = null
        target = null
        pendingSkins=emptyList();pendingSkinsLoaded=true
        state = ClientState(status = "Mac forgotten", practiceMode = preferences.practiceMode,
            hapticIntensity=preferences.hapticIntensity,surfaceRevision = revision)
        publishState()
    }
    private fun connectRemembered() {
        val mac = trusted ?: return
        if (!foreground || disposed) return
        closeSession()
        target = mac.target()
        trustedAttempt = true
        addressIndex = 0
        state = state.copy(paired = false, connecting = true, needsCode = false, error = null,
            status = "Reconnecting to Mac…", canReconnect = true, capabilities=emptySet(), surfaceRevision = revision)
        publishState()
        startDiscovery()
        openNextAddress()
    }
    private fun cancelRetry() { retry?.cancel(false); retry = null }
    private fun scheduleRetry() {
        if (!wantsConnection || !foreground || trusted == null || disposed || retry != null) return
        val delay = minOf(30L, 1L shl minOf(retryAttempt++, 5))
        state = state.copy(status = "Reconnecting in ${delay}s…")
        retry = queue.schedule({ retry = null; connectRemembered() }, delay, TimeUnit.SECONDS)
    }

    fun connect(value: PairingTarget) = enqueue {
        wantsConnection = true
        trustedAttempt = false
        stopDiscovery()
        retryAttempt = 0
        cancelRetry()
        closeSession()
        target = value
        addressIndex = 0
        state = state.copy(connecting = true, paired = false, needsCode = false, error = null, status = "Connecting to Mac…", capabilities=emptySet(), surfaceRevision = revision)
        publishState()
        startDiscovery()
        openNextAddress()
    }
    fun submitCode(code: String) = enqueue {
        if (!code.matches(Regex("[0-9]{6}"))) {
            state = state.copy(error = "Enter the six-digit code shown on the Mac."); publishState()
        } else if (socket != null && state.needsCode) {
            socket?.send(hello(code).toString())
            state = state.copy(needsCode = false, status = "Pairing…", error = null); publishState()
        }
    }
    fun edge(id: UUID, down: Boolean, press: Long, expectedRevision: Long) {
        enqueue { if (acceptsInput(expectedRevision)) inputs?.edge(id, down, press) }
    }
    fun elementEdge(id: UUID, part: InputPart, down: Boolean, press: Long, expectedRevision: Long) = enqueue {
        if (acceptsInput(expectedRevision)) inputs?.element(id, part, down, press)
    }
    fun stick(target: String, x: Double, y: Double, final: Boolean, expectedRevision: Long) = enqueue {
        val dx = if (x.isFinite()) x.coerceIn(-1.0, 1.0) else 0.0
        val dy = if (y.isFinite()) y.coerceIn(-1.0, 1.0) else 0.0
        queueAnalog(Analog.Stick(target, dx, dy), final || (kotlin.math.abs(dx) < .001 && kotlin.math.abs(dy) < .001), expectedRevision)
    }
    fun trigger(target: String, value: Double, final: Boolean, expectedRevision: Long) = enqueue {
        val amount = if (value.isFinite()) value.coerceIn(0.0, 1.0) else 0.0
        queueAnalog(Analog.Trigger(target, amount), final || amount < .001, expectedRevision)
    }
    fun pointer(kind: String, x: Double, y: Double, button: String?, down: Boolean?, expectedRevision: Long) = enqueue {
        if (acceptsInput(expectedRevision)) inputs?.pointer(kind, x, y, button, down)
    }
    fun releaseAll() = enqueue { clearAnalogQueue(); if (state.paired) inputs?.releaseAll() }
    fun setUDPEnabled(enabled: Boolean) = enqueue {
        state = state.copy(udpEnabled = enabled)
        publishState()
    }
    fun setHapticIntensity(value: Double) = enqueue {
        val next=preferences.copy(hapticIntensity=HapticIntensity.normalized(value))
        if (runCatching { store.savePreferences(next) }.isSuccess) {
            preferences=next
            state=state.copy(hapticIntensity=next.hapticIntensity,preferencesError=null)
        } else state=state.copy(preferencesError="Could not save haptic intensity. Try again.")
        publishState()
    }
    fun setPracticeMode(enabled: Boolean) = enqueue {
        if (!state.paired && !enabled) return@enqueue
        if (state.practiceMode == enabled) return@enqueue
        invalidateSurface()
        preferences = preferences.copy(practiceMode = enabled)
        val saved = runCatching { store.savePreferences(preferences) }.isSuccess
        state = state.copy(practiceMode = enabled, error = if (saved) null else "Could not save your practice preference.")
        publishState()
    }
    fun viewSavedKeypad() = enqueue {
        if (state.snapshot.selected == null) return@enqueue
        wantsConnection = false
        stopDiscovery(); cancelRetry(); closeSession()
        preferences = preferences.copy(practiceMode = true)
        runCatching { store.savePreferences(preferences) }
        state = state.copy(paired = false, connecting = false, needsCode = false, practiceMode = true,
            viewingSaved = true, udpAvailable = false, status = "Offline practice", error = null, surfaceRevision = revision)
        publishState()
    }
    fun showConnection() = enqueue {
        invalidateSurface()
        state = state.copy(viewingSaved = false)
        publishState()
    }
    fun surfaceChanged() = enqueue { invalidateSurface(); publishState() }
    fun commitSkinChange(expected: ControllerProfile, replacement: ControllerProfile, reference: SkinReference?, completed: (Boolean) -> Unit = {}) = enqueue {
        fun finish(success: Boolean) { publishState();main.post { completed(success) } }
        if (!pendingSkinsLoaded) { finish(false);return@enqueue }
        val current=state.snapshot.selected
        if (current?.id!=expected.id || current.source!==expected.source || replacement.id!=expected.id) {
            state=state.copy(error="The keypad changed while preparing the skin. Try again.");finish(false);return@enqueue
        }
        val next=SkinSelectionJournal.replacing(pendingSkins,PendingSkinSelection(expected.id,reference,System.currentTimeMillis(),trusted?.serverID))
        val snapshot=state.snapshot.copy(profiles=state.snapshot.profiles.map { if(it.id==expected.id) replacement else it })
        if (runCatching { store.saveSkinState(snapshot,next) }.isFailure) {
            state=state.copy(error="Could not save the skin change. Your keypad is unchanged.");finish(false);return@enqueue
        }
        pendingSkins=next
        invalidateSurface()
        state=state.copy(snapshot=snapshot,pendingSkinChanges=next.size,error=null)
        flushSkinSelections()
        finish(true)
    }
    private fun flushSkinSelections() {
        if (!state.paired || "gamepad_profile_skin_selection" !in state.capabilities) return
        for (pending in pendingSkins.sortedBy { it.updatedAt }) {
            if(pending.serverID!=null && pending.serverID!=trusted?.serverID) continue
            val reference=pending.reference
            val bytes=if(reference!=null && "skin_packages" in state.capabilities) runCatching { skinArchive(reference) }.getOrNull() else null
            if(bytes!=null && !sendSkinArchive(bytes)) continue
            if(socket?.send(pending.request().toString())!=true) return
        }
    }
    fun uploadSkinArchive(bytes: ByteArray) = enqueue {
        if(state.paired && "skin_packages" in state.capabilities) { sendSkinArchive(bytes);publishState() }
    }
    private fun sendSkinArchive(bytes: ByteArray): Boolean {
        if(bytes.size.toLong()*4/3+512>WireCodec.MAX_PAYLOAD) {
            state=state.copy(error="Skin saved locally, but its package is too large to sync to this Mac.");return false
        }
        val upload=WireCodec.message("skin_packages").put("skinPackages",org.json.JSONArray().put(java.util.Base64.getEncoder().encodeToString(bytes))).toString()
        if(upload.toByteArray().size>WireCodec.MAX_PAYLOAD) return false
        return socket?.send(upload)==true
    }
    private fun saveIncomingSkinState(snapshot: ProfileSnapshot, authoritativeProfiles: Boolean): String? {
        if(!pendingSkinsLoaded) return "Could not restore pending skin changes. Your saved data has been kept."
        val remaining=if(authoritativeProfiles) SkinSelectionJournal.acknowledge(pendingSkins,snapshot,trusted?.serverID) else pendingSkins
        return if(runCatching { store.saveSkinState(snapshot,remaining) }.isSuccess) {
            pendingSkins=remaining;state=state.copy(pendingSkinChanges=remaining.size);null
        } else "Connected, but could not save your keypad and pending skin changes."
    }
    fun setDefaultProfile(id: UUID) = enqueue {
        val request=ProfileActions.defaultProfile(state.snapshot,id) ?: return@enqueue
        if (state.paired) sendProfileAction(request)
        else if (state.viewingSaved) {
            val snapshot=state.snapshot.copy(defaultID=id)
            if (runCatching { store.saveSnapshot(snapshot) }.isSuccess) state=state.copy(snapshot=snapshot,error=null)
            else state=state.copy(error="Could not save your default keypad. Try again.")
            publishState()
        }
    }
    fun setOrientationPreference(preference: String) = enqueue {
        if (!state.paired) return@enqueue
        val request=ProfileActions.orientation(state.snapshot,state.capabilities,preference) ?: return@enqueue
        invalidateSurface()
        sendProfileAction(request)
    }
    fun launchProfileTarget() = enqueue {
        if (!state.paired) return@enqueue
        ProfileActions.launch(state.snapshot)?.let(::sendProfileAction)
    }
    private fun sendProfileAction(request: JSONObject) {
        if (socket?.send(request.toString()) != true) fail("Connection lost. The profile request was not sent.")
        else { state=state.copy(error=null);publishState() }
    }
    fun selectProfile(id: UUID) = enqueue {
        if (state.snapshot.profiles.none { it.id == id }) return@enqueue
        invalidateSurface()
        if (state.paired) {
            socket?.send(WireCodec.message("gamepad_profile_selection").put("gamepadProfileID", id.toString().uppercase()).toString())
        } else if (state.viewingSaved) {
            val snapshot = state.snapshot.copy(selectedID = id)
            runCatching { store.saveSnapshot(snapshot) }
            state = state.copy(snapshot = snapshot)
        }
        publishState()
    }
    fun disconnect() = enqueue {
        wantsConnection = false
        stopDiscovery()
        cancelRetry()
        closeSession()
        state = state.copy(paired = false, connecting = false, needsCode = false, error = null, status = "Disconnected", viewingSaved = false, surfaceRevision = revision)
        publishState()
    }
    fun dispose() = enqueue {
        disposed = true
        wantsConnection = false
        stopDiscovery()
        cancelRetry()
        closeSession()
        http.dispatcher.executorService.shutdown()
        http.connectionPool.evictAll()
        queue.shutdown()
    }
    private fun enqueue(action: () -> Unit) {
        try { queue.execute(action) } catch (_: RejectedExecutionException) { /* Activity already disposed. */ }
    }
    private fun hello(code: String?): JSONObject = WireCodec.message(if (code == null && !trustedAttempt) "pairing_request" else "hello")
        .put("clientName", "Thumble Android (${Build.MODEL})").also {
            if (trustedAttempt) trusted?.let { mac -> it.put("authToken", mac.authToken).put("serverID", mac.serverID) }
            else if (code != null) it.put("pairingCode", code)
        }

    private fun openNextAddress() {
        val value = target ?: return
        val url = value.urls.getOrNull(addressIndex) ?: run {
            socket = null
            if (discovering && !trustedAttempt) {
                state = state.copy(status = "Looking for your Mac nearby…")
                if (discoveryDeadline == null) {
                    val expected = discoveryEpoch
                    discoveryDeadline = queue.schedule({
                        if (expected == discoveryEpoch && !state.paired) fail("Could not find your Mac nearby. Check Wi-Fi and the Mac’s pairing screen.", false)
                    }, 30, TimeUnit.SECONDS)
                }
                publishState()
            } else fail("Could not reach the Mac. Keep both devices on the same Wi-Fi and check the Mac’s local network permission.")
            return
        }
        ++addressIndex
        val expectedEpoch = ++epoch
        val listener = object : WebSocketListener() {
            private fun enqueue(action: () -> Unit) {
                this@ControllerClient.enqueue { if (epoch == expectedEpoch) action() }
            }
            override fun onOpen(webSocket: WebSocket, response: Response) = enqueue {
                socket = webSocket
                discoveryDeadline?.cancel(false); discoveryDeadline = null
                webSocket.send(hello(value.code).toString())
                state = state.copy(status = "Pairing…"); publishState()
            }
            override fun onMessage(webSocket: WebSocket, text: String) = enqueue {
                if (text.length > WireCodec.MAX_PAYLOAD) fail("Host message is too large.", false)
                else receive(text.toByteArray(), url)
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) = enqueue {
                if (bytes.size > WireCodec.MAX_PAYLOAD) fail("Host message is too large.", false)
                else receive(bytes.toByteArray(), url)
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = enqueue {
                if (state.paired || state.needsCode) fail("Connection lost. Reconnecting when your Mac is available.")
                else { socket?.cancel(); deadline?.cancel(false); openNextAddress() }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = enqueue {
                webSocket.close(code, null)
                fail("The Mac disconnected.")
            }
        }
        socket = http.newWebSocket(Request.Builder().url(url).build(), listener)
        deadline?.cancel(false)
        deadline = queue.schedule({
            if (expectedEpoch == epoch && !state.paired) {
                if (state.needsCode) fail("Pairing timed out. Scan a fresh QR code on the Mac.")
                else { socket?.cancel(); openNextAddress() }
            }
        }, 30, TimeUnit.SECONDS)
    }
    private fun receive(bytes: ByteArray, url: String) {
        try {
            val message = WireCodec.decode(bytes)
            if (state.paired || message.optString("type") in setOf("hello", "pairing_accepted")) {
                message.optJSONObject("virtualGamepadStatus")?.let { state = state.copy(virtualGamepadStatus = it) }
                message.optJSONArray("capabilities")?.let { array ->
                    require(array.length() <= 128)
                    state = state.copy(capabilities = (0 until array.length()).map { array.getString(it).take(128) }.toSet())
                }
            }
            when (message.getString("type")) {
                "pairing_challenge" -> {
                    if (trustedAttempt) {
                        forgetExpiredTrust()
                        fail("Pairing has expired. Scan your Mac’s QR code again.", false)
                        return
                    }
                    state = state.copy(needsCode = true, status = "Enter the code shown on your Mac")
                    publishState()
                }
                "pairing_accepted", "hello" -> {
                    if (state.paired) return
                    require(message.optInt("inputProtocolVersion") == 3) { "Update Thumble Mac: Android requires input protocol v3." }
                    val expectedID = target?.serverID
                    require(expectedID == null || message.optString("serverID") == expectedID) { "The responding Mac does not match this QR code." }
                    val skinPackages=IncomingSkinPackages.validated(message,bytes.size)
                    val snapshot = state.snapshot.applying(message)
                    require(snapshot.selected != null) { "The Mac did not send a selected profile." }
                    deadline?.cancel(false)
                    cancelRetry()
                    stopDiscovery()
                    retryAttempt = 0
                    val server = message.optString("serverID").takeIf { it.isNotBlank() && it != "null" }
                    val auth = message.optString("authToken").takeIf { it.isNotBlank() && it != "null" }
                        ?: trusted?.authToken.takeIf { trustedAttempt }
                    var saveError: String? = null
                    if (server != null && auth != null) {
                        val endpoints = (listOf(url) + target!!.urls).distinct().take(16)
                        trusted = TrustedMac(server, auth, endpoints)
                        runCatching { store.saveMac(trusted!!) }.onFailure {
                            saveError = "Connected, but could not save this Mac for next time."
                        }
                    } else if (!trustedAttempt) {
                        store.forgetMac()
                        trusted = null
                    }
                    saveIncomingSkinState(snapshot,message.optJSONArray("gamepadProfiles")!=null)?.let { saveError=it }
                    inputs = InputSession(::sendInput, SecureRandom().nextInt(Int.MAX_VALUE - 1).toLong() + 1)
                    val token = message.optString("realtimeToken").takeIf { it.isNotBlank() && it != "null" }
                    if (token != null) startUDP(url, token)
                    state = state.copy(paired = true, connecting = false, needsCode = false, error = saveError,
                        status = "Connected", snapshot = snapshot, canReconnect = trusted != null, udpAvailable = udp != null, surfaceRevision = ++revision)
                    heartbeat = queue.scheduleWithFixedDelay({
                        if (state.paired) { inputs?.heartbeat(); publishState() }
                    }, 0, 250, TimeUnit.MILLISECONDS)
                    flushSkinSelections()
                    if(!offerSkinPackages(skinPackages)) return
                    publishState()
                }
                "gamepad_profiles", "gamepad_customization", "skin_packages" -> if (state.paired) {
                    val skinPackages=IncomingSkinPackages.validated(message,bytes.size)
                    val hasProfiles=message.optJSONArray("gamepadProfiles")!=null || message.optJSONObject("gamepadCustomization")!=null ||
                        message.has("gamepadProfileID") || message.has("defaultGamepadProfileID")
                    if(hasProfiles) {
                        val snapshot = state.snapshot.applying(message)
                        val saveError=saveIncomingSkinState(snapshot,message.optJSONArray("gamepadProfiles")!=null)
                        invalidateSurface()
                        state = state.copy(snapshot = snapshot,error=saveError)
                    }
                    if(!offerSkinPackages(skinPackages)) return
                    publishState()
                }
                "release_all" -> if (state.paired) {
                    ++revision
                    clearAnalogQueue()
                    inputs?.releaseAll(if (message.has("inputGeneration")) message.getLong("inputGeneration") else null)
                    state = state.copy(surfaceRevision = revision); publishState()
                }
                "ping" -> socket?.send(WireCodec.message("pong").put("timestamp", message.getLong("timestamp")).toString())
                "error" -> {
                    val expired = trustedAttempt && message.optString("message").contains("Trusted pairing expired", ignoreCase = true)
                    if (expired) forgetExpiredTrust()
                    // Host rejections require a deliberate retry; do not retry invalid codes or a busy Mac indefinitely.
                    fail(if (expired) "Pairing has expired. Scan your Mac’s QR code again." else
                        message.optString("message").takeIf { it.isNotBlank() }?.take(512) ?: "The Mac rejected the connection. Check its pairing status.", false)
                }
            }
        } catch (error: Exception) {
            fail("The Mac sent an unsupported profile or message. Check that both apps are up to date.", false)
        }
    }
    private fun offerSkinPackages(packages: IncomingSkinPackages?): Boolean {
        if(packages==null || packages.count==0 || incomingSkins(packages)) return true
        fail("Skin sync is busy. Reconnecting to receive your skins.")
        return false
    }
    private fun startUDP(url: String, token: String) {
        val uri = URI(url)
        try {
            val datagram = DatagramSocket()
            udp = datagram
            datagram.connect(InetAddress.getByName(uri.host), if (uri.port != -1) uri.port else if (uri.scheme == "wss") 443 else 80)
            val expectedEpoch = epoch
            val hello = WireCodec.message("hello").put("clientName", "Thumble Android")
                .put("realtimeToken", token).toString().toByteArray()
            repeat(5) { attempt -> queue.schedule({
                if (epoch == expectedEpoch && udp === datagram) sendDatagram(hello)
            }, attempt * 50L, TimeUnit.MILLISECONDS) }
        } catch (_: Exception) { udp?.close(); udp = null }
    }
    private fun sendDatagram(data: ByteArray) {
        val datagram = udp ?: return
        try { datagram.send(DatagramPacket(data, data.size)); ++udpFrames }
        catch (_: Exception) { datagram.close(); udp = null; state = state.copy(udpAvailable = false) }
    }
    private fun sendInput(data: ByteArray) {
        if (state.udpEnabled) sendDatagram(data)
        // Mirror every edge even while UDP is healthy: the host deduplicates by generation/sequence.
        if (socket?.send(data.toByteString()) == true) ++wsFrames
        else if (state.paired) fail("Connection lost. All controls have been released.")
    }
    private fun invalidateSurface() {
        clearAnalogQueue()
        ++revision
        inputs?.releaseAll()
        state = state.copy(surfaceRevision = revision)
    }
    private fun closeSession() {
        clearAnalogQueue()
        ++epoch
        ++revision
        heartbeat?.cancel(false); heartbeat = null
        deadline?.cancel(false); deadline = null
        // Do not call sendInput while tearing down: failure handling must not re-enter closeSession.
        val release = WireCodec.message("release_all", inputs?.generation?.plus(1)).toString()
        if (state.udpEnabled) udp?.let { datagram ->
            val data = release.toByteArray()
            runCatching { datagram.send(DatagramPacket(data, data.size)) }
        }
        inputs = null
        state = state.copy(virtualGamepadStatus = null, capabilities = emptySet(), udpAvailable = false)
        val retiringSocket = socket
        retiringSocket?.send(release)
        socket = null
        // The existing Network.framework receiver treats close-frame bytes as application data.
        // Match iOS: flush release-all, then end the transport rather than wait for a close reply.
        if (retiringSocket != null) queue.schedule({ retiringSocket.cancel() }, 100, TimeUnit.MILLISECONDS)
        udp?.close(); udp = null
    }
    private fun forgetExpiredTrust() {
        store.forgetMac()
        pendingSkins=emptyList();pendingSkinsLoaded=true
        state=state.copy(pendingSkinChanges=0)
        trusted = null
        wantsConnection = false
    }
    private fun fail(message: String, recoverable: Boolean = true) {
        val retryTrusted = trustedAttempt || state.paired
        closeSession()
        if (!recoverable || !retryTrusted) {
            wantsConnection = false
            stopDiscovery()
        }
        state = state.copy(paired = false, connecting = false, needsCode = false, status = "Disconnected", error = message,
            canReconnect = trusted != null, udpAvailable = false, virtualGamepadStatus = null, capabilities = emptySet(), surfaceRevision = revision)
        if (recoverable && retryTrusted) scheduleRetry()
        publishState()
    }
    private fun publishState() {
        val value = state.copy(udpFrames = udpFrames, webSocketFrames = wsFrames)
        main.post { publish(value) }
    }
}
