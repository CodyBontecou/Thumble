package com.thumble.rewrite.input

import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

private val editorClientPin = "a".repeat(64)
private val editorClientAuthority = "11111111-1111-1111-1111-111111111111"
private val editorClientConnection = "ab".repeat(16)

private fun editorClientScope() = EditorHostScope(editorClientPin, editorClientAuthority)

private fun editorClientIntent() =
    EditorLabelIntent(
        editorClientScope(),
        "edit-A-1",
        "7",
        "aaaaaaaa-0000-0000-0000-000000000001",
        "ce000000-0000-0000-0000-000000000001",
        "Move 🦊",
    )

private class EditorClientMemoryStore : EditorJournalStorage {
    var bytes: ByteArray? = null
    var fail = false

    override fun load() = bytes?.copyOf()

    override fun save(candidate: ByteArray, expected: ByteArray?) {
        if (fail) throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
        if (!(bytes?.contentEquals(expected ?: byteArrayOf()) ?: (expected == null)))
            throw EditorJournalException(EditorJournalException.Code.CHANGED_ON_DISK)
        bytes = candidate.copyOf()
    }
}

private fun editorClientFixture(): JSONObject =
    PhoneEditorTest::class
        .java
        .classLoader!!
        .getResourceAsStream("Fixtures/phone-editor-control-v1.json")!!
        .use { JSONObject(it.bufferedReader().readText()) }

private fun editorClientVector(name: String): ByteArray {
    val rows = editorClientFixture().getJSONArray("cases")
    return (0 until rows.length())
        .map { rows.getJSONObject(it) }
        .single { it.getString("name") == name }
        .getJSONObject("reply")
        .toString()
        .toByteArray(Charsets.UTF_8)
}

private class EditorScriptTransport(private val responses: MutableList<ByteArray>) :
    EditorRPCTransport {
    var count = 0

    override fun exchange(request: EditorRequest): EditorAuthenticatedReply {
        count++
        val reply = EditorWire.reply(responses.removeAt(0), request, editorClientConnection)
        return EditorAuthenticatedReply(request.scope, "phone-a", 1, editorClientConnection, reply)
    }

    override fun cancel() {}
}

