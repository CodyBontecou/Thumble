package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*

internal class SkinTextOracle(private val load: () -> JSONObject) {
    fun graphemeBoundariesMatchSwiftAcrossBothConformanceDatasets() {
        val oracle=load();val cases=oracle.getJSONArray("cases");assertEquals(1859,cases.length())
        assertEquals(1,oracle.getJSONObject("datasets").getJSONObject("16.0.0").getInt("nativeDisagreements"))
        assertEquals(8,oracle.getJSONObject("datasets").getJSONObject("17.0.0").getInt("nativeDisagreements"))
        repeat(cases.length()) { index ->
            val row=cases.getJSONObject(index);val expected=row.getJSONArray("expected");val text=row.getString("text")
            for(limit in 0..expected.length()+1) {
                val prefix=(0 until minOf(limit,expected.length())).joinToString("") { expected.getString(it) }
                assertEquals("Swift grapheme $index prefix $limit",prefix,SkinText.prefix(text,limit))
            }
        }
    }
    fun scalarCharacterSetsMatchFoundationOverTheEntireUnicodeDomain() {
        val properties=load().getJSONObject("properties")
        for((name,predicate) in listOf("alphanumeric" to SkinText::isAlphanumeric,"control" to SkinText::isControl,"whitespace" to SkinText::isWhitespace)) {
            val bits=ByteArray(0x110000/8)
            for(scalar in 0..0x10FFFF) if(predicate(scalar)) {
                val byte=scalar ushr 3
                bits[byte]=(bits[byte].toInt() or (1 shl (scalar and 7))).toByte()
            }
            assertEquals("Foundation $name membership",properties.getJSONObject(name).getString("membershipSHA256"),packageHash(bits))
        }
    }
}
