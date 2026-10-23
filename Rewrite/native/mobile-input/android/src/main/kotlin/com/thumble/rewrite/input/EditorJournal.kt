package com.thumble.rewrite.input

import java.math.BigInteger
import java.util.Collections

class EditorJournalException(val code: Code, val operationID: String? = null) :
    Exception("editor_journal_${code.name.lowercase()}") {
    enum class Code {
        INVALID,
        FULL,
        OPERATION_REUSED,
        UNAVAILABLE,
        CHANGED_ON_DISK,
        UNCERTAIN,
    }
}

class EditorHostScope(val certificateSHA256: String, authorityInstanceID: String) {
    val authorityInstanceID = EditorJournalCodec.uuid(authorityInstanceID)

    init {
        checkEditor(EditorJournalCodec.hash(certificateSHA256))
    }

    override fun equals(other: Any?) =
        other is EditorHostScope &&
            certificateSHA256 == other.certificateSHA256 &&
            authorityInstanceID == other.authorityInstanceID

    override fun hashCode() = listOf(certificateSHA256, authorityInstanceID).hashCode()
}

class EditorLabelIntent(
    scope: EditorHostScope,
    operationID: String,
    expectedRevision: String,
    profileID: String,
    controlID: String,
    label: String?,
) {
    val scope = scope
    val operationID = operationID
    val expectedRevision = expectedRevision
    val profileID = EditorJournalCodec.uuid(profileID)
    val controlID = EditorJournalCodec.uuid(controlID)
    val label = label

    init {
        checkEditor(
            EditorJournalCodec.operation(operationID) &&
                EditorJournalCodec.counter(expectedRevision) &&
                (label == null || EditorJournalCodec.label(label))
        )
    }

    override fun equals(other: Any?) =
        other is EditorLabelIntent &&
            scope == other.scope &&
            operationID == other.operationID &&
            expectedRevision == other.expectedRevision &&
            profileID == other.profileID &&
            controlID == other.controlID &&
            label == other.label

    override fun hashCode() =
        listOf(scope, operationID, expectedRevision, profileID, controlID, label).hashCode()
}

class EditorCachedControl(id: String, val generatedLabel: String, val labelOverride: String?) {
    val id = EditorJournalCodec.uuid(id)

    init {
        checkEditor(
            EditorJournalCodec.label(generatedLabel) &&
                (labelOverride == null || EditorJournalCodec.label(labelOverride))
        )
    }

    override fun equals(other: Any?) =
        other is EditorCachedControl &&
            id == other.id &&
            generatedLabel == other.generatedLabel &&
            labelOverride == other.labelOverride

    override fun hashCode() = listOf(id, generatedLabel, labelOverride).hashCode()
}

class EditorCachedProfile(
    val scope: EditorHostScope,
    id: String,
    val name: String,
    val revision: String,
    val sourceSHA256: String,
    controls: List<EditorCachedControl>,
) {
    val id = EditorJournalCodec.uuid(id)
    val controls: List<EditorCachedControl> = Collections.unmodifiableList(ArrayList(controls))

    init {
        checkEditor(
            EditorJournalCodec.scalars(name) &&
                name.codePointCount(0, name.length) <= 256 &&
                name.toByteArray(Charsets.UTF_8).size <= 1024 &&
                EditorJournalCodec.counter(revision) &&
                EditorJournalCodec.hash(sourceSHA256) &&
                this.controls.size <= 128 &&
                this.controls.map { it.id }.toSet().size == this.controls.size
        )
    }

    override fun equals(other: Any?) =
        other is EditorCachedProfile &&
            scope == other.scope &&
            id == other.id &&
            name == other.name &&
            revision == other.revision &&
            sourceSHA256 == other.sourceSHA256 &&
            controls == other.controls

    override fun hashCode() = listOf(scope, id, name, revision, sourceSHA256, controls).hashCode()
}

sealed class EditorPendingStatus {
    data object Queued : EditorPendingStatus()

    data object Uncertain : EditorPendingStatus()

    data object Rejected : EditorPendingStatus()

