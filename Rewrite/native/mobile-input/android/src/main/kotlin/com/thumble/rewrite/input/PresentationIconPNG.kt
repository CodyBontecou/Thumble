package com.thumble.rewrite.input

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import java.util.zip.Inflater

/** No platform renderer: validate bounded 32px IDAT before exposing image bytes. */
internal object PresentationIconPNG {
    fun verify(bytes: ByteArray) {
        fun reject(): Nothing = throw PhonePresentationRejected()
        if (
            bytes.size !in 57..8192 ||
                !bytes
                    .copyOfRange(0, 8)
                    .contentEquals(byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10))
        )
            reject()
        fun uint(at: Int): Long =
            (0..3).fold(0L) { n, i -> (n shl 8) or (bytes[at + i].toLong() and 255) }
        var at = 8
        var chunks = 0
        var channels = 0
        var sawData = false
        var endedData = false
        var end = false
        var palette = false
        var transparency = false
        val compressed = ByteArrayOutputStream()
        while (at < bytes.size) {
            if (++chunks > 64 || bytes.size - at < 12) reject()
            val length = uint(at)
            if (length > 8192 || length > bytes.size - at - 12) reject()
            val size = length.toInt()
            val start = at + 8
            val next = start + size + 4
            val nameBytes = bytes.copyOfRange(at + 4, at + 8)
            if (
                nameBytes.any {
                    (it.toInt() and 255) !in 65..90 && (it.toInt() and 255) !in 97..122
                } || (nameBytes[2].toInt() and 32) != 0
            )
                reject()
            val name = String(nameBytes, Charsets.US_ASCII)
            val crc = CRC32()
            crc.update(bytes, at + 4, size + 4)
            if (crc.value != uint(start + size)) reject()
            if (chunks == 1 && name != "IHDR") reject()
            if (sawData && name != "IDAT") endedData = true
            when (name) {
                "IHDR" -> {
                    if (
                        chunks != 1 ||
                            size != 13 ||
                            uint(start) != 32L ||
                            uint(start + 4) != 32L ||
                            bytes[start + 8].toInt() != 8 ||
                            bytes[start + 9].toInt() !in setOf(2, 6) ||
                            bytes[start + 10].toInt() != 0 ||
                            bytes[start + 11].toInt() != 0 ||
                            bytes[start + 12].toInt() != 0
                    )
                        reject()
                    channels = if (bytes[start + 9].toInt() == 6) 4 else 3
                }
                "PLTE" -> {
                    if (palette || sawData || size !in 3..768 || size % 3 != 0) reject()
                    palette = true
                }
                "tRNS" -> {
                    if (
                        sawData ||
                            transparency ||
                            channels != 3 ||
                            size != 6 ||
                            listOf(0, 2, 4).any { bytes[start + it].toInt() != 0 }
                    )
                        reject()
                    transparency = true
                }
                "IDAT" -> {
                    if (endedData || channels == 0) reject()
                    sawData = true
                    compressed.write(bytes, start, size)
                }
                "IEND" -> {
                    if (size != 0 || !sawData || next != bytes.size) reject()
                    end = true
                }
                "acTL",
                "fcTL",
                "fdAT",
                "iCCP",
                "zTXt",
                "iTXt" -> reject()
                else -> if ((nameBytes[0].toInt() and 32) == 0) reject()
            }
            at = next
        }
        if (!end || compressed.size() == 0) reject()
        val expected = 32 * (1 + 32 * channels)
        val output = ByteArray(expected + 1)
        val inflater = Inflater()
        try {
            inflater.setInput(compressed.toByteArray())
            var count = 0
            while (!inflater.finished() && count < output.size) {
                val n = inflater.inflate(output, count, output.size - count)
                if (n == 0) reject()
                count += n
            }
            if (!inflater.finished() || inflater.remaining != 0 || count != expected) reject()
            for (row in 0 until 32) if ((output[row * (1 + 32 * channels)].toInt() and 255) > 4)
                reject()
        } catch (_: java.util.zip.DataFormatException) {
            reject()
        } finally {
            inflater.end()
        }
    }
}
