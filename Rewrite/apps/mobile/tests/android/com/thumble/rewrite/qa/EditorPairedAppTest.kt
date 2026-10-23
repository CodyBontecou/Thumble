package com.thumble.rewrite.qa

import android.content.Context
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.thumble.rewrite.input.*
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Explicit opt-in target-UID witness: production enrollment/vault/journal/RPC; no input host. */
@RunWith(AndroidJUnit4::class)
class EditorPairedAppTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val target = instrumentation.targetContext
    private val args = InstrumentationRegistry.getArguments()
    private fun gateway(path: String, body: JSONObject? = null): JSONObject {
        check(path in setOf("/fixture", "/enrolled", "/captured", "/verified", "/cleaned"))
        val port = checkNotNull(args.getString("thumbleEditorFixturePort")).toInt()
        check(port in 1..65535)
        return Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", port), 3000)
            socket.soTimeout = 5000
            val payload = body?.toString()?.toByteArray(Charsets.UTF_8) ?: byteArrayOf()
            check(payload.size <= 4096)
            socket.getOutputStream().write(("${if (body == null) "GET" else "POST"} $path HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\nContent-Length: ${payload.size}\r\n\r\n").toByteArray(Charsets.US_ASCII))
            socket.getOutputStream().write(payload)
            val out = ByteArrayOutputStream()
            val chunk = ByteArray(1024)
            while (true) {
                val count = socket.getInputStream().read(chunk)
                if (count < 0) break
                check(out.size() + count <= 8192) { "paired_fixture_bound" }
                out.write(chunk, 0, count)
            }
            val text = out.toString("UTF-8")
            check(text.startsWith("HTTP/1.1 200") || text.startsWith("HTTP/1.0 200")) { "paired_fixture_rejected" }
            JSONObject(text.substringAfter("\r\n\r\n"))
        }
    }
    private fun endpoint(): TrustedHostEndpoint {
        val text = checkNotNull(target.getSharedPreferences("rewrite.phone.v1", Context.MODE_PRIVATE).getString("endpoint", null))
        check(text.toByteArray().size <= 1024)
        val row = JSONObject(text)
        check(row.keys().asSequence().toSet() == setOf("host", "port", "pin", "authority"))
        return TrustedHostEndpoint(row.getString("host"), row.getInt("port"), row.getString("pin"), row.getString("authority"))
    }
    private fun snapshot(): PhoneEditorSnapshot {
        val session = PhoneEditorSession(endpoint(), target)
        try { return session.snapshot().get(10, TimeUnit.SECONDS) }
        finally {
            session.close()
            val until = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (!session.settled && System.nanoTime() < until) Thread.sleep(5)
            check(session.settled) { "paired_session_drain" }
        }
    }
    @Test fun actualTargetUidEnrollmentJournalAndExactReceipt() {
        assumeTrue("explicit paired editor witness", args.getString("thumblePairedEditor") == "1")
        check(target.packageName == "com.codybontecou.thumble.rewrite.qa") { "paired_target_uid" }
        check(Looper.myLooper() != Looper.getMainLooper()) { "paired_worker_required" }
        when (args.getString("thumbleEditorPhase")) {
            "enroll" -> {
                val fixture = gateway("/fixture")
                val invitation = EnrollmentInvitation.decode(fixture.getJSONObject("invitation").toString().toByteArray(Charsets.UTF_8))
                check(invitation.host == "127.0.0.1")
                val prefs = target.getSharedPreferences("rewrite.phone.v1", Context.MODE_PRIVATE)
                check(prefs.getString("endpoint", null) == null) { "paired_target_not_fresh" }
                val metadata = PhoneEnrollmentClient(invitation, target).use { it.enroll("paired-android-ui", "Editor paired UI witness") }
                val restored = PhoneCredentialVault(target).load(invitation.certificatePin, System.currentTimeMillis())
                check(restored != null && restored.metadata == metadata) { "paired_keystore_roundtrip" }
                check(prefs.edit().putString("phoneID", metadata.phoneID).putString("endpoint", JSONObject()
                    .put("host", invitation.host).put("port", invitation.port).put("pin", invitation.certificatePin)
                    .put("authority", invitation.authorityInstanceID).toString()).commit())
                check(snapshot().entries.isEmpty()) { "paired_initial_journal" }
                gateway("/enrolled", JSONObject().put("version", 1).put("keystoreRoundTrip", true).put("targetUid", true))
            }
            "capture" -> {
                val persisted = snapshot()
                val entry = persisted.entries.single()
                check(entry.status == EditorPendingStatus.Queued && entry.intent.label == "PairedAndroid") { "paired_durable_original" }
                val intent = entry.intent
                val savedEndpoint=endpoint()
                check(intent.scope.certificateSHA256 == savedEndpoint.certificatePin && intent.scope.authorityInstanceID == savedEndpoint.authorityInstanceID) { "paired_original_scope" }
                val cached=persisted.profiles.single { it.profileID == intent.profileID && it.revision == intent.expectedRevision }
                val row = JSONObject().put("certificatePin", intent.scope.certificateSHA256).put("authorityInstanceId", intent.scope.authorityInstanceID)
                    .put("operationId", intent.operationID).put("expectedRevision", intent.expectedRevision).put("profileId", intent.profileID)
                    .put("controlId", intent.controlID).put("label", intent.label).put("sourceHash", cached.sourceSHA256)
                target.openFileOutput("paired-editor-original.json", Context.MODE_PRIVATE).use { it.write(row.toString().toByteArray(Charsets.UTF_8)) }
                gateway("/captured", row)
            }
            "verify" -> {
                check(snapshot().entries.isEmpty()) { "paired_committed_queue_not_empty" }
                val file = target.getFileStreamPath("paired-editor-original.json")
                check(file.length() in 1..4096)
                val row = JSONObject(file.readText(Charsets.UTF_8))
                val intent = EditorLabelIntent(EditorHostScope(row.getString("certificatePin"), row.getString("authorityInstanceId")),
                    row.getString("operationId"), row.getString("expectedRevision"), row.getString("profileId"), row.getString("controlId"), row.getString("label"))
                gateway("/verified", EditorWitnessRPC.verify(endpoint(), target, intent))
            }
            "cleanup" -> {
                val pin = endpoint().certificatePin
                PhoneCredentialVault(target).forget(pin)
                check(PhoneCredentialVault(target).load(pin, System.currentTimeMillis()) == null) { "paired_credential_still_present" }
                check(target.getSharedPreferences("rewrite.phone.v1", Context.MODE_PRIVATE).edit().clear().commit())
                target.deleteFile("paired-editor-original.json")
                gateway("/cleaned", JSONObject().put("version", 1).put("credentialForgotten", true))
            }
            else -> error("paired_phase_required")
        }
    }
}
