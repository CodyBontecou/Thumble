package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** Same duplicate-key and finite-number contract on Android and the JVM test runtime. */
internal object PackageJSON {
    fun objectValue(bytes: ByteArray): JSONObject {
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        return Reader(text).read() as? JSONObject ?: throw SkinPackageException("invalid-json")
    }
    private class Reader(private val text: String) {
        private var at = 0
        private fun bad(): Nothing = throw SkinPackageException("invalid-json")
        private fun space() { while (at < text.length && text[at] in " \t\n\r") at++ }
        fun read(): Any { val result=value(0);space();if (at != text.length) bad();return result }
        private fun value(depth: Int): Any {
            if (depth > 128) bad()
            space();if (at == text.length) bad()
            return when (text[at]) {
                '{' -> {
                    at++;space();val result=JSONObject();val seen=mutableSetOf<String>()
                    if (at < text.length && text[at] == '}') { at++;return result }
                    while (true) {
                        space();val key=string();if (!seen.add(SkinText.canonicalKey(key))) throw SkinPackageException("duplicate-json-key")
                        space();if (at == text.length || text[at++] != ':') bad()
                        result.put(key,value(depth+1));space()
                        if (at == text.length) bad()
                        when (text[at++]) { '}' -> return result; ',' -> {}; else -> bad() }
                    }
                    @Suppress("UNREACHABLE_CODE") result
                }
                '[' -> {
                    at++;space();val result=JSONArray()
                    if (at < text.length && text[at] == ']') { at++;return result }
                    while (true) {
                        result.put(value(depth+1));space();if (at == text.length) bad()
                        when (text[at++]) { ']' -> return result; ',' -> {}; else -> bad() }
                    }
                    @Suppress("UNREACHABLE_CODE") result
                }
                '"' -> string()
                't' -> literal("true",true)
                'f' -> literal("false",false)
                'n' -> literal("null",JSONObject.NULL)
                else -> {
                    val start=at
                    while (at < text.length && text[at] !in ",]} \t\n\r") at++
                    val number=text.substring(start,at)
                    if (!number.matches(Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?"))) bad()
                    number.toLongOrNull() ?: number.toDoubleOrNull()?.takeIf { it.isFinite() } ?: bad()
                }
            }
        }
        private fun literal(expected: String,result: Any): Any {
            if (!text.startsWith(expected,at)) bad();at+=expected.length;return result
        }
        private fun string(): String {
            if (at == text.length || text[at] != '"') bad()
            val start=at++
            while (at < text.length) {
                when (val c=text[at++]) {
                    '"' -> return (JSONTokener(text.substring(start,at)).nextValue() as? String)?.takeIf(SkinText::isWellFormed) ?: bad()
                    '\\' -> {
                        if (at == text.length) bad()
                        when (text[at++]) {
                            '"','\\','/','b','f','n','r','t' -> {}
                            'u' -> { repeat(4) { if (at == text.length || text[at++].digitToIntOrNull(16) == null) bad() } }
                            else -> bad()
                        }
                    }
                    else -> if (c.code < 32) bad()
                }
            }
            bad()
        }
    }
}
