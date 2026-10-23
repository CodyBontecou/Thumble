package com.thumble.rewrite.input

import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import org.json.JSONArray
import org.json.JSONObject

class PhoneEditorException(val code: Code = Code.REJECTED) :
    Exception("phone_editor_${code.name.lowercase()}") {
    enum class Code {
        REJECTED,
        BUSY,
        UNAVAILABLE,
        ORIGIN_RECONCILIATION_REQUIRED,
    }
}

private fun editorWireRequire(value: Boolean) {
    if (!value) throw PhoneEditorException()
}

internal class EditorWireParser(bytes: ByteArray) {
    private val text: String
    private var at = 0
    private var nodes = 0

    init {
        editorWireRequire(bytes.size <= 16384)
        text =
            try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
                    .toString()
            } catch (_: Exception) {
                throw PhoneEditorException()
            }
    }

    fun parse(): Map<String, Any?> {
        val value = value(0)
        whitespace()
        editorWireRequire(at == text.length)
        return obj(value)
    }

    private fun whitespace() {
        while (at < text.length && text[at] in " \t\r\n") at++
    }

    private fun consume(char: Char) {
        whitespace()
        editorWireRequire(at < text.length && text[at] == char)
        at++
    }

    private fun string(): String {
        whitespace()
        val start = at
        consume('"')
        var escaped = false
        while (at < text.length) {
            val char = text[at++]
            editorWireRequire(char.code >= 32)
            if (!escaped && char == '"') {
                val decoded =
                    try {
                        JSONArray("[" + text.substring(start, at) + "]").getString(0)
                    } catch (_: Exception) {
                        throw PhoneEditorException()
                    }
                editorWireRequire(
                    EditorJournalCodec.scalars(decoded) &&
                        decoded.toByteArray(Charsets.UTF_8).size <= 1024
                )
                return decoded
            }
            escaped = !escaped && char == '\\'
        }
        throw PhoneEditorException()
    }

    private fun value(depth: Int): Any? {
        whitespace()
        nodes++
        editorWireRequire(depth <= 4 && nodes <= 128 && at < text.length)
        return when (text[at]) {
            '{' -> {
                at++
                whitespace()
                val fields = linkedMapOf<String, Any?>()
                if (at < text.length && text[at] == '}') {
                    at++
                    fields
                } else {
                    while (true) {
                        val key = string()
                        editorWireRequire(
                            key.toByteArray(Charsets.UTF_8).size <= 64 && !fields.containsKey(key)
                        )
                        consume(':')
                        fields[key] = value(depth + 1)
                        whitespace()
                        editorWireRequire(at < text.length)
                        if (text[at] == '}') {
                            at++
                            break
                        }
                        consume(',')
                    }
                    fields
                }
            }
            '[' -> {
                at++
                whitespace()
                val values = arrayListOf<Any?>()
                if (at < text.length && text[at] == ']') {
                    at++
                    values
                } else {
                    while (true) {
                        editorWireRequire(values.size < 8)
                        values.add(value(depth + 1))
                        whitespace()
                        editorWireRequire(at < text.length)
                        if (text[at] == ']') {
                            at++
                            break
                        }
                        consume(',')
                    }
                    values
                }
            }
            '"' -> string()
            'n' -> {
                literal("null")
                null
            }
            't' -> {
                literal("true")
                true
            }
            'f' -> {
                literal("false")
                false
            }
            else -> {
                val start = at
                editorWireRequire(text[at] != '-')
                editorWireRequire(at < text.length && text[at] in '0'..'9')
                if (text[at] == '0') at++ else while (at < text.length && text[at] in '0'..'9') at++
                text.substring(start, at).toLongOrNull() ?: throw PhoneEditorException()
            }
        }
    }

    private fun literal(word: String) {
        editorWireRequire(text.startsWith(word, at))
        at += word.length
    }

    companion object {
        fun obj(value: Any?): Map<String, Any?> {
            editorWireRequire(value is Map<*, *> && value.keys.all { it is String })
            @Suppress("UNCHECKED_CAST")
            return value as Map<String, Any?>
        }
    }
}

internal data class EditorReadPin(
    val scope: EditorHostScope,
    val revision: String,
    val sourceHash: String,
    val profileID: String,
) {
    init {
        editorWireRequire(
            EditorJournalCodec.counter(revision) &&
                EditorJournalCodec.hash(sourceHash) &&
                EditorJournalCodec.uuid(profileID) == profileID
        )
    }
}

internal sealed class EditorRequest {
    abstract val scope: EditorHostScope
    abstract val command: String

    data class Profile(val pin: EditorReadPin, val offset: Int) : EditorRequest() {
        override val scope = pin.scope
        override val command = "editor-profile"

        init {
            editorWireRequire(offset in 0..120 && offset % 8 == 0)
        }
    }

    data class Label(val intent: EditorLabelIntent) : EditorRequest() {
        override val scope = intent.scope
        override val command = "configuration-set-control-label"
    }

    data class Status(val intent: EditorLabelIntent) : EditorRequest() {
        override val scope = intent.scope
        override val command = "editor-label-status"
    }

