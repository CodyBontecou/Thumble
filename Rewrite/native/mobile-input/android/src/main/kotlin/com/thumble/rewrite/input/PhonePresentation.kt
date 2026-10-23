package com.thumble.rewrite.input

import java.util.Collections
import org.json.JSONObject

class PhonePresentationRejected : Exception("phone_presentation_rejected")

class PhonePresentationUnavailable(val code: String) : Exception(code)

/** Immutable installed-map pin; cosmetics never change input ownership. */
class PhonePresentationRequest(
    val saved: SavedControllerRequest,
    map: SavedControllerMap,
    val colorScheme: String,
    val bank: PhonePresentationBank? = null,
) {
    internal val protocolVersion
        get() = if (bank == null) 1L else 2L

    internal val controlVersion
        get() = if (bank == null) 10L else 11L

    val configurationSha256 = map.configurationSha256
    internal val controlIDs = map.map.controls.map { it.id }.toList()

    init {
        try {
            map.map.validated()
        } catch (_: IllegalArgumentException) {
            throw PhonePresentationRejected()
        }
        if (
            colorScheme !in setOf("light", "dark") ||
                !PhoneCatalogClient.hex(configurationSha256, 64) ||
                map.map.generation != saved.generation ||
                map.map.revision != saved.revision ||
                controlIDs.size !in 1..64 ||
                controlIDs.toSet().size != controlIDs.size
        )
            throw PhonePresentationRejected()
    }

    internal fun fields(connection: String): JSONObject =
        saved
            .fields(connection)
            .put("command", "configuration-presentation")
            .put("version", protocolVersion)
            .put("configurationSha256", configurationSha256)
            .put("colorScheme", colorScheme)
            .apply { bank?.let { put("bank", it.wire) } }

    internal fun installed(authority: String? = null): Map<String, Any> {
        val legacy =
            mapOf(
                "generation" to saved.generation,
                "revision" to saved.revision,
                "configurationSha256" to configurationSha256,
                "expectedConfigurationRevision" to saved.configurationRevision,
                "expectedSourceHash" to saved.sourceHash,
                "profileId" to saved.profileID,
            )
        if (bank == null) return legacy
        if (authority == null || !EnrollmentInvitation.identity(authority))
            throw PhonePresentationRejected()
        return legacy +
            mapOf(
                "presentationProtocol" to 2,
                "authorityInstanceId" to authority,
                "viewportWidth" to saved.viewportWidth,
                "viewportHeight" to saved.viewportHeight,
                "colorScheme" to colorScheme,
                "bank" to bank.wire,
            )
    }

    fun bankNotification(authority: String): Map<String, Any> {
        if (bank == null) throw PhonePresentationRejected()
        return installed(authority) + mapOf("kind" to "bank")
    }
}

class PhonePresentationControl
internal constructor(
    val id: String,
    val label: String,
    val iconSHA256: String?,
    val iconByteCount: Int?,
    val iconName: String?,
)

class PhonePresentationMetadata
internal constructor(
    internal val request: PhonePresentationRequest,
    val presentationRevision: String,
    val presentationSourceHash: String,
    val profileName: String,
    val freshness: String,
    controls: List<PhonePresentationControl>,
    internal val authorityInstanceID: String,
) {
    val controls: List<PhonePresentationControl> = Collections.unmodifiableList(controls.toList())

    internal fun presented(): Map<String, Any> =
        mapOf(
            "presentationRevision" to presentationRevision,
            "presentationSourceHash" to presentationSourceHash,
            "colorScheme" to request.colorScheme,
            "bank" to (request.bank?.wire ?: "base"),
        )

    fun bridgeEvent(): Map<String, Any> =
        request.installed(authorityInstanceID) +
            presented() +
            mapOf(
                "kind" to "presentation",
                "profileName" to profileName,
                "freshness" to freshness,
                "controls" to
                    controls.map { c ->
                        mutableMapOf<String, Any>("id" to c.id, "label" to c.label).apply {
                            if (c.iconSHA256 != null) {
                                put("iconSHA256", c.iconSHA256)
                                put("iconByteCount", c.iconByteCount!!)
                                put("iconName", c.iconName!!)
                            }
                        }
                    },
            )
}