    data class Conflict(val currentRevision: String) : EditorPendingStatus() {
        init {
            checkEditor(EditorJournalCodec.counter(currentRevision))
        }
    }
}

data class EditorPendingEntry(val intent: EditorLabelIntent, val status: EditorPendingStatus)

class EditorSelection(val scope: EditorHostScope, profileID: String) {
    val profileID = EditorJournalCodec.uuid(profileID)

    override fun equals(other: Any?) =
        other is EditorSelection && scope == other.scope && profileID == other.profileID

    override fun hashCode() = listOf(scope, profileID).hashCode()
}

class EditorJournalSnapshot
internal constructor(
    val certificateSHA256: String,
    entries: List<EditorPendingEntry> = emptyList(),
    profiles: List<EditorCachedProfile> = emptyList(),
    val selection: EditorSelection? = null,
) {
    val entries: List<EditorPendingEntry> = Collections.unmodifiableList(ArrayList(entries))
    val profiles: List<EditorCachedProfile> = Collections.unmodifiableList(ArrayList(profiles))

    init {
        checkEditor(
            EditorJournalCodec.hash(certificateSHA256) &&
                this.entries.size <= 128 &&
                this.profiles.size <= 8 &&
                this.entries.all { it.intent.scope.certificateSHA256 == certificateSHA256 } &&
                this.profiles.all { it.scope.certificateSHA256 == certificateSHA256 } &&
                this.entries.map { it.intent.operationID }.toSet().size == this.entries.size &&
                this.profiles.map { it.scope.authorityInstanceID + "/" + it.id }.toSet().size ==
                    this.profiles.size &&
                (selection == null ||
                    this.profiles.any {
                        it.scope == selection.scope && it.id == selection.profileID
                    })
        )
    }

    override fun equals(other: Any?) =
        other is EditorJournalSnapshot &&
            certificateSHA256 == other.certificateSHA256 &&
            entries == other.entries &&
            profiles == other.profiles &&
            selection == other.selection

    override fun hashCode() = listOf(certificateSHA256, entries, profiles, selection).hashCode()
}

/** Future trusted role12 client only. No JSON factory or exported React acknowledgment API. */
internal class VerifiedEditorAcknowledgment(
    val intent: EditorLabelIntent,
    val responseScope: EditorHostScope,
    val sessionID: String,
    val receiptOperationID: String,
    val resultingRevision: String,
    val contentSHA256: String,
    affectedEntities: List<String>,
    val originRebound: Boolean,
) {
    val affectedEntities: List<String> = Collections.unmodifiableList(ArrayList(affectedEntities))
}

internal class VerifiedEditorRead(val profile: EditorCachedProfile)

interface EditorJournalStorage {
    fun load(): ByteArray?

    /**
     * Compare expected bytes under the storage transaction. Precommit errors preserve old bytes.
     */
    fun save(candidate: ByteArray, expected: ByteArray?)
}

/** Synchronous native owner. Never call disk work on input-delivery or animation paths. */
class EditorJournal(certificateSHA256: String, private val storage: EditorJournalStorage) {
    private var persisted: ByteArray? = storage.load()?.copyOf()
    private var state =
        persisted?.let(EditorJournalCodec::decode) ?: EditorJournalSnapshot(certificateSHA256)
    private var recovery: ByteArray? = null
    private var uncertainOperation: String? = null

    init {
        checkEditor(state.certificateSHA256 == certificateSHA256)
    }

    @Synchronized fun snapshot() = state

    @Synchronized fun requiresReopen() = recovery != null

    @Synchronized fun recoveryOperationID() = uncertainOperation

    private fun commit(candidate: EditorJournalSnapshot, operation: String?) {
        if (recovery != null)
            throw EditorJournalException(EditorJournalException.Code.UNCERTAIN, uncertainOperation)
        val bytes = EditorJournalCodec.encode(candidate)
        try {
            storage.save(bytes.copyOf(), persisted?.copyOf())
        } catch (error: EditorJournalException) {
            if (error.code == EditorJournalException.Code.UNCERTAIN) {
                recovery = bytes.copyOf()
                uncertainOperation = operation
                throw EditorJournalException(EditorJournalException.Code.UNCERTAIN, operation)
            }
            throw error
        }
        state = candidate
        persisted = bytes
    }

