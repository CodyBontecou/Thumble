package com.thumble.rewrite.input

import java.math.BigInteger
import org.json.JSONArray
import org.json.JSONObject

/** Canonical private disk schema. Neither a network parser nor authentication proof. */
internal object EditorJournalCodec {
    const val MAXIMUM_BYTES = 2 * 1024 * 1024
    private val maximumCounter = BigInteger("18446744073709551615")

    fun hash(value: String) = value.length == 64 && value.matches(Regex("[a-f0-9]{64}"))

    fun uuid(value: String): String {
        val canonical = value.lowercase(java.util.Locale.ROOT)
        checkEditor(
            canonical.matches(Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"))
        )
        return canonical
    }

    fun counter(value: String) =
        value.length <= 20 &&
            value.matches(Regex("0|[1-9][0-9]*")) &&
            BigInteger(value) <= maximumCounter

    fun operation(value: String) = value.matches(Regex("[A-Za-z0-9-]{1,64}"))

    fun scalars(value: String): Boolean {
        var at = 0
        while (at < value.length) {
            val char = value[at++]
            if (Character.isHighSurrogate(char)) {
                if (at == value.length || !Character.isLowSurrogate(value[at++])) return false
            } else if (Character.isLowSurrogate(char)) return false
        }
        return true
    }

    fun label(value: String) = scalars(value) && value.toByteArray(Charsets.UTF_8).size <= 128

    private fun obj(value: Any?, keys: Set<String>): JSONObject {
        checkEditor(value is JSONObject)
        value as JSONObject
        checkEditor(value.keys().asSequence().toSet() == keys)
        return value
    }

    private fun text(value: Any?): String {
        checkEditor(value is String)
        return value as String
    }

    private fun nullable(value: Any?): String? {
        checkEditor(value != null)
        return if (value === JSONObject.NULL) null else text(value)
    }

    private fun array(value: Any?, maximum: Int): List<Any> {
        checkEditor(value is JSONArray)
        value as JSONArray
        checkEditor(value.length() <= maximum)
        return (0 until value.length()).map { value.get(it) }
    }

    private fun scope(value: Any?): EditorHostScope {
        val v = obj(value, setOf("certificateSHA256", "authorityInstanceId"))
        return EditorHostScope(text(v.get("certificateSHA256")), text(v.get("authorityInstanceId")))
    }

    private fun scopeJSON(scope: EditorHostScope) =
        mapOf(
            "certificateSHA256" to scope.certificateSHA256,
            "authorityInstanceId" to scope.authorityInstanceID,
        )

    private fun intent(value: Any?): EditorLabelIntent {
        val v =
            obj(
                value,
                setOf("scope", "operationId", "expectedRevision", "profileId", "controlId", "label"),
            )
        return EditorLabelIntent(
            scope(v.get("scope")),
            text(v.get("operationId")),
            text(v.get("expectedRevision")),
            text(v.get("profileId")),
            text(v.get("controlId")),
            nullable(v.get("label")),
        )
    }

    private fun intentJSON(intent: EditorLabelIntent) =
        mapOf(
            "scope" to scopeJSON(intent.scope),
            "operationId" to intent.operationID,
            "expectedRevision" to intent.expectedRevision,
            "profileId" to intent.profileID,
            "controlId" to intent.controlID,
            "label" to intent.label,
        )

    private fun status(value: Any?): EditorPendingStatus {
        checkEditor(value is JSONObject)
        return when (text((value as JSONObject).get("kind"))) {
            "queued" -> {
                obj(value, setOf("kind"))
                EditorPendingStatus.Queued
            }
            "uncertain" -> {
                obj(value, setOf("kind"))
                EditorPendingStatus.Uncertain
            }
            "rejected" -> {
                obj(value, setOf("kind"))
                EditorPendingStatus.Rejected
            }
            "conflict" -> {
                obj(value, setOf("kind", "currentRevision"))
                EditorPendingStatus.Conflict(text(value.get("currentRevision")))
            }
            else -> throw EditorJournalException(EditorJournalException.Code.INVALID)
        }
    }

    private fun statusJSON(status: EditorPendingStatus): Map<String, Any> =
        when (status) {
            EditorPendingStatus.Queued -> mapOf("kind" to "queued")
            EditorPendingStatus.Uncertain -> mapOf("kind" to "uncertain")
            EditorPendingStatus.Rejected -> mapOf("kind" to "rejected")
            is EditorPendingStatus.Conflict ->
                mapOf("kind" to "conflict", "currentRevision" to status.currentRevision)
        }

    private fun profile(value: Any?): EditorCachedProfile {
        val v =
            obj(value, setOf("scope", "profileId", "name", "revision", "sourceSHA256", "controls"))
        val controls =
            array(v.get("controls"), 128).map {
                val c = obj(it, setOf("controlId", "generatedLabel", "labelOverride"))
                EditorCachedControl(
                    text(c.get("controlId")),
                    text(c.get("generatedLabel")),
                    nullable(c.get("labelOverride")),
                )
            }
        return EditorCachedProfile(
            scope(v.get("scope")),
            text(v.get("profileId")),
            text(v.get("name")),
            text(v.get("revision")),
            text(v.get("sourceSHA256")),
            controls,
        )
    }

    private fun quote(value: String): String {
        checkEditor(scalars(value))
        return buildString {
            append('"')
            for (char in value) when (char) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\u000c' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else ->
                    if (char.code < 32) append("\\u" + char.code.toString(16).padStart(4, '0'))
                    else append(char)
            }
            append('"')
        }
    }