class PhonePresentationIcon
internal constructor(val sha256: String, private val base64: String, val byteCount: Int) {
    fun notification(metadata: PhonePresentationMetadata, controlId: String): Map<String, Any> {
        val control =
            metadata.controls.singleOrNull { it.id == controlId }
                ?: throw PhonePresentationRejected()
        if (control.iconSHA256 != sha256 || control.iconByteCount != byteCount)
            throw PhonePresentationRejected()
        return metadata.request.installed(metadata.authorityInstanceID) +
            metadata.presented() +
            mapOf(
                "kind" to "icon",
                "controlId" to controlId,
                "iconSHA256" to sha256,
                "pngBase64" to base64,
            )
    }
}

internal object PhonePresentationWire {
    val errors =
        setOf(
            "presentation_busy",
            "presentation_timeout",
            "presentation_unavailable",
            "presentation_reactivation_required",
            "presentation_unsupported_profile",
            "presentation_response_too_large",
            "presentation_stale",
        )
    private val header = setOf("version", "command", "connectionId", "kind")

    private fun text(f: Map<String, EnrollmentJSON.Value>, k: String): String =
        (f[k] as? EnrollmentJSON.Value.Text)?.value ?: throw PhonePresentationRejected()

    private fun integer(f: Map<String, EnrollmentJSON.Value>, k: String): Long =
        (f[k] as? EnrollmentJSON.Value.Integer)?.value ?: throw PhonePresentationRejected()

    private fun label(s: String): String {
        var i = 0
        while (i < s.length) {
            val c = s[i++]
            if (Character.isHighSurrogate(c)) {
                if (i == s.length || !Character.isLowSurrogate(s[i++]))
                    throw PhonePresentationRejected()
            } else if (Character.isLowSurrogate(c)) throw PhonePresentationRejected()
        }
        if (s.toByteArray(Charsets.UTF_8).size > 128) throw PhonePresentationRejected()
        return s
    }

    private fun common(
        f: Map<String, EnrollmentJSON.Value>,
        r: PhonePresentationRequest,
        a: String,
        c: String,
        icon: Boolean,
    ): MutableSet<String> {
        if (
            f["version"] != EnrollmentJSON.Value.Integer(r.protocolVersion) ||
                text(f, "command") !=
                    (if (icon) "configuration-presentation-icon-result"
                    else "configuration-presentation-result") ||
                text(f, "connectionId") != c
        )
            throw PhonePresentationRejected()
        if (f["kind"] == EnrollmentJSON.Value.Text("error")) {
            val e = text(f, "error")
            if (f.keys != header + "error" || e !in errors) throw PhonePresentationRejected()
            throw PhonePresentationUnavailable(e)
        }
        val expected =
            mutableMapOf(
                "authorityInstanceId" to a,
                "expectedConfigurationRevision" to r.saved.configurationRevision,
                "expectedSourceHash" to r.saved.sourceHash,
                "profileId" to r.saved.profileID,
                "generation" to r.saved.generation,
                "revision" to r.saved.revision,
                "viewportWidth" to r.saved.viewportWidth,
                "viewportHeight" to r.saved.viewportHeight,
                "configurationSha256" to r.configurationSha256,
                "colorScheme" to r.colorScheme,
            )
        r.bank?.let { expected["bank"] = it.wire }
        if (expected.any { text(f, it.key) != it.value }) throw PhonePresentationRejected()
        return (header + expected.keys).toMutableSet()
    }