    @Synchronized
    fun enqueue(intent: EditorLabelIntent) {
        if (recovery != null)
            throw EditorJournalException(EditorJournalException.Code.UNCERTAIN, uncertainOperation)
        checkEditor(intent.scope.certificateSHA256 == state.certificateSHA256)
        state.entries
            .firstOrNull { it.intent.operationID == intent.operationID }
            ?.let {
                if (it.intent != intent)
                    throw EditorJournalException(EditorJournalException.Code.OPERATION_REUSED)
                return
            }
        if (state.entries.size >= 128)
            throw EditorJournalException(EditorJournalException.Code.FULL)
        commit(
            EditorJournalSnapshot(
                state.certificateSHA256,
                state.entries + EditorPendingEntry(intent, EditorPendingStatus.Queued),
                state.profiles,
                state.selection,
            ),
            intent.operationID,
        )
    }

    @Synchronized
    fun select(selection: EditorSelection?) =
        commit(
            EditorJournalSnapshot(
                state.certificateSHA256,
                state.entries,
                state.profiles,
                selection,
            ),
            null,
        )

    @Synchronized
    internal fun accept(read: VerifiedEditorRead) {
        val profile = read.profile
        checkEditor(profile.scope.certificateSHA256 == state.certificateSHA256)
        val profiles = state.profiles.toMutableList()
        val at = profiles.indexOfFirst { it.scope == profile.scope && it.id == profile.id }
        if (at >= 0) {
            val old = profiles[at]
            checkEditor(
                BigInteger(profile.revision) >= BigInteger(old.revision) &&
                    (profile.revision != old.revision || profile == old)
            )
            profiles[at] = profile
        } else {
            if (profiles.size >= 8) throw EditorJournalException(EditorJournalException.Code.FULL)
            profiles += profile
        }
        commit(
            EditorJournalSnapshot(
                state.certificateSHA256,
                state.entries,
                profiles,
                state.selection,
            ),
            null,
        )
    }

    @Synchronized
    internal fun mark(operationID: String, status: EditorPendingStatus) {
        val at = state.entries.indexOfFirst { it.intent.operationID == operationID }
        checkEditor(at >= 0)
        val entries = state.entries.toMutableList()
        entries[at] = EditorPendingEntry(entries[at].intent, status)
        commit(
            EditorJournalSnapshot(
                state.certificateSHA256,
                entries,
                state.profiles,
                state.selection,
            ),
            operationID,
        )
    }

    @Synchronized
    internal fun acknowledge(
        ack: VerifiedEditorAcknowledgment,
        currentScope: EditorHostScope,
        sessionID: String,
    ) {
        checkEditor(
            ack.responseScope == currentScope &&
                ack.responseScope.certificateSHA256 == state.certificateSHA256 &&
                sessionID.isNotEmpty() &&
                sessionID.toByteArray(Charsets.UTF_8).size <= 128 &&
                ack.sessionID == sessionID &&
                (ack.originRebound || ack.intent.scope == ack.responseScope) &&
                ack.receiptOperationID == ack.intent.operationID &&
                EditorJournalCodec.counter(ack.resultingRevision) &&
                EditorJournalCodec.hash(ack.contentSHA256) &&
                BigInteger(ack.resultingRevision) ==
                    BigInteger(ack.intent.expectedRevision).add(BigInteger.ONE) &&
                ack.affectedEntities == listOf(ack.intent.profileID, ack.intent.controlID)
        )
        val at = state.entries.indexOfFirst { it.intent == ack.intent }
        checkEditor(at >= 0)
        val entries = state.entries.toMutableList()
        entries.removeAt(at)
        commit(
            EditorJournalSnapshot(
                state.certificateSHA256,
                entries,
                state.profiles,
                state.selection,
            ),
            ack.intent.operationID,
        )
    }
}

internal fun checkEditor(condition: Boolean) {
    if (!condition) throw EditorJournalException(EditorJournalException.Code.INVALID)
}
