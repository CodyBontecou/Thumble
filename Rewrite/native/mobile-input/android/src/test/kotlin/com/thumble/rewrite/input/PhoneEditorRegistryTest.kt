package com.thumble.rewrite.input

import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

private val registryPin = "a".repeat(64)
private val registryAuthority = "11111111-1111-1111-1111-111111111111"
private val registryProfile = "aaaaaaaa-0000-0000-0000-000000000001"
private val registryControl = "ce000000-0000-0000-0000-000000000001"
private fun registryEndpoint() = TrustedHostEndpoint("127.0.0.1", 9999, registryPin, registryAuthority)
private class RegistryGate {
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    fun waitHere() { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
    fun awaitEntry() { assertTrue(entered.await(5, TimeUnit.SECONDS)) }
}
private class RegistryStore : EditorJournalStorage {
    private var bytes: ByteArray? = null
    @Volatile var saveGate: RegistryGate? = null
    @Volatile var loadGate: RegistryGate? = null
    override fun load(): ByteArray? {
        loadGate?.let { gate -> loadGate = null; gate.waitHere() }
        return synchronized(this) { bytes?.copyOf() }
    }
    override fun save(candidate: ByteArray, expected: ByteArray?) {
        saveGate?.let { gate -> saveGate = null; gate.waitHere() }
        synchronized(this) {
            check(bytes?.contentEquals(expected ?: byteArrayOf()) ?: (expected == null))
            bytes = candidate.copyOf()
        }
    }
}
private class RegistryTransport(val exchangeGate: RegistryGate? = null, val cancelGate: RegistryGate? = null) : EditorRPCTransport {
    val calls = AtomicInteger()
    val cancellations = AtomicInteger()
    override fun exchange(request: EditorRequest): EditorAuthenticatedReply { calls.incrementAndGet(); exchangeGate?.waitHere(); throw PhoneEditorException() }
    override fun cancel() { cancellations.incrementAndGet(); cancelGate?.waitHere() }
}
private fun registryStore(): RegistryStore {
    val store = RegistryStore()
    EditorJournal(registryPin, store).accept(VerifiedEditorRead(EditorCachedProfile(
        EditorHostScope(registryPin, registryAuthority), registryProfile, "Controller", "7", "b".repeat(64),
        listOf(EditorCachedControl(registryControl, "Jump", null)))))
    return store
}
private fun registrySession(store: RegistryStore, transport: RegistryTransport = RegistryTransport()) =
    PhoneEditorSession(registryEndpoint(), transport, { EditorJournal(registryPin, store) }, { registryEndpoint() })
private fun awaitSettled(session: PhoneEditorSession) {
    val limit = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
    while (!session.settled && System.nanoTime() < limit) Thread.yield()
    assertTrue(session.settled)
}
class PhoneEditorRegistryTest {
    @Test fun invalidationDuringCreationReservesCandidateAndLateDestroyCannotCloseNewOwner() {
        val registry = PhoneEditorRegistry(); val old = PhoneEditorModuleLifetime(); val fresh = PhoneEditorModuleLifetime()
        val gate = RegistryGate(); val store = registryStore(); val candidate = registrySession(store)
        val pending = CompletableFuture.supplyAsync { registry.open(old) { gate.waitHere(); candidate }.get() }
        gate.awaitEntry()
        val teardown = registry.invalidate(old)
        assertFalse(teardown.isDone)
        assertThrows(Exception::class.java) { registry.open(fresh) { registrySession(store) }.get(1, TimeUnit.SECONDS) }
        gate.release.countDown()
        assertThrows(Exception::class.java) { pending.get(5, TimeUnit.SECONDS) }
        teardown.get(5, TimeUnit.SECONDS)
        awaitSettled(candidate)
        val id = registry.open(fresh) { registrySession(store) }.get(5, TimeUnit.SECONDS)
        registry.invalidate(old).get(1, TimeUnit.SECONDS)
        assertEquals(1, registry.session(fresh, id).snapshot().get().profiles.size)
        assertThrows(Exception::class.java) { registry.session(old, id) }
        registry.close(fresh, id).get(5, TimeUnit.SECONDS)
        registry.invalidate(fresh).get(1, TimeUnit.SECONDS)
    }
    @Test fun invalidationDuringInitialSnapshotClosesProvisionalSessionBeforeReuse() {
        val registry = PhoneEditorRegistry(); val old = PhoneEditorModuleLifetime(); val fresh = PhoneEditorModuleLifetime()
        val gate = RegistryGate(); val store = registryStore(); store.loadGate = gate
        val candidate = registrySession(store)
        val pending = registry.open(old) { candidate }
        gate.awaitEntry()
        val teardown = registry.invalidate(old)
        assertThrows(Exception::class.java) { registry.open(fresh) { registrySession(store) }.get(1, TimeUnit.SECONDS) }
        gate.release.countDown()
        assertThrows(Exception::class.java) { pending.get(5, TimeUnit.SECONDS) }
        teardown.get(5, TimeUnit.SECONDS)
        awaitSettled(candidate)
        val id = registry.open(fresh) { registrySession(store) }.get(5, TimeUnit.SECONDS)
        registry.close(fresh, id).get(5, TimeUnit.SECONDS)
    }
    @Test fun cancelledOpenFutureRetiresProvisionalSessionWithoutExposingHandle() {
        val registry = PhoneEditorRegistry(); val old = PhoneEditorModuleLifetime(); val fresh = PhoneEditorModuleLifetime()
        val gate = RegistryGate(); val store = registryStore(); store.loadGate = gate
        val candidate = registrySession(store)
        val pending = registry.open(old) { candidate }
        gate.awaitEntry()
        assertTrue(pending.cancel(true))
        val closing = registry.invalidate(old)
        assertThrows(Exception::class.java) { registry.open(fresh) { registrySession(store) }.get(1, TimeUnit.SECONDS) }
        gate.release.countDown()
        closing.get(5, TimeUnit.SECONDS)
        awaitSettled(candidate)
        val id = registry.open(fresh) { registrySession(store) }.get(5, TimeUnit.SECONDS)
        registry.close(fresh, id).get(5, TimeUnit.SECONDS)
    }
    @Test fun failedSnapshotRetiresActualSessionWithoutResettingCorruptJournal() {
        val registry = PhoneEditorRegistry(); val owner = PhoneEditorModuleLifetime()
        val candidate = PhoneEditorSession(registryEndpoint(), RegistryTransport(), { error("corrupt") }, { registryEndpoint() })
        assertThrows(Exception::class.java) { registry.open(owner) { candidate }.get(5, TimeUnit.SECONDS) }
        awaitSettled(candidate)
        val store = registryStore()
        val id = registry.open(owner) { registrySession(store) }.get(5, TimeUnit.SECONDS)
        assertEquals(1, registry.session(owner, id).snapshot().get().profiles.size)
        registry.close(owner, id).get(5, TimeUnit.SECONDS)
    }
    @Test fun closeReturnedAndActualRPCDrainBothGateReplacementWithoutHoldingMonitor() {
        val registry = PhoneEditorRegistry(); val old = PhoneEditorModuleLifetime(); val fresh = PhoneEditorModuleLifetime()
        val exchange = RegistryGate(); val cancel = RegistryGate(); val store = registryStore()
        val transport = RegistryTransport(exchange, cancel); val candidate = registrySession(store, transport)
        val id = registry.open(old) { candidate }.get(5, TimeUnit.SECONDS)
        val rpc = candidate.read(registryProfile, "7", "b".repeat(64))
        exchange.awaitEntry()
        val closing = registry.close(old, id)
        cancel.awaitEntry()
        val teardown = registry.invalidate(old)
        assertSame(closing, teardown)
        assertFalse(closing.isDone)
        // This must return promptly even while actual SDK close blocks inside cancel IO.
        assertThrows(Exception::class.java) { registry.open(fresh) { registrySession(store) }.get(1, TimeUnit.SECONDS) }
        cancel.release.countDown()
        closing.get(5, TimeUnit.SECONDS)
        assertFalse(candidate.settled)
        assertThrows(Exception::class.java) { registry.open(fresh) { registrySession(store) }.get(1, TimeUnit.SECONDS) }
        exchange.release.countDown()
        assertThrows(Exception::class.java) { rpc.get(5, TimeUnit.SECONDS) }
        awaitSettled(candidate)
        val next = registry.open(fresh) { registrySession(store) }.get(5, TimeUnit.SECONDS)
        assertEquals(1, transport.cancellations.get())
        registry.invalidate(old).get()
        assertNotNull(registry.session(fresh, next))
        registry.close(fresh, next).get(5, TimeUnit.SECONDS)
    }
    @Test fun localJournalMutationDrainsBeforeNewOwnerAndOriginalIntentSurvives() {
        val registry = PhoneEditorRegistry(); val old = PhoneEditorModuleLifetime(); val fresh = PhoneEditorModuleLifetime()
        val store = registryStore(); val candidate = registrySession(store)
        registry.open(old) { candidate }.get(5, TimeUnit.SECONDS)
        val summary = candidate.snapshot().get().profiles.single()
        val gate = RegistryGate(); store.saveGate = gate
        val mutation = candidate.enqueue(summary.contextID, summary.revision, summary.sourceSHA256, registryControl, "original-local-edit", "Leap")
        gate.awaitEntry()
        val closing = registry.invalidate(old)
        assertThrows(Exception::class.java) { registry.open(fresh) { registrySession(store) }.get(1, TimeUnit.SECONDS) }
        gate.release.countDown()
        mutation.get(5, TimeUnit.SECONDS)
        closing.get(5, TimeUnit.SECONDS)
        awaitSettled(candidate)
        val next = registry.open(fresh) { registrySession(store) }.get(5, TimeUnit.SECONDS)
        assertEquals(listOf("original-local-edit"), registry.session(fresh, next).snapshot().get().entries.map { it.intent.operationID })
        registry.close(fresh, next).get(5, TimeUnit.SECONDS)
    }
}
