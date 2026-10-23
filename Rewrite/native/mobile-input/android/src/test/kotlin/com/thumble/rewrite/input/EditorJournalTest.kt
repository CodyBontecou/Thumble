package com.thumble.rewrite.input

import java.security.MessageDigest
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

private val editorPin = "a".repeat(64)
private val editorAuthority = "11111111-1111-1111-1111-111111111111"
private val editorA = "aaaaaaaa-0000-0000-0000-000000000001"
private val editorB = "bbbbbbbb-0000-0000-0000-000000000002"
private val editorControl = "ce000000-0000-0000-0000-000000000001"

private fun scope(authority: String = editorAuthority) = EditorHostScope(editorPin, authority)

private fun intent(op: String = "edit-A-1", profile: String = editorA, label: String? = "Move 🦊") =
    EditorLabelIntent(scope(), op, "7", profile, editorControl, label)

private fun profile(id: String = editorA, revision: String = "7") =
    EditorCachedProfile(
        scope(),
        id,
        "Synthetic",
        revision,
        "b".repeat(64),
        listOf(EditorCachedControl(editorControl, "Movement", null)),
    )

private class EditorMemoryStore : EditorJournalStorage {
    var bytes: ByteArray? = null
    var beforeFailure = false
    var afterFailure = false

    override fun load() = bytes?.copyOf()

    override fun save(candidate: ByteArray, expected: ByteArray?) {
        if (!(bytes?.contentEquals(expected ?: byteArrayOf()) ?: (expected == null)))
            throw EditorJournalException(EditorJournalException.Code.CHANGED_ON_DISK)
        if (beforeFailure) throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
        bytes = candidate.copyOf()
        if (afterFailure) throw EditorJournalException(EditorJournalException.Code.UNCERTAIN)
    }
}

private fun ack(
    intent: EditorLabelIntent,
    operation: String = intent.operationID,
    responseScope: EditorHostScope = scope(),
    session: String = "verified-session",
    revision: String = "8",
    hash: String = "c".repeat(64),
    entities: List<String> = listOf(intent.profileID, intent.controlID),
    rebound: Boolean = false,
) =
    VerifiedEditorAcknowledgment(
        intent,
        responseScope,
        session,
        operation,
        revision,
        hash,
        entities,
        rebound,
    )

private fun fails(
    code: EditorJournalException.Code = EditorJournalException.Code.INVALID,
    action: () -> Unit,
) {
    try {
        action()
        fail("expected_editor_journal_rejection")
    } catch (error: EditorJournalException) {
        assertEquals(code, error.code)
    }
}

