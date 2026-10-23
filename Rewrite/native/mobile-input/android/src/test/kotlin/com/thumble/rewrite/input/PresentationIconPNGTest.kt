package com.thumble.rewrite.input

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import java.util.zip.DeflaterOutputStream
import org.junit.Assert.*
import org.junit.Test

class PresentationIconPNGTest {
    private fun chunk(type: String, data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        fun word(n: Long) {
            for (i in 3 downTo 0) out.write((n ushr (i * 8)).toInt() and 255)
        }
        word(data.size.toLong())
        val name = type.toByteArray(Charsets.US_ASCII)
        out.write(name)
        out.write(data)
        val crc = CRC32()
        crc.update(name)
        crc.update(data)
        word(crc.value)
        return out.toByteArray()
    }

    private fun compress(raw: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        DeflaterOutputStream(out).use { it.write(raw) }
        return out.toByteArray()
    }

    private fun png(
        raw: ByteArray = ByteArray(4128),
        compressed: ByteArray = compress(raw),
        extra: ByteArray = byteArrayOf(),
        color: Int = 6,
    ): ByteArray {
        val header = byteArrayOf(0, 0, 0, 32, 0, 0, 0, 32, 8, color.toByte(), 0, 0, 0)
        return byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10) +
            chunk("IHDR", header) +
            extra +
            chunk("IDAT", compressed) +
            chunk("IEND", byteArrayOf())
    }

    private fun reject(bytes: ByteArray) {
        try {
            PresentationIconPNG.verify(bytes)
            fail("unsafe PNG admitted")
        } catch (_: PhonePresentationRejected) {}
    }

    @Test
    fun validRGBRGBAAndAncillaryMetadataAreBoundedWithoutRenderer() {
        PresentationIconPNG.verify(png())
        PresentationIconPNG.verify(png(raw = ByteArray(3104), color = 2))
        PresentationIconPNG.verify(
            png(extra = chunk("sRGB", byteArrayOf(0)) + chunk("eXIf", byteArrayOf(1, 2, 3)))
        )
        val raw = ByteArray(4128)
        for (row in 0 until 32) raw[row * 129] = (row % 5).toByte()
        PresentationIconPNG.verify(png(raw))
    }

    @Test
    fun rejectsCRCTruncationTrailingCompressedStreamsAndOversizedOutput() {
        val valid = png()
        reject(valid.copyOf().also { it[40] = (it[40].toInt() xor 1).toByte() })
        reject(valid.copyOf(valid.size - 1))
        reject(valid + byteArrayOf(0))
        reject(ByteArray(8193))
        reject(png(compressed = compress(ByteArray(4128)) + byteArrayOf(0)))
        reject(png(compressed = compress(ByteArray(4128)) + compress(ByteArray(4128))))
        reject(png(raw = ByteArray(4129)))
        reject(png(raw = ByteArray(4127)))
        reject(png(raw = ByteArray(4128).also { it[0] = 5 }))
        reject(png(compressed = byteArrayOf(0, 1, 2, 3)))
    }

    @Test
    fun rejectsIndependentCompressedAncillaryAnimationUnknownCriticalAndMalformedTransparency() {
        for (name in listOf("iCCP", "zTXt", "iTXt", "acTL", "fcTL", "fdAT", "ABCD")) reject(
            png(extra = chunk(name, byteArrayOf(0)))
        )
        reject(png(extra = chunk("tRNS", ByteArray(6))))
        reject(png(raw = ByteArray(3104), color = 2, extra = chunk("tRNS", ByteArray(6) { 1 })))
        reject(
            png(
                raw = ByteArray(3104),
                color = 2,
                extra = chunk("tRNS", ByteArray(6)) + chunk("tRNS", ByteArray(6)),
            )
        )
        reject(png(extra = chunk("PLTE", byteArrayOf(1, 2))))
        reject(
            png(
                extra =
                    (1..64).fold(byteArrayOf()) { bytes, _ -> bytes + chunk("teSt", byteArrayOf()) }
            )
        )
    }
}