    fun fields(connection: String): Map<String, Any?> {
        editorWireRequire(EditorWire.hex(connection, 32))
        val result =
            linkedMapOf<String, Any?>(
                "version" to 1,
                "connectionId" to connection,
                "authorityInstanceId" to scope.authorityInstanceID,
                "command" to command,
            )
        when (this) {
            is Profile ->
                result.putAll(
                    mapOf(
                        "expectedRevision" to pin.revision,
                        "expectedSourceHash" to pin.sourceHash,
                        "profileId" to pin.profileID,
                        "offset" to offset,
                    )
                )
            is Label -> result.putAll(intentFields(intent))
            is Status ->
                result["intent"] =
                    intentFields(intent) + ("command" to "configuration-set-control-label")
        }
        return result
    }

    companion object {
        fun intentFields(intent: EditorLabelIntent) =
            mapOf(
                "operationId" to intent.operationID,
                "expectedRevision" to intent.expectedRevision,
                "profileId" to intent.profileID,
                "controlId" to intent.controlID,
                "label" to (intent.label ?: JSONObject.NULL),
            )
    }
}

internal class EditorProfilePage(
    val pin: EditorReadPin,
    val name: String,
    val offset: Int,
    val total: Int,
    val next: Int?,
    controls: List<EditorCachedControl>,
) {
    val controls: List<EditorCachedControl> =
        java.util.Collections.unmodifiableList(ArrayList(controls))
}

internal class EditorReceipt(
    val operationID: String,
    val revision: String,
    val hash: String,
    entities: List<String>,
) {
    val entities: List<String> = java.util.Collections.unmodifiableList(ArrayList(entities))
}

internal sealed class EditorReply {
    data class Profile(val page: EditorProfilePage) : EditorReply()

    data object Admitted : EditorReply()

    data object Pending : EditorReply()

    data class Committed(val receipt: EditorReceipt) : EditorReply()

    data class Conflict(val revision: String) : EditorReply()

    data class Error(val code: String) : EditorReply()
}

internal object EditorWire {
    val errors =
        setOf(
            "editor_busy",
            "editor_unavailable",
            "editor_invalid_request",
            "editor_access_denied",
            "editor_operation_reused",
            "editor_profile_not_found",
            "editor_control_not_found",
            "editor_source_changed",
            "editor_unsupported_profile",
            "editor_response_too_large",
        )

    fun hex(value: String, count: Int) =
        value.length == count && value.all { it in '0'..'9' || it in 'a'..'f' }

    fun parse(bytes: ByteArray) = EditorWireParser(bytes).parse()

    fun keys(fields: Map<String, Any?>, expected: Set<String>) =
        editorWireRequire(fields.keys == expected)

    fun request(bytes: ByteArray, scope: EditorHostScope, connection: String): EditorRequest {
        editorWireRequire(bytes.size <= 2048)
        val f = parse(bytes)
        val common = setOf("version", "connectionId", "authorityInstanceId", "command")
        editorWireRequire(
            f["version"] == 1L &&
                f["connectionId"] == connection &&
                f["authorityInstanceId"] == scope.authorityInstanceID
        )
        return when (f["command"]) {
            "editor-profile" -> {
                keys(
                    f,
                    common + setOf("expectedRevision", "expectedSourceHash", "profileId", "offset"),
                )
                val offset = f["offset"] as? Long ?: throw PhoneEditorException()
                editorWireRequire(offset in 0..120 && offset % 8 == 0L)
                EditorRequest.Profile(
                    EditorReadPin(
                        scope,
                        string(f["expectedRevision"]),
                        string(f["expectedSourceHash"]),
                        string(f["profileId"]),
                    ),
                    offset.toInt(),
                )
            }
            "configuration-set-control-label" -> {
                keys(
                    f,
                    common +
                        setOf("operationId", "expectedRevision", "profileId", "controlId", "label"),
                )
                EditorRequest.Label(intent(f, scope))
            }
            "editor-label-status" -> {
                keys(f, common + "intent")
                val inner = EditorWireParser.obj(f["intent"])
                keys(
                    inner,
                    setOf(
                        "command",
                        "operationId",
                        "expectedRevision",
                        "profileId",
                        "controlId",
                        "label",
                    ),
                )
                editorWireRequire(inner["command"] == "configuration-set-control-label")
                EditorRequest.Status(intent(inner, scope))
            }
            else -> throw PhoneEditorException()
        }
    }

