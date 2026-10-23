package com.thumble.rewrite.input

import android.content.Context
import java.io.Closeable
import java.net.InetSocketAddress
import java.util.Collections
import java.util.UUID
import java.util.concurrent.*

class PhoneEditorCacheSummary internal constructor(val contextID: String, profile: EditorCachedProfile) {
    val profileID = profile.id
    val name = profile.name
    val revision = profile.revision
    val sourceSHA256 = profile.sourceSHA256
    val controlCount = profile.controls.size
}
class PhoneEditorSnapshot internal constructor(profiles: List<PhoneEditorCacheSummary>, entries: List<EditorPendingEntry>, val selection: String?) {
    val profiles: List<PhoneEditorCacheSummary> = Collections.unmodifiableList(profiles.toList())
    val entries: List<EditorPendingEntry> = Collections.unmodifiableList(entries.toList())
}
class PhoneEditorCachePage internal constructor(val contextID: String, val offset: Int, val nextOffset: Int?, controls: List<EditorCachedControl>) {
    val controls: List<EditorCachedControl> = Collections.unmodifiableList(controls.toList())
}

/** Explicit editor owner; its protected journal opens on a native worker. */
class PhoneEditorSession internal constructor(
    private val endpoint: TrustedHostEndpoint,
    private val transport: EditorRPCTransport,
    openJournal: () -> EditorJournal,
    private val resolve: () -> TrustedHostEndpoint,
) : Closeable {
    constructor(endpoint: TrustedHostEndpoint, context: Context) : this(
        endpoint, EditorSessionTransport(endpoint, context.applicationContext),
        { EditorJournal(endpoint.certificatePin, EditorJournalFileStore(context.applicationContext, endpoint.certificatePin)) },
        { PhoneAuthorityResolver(endpoint).use { it.resolve() } },
    )
    private val coordinator = PhoneEditorCoordinator(openJournal, transport)
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(16),
        { action -> Thread(action, "thumble-editor-session").apply { isDaemon = true } }, ThreadPoolExecutor.AbortPolicy())
    private val gate = Any()
    private var closed = false
    private var active = false
    private var pendingLocal = 0
    private var catalogClient: PhoneCatalogClient? = null
    private var generation = 0L
    private val contexts = linkedMapOf<String, EditorCachedProfile>()
    val settled: Boolean get() = synchronized(gate) { !active && pendingLocal == 0 }
    private fun checkOpen() { synchronized(gate) { if (closed) throw PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE) } }
    private fun <T> work(action: () -> T): CompletableFuture<T> {
        val result = CompletableFuture<T>()
        synchronized(gate) {
            if (closed) {
                result.completeExceptionally(PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE))
                return result
            }
            pendingLocal++
        }
        try {
            worker.execute {
                try { checkOpen(); result.complete(action()) }
                catch (error: Exception) { result.completeExceptionally(error) }
                finally { synchronized(gate) { pendingLocal-- } }
            }
        } catch (error: Exception) {
            synchronized(gate) { pendingLocal-- }
            result.completeExceptionally(error)
        }
        return result
    }
    private fun snapshotNow(): PhoneEditorSnapshot {
        val snapshot = coordinator.snapshot().get()
        contexts.entries.removeAll { !snapshot.profiles.contains(it.value) }
        val profiles = snapshot.profiles.map { profile ->
            val id = contexts.entries.firstOrNull { it.value == profile }?.key ?: UUID.randomUUID().toString().also { contexts[it] = profile }
            PhoneEditorCacheSummary(id, profile)
        }
        val selected = snapshot.selection?.let { selection -> contexts.entries.firstOrNull { it.value.scope == selection.scope && it.value.id == selection.profileID }?.key }
        return PhoneEditorSnapshot(profiles, snapshot.entries, selected)
    }
    fun snapshot() = work { snapshotNow() }
    private fun context(id: String) = contexts[id] ?: throw PhoneEditorException()
    fun cachePage(contextID: String, offset: Int) = work {
        val profile = context(contextID)
        if (offset < 0 || offset > profile.controls.size || offset % 8 != 0) throw PhoneEditorException()
        val end = minOf(offset + 8, profile.controls.size)
        PhoneEditorCachePage(contextID, offset, if (end < profile.controls.size) end else null, profile.controls.subList(offset, end))
    }
    fun select(contextID: String?) = work {
        coordinator.select(contextID?.let { context(it).let { profile -> EditorSelection(profile.scope, profile.id) } }).get()
        Unit
    }
    fun enqueue(contextID: String, expectedRevision: String, sourceSHA256: String, controlID: String, operationID: String, label: String?) = work {
        val profile = context(contextID)
        if (profile.revision != expectedRevision || profile.sourceSHA256 != sourceSHA256 ||
            !coordinator.snapshot().get().profiles.contains(profile) || profile.controls.none { it.id == controlID }) throw PhoneEditorException()
        coordinator.enqueue(EditorLabelIntent(profile.scope, operationID, profile.revision, profile.id, controlID, label)).get()
        Unit
    }
    private fun <T> network(action: (TrustedHostEndpoint, Long) -> T): CompletableFuture<T> {
        val token = synchronized(gate) {
            checkOpen()
            if (active || generation == Long.MAX_VALUE) throw PhoneEditorException(PhoneEditorException.Code.BUSY)
            active = true; ++generation
        }
        val result = CompletableFuture<T>()
        try { worker.execute {
            try {
                fun checkpoint() { synchronized(gate) { if (closed || generation != token || result.isCancelled) throw PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE) } }
                checkpoint()
                val current = resolve()
                checkpoint()
                if (current.host != endpoint.host || current.port != endpoint.port || current.certificatePin != endpoint.certificatePin) throw PhoneEditorException()
                result.complete(action(current, token))
            } catch (error: Exception) { result.completeExceptionally(error) }
            finally { synchronized(gate) { active = false } }
        } } catch (error: Exception) { synchronized(gate) { active = false }; result.completeExceptionally(error) }
        result.whenComplete { _, _ -> if (result.isCancelled) synchronized(gate) { if (active && generation == token) { generation++; coordinator.cancel(); catalogClient?.close() } } }
        return result
    }
    private fun <T> admit(token: Long, action: () -> CompletableFuture<T>): CompletableFuture<T> = synchronized(gate) {
        if (closed || generation != token) throw PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE)
        action()
    }
    fun read(profileID: String, expectedRevision: String, sourceSHA256: String) = network { current, token ->
        admit(token) { coordinator.readProfile(EditorReadPin(EditorHostScope(current.certificatePin, current.authorityInstanceID), expectedRevision, sourceSHA256, profileID)) }.get()
        snapshotNow()
    }
    fun catalog(context: Context, expectedRevision: String?, offset: Int) = network { current, token ->
        val client = synchronized(gate) {
            if (closed || generation != token) throw PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE)
            PhoneCatalogClient(current, context.applicationContext).also { catalogClient = it }
        }
        val result = try { client.use { it.read(expectedRevision, offset) } }
            finally { synchronized(gate) { if (catalogClient === client) catalogClient = null } }
        synchronized(gate) { if (closed || generation != token) throw PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE) }
        result
    }
    fun submit(operationID: String) = dispatch(operationID, false)
    fun reconcile(operationID: String) = dispatch(operationID, true)
    private fun dispatch(id: String, reconcile: Boolean) = network { current, token ->
        val scope = EditorHostScope(current.certificatePin, current.authorityInstanceID)
        val outcome = if (reconcile) admit(token) { coordinator.reconcile(id, scope) }.get() else admit(token) { coordinator.submit(id, scope) }.get()
        when (outcome) { EditorDispatchOutcome.Committed -> "committed"; EditorDispatchOutcome.Retained -> "retained"; is EditorDispatchOutcome.Conflict -> "conflict" }
    }
    fun cancel() { synchronized(gate) { if (active) generation++; coordinator.cancel(); catalogClient?.close() } }
    override fun close() { synchronized(gate) { closed = true; if (active) generation++; coordinator.close(); catalogClient?.close() }; worker.shutdown() }
}

private class EditorSessionTransport(private val endpoint: TrustedHostEndpoint, context: Context) : EditorRPCTransport {
    private val vault = PhoneCredentialVault(context)
    @Volatile private var rpc: PhoneEditorRPC? = null
    override fun cancel() { rpc?.cancel() }
    override fun exchange(request: EditorRequest): EditorAuthenticatedReply {
        check(rpc == null)
        val current = TrustedHostEndpoint(endpoint.host, endpoint.port, endpoint.certificatePin, request.scope.authorityInstanceID)
        val call = PhoneEditorRPC(current, {
            val client = ControlTLSClient.connect(InetSocketAddress(current.host, current.port), current.certificatePin)
            object : NativeFrameIO {
                override fun send(frame: ControlTLSFrame) = client.send(frame)
                override fun receive() = client.receive()
                override fun close() = client.close()
            }
        }, vault::load, System::currentTimeMillis)
        rpc = call
        try { return call.exchange(request) } finally { rpc = null }
    }
}