    private fun json(value: Any?): String =
        when (value) {
            null -> "null"
            is String -> quote(value)
            is Int -> value.toString()
            is Map<*, *> ->
                value.keys
                    .map { it as String }
                    .sorted()
                    .joinToString(",", "{", "}") { quote(it) + ":" + json(value[it]) }
            is List<*> -> value.joinToString(",", "[", "]") { json(it) }
            else -> throw EditorJournalException(EditorJournalException.Code.INVALID)
        }

    fun encode(state: EditorJournalSnapshot): ByteArray {
        val value =
            mapOf(
                "schemaVersion" to 1,
                "certificateSHA256" to state.certificateSHA256,
                "entries" to
                    state.entries.map {
                        mapOf("intent" to intentJSON(it.intent), "status" to statusJSON(it.status))
                    },
                "profiles" to
                    state.profiles.map { p ->
                        mapOf(
                            "scope" to scopeJSON(p.scope),
                            "profileId" to p.id,
                            "name" to p.name,
                            "revision" to p.revision,
                            "sourceSHA256" to p.sourceSHA256,
                            "controls" to
                                p.controls.map {
                                    mapOf(
                                        "controlId" to it.id,
                                        "generatedLabel" to it.generatedLabel,
                                        "labelOverride" to it.labelOverride,
                                    )
                                },
                        )
                    },
                "selection" to
                    state.selection?.let {
                        mapOf("scope" to scopeJSON(it.scope), "profileId" to it.profileID)
                    },
            )
        val bytes = json(value).toByteArray(Charsets.UTF_8)
        if (bytes.size > MAXIMUM_BYTES)
            throw EditorJournalException(EditorJournalException.Code.FULL)
        return bytes
    }

    fun decode(bytes: ByteArray): EditorJournalSnapshot {
        checkEditor(bytes.isNotEmpty() && bytes.size <= MAXIMUM_BYTES)
        val decodedText =
            try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                    .decode(java.nio.ByteBuffer.wrap(bytes))
                    .toString()
            } catch (_: Exception) {
                throw EditorJournalException(EditorJournalException.Code.INVALID)
            }
        var depth = 0
        var nodes = 0
        var quoted = false
        var escaped = false
        for (char in decodedText) {
            if (quoted) {
                if (escaped) escaped = false
                else if (char == '\\') escaped = true else if (char == '"') quoted = false
            } else if (char == '"') quoted = true
            else if (char == '{' || char == '[') {
                depth++
                nodes++
                checkEditor(depth <= 12 && nodes <= 4096)
            } else if (char == '}' || char == ']') {
                depth--
                checkEditor(depth >= 0)
            }
        }
        checkEditor(!quoted && depth == 0)
        try {
            val v =
                obj(
                    JSONObject(decodedText),
                    setOf("schemaVersion", "certificateSHA256", "entries", "profiles", "selection"),
                )
            checkEditor(v.get("schemaVersion") is Int && v.get("schemaVersion") == 1)
            val entries =
                array(v.get("entries"), 128).map { raw ->
                    val e = obj(raw, setOf("intent", "status"))
                    EditorPendingEntry(intent(e.get("intent")), status(e.get("status")))
                }
            val profiles = array(v.get("profiles"), 8).map(::profile)
            val selected =
                if (v.get("selection") === JSONObject.NULL) null
                else {
                    val s = obj(v.get("selection"), setOf("scope", "profileId"))
                    EditorSelection(scope(s.get("scope")), text(s.get("profileId")))
                }
            val state =
                EditorJournalSnapshot(text(v.get("certificateSHA256")), entries, profiles, selected)
            checkEditor(encode(state).contentEquals(bytes))
            return state
        } catch (_: Exception) {
            throw EditorJournalException(EditorJournalException.Code.INVALID)
        }
    }
}
