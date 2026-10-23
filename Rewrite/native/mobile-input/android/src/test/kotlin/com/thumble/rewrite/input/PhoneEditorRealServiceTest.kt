package com.thumble.rewrite.input

import java.io.File
import java.net.InetSocketAddress
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in JVM witness: actual production TLS/RPC/session, injected credentials and memory journal. */
class PhoneEditorRealServiceTest {
    private class MemoryJournal : EditorJournalStorage {
        private var bytes: ByteArray? = null
        @Synchronized override fun load() = bytes?.copyOf()
        @Synchronized override fun save(candidate: ByteArray, expected: ByteArray?) {
            check(bytes?.contentEquals(expected ?: byteArrayOf()) ?: (expected == null))
            bytes = candidate.copyOf()
        }
    }

    @Test fun realServiceEditorUsesPinnedTLSAndExactReceipt() {
        val fixturePath = System.getenv("THUMBLE_EDITOR_ANDROID_FIXTURE")
        assumeTrue("opt-in actual recording host fixture", fixturePath != null)
        val summaryPath = System.getenv("THUMBLE_EDITOR_ANDROID_SUMMARY")
        check(summaryPath != null)
        val file = File(fixturePath!!)
        check(file.length() in 1..4096)
        val fixture = JSONObject(file.readText(Charsets.UTF_8))
        check(fixture.getInt("version") == 1 && fixture.getString("host") == "127.0.0.1")
        val revision = fixture.getString("revision")
        check(revision == "3" || revision == "4")
        val nextRevision = (revision.toLong() + 1).toString()
        val tokenText = fixture.getString("credential")
        check(tokenText.matches(Regex("[0-9a-f]{64}")))
        val token = tokenText.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val endpoint = TrustedHostEndpoint(fixture.getString("host"), fixture.getInt("port"),
            fixture.getString("certificatePin"), fixture.getString("authorityInstanceId"))
        val credential = PhoneCredential(PhoneCredentialMetadata(endpoint.certificatePin,
            fixture.getString("phoneId"), fixture.getLong("credentialEpoch"), fixture.getLong("expiresAt")), token)
        fun nativeIO() = ControlTLSClient.connect(InetSocketAddress(endpoint.host, endpoint.port), endpoint.certificatePin).nativeFrames()
        val rpc = PhoneEditorRPC(endpoint, ::nativeIO, { pin, now ->
            if (pin == credential.metadata.hostPin && now < credential.metadata.expiresAt) credential else null
        }, System::currentTimeMillis)
        val store = MemoryJournal()
        // The internal resolver omits only Android Looper inspection on this JVM worker.
        // Its actual pinned TLS and native hello validation remain in production code.
        val session = PhoneEditorSession(endpoint, rpc, { EditorJournal(endpoint.certificatePin, store) }, {
            PhoneAuthorityResolver(endpoint, ::nativeIO, requireWorker = false).use { it.resolve() }
        })
        try {
            val profileID = fixture.getString("profileId")
            val controlID = fixture.getString("controlId")
            val before = session.read(profileID, revision, fixture.getString("sourceHash")).get(10, TimeUnit.SECONDS)
            val profile = before.profiles.single()
            assertEquals(revision, profile.revision)
            assertTrue(session.cachePage(profile.contextID, 0).get(5, TimeUnit.SECONDS).controls.any { it.id == controlID })
            val operation = "kotlin-cross-layer-label"
            session.enqueue(profile.contextID, revision, profile.sourceSHA256, controlID, operation, "AndroidSDK").get(5, TimeUnit.SECONDS)
            assertEquals(1, EditorJournal(endpoint.certificatePin, store).snapshot().entries.size)
            var outcome = session.submit(operation).get(10, TimeUnit.SECONDS)
            repeat(5) {
                if (outcome == "retained") outcome = session.reconcile(operation).get(10, TimeUnit.SECONDS)
            }
            assertEquals("committed", outcome)
            val snapshot = session.snapshot().get(5, TimeUnit.SECONDS)
            assertTrue(snapshot.entries.isEmpty())
            assertTrue(EditorJournal(endpoint.certificatePin, store).snapshot().entries.isEmpty())
            assertEquals(revision, snapshot.profiles.single().revision)
            val intent = EditorLabelIntent(EditorHostScope(endpoint.certificatePin, endpoint.authorityInstanceID),
                operation, revision, profileID, controlID, "AndroidSDK")
            val status = rpc.exchange(EditorRequest.Status(intent)).reply
            check(status is EditorReply.Committed)
            assertEquals(operation, status.receipt.operationID)
            assertEquals(nextRevision, status.receipt.revision)
            assertEquals(listOf(profileID, controlID), status.receipt.entities)
            val retry = rpc.exchange(EditorRequest.Label(intent)).reply
            check(retry is EditorReply.Committed)
            assertEquals(status.receipt.revision, retry.receipt.revision)
            assertEquals(status.receipt.hash, retry.receipt.hash)
            val statusAgain = rpc.exchange(EditorRequest.Status(intent)).reply
            check(statusAgain is EditorReply.Committed)
            assertEquals(nextRevision, statusAgain.receipt.revision)
            assertEquals(status.receipt.hash, statusAgain.receipt.hash)
            val after = session.read(profileID, nextRevision, status.receipt.hash).get(10, TimeUnit.SECONDS)
            val updated = after.profiles.single()
            assertEquals("AndroidSDK", session.cachePage(updated.contextID, 0).get(5, TimeUnit.SECONDS)
                .controls.single { it.id == controlID }.labelOverride)
            File(summaryPath).writeText(JSONObject(linkedMapOf("version" to 1, "kind" to "kotlin-editor-sdk",
                "committed" to true, "queueEmpty" to true, "baseRevision" to revision,
                "resultingRevision" to nextRevision)).toString(), Charsets.UTF_8)
        } finally { session.close() }
    }
}
