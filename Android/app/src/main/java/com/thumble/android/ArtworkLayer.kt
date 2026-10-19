package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.roundToInt
import kotlin.math.sqrt

internal data class ArtworkLayer(val id: String, val plane: String, val x: Double, val y: Double, val width: Double,
    val height: Double, val fill: JSONObject, val opacity: Double, val rotation: Double, val blend: String, val z: Int)
internal fun artworkLayers(array: JSONArray?): List<ArtworkLayer> {
    require((array?.length() ?: 0) <= 2048) { "Profile has too many artwork layers." }
    return (0 until (array?.length() ?: 0)).mapNotNull { index ->
        val layer = array!!.optJSONObject(index) ?: return@mapNotNull null
        val id = normalizedStyleID(layer.optString("id"))
        val fill = layer.optJSONObject("fillStyle") ?: return@mapNotNull null
        if (id.isEmpty() || layer.optBoolean("isHidden")) return@mapNotNull null
        val frame = layer.optJSONObject("frame")
        val width = (frame?.finite("width", 1.0) ?: 1.0).coerceIn(0.0, 1.0)
        val height = (frame?.finite("height", 1.0) ?: 1.0).coerceIn(0.0, 1.0)
        ArtworkLayer(id, layer.optString("plane", "underlay"), (frame?.finite("x", 0.0) ?: 0.0).coerceIn(0.0, 1 - width),
            (frame?.finite("y", 0.0) ?: 0.0).coerceIn(0.0, 1 - height), width, height, fill,
            layer.finite("opacity", 1.0).coerceIn(0.0, 1.0), layer.finite("rotationDegrees", 0.0) % 360,
            layer.optString("blendMode", "normal"), layer.optInt("zIndex").coerceIn(-10_000, 10_000))
    }.sortedWith(compareBy<ArtworkLayer> { it.z }.thenBy { it.id })
}

/** W3C separable soft-light plus source-over alpha, for Android 26–28. */
internal fun softLight(source: Int, destination: Int): Int {
    return blendArtwork("soft_light", source, destination)
}
internal fun blendArtwork(mode: String, source: Int, destination: Int): Int {
    val sa = (source ushr 24) / 255.0; val da = (destination ushr 24) / 255.0
    if (sa == 0.0) return destination
    val alpha = sa + da - sa * da
    if (alpha <= 0) return 0
    var output = (alpha * 255).roundToInt().coerceIn(0, 255) shl 24
    for (channelIndex in 0..2) {
        val shift = 16 - channelIndex * 8
        val s = (source ushr shift and 255) / 255.0; val d = (destination ushr shift and 255) / 255.0
        val curve = if (d <= .25) ((16 * d - 12) * d + 4) * d else sqrt(d)
        val blend = if (mode == "multiply") s * d else if (s <= .5) d - (1 - 2 * s) * d * (1 - d) else d + (2 * s - 1) * (curve - d)
        val channel = (sa * (1 - da) * s + sa * da * blend + (1 - sa) * da * d) / alpha
        output = output or ((channel * 255).roundToInt().coerceIn(0, 255) shl shift)
    }
    return output
}