class PhoneEditorTest {
    @Test
    fun sharedStrictVectorsAndHostileRequestsReplies() {
        val fixture = editorClientFixture()
        val scope = editorClientScope()
        val cases = fixture.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val vector = cases.getJSONObject(i)
            val bytes = vector.getJSONObject("request").toString().toByteArray(Charsets.UTF_8)
            val request = EditorWire.request(bytes, scope, editorClientConnection)
            assertEquals(
                EditorWire.parse(bytes),
                EditorWire.parse(
                    JSONObject(request.fields(editorClientConnection))
                        .toString()
                        .toByteArray(Charsets.UTF_8)
                ),
            )
            EditorWire.reply(
                vector.getJSONObject("reply").toString().toByteArray(Charsets.UTF_8),
                request,
                editorClientConnection,
            )
        }
        for (key in listOf("invalidRequests", "invalidReplies")) {
            val rows = fixture.getJSONArray(key)
            for (i in 0 until rows.length()) {
                val vector = rows.getJSONObject(i)
                val raw = vector.getString("utf8").toByteArray(Charsets.UTF_8)
                try {
                    if (key == "invalidRequests")
                        EditorWire.request(raw, scope, editorClientConnection)
                    else
                        EditorWire.reply(
                            raw,
                            EditorWire.request(
                                vector
                                    .getJSONObject("request")
                                    .toString()
                                    .toByteArray(Charsets.UTF_8),
                                scope,
                                editorClientConnection,
                            ),
                            editorClientConnection,
                        )
                    fail("editor_hostile_vector_accepted")
                } catch (_: PhoneEditorException) {} catch (_: EditorJournalException) {}
            }
        }
    }

    @Test
    fun durableUncertainBeforeDispatchExactStatusOnlyRetires() {
        val transport =
            EditorScriptTransport(
                mutableListOf(
                    editorClientVector("label-admitted"),
                    editorClientVector("status-receipt"),
                )
            )
        PhoneEditorCoordinator(
                { EditorJournal(editorClientPin, EditorClientMemoryStore()) },
                transport,
            )
            .use { coordinator ->
                val intent = editorClientIntent()
                coordinator.enqueue(intent).get(2, TimeUnit.SECONDS)
                assertEquals(
                    EditorDispatchOutcome.Retained,
                    coordinator
                        .submit(intent.operationID, editorClientScope())
                        .get(2, TimeUnit.SECONDS),
                )
                assertEquals(
                    EditorPendingStatus.Uncertain,
                    coordinator.snapshot().get(2, TimeUnit.SECONDS).entries.single().status,
                )
                assertEquals(
                    EditorDispatchOutcome.Retained,
                    coordinator
                        .submit(intent.operationID, editorClientScope())
                        .get(2, TimeUnit.SECONDS),
                )
                assertEquals(1, transport.count)
                assertEquals(
                    EditorDispatchOutcome.Committed,
                    coordinator
                        .reconcile(intent.operationID, editorClientScope())
                        .get(2, TimeUnit.SECONDS),
                )
                assertTrue(coordinator.snapshot().get(2, TimeUnit.SECONDS).entries.isEmpty())
                assertTrue(coordinator.snapshot().get(2, TimeUnit.SECONDS).profiles.isEmpty())
            }
    }

    private fun pages(): List<ByteArray> {
        val first = editorClientVector("profile-first-page")
        val middle =
            JSONObject(String(first, Charsets.UTF_8)).put("offset", 8).put("nextOffset", 16)
        fun controls(start: Int, end: Int) =
            org.json.JSONArray().also { rows ->
                for (i in start..end) rows.put(
                    JSONObject()
                        .put("id", "ce000000-0000-0000-0000-%012d".format(i))
                        .put("generatedLabel", "Control $i")
                        .put("labelOverride", JSONObject.NULL)
                )
            }
        middle.put("controls", controls(9, 16))
        val last =
            JSONObject(String(editorClientVector("profile-final-page"), Charsets.UTF_8))
                .put("controls", controls(17, 18))
        return listOf(
            first,
            middle.toString().toByteArray(Charsets.UTF_8),
            last.toString().toByteArray(Charsets.UTF_8),
        )
    }

    @Test
    fun completeReadRejectsPeerNameTotalAndDuplicateDriftBeforeCache() {
        val pin =
            EditorReadPin(
                editorClientScope(),
                "7",
                "a".repeat(64),
                "aaaaaaaa-0000-0000-0000-000000000001",
            )
        for (mode in listOf("good", "phone", "epoch", "name", "total", "duplicate")) {
            val bytes = pages().toMutableList()
            if (mode in listOf("name", "total", "duplicate")) {
                val middle = JSONObject(String(bytes[1], Charsets.UTF_8))
                if (mode == "name") middle.put("name", "Changed name")
                if (mode == "total") middle.put("totalControls", 19)
                if (mode == "duplicate")
                    middle
                        .getJSONArray("controls")
                        .getJSONObject(0)
                        .put("id", "ce000000-0000-0000-0000-000000000001")
                bytes[1] = middle.toString().toByteArray(Charsets.UTF_8)
            }
            val transport =
                object : EditorRPCTransport {
                    var index = 0

                    override fun exchange(request: EditorRequest): EditorAuthenticatedReply {
                        val at = index++
                        return EditorAuthenticatedReply(
                            request.scope,
                            if (mode == "phone" && at == 1) "phone-b" else "phone-a",
                            if (mode == "epoch" && at == 1) 2 else 1,
                            editorClientConnection,
                            EditorWire.reply(bytes[at], request, editorClientConnection),
                        )
                    }

                    override fun cancel() {}
                }
            PhoneEditorCoordinator(
                    { EditorJournal(editorClientPin, EditorClientMemoryStore()) },
                    transport,
                )
                .use { coordinator ->
                    if (mode == "good") {
                        assertEquals(
                            18,
                            coordinator.readProfile(pin).get(2, TimeUnit.SECONDS).controls.size,
                        )
                        assertEquals(
                            1,
                            coordinator.snapshot().get(2, TimeUnit.SECONDS).profiles.size,
                        )
                    } else {
                        try {
                            coordinator.readProfile(pin).get(2, TimeUnit.SECONDS)
                            fail("editor_page_drift_accepted")
                        } catch (_: java.util.concurrent.ExecutionException) {}
                        assertTrue(
                            coordinator.snapshot().get(2, TimeUnit.SECONDS).profiles.isEmpty()
                        )
                    }
                }
        }
    }

    @Test
    fun durableMarkerFailureAndOriginMismatchNeverDispatch() {
        val store = EditorClientMemoryStore()
        val transport = EditorScriptTransport(mutableListOf())
        PhoneEditorCoordinator({ EditorJournal(editorClientPin, store) }, transport).use {
            coordinator ->
            val intent = editorClientIntent()
            coordinator.enqueue(intent).get(2, TimeUnit.SECONDS)
            store.fail = true
            try {
                coordinator.submit(intent.operationID, editorClientScope()).get(2, TimeUnit.SECONDS)
                fail("failed_marker_dispatched")
            } catch (error: java.util.concurrent.ExecutionException) {
                assertEquals(
                    EditorJournalException.Code.UNAVAILABLE,
                    (error.cause as EditorJournalException).code,
                )
            }
            val changed = EditorHostScope(editorClientPin, "22222222-2222-2222-2222-222222222222")
            try {
                coordinator.reconcile(intent.operationID, changed).get(2, TimeUnit.SECONDS)
                fail("old_origin_retargeted")
            } catch (error: java.util.concurrent.ExecutionException) {
                assertEquals(
                    PhoneEditorException.Code.ORIGIN_RECONCILIATION_REQUIRED,
                    (error.cause as PhoneEditorException).code,
                )
            }
            assertEquals(0, transport.count)
        }
    }

    @Test
    fun cancellationFencesLateReceiptAndRetainsTheInflightSlot() {
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val transport =
            object : EditorRPCTransport {
                override fun exchange(request: EditorRequest): EditorAuthenticatedReply {
                    entered.countDown()
                    check(release.await(2, TimeUnit.SECONDS))
                    return EditorAuthenticatedReply(
                        request.scope,
                        "phone-a",
                        1,
                        editorClientConnection,
                        EditorWire.reply(
                            editorClientVector("label-committed"),
                            request,
                            editorClientConnection,
                        ),
                    )
                }

                override fun cancel() {}
            }
        PhoneEditorCoordinator(
                { EditorJournal(editorClientPin, EditorClientMemoryStore()) },
                transport,
            )
            .use { coordinator ->
                val intent = editorClientIntent()
                coordinator.enqueue(intent).get(2, TimeUnit.SECONDS)
                val pending = coordinator.submit(intent.operationID, editorClientScope())
                assertTrue(entered.await(2, TimeUnit.SECONDS))
                coordinator.cancel()
                try {
                    coordinator
                        .reconcile(intent.operationID, editorClientScope())
                        .get(2, TimeUnit.SECONDS)
                    fail("overlapping_rpc_admitted")
                } catch (error: java.util.concurrent.ExecutionException) {
                    assertEquals(
                        PhoneEditorException.Code.BUSY,
                        (error.cause as PhoneEditorException).code,
                    )
                }
                release.countDown()
                try {
                    pending.get(2, TimeUnit.SECONDS)
                    fail("late_cancelled_receipt_retired")
                } catch (error: java.util.concurrent.ExecutionException) {
                    assertEquals(
                        PhoneEditorException.Code.UNAVAILABLE,
                        (error.cause as PhoneEditorException).code,
                    )
                }
                assertEquals(
                    EditorPendingStatus.Uncertain,
                    coordinator.snapshot().get(2, TimeUnit.SECONDS).entries.single().status,
                )
            }
    }

    @Test
    fun conflictsUnknownErrorsAndPendingCannotRetireTheIntent() {
        for (vector in listOf("label-conflict", "editor_unavailable", "unknown")) {
            val transport =
                EditorScriptTransport(
                    if (vector == "unknown") mutableListOf()
                    else mutableListOf(editorClientVector(vector))
                )
            PhoneEditorCoordinator(
                    { EditorJournal(editorClientPin, EditorClientMemoryStore()) },
                    transport,
                )
                .use { coordinator ->
                    val intent = editorClientIntent()
                    coordinator.enqueue(intent).get(2, TimeUnit.SECONDS)
                    try {
                        coordinator
                            .submit(intent.operationID, editorClientScope())
                            .get(2, TimeUnit.SECONDS)
                        assertNotEquals("unknown", vector)
                    } catch (_: java.util.concurrent.ExecutionException) {
                        assertEquals("unknown", vector)
                    }
                    assertEquals(1, coordinator.snapshot().get(2, TimeUnit.SECONDS).entries.size)
                }
        }
        PhoneEditorCoordinator(
                { EditorJournal(editorClientPin, EditorClientMemoryStore()) },
                EditorScriptTransport(
                    mutableListOf(
                        editorClientVector("label-admitted"),
                        editorClientVector("status-pending-unknown"),
                    )
                ),
            )
            .use { coordinator ->
                val intent = editorClientIntent()
                coordinator.enqueue(intent).get(2, TimeUnit.SECONDS)
                coordinator.submit(intent.operationID, editorClientScope()).get(2, TimeUnit.SECONDS)
                assertEquals(
                    EditorDispatchOutcome.Retained,
                    coordinator
                        .reconcile(intent.operationID, editorClientScope())
                        .get(2, TimeUnit.SECONDS),
                )
                assertEquals(
                    EditorPendingStatus.Uncertain,
                    coordinator.snapshot().get(2, TimeUnit.SECONDS).entries.single().status,
                )
            }
    }

    @Test
    fun completedOldFutureCannotCancelANewRpc() {
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val cancels = java.util.concurrent.atomic.AtomicInteger()
        val calls = java.util.concurrent.atomic.AtomicInteger()
        val transport =
            object : EditorRPCTransport {
                override fun exchange(request: EditorRequest): EditorAuthenticatedReply {
                    val at = calls.incrementAndGet()
                    if (at == 2) {
                        entered.countDown()
                        check(release.await(2, TimeUnit.SECONDS))
                    }
                    val bytes =
                        editorClientVector(if (at == 1) "label-admitted" else "status-receipt")
                    return EditorAuthenticatedReply(
                        request.scope,
                        "phone-a",
                        1,
                        editorClientConnection,
                        EditorWire.reply(bytes, request, editorClientConnection),
                    )
                }

                override fun cancel() {
                    cancels.incrementAndGet()
                }
            }
        PhoneEditorCoordinator(
                { EditorJournal(editorClientPin, EditorClientMemoryStore()) },
                transport,
            )
            .use { coordinator ->
                val intent = editorClientIntent()
                coordinator.enqueue(intent).get(2, TimeUnit.SECONDS)
                val old = coordinator.submit(intent.operationID, editorClientScope())
                old.get(2, TimeUnit.SECONDS)
                val next = coordinator.reconcile(intent.operationID, editorClientScope())
                try {
                    assertTrue(entered.await(2, TimeUnit.SECONDS))
                    assertFalse(old.cancel(false))
                    assertEquals(0, cancels.get())
                } finally {
                    release.countDown()
                }
                assertEquals(EditorDispatchOutcome.Committed, next.get(2, TimeUnit.SECONDS))
            }
    }

    @Test
    fun alreadyCancelledOldFutureCannotCancelANewRpc() {
        val firstEntered = java.util.concurrent.CountDownLatch(1)
        val firstRelease = java.util.concurrent.CountDownLatch(1)
        val nextEntered = java.util.concurrent.CountDownLatch(1)
        val nextRelease = java.util.concurrent.CountDownLatch(1)
        val cancels = java.util.concurrent.atomic.AtomicInteger()
        val calls = java.util.concurrent.atomic.AtomicInteger()
        val transport =
            object : EditorRPCTransport {
                override fun exchange(request: EditorRequest): EditorAuthenticatedReply {
                    val at = calls.incrementAndGet()
                    if (at == 1) {
                        firstEntered.countDown()
                        check(firstRelease.await(2, TimeUnit.SECONDS))
                    } else {
                        nextEntered.countDown()
                        check(nextRelease.await(2, TimeUnit.SECONDS))
                    }
                    return EditorAuthenticatedReply(
                        request.scope,
                        "phone-a",
                        1,
                        editorClientConnection,
                        EditorWire.reply(
                            editorClientVector(
                                if (at == 1) "label-committed" else "status-receipt"
                            ),
                            request,
                            editorClientConnection,
                        ),
                    )
                }

                override fun cancel() {
                    cancels.incrementAndGet()
                }
            }
        PhoneEditorCoordinator(
                { EditorJournal(editorClientPin, EditorClientMemoryStore()) },
                transport,
            )
            .use { coordinator ->
                val intent = editorClientIntent()
                coordinator.enqueue(intent).get(2, TimeUnit.SECONDS)
                val old = coordinator.submit(intent.operationID, editorClientScope())
                assertTrue(firstEntered.await(2, TimeUnit.SECONDS))
                assertTrue(old.cancel(false))
                firstRelease.countDown()
                assertEquals(
                    EditorPendingStatus.Uncertain,
                    coordinator.snapshot().get(2, TimeUnit.SECONDS).entries.single().status,
                )
                val next = coordinator.reconcile(intent.operationID, editorClientScope())
                try {
                    assertTrue(nextEntered.await(2, TimeUnit.SECONDS))
                    assertFalse(old.cancel(false))
                    assertEquals(1, cancels.get())
                } finally {
                    nextRelease.countDown()
                }
                assertEquals(EditorDispatchOutcome.Committed, next.get(2, TimeUnit.SECONDS))
            }
    }
}