    fun reply(bytes: ByteArray, request: EditorRequest, connection: String): EditorReply {
        val f = parse(bytes)
        val common = setOf("version", "connectionId", "authorityInstanceId", "command", "kind")
        editorWireRequire(
            f["version"] == 1L &&
                f["connectionId"] == connection &&
                f["authorityInstanceId"] == request.scope.authorityInstanceID &&
                f["command"] == request.command + "-result"
        )
        val kind = string(f["kind"])
        if (kind == "error") {
            keys(f, common + "error")
            val code = string(f["error"])
            editorWireRequire(code in errors)
            return EditorReply.Error(code)
        }
        if (request is EditorRequest.Profile) {
            keys(
                f,
                common +
                    setOf(
                        "revision",
                        "contentHash",
                        "profileId",
                        "name",
                        "offset",
                        "totalControls",
                        "nextOffset",
                        "controls",
                    ),
            )
            editorWireRequire(
                kind == "editor-profile" &&
                    f["revision"] == request.pin.revision &&
                    f["contentHash"] == request.pin.sourceHash &&
                    f["profileId"] == request.pin.profileID &&
                    f["offset"] == request.offset.toLong()
            )
            val name = string(f["name"])
            editorWireRequire(validName(name))
            val total = f["totalControls"] as? Long ?: throw PhoneEditorException()
            editorWireRequire(
                total in 0..128 &&
                    request.offset <= total &&
                    (request.offset == 0 || request.offset < total)
            )
            val rows = f["controls"] as? List<*> ?: throw PhoneEditorException()
            editorWireRequire(rows.size == minOf(8, (total - request.offset).toInt()))
            val next = if (request.offset + rows.size < total) request.offset + rows.size else null
            editorWireRequire(f["nextOffset"] == next?.toLong())
            val controls = rows.map {
                val row = EditorWireParser.obj(it)
                keys(row, setOf("id", "generatedLabel", "labelOverride"))
                val id = string(row["id"])
                editorWireRequire(EditorJournalCodec.uuid(id) == id)
                EditorCachedControl(
                    id,
                    string(row["generatedLabel"]),
                    nullableLabel(row["labelOverride"]),
                )
            }
            editorWireRequire(controls.map { it.id }.toSet().size == controls.size)
            return EditorReply.Profile(
                EditorProfilePage(request.pin, name, request.offset, total.toInt(), next, controls)
            )
        }
        val intent =
            when (request) {
                is EditorRequest.Label -> request.intent
                is EditorRequest.Status -> request.intent
                else -> throw PhoneEditorException()
            }
        if (kind == "editor-label-admitted" || kind == "editor-label-pending") {
            keys(f, common + "operationId")
            editorWireRequire(
                f["operationId"] == intent.operationID &&
                    ((request is EditorRequest.Label && kind == "editor-label-admitted") ||
                        (request is EditorRequest.Status && kind == "editor-label-pending"))
            )
            return if (kind == "editor-label-admitted") EditorReply.Admitted
            else EditorReply.Pending
        }
        if (kind == "conflict") {
            keys(f, common + "currentRevision")
            val revision = string(f["currentRevision"])
            editorWireRequire(
                request is EditorRequest.Label && EditorJournalCodec.counter(revision)
            )
            return EditorReply.Conflict(revision)
        }
        val committed = request is EditorRequest.Label
        keys(f, common + "receipt" + if (committed) setOf("replayed") else emptySet())
        editorWireRequire(kind == if (committed) "committed" else "editor-label-receipt")
        if (committed) editorWireRequire(f["replayed"] is Boolean)
        val receipt = EditorWireParser.obj(f["receipt"])
        keys(
            receipt,
            setOf("version", "operationId", "resultingRevision", "contentHash", "affectedEntities"),
        )
        val revision = string(receipt["resultingRevision"])
        val hash = string(receipt["contentHash"])
        editorWireRequire(
            receipt["version"] == 1L &&
                receipt["operationId"] == intent.operationID &&
                EditorJournalCodec.counter(revision) &&
                BigInteger(revision) == BigInteger(intent.expectedRevision).add(BigInteger.ONE) &&
                EditorJournalCodec.hash(hash) &&
                receipt["affectedEntities"] == listOf(intent.profileID, intent.controlID)
        )
        return EditorReply.Committed(
            EditorReceipt(
                intent.operationID,
                revision,
                hash,
                listOf(intent.profileID, intent.controlID),
            )
        )
    }

    private fun string(value: Any?) = value as? String ?: throw PhoneEditorException()

    private fun nullableLabel(value: Any?): String? {
        if (value == null) return null
        val result = string(value)
        editorWireRequire(EditorJournalCodec.label(result))
        return result
    }

    private fun intent(f: Map<String, Any?>, scope: EditorHostScope): EditorLabelIntent {
        val profile = string(f["profileId"])
        val control = string(f["controlId"])
        editorWireRequire(
            EditorJournalCodec.uuid(profile) == profile &&
                EditorJournalCodec.uuid(control) == control
        )
        return EditorLabelIntent(
            scope,
            string(f["operationId"]),
            string(f["expectedRevision"]),
            profile,
            control,
            nullableLabel(f["label"]),
        )
    }

    private fun validName(name: String) =
        EditorJournalCodec.scalars(name) &&
            name.codePointCount(0, name.length) <= 256 &&
            name.toByteArray(Charsets.UTF_8).size <= 1024 &&
            name.codePoints().anyMatch {
                it !in 9..13 &&
                    it !in setOf(32, 160, 5760, 8232, 8233, 8239, 8287, 12288, 65279) &&
                    it !in 8192..8202
            }
}
