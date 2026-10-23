package com.thumble.rewrite.bridge

import android.content.Context
import com.thumble.rewrite.input.*
import java.util.UUID
import java.util.concurrent.CompletableFuture
import expo.modules.kotlin.Promise
import org.json.JSONObject

/** App-owned registry. No endpoint, epoch, credential, receipt or path comes from React. */
internal object NativeEditorSession {
    private var session: PhoneEditorSession? = null
    private var handle: String? = null
    private var closing = false
    @Synchronized fun open(context: Context): String {
        session?.let { check(closing && it.settled) { "editor_busy" } }
        val text = context.getSharedPreferences("rewrite.phone.v1", Context.MODE_PRIVATE).getString("endpoint", null)
            ?: error("editor_pairing_required")
        check(text.toByteArray(Charsets.UTF_8).size <= 1024)
        val value = JSONObject(text)
        check(value.keys().asSequence().toSet() == setOf("host", "port", "pin", "authority"))
        val endpoint = TrustedHostEndpoint(value.getString("host"), value.getInt("port"), value.getString("pin"), value.getString("authority"))
        val next = PhoneEditorSession(endpoint, context.applicationContext)
        try { next.snapshot().get() } catch (error: Exception) { next.close(); throw error }
        val id = UUID.randomUUID().toString()
        session = next; handle = id; closing = false
        return id
    }
    @Synchronized fun get(id: String): PhoneEditorSession {
        check(!closing && id == handle) { "editor_closed" }
        return checkNotNull(session)
    }
    @Synchronized fun close(id: String) { val owner = get(id); closing = true; owner.close() }
}
internal fun <T> editorComplete(future: CompletableFuture<T>, promise: Promise, map: (T) -> Any?) {
    future.whenComplete { value, error ->
        if (error != null) {
            var cause = error
            while (cause is java.util.concurrent.ExecutionException || cause is java.util.concurrent.CompletionException) cause = cause.cause ?: break
            val code = if (cause is PhoneEditorException && cause.code == PhoneEditorException.Code.ORIGIN_RECONCILIATION_REQUIRED) "origin-reconciliation-required" else "editor_unavailable"
            promise.reject(code, code, cause)
        }
        else try { promise.resolve(map(value)) } catch (failure: Exception) { promise.reject("editor_unavailable", "Editor operation failed", failure) }
    }
}
internal fun PhoneEditorSnapshot.editorBridge(): Map<String, Any?> = mapOf(
    "profiles" to profiles.map { mapOf("contextId" to it.contextID, "profileId" to it.profileID,
        "name" to it.name, "revision" to it.revision, "sourceSha256" to it.sourceSHA256, "controlCount" to it.controlCount) },
    "selection" to selection,
    "queue" to entries.map { entry ->
        val status = when (entry.status) { EditorPendingStatus.Queued -> "queued"; EditorPendingStatus.Uncertain -> "uncertain"; EditorPendingStatus.Rejected -> "rejected"; is EditorPendingStatus.Conflict -> "conflict" }
        mapOf("operationId" to entry.intent.operationID, "profileId" to entry.intent.profileID,
            "controlId" to entry.intent.controlID, "expectedRevision" to entry.intent.expectedRevision,
            "label" to entry.intent.label, "status" to status, "conflictRevision" to (entry.status as? EditorPendingStatus.Conflict)?.currentRevision)
    })
internal fun PhoneEditorCachePage.editorBridge(): Map<String, Any?> = mapOf(
    "contextId" to contextID, "offset" to offset, "nextOffset" to nextOffset,
    "controls" to controls.map { mapOf("id" to it.id, "generatedLabel" to it.generatedLabel, "labelOverride" to it.labelOverride) })
