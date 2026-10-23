package com.thumble.rewrite.input

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

private val sessionPin = "a".repeat(64)
private val sessionAuthority = "11111111-1111-1111-1111-111111111111"
private val sessionProfile = "aaaaaaaa-0000-0000-0000-000000000001"
private fun sessionEndpoint(authority: String = sessionAuthority) = TrustedHostEndpoint("127.0.0.1", 9999, sessionPin, authority)
private class SessionStore : EditorJournalStorage {
    private var bytes: ByteArray? = null
    @Synchronized override fun load() = bytes?.copyOf()
    @Synchronized override fun save(candidate: ByteArray, expected: ByteArray?) {
        check(bytes?.contentEquals(expected ?: byteArrayOf()) ?: (expected == null))
        bytes = candidate.copyOf()
    }
}
private class SessionTransport : EditorRPCTransport {
    var count = 0
    override fun exchange(request: EditorRequest): EditorAuthenticatedReply { count++; throw PhoneEditorException() }
    override fun cancel() {}
}
private fun sessionStore(): SessionStore {
    val store = SessionStore()
    val journal = EditorJournal(sessionPin, store)
    val controls = (1..18).map { EditorCachedControl("ce000000-0000-0000-0000-%012d".format(it), "Control $it", null) }
    journal.accept(VerifiedEditorRead(EditorCachedProfile(EditorHostScope(sessionPin, sessionAuthority), sessionProfile, "Profile", "7", "b".repeat(64), controls)))
    return store
}
class PhoneEditorSessionTest {
    @Test fun offlinePinsBoundedPagesAndDurableQueue() {
        val store = sessionStore(); val transport = SessionTransport()
        val session = PhoneEditorSession(sessionEndpoint(), transport, { EditorJournal(sessionPin, store) }, { error("offline") })
        try {
            val summary = session.snapshot().get().profiles.single()
            assertEquals(18, summary.controlCount)
            assertEquals(8, session.cachePage(summary.contextID, 0).get().controls.size)
            assertEquals(2, session.cachePage(summary.contextID, 16).get().controls.size)
            for ((revision, hash) in listOf("8" to summary.sourceSHA256, "7" to "c".repeat(64))) {
                assertThrows(Exception::class.java) { session.enqueue(summary.contextID, revision, hash, "ce000000-0000-0000-0000-000000000001", "test-op", "New").get() }
            }
            session.enqueue(summary.contextID, "7", summary.sourceSHA256, "ce000000-0000-0000-0000-000000000001", "test-op", "New").get()
            assertEquals(1, EditorJournal(sessionPin, store).snapshot().entries.size)
            session.select(summary.contextID).get()
            assertEquals(summary.contextID, session.snapshot().get().selection)
            assertEquals(0, transport.count)
        } finally { session.close() }
    }
    @Test fun cancelReservesActualOwnerUntilResolutionSettles() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val store = sessionStore(); val transport = SessionTransport()
        val session = PhoneEditorSession(sessionEndpoint(), transport, { EditorJournal(sessionPin, store) }, {
            entered.countDown(); check(release.await(3, TimeUnit.SECONDS)); sessionEndpoint()
        })
        val old = session.read(sessionProfile, "7", "b".repeat(64))
        assertTrue(entered.await(3, TimeUnit.SECONDS))
        old.cancel(true)
        assertFalse(session.settled)
        assertThrows(Exception::class.java) { session.submit("other") }
        session.close()
        assertFalse(session.settled)
        release.countDown()
        val limit = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (!session.settled && System.nanoTime() < limit) Thread.yield()
        assertTrue(session.settled)
        assertEquals(0, transport.count)
    }
    @Test fun restoredOriginNeverRetargets() {
        val store = sessionStore(); val transport = SessionTransport()
        EditorJournal(sessionPin, store).enqueue(EditorLabelIntent(EditorHostScope(sessionPin, sessionAuthority), "old-op", "7", sessionProfile, "ce000000-0000-0000-0000-000000000001", null))
        val session = PhoneEditorSession(sessionEndpoint(), transport, { EditorJournal(sessionPin, store) }, { sessionEndpoint("22222222-2222-2222-2222-222222222222") })
        try {
            assertThrows(Exception::class.java) { session.submit("old-op").get() }
            assertThrows(Exception::class.java) { session.reconcile("old-op").get() }
            assertEquals(0, transport.count)
            assertEquals(1, session.snapshot().get().entries.size)
        } finally { session.close() }
    }
    @Test fun corruptJournalNeverResets() {
        val corrupt = "broken".toByteArray()
        var saves = 0
        val store = object : EditorJournalStorage {
            override fun load() = corrupt.copyOf()
            override fun save(candidate: ByteArray, expected: ByteArray?) { saves++ }
        }
        val session = PhoneEditorSession(sessionEndpoint(), SessionTransport(), { EditorJournal(sessionPin, store) }, { sessionEndpoint() })
        try {
            assertThrows(Exception::class.java) { session.snapshot().get() }
            assertThrows(Exception::class.java) { session.snapshot().get() }
            assertEquals(0, saves)
        } finally { session.close() }
    }

    @Test fun closeAlsoReservesPendingOfflineJournalWork() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val session = PhoneEditorSession(sessionEndpoint(), SessionTransport(), {
            entered.countDown(); check(release.await(3, TimeUnit.SECONDS))
            EditorJournal(sessionPin, SessionStore())
        }, { error("offline") })
        val snapshot = session.snapshot()
        assertTrue(entered.await(3, TimeUnit.SECONDS))
        session.close()
        assertFalse(session.settled)
        release.countDown()
        try { snapshot.get(3, TimeUnit.SECONDS) } catch (_: Exception) {}
        val limit = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (!session.settled && System.nanoTime() < limit) Thread.yield()
        assertTrue(session.settled)
    }

}