    fun metadata(
        f: Map<String, EnrollmentJSON.Value>,
        r: PhonePresentationRequest,
        a: String,
        c: String,
    ): PhonePresentationMetadata {
        val keys = common(f, r, a, c, false)
        keys.addAll(
            setOf(
                "bank",
                "profileName",
                "presentationRevision",
                "presentationSourceHash",
                "freshness",
                "controlCount",
            )
        )
        val revision = text(f, "presentationRevision")
        val hash = text(f, "presentationSourceHash")
        val freshness = text(f, "freshness")
        val count = integer(f, "controlCount")
        if (
            text(f, "kind") != "presentation" ||
                text(f, "bank") != (r.bank?.wire ?: "base") ||
                !PhoneCatalogClient.counter(revision) ||
                java.math.BigInteger(revision) <
                    java.math.BigInteger(r.saved.configurationRevision) ||
                !PhoneCatalogClient.hex(hash, 64) ||
                freshness !in setOf("observed", "stale", "not-evaluated") ||
                count !in 1..64 ||
                count.toInt() != r.controlIDs.size
        )
            throw PhonePresentationRejected()
        val controls =
            (0 until count.toInt()).map { i ->
                val p = "control$i"
                keys.addAll(setOf(p + "Id", p + "Label"))
                val id = text(f, p + "Id")
                val optional = listOf(p + "IconSHA256", p + "IconByteCount", p + "IconName")
                var sha: String? = null
                var size: Int? = null
                var name: String? = null
                if (optional.any { it in f }) {
                    keys.addAll(optional)
                    sha = text(f, optional[0])
                    val n = integer(f, optional[1])
                    name = label(text(f, optional[2]))
                    if (!PhoneCatalogClient.hex(sha, 64) || n !in 57..8192)
                        throw PhonePresentationRejected()
                    size = n.toInt()
                }
                PhonePresentationControl(id, label(text(f, p + "Label")), sha, size, name)
            }
        if (
            f.keys != keys ||
                controls.map { it.id }.toSet() != r.controlIDs.toSet() ||
                controls.map { it.id }.toSet().size != controls.size
        )
            throw PhonePresentationRejected()
        return PhonePresentationMetadata(
            r,
            revision,
            hash,
            label(text(f, "profileName")),
            freshness,
            controls,
            a,
        )
    }

    fun icon(
        f: Map<String, EnrollmentJSON.Value>,
        m: PhonePresentationMetadata,
        control: PhonePresentationControl,
        a: String,
        c: String,
    ): PhonePresentationIcon {
        val keys = common(f, m.request, a, c, true)
        keys.addAll(
            setOf(
                "presentationRevision",
                "presentationSourceHash",
                "controlId",
                "iconSHA256",
                "byteCount",
                "pngBase64",
            )
        )
        if (
            f.keys != keys ||
                text(f, "kind") != "icon" ||
                text(f, "presentationRevision") != m.presentationRevision ||
                text(f, "presentationSourceHash") != m.presentationSourceHash ||
                text(f, "controlId") != control.id ||
                text(f, "iconSHA256") != control.iconSHA256 ||
                integer(f, "byteCount") != control.iconByteCount?.toLong()
        )
            throw PhonePresentationRejected()
        val base64 = text(f, "pngBase64")
        if (base64.length > 10924) throw PhonePresentationRejected()
        val bytes =
            try {
                java.util.Base64.getDecoder().decode(base64)
            } catch (_: IllegalArgumentException) {
                throw PhonePresentationRejected()
            }
        if (
            java.util.Base64.getEncoder().encodeToString(bytes) != base64 ||
                bytes.size != control.iconByteCount
        )
            throw PhonePresentationRejected()
        val digest =
            java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
                "%02x".format(it.toInt() and 255)
            }
        if (digest != control.iconSHA256) throw PhonePresentationRejected()
        PresentationIconPNG.verify(bytes)
        return PhonePresentationIcon(digest, base64, bytes.size)
    }
}
