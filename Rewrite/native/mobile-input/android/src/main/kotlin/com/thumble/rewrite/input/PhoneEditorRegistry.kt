package com.thumble.rewrite.input

import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Native module identity. Invalidating it never waits for a registry, journal or transport lock. */
class PhoneEditorModuleLifetime {
    private val live = AtomicBoolean(true)
    val isValid: Boolean get() = live.get()
    fun invalidate() { live.set(false) }
}

/** Process-wide protected journal reservation across JavaScript module lifetimes. */
class PhoneEditorRegistry {
    private class Reservation(val owner: PhoneEditorModuleLifetime) {
        var session: PhoneEditorSession? = null
        var handle: String? = null
        var creating = true
        var closing = false
        var closeStarted = false
        var closeReturned = false
        val closed = CompletableFuture<Unit>()
    }
    private val gate = Any()
    private var record: Reservation? = null
    private var opening = false
    // Only one record can retire at a time; no new owner can open before this close returns.
    private val closer = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { action -> Thread(action, "thumble-editor-close").apply { isDaemon = true } }, ThreadPoolExecutor.AbortPolicy())

    fun open(owner: PhoneEditorModuleLifetime, create: () -> PhoneEditorSession): CompletableFuture<String> {
        val result = CompletableFuture<String>()
        val previous: Reservation?
        synchronized(gate) {
            if (!owner.isValid || opening) return failed()
            opening = true
            previous = record
        }
        var candidate: Reservation? = null
        try {
            // Do not acquire a session gate or do IO while holding the registry monitor.
            if (previous != null) {
                val canReuse = synchronized(gate) { previous.closing && previous.closeReturned }
                check(canReuse && (previous.session?.settled ?: true)) { "editor_busy" }
            }
            val next = Reservation(owner)
            synchronized(gate) {
                check(owner.isValid && record === previous) { "editor_closed" }
                record = next
                candidate = next
            }
            result.whenComplete { _, _ -> if (result.isCancelled) retire(next) }
            val session = create()
            val admitted = synchronized(gate) {
                next.session = session
                next.creating = false
                owner.isValid && !next.closing
            }
            if (!admitted) throw PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE)
            session.snapshot().whenComplete { _, error ->
                val handle = synchronized(gate) {
                    if (error == null && owner.isValid && !next.closing && record === next && !result.isCancelled) {
                        UUID.randomUUID().toString().also { next.handle = it; opening = false }
                    } else null
                }
                if (handle != null) result.complete(handle)
                else retire(next).whenComplete { _, _ ->
                    synchronized(gate) { opening = false }
                    result.completeExceptionally(error ?: PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE))
                }
            }
        } catch (error: Exception) {
            val failed = candidate
            if (failed != null) {
                synchronized(gate) { failed.creating = false }
                retire(failed).whenComplete { _, _ ->
                    synchronized(gate) { opening = false }
                    result.completeExceptionally(error)
                }
            } else {
                synchronized(gate) { opening = false }
                result.completeExceptionally(error)
            }
        }
        return result
    }
    fun session(owner: PhoneEditorModuleLifetime, handle: String): PhoneEditorSession = synchronized(gate) {
        val current = record
        check(owner.isValid && current != null && current.owner === owner && !current.closing && current.handle == handle) { "editor_closed" }
        checkNotNull(current.session)
    }
    fun close(owner: PhoneEditorModuleLifetime, handle: String): CompletableFuture<Unit> {
        val current = synchronized(gate) {
            val current = record
            check(owner.isValid && current != null && current.owner === owner && current.handle == handle) { "editor_closed" }
            current
        }
        return retire(current)
    }
    fun invalidate(owner: PhoneEditorModuleLifetime): CompletableFuture<Unit> {
        owner.invalidate()
        val current = synchronized(gate) { record?.takeIf { it.owner === owner } }
        return current?.let { retire(it) } ?: CompletableFuture.completedFuture(Unit)
    }
    private fun retire(current: Reservation): CompletableFuture<Unit> {
        var session: PhoneEditorSession? = null
        var noCandidate = false
        synchronized(gate) {
            current.closing = true
            if (!current.closeStarted && !current.creating) {
                current.closeStarted = true
                session = current.session
                noCandidate = session == null
                if (noCandidate) current.closeReturned = true
            }
        }
        if (noCandidate) current.closed.complete(Unit)
        session?.let { closing ->
            try {
                closer.execute {
                    try {
                        closing.close()
                        synchronized(gate) { current.closeReturned = true }
                        current.closed.complete(Unit)
                    } catch (error: Exception) { current.closed.completeExceptionally(error) }
                }
            } catch (error: Exception) { current.closed.completeExceptionally(error) }
        }
        return current.closed
    }
    private fun <T> failed(): CompletableFuture<T> = CompletableFuture<T>().also {
        it.completeExceptionally(PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE))
    }
}
