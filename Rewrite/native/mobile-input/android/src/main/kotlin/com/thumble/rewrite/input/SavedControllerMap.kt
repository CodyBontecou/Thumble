package com.thumble.rewrite.input

import org.json.JSONObject

class SavedControllerRejected : Exception("saved_controller_rejected")

class SavedControllerUnavailable(val code: String) : Exception(code)

/** Public read pin only; never creates or owns an input activation. */
data class SavedControllerRequest(
    val configurationRevision: String,
    val sourceHash: String,
    val profileID: String,
    val generation: String,
    val revision: String,
    val viewportWidth: String,
    val viewportHeight: String,
) {
    init {
        val width = SavedControllerWire.number(viewportWidth)
        val height = SavedControllerWire.number(viewportHeight)
        if (
            !PhoneCatalogClient.counter(configurationRevision) ||
                configurationRevision == "0" ||
                !PhoneCatalogClient.hex(sourceHash, 64) ||
                !PhoneCatalogClient.profileID(profileID) ||
                !PhoneCatalogClient.counter(generation) ||
                generation == "0" ||
                !PhoneCatalogClient.counter(revision) ||
                width == null ||
                height == null ||
                height < 240 ||
                width < height ||
                width > 4096 ||
                height > 4096
        )
            throw SavedControllerRejected()
    }

    internal fun fields(connection: String): JSONObject =
        JSONObject()
            .put("version", 1)
            .put("command", "configuration-controls")
            .put("connectionId", connection)
            .put("expectedConfigurationRevision", configurationRevision)
            .put("expectedSourceHash", sourceHash)
            .put("profileId", profileID)
            .put("generation", generation)
            .put("revision", revision)
            .put("viewportWidth", viewportWidth)
            .put("viewportHeight", viewportHeight)
}

data class SavedControllerMap(val map: ControlMap, val configurationSha256: String) {
    /** Presentation only; emitted after this map's native engine installs. */
    val bridgeMap: Map<String, Any>
        get() =
            mapOf(
                "version" to 1,
                "generation" to map.generation,
                "revision" to map.revision,
                "controls" to
                    map.controls.map { control ->
                        mutableMapOf<String, Any>(
                                "id" to control.id,
                                "action" to control.action,
                                "x" to control.x,
                                "y" to control.y,
                                "width" to control.width,
                                "height" to control.height,
                            )
                            .apply {
                                control.hapticFeedback?.let { haptic ->
                                    put(
                                        "hapticFeedback",
                                        mapOf(
                                            "style" to haptic.style.name,
                                            "pattern" to haptic.pattern.name,
                                            "intensity" to haptic.intensity,
                                            "sharpness" to haptic.sharpness,
                                            "duration" to haptic.duration,
                                        ),
                                    )
                                }
                            }
                    },
            )
}

internal object SavedControllerWire {
    val errors =
        setOf(
            "saved_map_busy",
            "saved_map_timeout",
            "saved_map_unavailable",
            "saved_map_reactivation_required",
            "saved_map_unsupported_profile",
            "saved_map_response_too_large",
        )

    fun number(value: String): Double? =
        if (
            value.length <= 32 &&
                Regex("(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:e[+-]?[0-9]+)?").matches(value)
        )
            value.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 }
        else null

    fun decode(
        fields: Map<String, EnrollmentJSON.Value>,
        request: SavedControllerRequest,
        authority: String,
        connection: String,
    ): SavedControllerMap {
        fun text(key: String) =
            (fields[key] as? EnrollmentJSON.Value.Text)?.value ?: throw SavedControllerRejected()
        fun numberField(key: String) = number(text(key)) ?: throw SavedControllerRejected()
        val header = setOf("version", "command", "connectionId", "kind")
        if (
            fields.size > 848 ||
                fields["version"] != EnrollmentJSON.Value.Integer(1) ||
                fields["command"] != EnrollmentJSON.Value.Text("configuration-controls-result") ||
                fields["connectionId"] != EnrollmentJSON.Value.Text(connection)
        )
            throw SavedControllerRejected()
        if (fields["kind"] == EnrollmentJSON.Value.Text("error")) {
            val error = text("error")
            if (fields.keys != header + "error" || error !in errors) throw SavedControllerRejected()
            throw SavedControllerUnavailable(error)
        }
        val keys =
            (header +
                    setOf(
                        "authorityInstanceId",
                        "configurationRevision",
                        "sourceHash",
                        "configurationSha256",
                        "profileId",
                        "generation",
                        "revision",
                        "viewportWidth",
                        "viewportHeight",
                        "controlCount",
                    ))
                .toMutableSet()
        val count =
            (fields["controlCount"] as? EnrollmentJSON.Value.Integer)?.value
                ?: throw SavedControllerRejected()
        if (
            fields["kind"] != EnrollmentJSON.Value.Text("controls") ||
                text("authorityInstanceId") != authority ||
                text("configurationRevision") != request.configurationRevision ||
                text("sourceHash") != request.sourceHash ||
                text("profileId") != request.profileID ||
                text("generation") != request.generation ||
                text("revision") != request.revision ||
                text("viewportWidth") != request.viewportWidth ||
                text("viewportHeight") != request.viewportHeight ||
                !PhoneCatalogClient.hex(text("configurationSha256"), 64) ||
                count !in 1..64
        )
            throw SavedControllerRejected()
        val controls =
            (0 until count.toInt()).map { index ->
                val prefix = "control$index"
                keys.addAll(listOf("Id", "Action", "X", "Y", "Width", "Height").map { prefix + it })
                val hapticKeys =
                    listOf("Style", "Pattern", "Intensity", "Sharpness", "Duration").map {
                        prefix + "Haptic" + it
                    }
                val haptic =
                    if (hapticKeys.any { it in fields }) {
                        keys.addAll(hapticKeys)
                        try {
                            TouchHapticFeedback(
                                    TouchHapticFeedback.Style.valueOf(text(hapticKeys[0])),
                                    TouchHapticFeedback.Pattern.valueOf(text(hapticKeys[1])),
                                    numberField(hapticKeys[2]),
                                    numberField(hapticKeys[3]),
                                    numberField(hapticKeys[4]),
                                )
                                .also {
                                    if (!it.valid()) throw SavedControllerRejected()
                                }
                                .normalized
                        } catch (_: IllegalArgumentException) {
                            throw SavedControllerRejected()
                        }
                    } else null
                ControlRegion(
                    text(prefix + "Id"),
                    text(prefix + "Action"),
                    numberField(prefix + "X"),
                    numberField(prefix + "Y"),
                    numberField(prefix + "Width"),
                    numberField(prefix + "Height"),
                    haptic,
                )
            }
        if (fields.keys != keys) throw SavedControllerRejected()
        val map =
            ControlMap(
                generation = request.generation,
                revision = request.revision,
                controls = controls,
            )
        try {
            map.validated()
        } catch (_: IllegalArgumentException) {
            throw SavedControllerRejected()
        }
        return SavedControllerMap(map, text("configurationSha256"))
    }
}
