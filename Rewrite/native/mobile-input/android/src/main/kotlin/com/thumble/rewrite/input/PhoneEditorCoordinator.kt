package com.thumble.rewrite.input

import java.io.Closeable
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal sealed class EditorDispatchOutcome {
    data object Committed : EditorDispatchOutcome()

    data object Retained : EditorDispatchOutcome()

    data class Conflict(val revision: String) : EditorDispatchOutcome()
}

/** Single native worker owns journal IO and management IO; no UI/input executor is shared. */
internal class PhoneEditorCoordinator(
    private val openJournal: () -> EditorJournal,
    private val transport: EditorRPCTransport,
) : Closeable {
    private val worker =
        ThreadPoolExecutor(
            1,
            1,
            0,
            TimeUnit.MILLISECONDS,
            ArrayBlockingQueue(16),
            { action -> Thread(action, "thumble-editor-owner").apply { isDaemon = true } },
            ThreadPoolExecutor.AbortPolicy(),
        )
    private val closed = AtomicBoolean(false)

    private class RpcLease {
        var cancelled = false
    }

    private val rpcGate = Any()
    private var active: RpcLease? = null
    private var journal: EditorJournal? = null

    private fun owner(): EditorJournal = journal ?: openJournal().also { journal = it }

    private fun <T> work(action: () -> T): CompletableFuture<T> {
        val future = CompletableFuture<T>()
        if (closed.get()) {
            future.completeExceptionally(
                PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE)
            )
            return future
        }
        try {
            worker.execute {
                if (closed.get())
                    future.completeExceptionally(
                        PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE)
                    )
                else
                    try {
                        future.complete(action())
                    } catch (error: Exception) {
                        future.completeExceptionally(error)
                    }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            future.completeExceptionally(PhoneEditorException(PhoneEditorException.Code.BUSY))
        }
        return future
    }

    fun snapshot() = work { owner().snapshot() }

    fun enqueue(intent: EditorLabelIntent) = work { owner().enqueue(intent) }

    fun select(selection: EditorSelection?) = work { owner().select(selection) }

    // This gate is editor-local. Admission, cancellation/close and final slot release
    // are ordered together; a stale future can never close a newer transport.
    fun cancel() =
        synchronized(rpcGate) {
            val lease = active
            if (lease != null && !lease.cancelled) {
                lease.cancelled = true
                transport.cancel()
            }
        }

    private fun current(token: RpcLease) =
        synchronized(rpcGate) {
            if (
                closed.get() ||
                    active !== token ||
                    token.cancelled ||
                    Thread.currentThread().isInterrupted
            )
                throw PhoneEditorException(PhoneEditorException.Code.UNAVAILABLE)
        }

    private fun <T> apply(token: RpcLease, action: () -> T): T =
        synchronized(rpcGate) {
            current(token)
            action()
        }

    private fun <T> rpc(action: (RpcLease) -> T): CompletableFuture<T> =
        synchronized(rpcGate) {
            if (closed.get() || active != null)
                return@synchronized CompletableFuture<T>().also {
                    it.completeExceptionally(
                        PhoneEditorException(
                            if (closed.get()) PhoneEditorException.Code.UNAVAILABLE
                            else PhoneEditorException.Code.BUSY
                        )
                    )
                }
            val token = RpcLease()
            active = token
            val future =
                object : CompletableFuture<T>() {
                    override fun cancel(mayInterruptIfRunning: Boolean): Boolean =
                        synchronized(rpcGate) {
                            if (active !== token || token.cancelled || isDone)
                                return@synchronized false
                            val changed = super.cancel(false)
                            if (changed && !token.cancelled) {
                                token.cancelled = true
                                transport.cancel()
                            }
                            changed
                        }
                }
            fun finish(result: T?, error: Exception?) =
                synchronized(rpcGate) {
                    if (active === token) active = null
                    if (error != null) future.completeExceptionally(error)
                    else {
                        @Suppress("UNCHECKED_CAST") future.complete(result as T)
                    }
                }
            try {
                worker.execute {
                    try {
                        current(token)
                        finish(action(token), null)
                    } catch (error: Exception) {
                        finish(null, error)
                    }
                }
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                finish(null, PhoneEditorException(PhoneEditorException.Code.BUSY))
            }
            future
        }

    private fun validate(result: EditorAuthenticatedReply, scope: EditorHostScope) {
        if (
            result.scope != scope ||
                result.phoneID.isEmpty() ||
                result.phoneID.toByteArray(Charsets.UTF_8).size > 128 ||
                result.credentialEpoch <= 0 ||
                !EditorWire.hex(result.connectionID, 32)
        )
            throw PhoneEditorException()
    }

    fun readProfile(pin: EditorReadPin) = rpc { token ->
        val controls = arrayListOf<EditorCachedControl>()
        val seen = hashSetOf<String>()
        var offset = 0
        var total: Int? = null
        var name: String? = null
        var identity: Pair<String, Long>? = null
        var completed: EditorCachedProfile? = null
        for (pageIndex in 0 until 16) {
            current(token)
            val result = transport.exchange(EditorRequest.Profile(pin, offset))
            current(token)
            validate(result, pin.scope)
            val peer = Pair(result.phoneID, result.credentialEpoch)
            if (identity != null && identity != peer) throw PhoneEditorException()
            identity = peer
            val page = (result.reply as? EditorReply.Profile)?.page ?: throw PhoneEditorException()
            if (
                page.pin != pin ||
                    page.offset != offset ||
                    (total != null && total != page.total) ||
                    (name != null && name != page.name)
            )
                throw PhoneEditorException()
            total = page.total
            name = page.name
            for (control in page.controls) {
                if (!seen.add(control.id)) throw PhoneEditorException()
                controls.add(control)
            }
            if (controls.size > 128) throw PhoneEditorException()
            if (page.next == null) {
                if (controls.size != page.total) throw PhoneEditorException()
                completed =
                    EditorCachedProfile(
                        pin.scope,
                        pin.profileID,
                        page.name,
                        pin.revision,
                        pin.sourceHash,
                        controls,
                    )
                break
            }
            if (page.next != controls.size || page.next <= offset) throw PhoneEditorException()
            offset = page.next
        }
        val profile = completed ?: throw PhoneEditorException()
        apply(token) { owner().accept(VerifiedEditorRead(profile)) }
        profile
    }

    private fun pending(id: String, scope: EditorHostScope): EditorPendingEntry {
        val entry =
            owner().snapshot().entries.firstOrNull { it.intent.operationID == id }
                ?: throw PhoneEditorException()
        if (entry.intent.scope != scope)
            throw PhoneEditorException(PhoneEditorException.Code.ORIGIN_RECONCILIATION_REQUIRED)
        return entry
    }

    fun submit(operationID: String, scope: EditorHostScope) = rpc { token ->
        val entry = pending(operationID, scope)
        if (entry.status != EditorPendingStatus.Queued) EditorDispatchOutcome.Retained
        else {
            apply(token) { owner().mark(operationID, EditorPendingStatus.Uncertain) }
            current(token)
            val result = transport.exchange(EditorRequest.Label(entry.intent))
            current(token)
            validate(result, entry.intent.scope)
            apply(token) { consume(result, entry.intent) }
        }
    }

    fun reconcile(operationID: String, scope: EditorHostScope) = rpc { token ->
        val entry = pending(operationID, scope)
        current(token)
        val result = transport.exchange(EditorRequest.Status(entry.intent))
        current(token)
        validate(result, entry.intent.scope)
        apply(token) { consume(result, entry.intent) }
    }

    private fun consume(
        result: EditorAuthenticatedReply,
        intent: EditorLabelIntent,
    ): EditorDispatchOutcome =
        when (val reply = result.reply) {
            is EditorReply.Committed -> {
                val receipt = reply.receipt
                owner()
                    .acknowledge(
                        VerifiedEditorAcknowledgment(
                            intent,
                            result.scope,
                            result.connectionID,
                            receipt.operationID,
                            receipt.revision,
                            receipt.hash,
                            receipt.entities,
                            false,
                        ),
                        result.scope,
                        result.connectionID,
                    )
                EditorDispatchOutcome.Committed
            }
            is EditorReply.Conflict -> {
                owner().mark(intent.operationID, EditorPendingStatus.Conflict(reply.revision))
                EditorDispatchOutcome.Conflict(reply.revision)
            }
            is EditorReply.Error -> {
                if (reply.code == "editor_operation_reused")
                    owner().mark(intent.operationID, EditorPendingStatus.Rejected)
                EditorDispatchOutcome.Retained
            }
            EditorReply.Admitted,
            EditorReply.Pending -> EditorDispatchOutcome.Retained
            is EditorReply.Profile -> throw PhoneEditorException()
        }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            cancel()
            worker.shutdown()
        }
    }
}