class EditorJournalTest {
    @Test
    fun sharedCanonicalFixturePreservesABAAndNullableLabels() {
        val fixture =
            javaClass.classLoader!!
                .getResourceAsStream("Fixtures/phone-editor-journal-v1.json")!!
                .use { JSONObject(it.bufferedReader().readText()) }
        val bytes = fixture.getString("canonicalState").toByteArray(Charsets.UTF_8)
        val state = EditorJournalCodec.decode(bytes)
        assertArrayEquals(bytes, EditorJournalCodec.encode(state))
        assertEquals(
            fixture.getString("stateSHA256"),
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
                "%02x".format(it.toInt() and 255)
            },
        )
        assertEquals(listOf(editorA, editorB, editorA), state.entries.map { it.intent.profileID })
        assertEquals(listOf("Move 🦊", "", null), state.entries.map { it.intent.label })
        assertEquals(
            listOf(
                EditorPendingStatus.Queued,
                EditorPendingStatus.Uncertain,
                EditorPendingStatus.Conflict("9"),
            ),
            state.entries.map { it.status },
        )
        assertEquals(editorA, state.selection!!.profileID)
    }

    @Test
    fun durableEnqueueAndSelectionNeverRedirectOriginalIntents() {
        val store = EditorMemoryStore()
        val journal = EditorJournal(editorPin, store)
        journal.accept(VerifiedEditorRead(profile()))
        journal.accept(VerifiedEditorRead(profile(editorB)))
        val first = intent()
        journal.enqueue(first)
        journal.select(EditorSelection(scope(), editorB))
        journal.enqueue(intent("edit-B-1", editorB, ""))
        journal.select(EditorSelection(scope(), editorA))
        journal.enqueue(intent("edit-A-2", label = null))
        val bytes = store.bytes!!.copyOf()
        journal.enqueue(first)
        assertArrayEquals(bytes, store.bytes)
        assertEquals(
            listOf(editorA, editorB, editorA),
            journal.snapshot().entries.map { it.intent.profileID },
        )
        assertEquals(journal.snapshot(), EditorJournal(editorPin, store).snapshot())
        fails(EditorJournalException.Code.OPERATION_REUSED) {
            journal.enqueue(intent(label = "changed"))
        }
    }

    @Test
    fun exactAcknowledgmentRetiresOnlyItsEntryAndCannotAdvanceReadCache() {
        val store = EditorMemoryStore()
        val journal = EditorJournal(editorPin, store)
        val first = intent()
        journal.accept(VerifiedEditorRead(profile(revision = "20")))
        journal.enqueue(first)
        journal.enqueue(intent("another", editorB))
        val before = journal.snapshot().profiles
        val invalid =
            listOf(
                ack(first, operation = "wrong"),
                ack(intent(label = "changed")),
                ack(first, session = "old-session"),
                ack(first, revision = "7"),
                ack(first, revision = "9"),
                ack(first, hash = "bad"),
                ack(first, entities = listOf(editorA)),
            )
        for (bad in invalid) {
            fails { journal.acknowledge(bad, scope(), "verified-session") }
            assertEquals(2, journal.snapshot().entries.size)
        }
        journal.acknowledge(ack(first), scope(), "verified-session")
        assertEquals(listOf("another"), journal.snapshot().entries.map { it.intent.operationID })
        assertEquals(before, journal.snapshot().profiles)
        assertEquals(journal.snapshot(), EditorJournal(editorPin, store).snapshot())
    }

    @Test
    fun oldAuthorityNeedsInternalVerifiedRebindAndCrossHostNeverAcknowledges() {
        val store = EditorMemoryStore()
        val journal = EditorJournal(editorPin, store)
        val first = intent()
        journal.enqueue(first)
        val current = scope("22222222-2222-2222-2222-222222222222")
        fails {
            journal.acknowledge(ack(first, responseScope = current), current, "verified-session")
        }
        val foreign = EditorHostScope("d".repeat(64), editorAuthority)
        fails {
            journal.acknowledge(
                ack(first, responseScope = foreign, rebound = true),
                foreign,
                "verified-session",
            )
        }
        journal.acknowledge(
            ack(first, responseScope = current, rebound = true),
            current,
            "verified-session",
        )
        assertTrue(journal.snapshot().entries.isEmpty())
    }

    @Test
    fun conflictRejectedAndUncertainOutcomesNeverDiscardIntent() {
        val store = EditorMemoryStore()
        val journal = EditorJournal(editorPin, store)
        val first = intent()
        journal.enqueue(first)
        for (status in
            listOf(
                EditorPendingStatus.Conflict("9"),
                EditorPendingStatus.Uncertain,
                EditorPendingStatus.Rejected,
            )) {
            journal.mark(first.operationID, status)
            assertEquals(listOf(EditorPendingEntry(first, status)), journal.snapshot().entries)
            assertEquals(journal.snapshot(), EditorJournal(editorPin, store).snapshot())
        }
    }

    @Test
    fun precommitWriteFailurePreservesDiskAndMemoryForEnqueueAndAck() {
        val store = EditorMemoryStore()
        val journal = EditorJournal(editorPin, store)
        val first = intent()
        val empty = journal.snapshot()
        store.beforeFailure = true
        fails(EditorJournalException.Code.UNAVAILABLE) { journal.enqueue(first) }
        assertNull(store.bytes)
        assertEquals(empty, journal.snapshot())
        store.beforeFailure = false
        journal.enqueue(first)
        val bytes = store.bytes!!.copyOf()
        val before = journal.snapshot()
        store.beforeFailure = true
        fails(EditorJournalException.Code.UNAVAILABLE) {
            journal.acknowledge(ack(first), scope(), "verified-session")
        }
        assertArrayEquals(bytes, store.bytes)
        assertEquals(before, journal.snapshot())
    }

    @Test
    fun postReplaceUncertaintyKeepsOriginalOperationAndLatchesUntilReopen() {
        val store = EditorMemoryStore()
        val journal = EditorJournal(editorPin, store)
        val first = intent()
        store.afterFailure = true
        fails(EditorJournalException.Code.UNCERTAIN) { journal.enqueue(first) }
        assertTrue(journal.requiresReopen())
        assertEquals(first.operationID, journal.recoveryOperationID())
        assertTrue(journal.snapshot().entries.isEmpty())
        fails(EditorJournalException.Code.UNCERTAIN) { journal.enqueue(intent("new-id")) }
        store.afterFailure = false
        val recovered = EditorJournal(editorPin, store)
        assertEquals(listOf(first), recovered.snapshot().entries.map { it.intent })
        store.afterFailure = true
        fails(EditorJournalException.Code.UNCERTAIN) {
            recovered.acknowledge(ack(first), scope(), "verified-session")
        }
        assertEquals(1, recovered.snapshot().entries.size)
        assertTrue(EditorJournal(editorPin, store).snapshot().entries.isEmpty())
    }

    @Test
    fun corruptUnknownDuplicateAndOversizedStateCannotBeReset() {
        val valid = EditorJournalCodec.encode(EditorJournalSnapshot(editorPin))
        val duplicates =
            "{\"certificateSHA256\":\"$editorPin\",\"certificateSHA256\":\"$editorPin\",\"entries\":[],\"profiles\":[],\"schemaVersion\":1,\"selection\":null}"
                .toByteArray()
        for (bytes in
            listOf(
                byteArrayOf(),
                "{}".toByteArray(),
                valid + byteArrayOf(32),
                duplicates,
                "[".repeat(2000).toByteArray(),
                byteArrayOf(0xFF.toByte()),
                ByteArray(EditorJournalCodec.MAXIMUM_BYTES + 1) { 32 },
            )) {
            val store = EditorMemoryStore()
            store.bytes = bytes.copyOf()
            fails { EditorJournal(editorPin, store) }
            assertArrayEquals(bytes, store.bytes)
        }
        val store = EditorMemoryStore()
        store.bytes = valid
        fails { EditorJournal("d".repeat(64), store) }
    }

    @Test
    fun unicodeCounterAndCollectionBoundsAreExactAndSnapshotsAreImmutable() {
        EditorCachedProfile(
            scope(),
            editorA,
            "🦊".repeat(256),
            "18446744073709551615",
            "b".repeat(64),
            emptyList(),
        )
        fails {
            EditorCachedProfile(
                scope(),
                editorA,
                "🦊".repeat(257),
                "1",
                "b".repeat(64),
                emptyList(),
            )
        }
        intent(label = "🦊".repeat(32))
        fails { intent(label = "🦊".repeat(33)) }
        fails { intent(label = "\uD800") }
        val store = EditorMemoryStore()
        val journal = EditorJournal(editorPin, store)
        repeat(128) { journal.enqueue(intent("bounded-$it")) }
        val bytes = store.bytes!!.copyOf()
        fails(EditorJournalException.Code.FULL) { journal.enqueue(intent("overflow")) }
        assertArrayEquals(bytes, store.bytes)
        try {
            (journal.snapshot().entries as MutableList).clear()
            fail("immutable_list_required")
        } catch (_: UnsupportedOperationException) {}
        assertEquals(128, journal.snapshot().entries.size)
    }

    @Test
    fun cacheBoundsAndRevisionPinsRejectStaleOrConflictingReads() {
        val store = EditorMemoryStore()
        val journal = EditorJournal(editorPin, store)
        journal.accept(VerifiedEditorRead(profile(revision = "20")))
        val saved = store.bytes!!.copyOf()
        fails { journal.accept(VerifiedEditorRead(profile(revision = "19"))) }
        fails {
            journal.accept(
                VerifiedEditorRead(
                    EditorCachedProfile(
                        scope(),
                        editorA,
                        "changed",
                        "20",
                        "c".repeat(64),
                        emptyList(),
                    )
                )
            )
        }
        assertArrayEquals(saved, store.bytes)
        val controls =
            (0..128).map {
                EditorCachedControl("ce000000-0000-0000-0000-%012d".format(it), "", null)
            }
        fails { EditorCachedProfile(scope(), editorA, "", "1", "b".repeat(64), controls) }
        for (i in 1..7) journal.accept(
            VerifiedEditorRead(profile("aa000000-0000-0000-0000-%012d".format(i)))
        )
        val full = store.bytes!!.copyOf()
        fails(EditorJournalException.Code.FULL) {
            journal.accept(VerifiedEditorRead(profile(editorB)))
        }
        assertArrayEquals(full, store.bytes)
        val overflow =
            EditorLabelIntent(
                scope(),
                "max-revision",
                "18446744073709551615",
                editorA,
                editorControl,
                null,
            )
        journal.enqueue(overflow)
        fails { journal.acknowledge(ack(overflow, revision = "1"), scope(), "verified-session") }
    }
}
