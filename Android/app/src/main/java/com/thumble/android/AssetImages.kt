package com.thumble.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import android.util.Base64
import android.util.LruCache
import org.json.JSONObject
import java.security.MessageDigest
import java.io.ByteArrayInputStream

internal fun normalizedStyleID(value: String): String = buildString {
    SkinText.trim(value).codePoints().forEach { scalar ->
        appendCodePoint(if (SkinText.isAlphanumeric(scalar) || scalar in listOf(45, 95, 46)) scalar else 45)
    }
}.trim('-', '.')

internal data class RasterAsset(val bitmap: Bitmap, val intrinsicWidth: Int, val intrinsicHeight: Int)

/** One profile surface owns this cache. It never fetches URLs or writes asset data. */
internal class AssetImages(library: JSONObject = JSONObject()) {
    private val assets = linkedMapOf<String, JSONObject>()
    private val decoded = object : LruCache<String, RasterAsset>(32 * 1024 * 1024) {
        override fun sizeOf(key: String, value: RasterAsset) = value.bitmap.allocationByteCount
    }
    init {
        val array = library.optJSONArray("assets")
        for (index in 0 until (array?.length() ?: 0)) {
            val asset = array!!.optJSONObject(index) ?: continue
            val id = normalizedStyleID(asset.optString("id"))
            if (id.isNotEmpty() && asset.optString("name").isNotBlank()) assets.putIfAbsent(id, asset)
        }
    }
    private fun data(value: String?): ByteArray? {
        if (value == null || value.isEmpty() || value.length > 3_400_000) return null
        return runCatching { Base64.decode(value, Base64.DEFAULT) }.getOrNull()?.takeIf { it.size <= 2_500_000 }
    }
    fun image(fill: JSONObject, width: Int = 1024, height: Int = 1024): RasterAsset? {
        val inline = fill.optString("data").takeUnless { it == "null" || it.isEmpty() }
        val id = normalizedStyleID(fill.optString("assetID"))
        val bytes = data(inline) ?: data(assets[id]?.optString("data")) ?: return null
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { byte -> "%02x".format(byte) }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true; inScaled = false }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val orientation = runCatching { ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1)
        val swap = orientation in 5..8
        val intrinsicWidth = if (swap) bounds.outHeight else bounds.outWidth
        val intrinsicHeight = if (swap) bounds.outWidth else bounds.outHeight
        var sample = 1
        val mode = fill.optString("resizingMode").ifEmpty { if (fill.optString("contentMode") == "tile") "tile" else "scale" }
        if (mode == "scale") {
            val x = width.coerceAtLeast(1).toDouble() / intrinsicWidth
            val y = height.coerceAtLeast(1).toDouble() / intrinsicHeight
            val scale = if (fill.optString("contentMode") == "fit") minOf(x, y) else maxOf(x, y)
            while (sample < 1_048_576 && sample * 2 * scale <= 1) sample *= 2
        }
        while (bounds.outWidth / sample > 4096 || bounds.outHeight / sample > 4096 ||
            (bounds.outWidth.toLong() / sample) * (bounds.outHeight.toLong() / sample) > 4_194_304) sample *= 2
        val key = "$hash:$sample"
        decoded.get(key)?.let { return it }
        val bitmap = runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inScaled = false; inSampleSize = sample }) }.getOrNull() ?: return null
        val matrix = Matrix()
        when (orientation) {
            2 -> matrix.setScale(-1f, 1f)
            3 -> matrix.setRotate(180f)
            4 -> matrix.setScale(1f, -1f)
            5 -> matrix.setValues(floatArrayOf(0f,1f,0f, 1f,0f,0f, 0f,0f,1f))
            6 -> matrix.setRotate(90f)
            7 -> matrix.setValues(floatArrayOf(0f,-1f,0f, -1f,0f,0f, 0f,0f,1f))
            8 -> matrix.setRotate(270f)
        }
        val oriented = if (matrix.isIdentity) bitmap else Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (oriented !== bitmap) bitmap.recycle()
        return RasterAsset(oriented, intrinsicWidth, intrinsicHeight).also { decoded.put(key, it) }
    }
}
