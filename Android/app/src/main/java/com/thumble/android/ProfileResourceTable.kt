package com.thumble.android

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/** Preparation reader; activation still requires v5 profiles and peer negotiation. */
internal class ProfileResourceTable private constructor(private val entries: Map<String, ByteArray>) {
    /** No mutable array escapes the table; readers share one immutable backing buffer. */
    fun data(reference: JSONObject): ByteBuffer {
        require(reference.length() == 1 && reference.opt(REFERENCE) is String) { "invalid-resource-reference" }
        val digest = reference.getString(REFERENCE)
        val bytes = entries[digest] ?: throw IllegalArgumentException("missing-resource:$digest")
        return ByteBuffer.wrap(bytes).asReadOnlyBuffer()
    }

    /** Worker-only render copy. Repeated references share a single immutable Base64 string.
     * The saved profile remains compact; containers returned here are independently editable.
     */
    fun expanding(value: JSONObject): JSONObject {
        val encoded = mutableMapOf<String, String>()
        fun expand(node: Any): Any = when (node) {
            is JSONObject -> if (node.has(REFERENCE)) {
                data(node) // Validate exact reference shape, including unknown metadata owners.
                val digest = node.getString(REFERENCE)
                encoded.getOrPut(digest) { Base64.getEncoder().encodeToString(entries.getValue(digest)) }
            } else JSONObject().also { result -> node.keys().forEach { result.put(it, expand(node.get(it))) } }
            is JSONArray -> JSONArray().also { result -> repeat(node.length()) { result.put(expand(node.get(it))) } }
            else -> node
        }
        return expand(value) as JSONObject
    }

    /** Call after removing local-only fields, so bookmarks/icons cannot remain orphaned. */
    fun pruningUnused(profile: JSONObject): JSONObject {
        val used = referencedIDs(profile)
        val copy = JSONObject(profile.toString())
        val resources = copy.getJSONObject(RESOURCES)
        resources.keys().asSequence().toList().filterNot(used::contains).forEach(resources::remove)
        return copy
    }

    /** Validated references in a retained layout, including opaque metadata. */
    fun referencedResourceIDs(value: JSONObject): Set<String> = referencedIDs(value)

    private fun referencedIDs(profile: JSONObject): Set<String> {
        val used = mutableSetOf<String>()
        val pending = ArrayDeque<Any>()
        profile.keys().asSequence().filter { it != RESOURCES }.forEach { pending.addLast(profile.get(it)) }
        while (pending.isNotEmpty()) {
            when (val node = pending.removeLast()) {
                is JSONObject -> if (node.has(REFERENCE)) {
                    data(node)
                    used.add(node.getString(REFERENCE))
                } else node.keys().asSequence().forEach { pending.addLast(node.get(it)) }
                is JSONArray -> repeat(node.length()) { pending.addLast(node.get(it)) }
            }
        }
        return used
    }

    companion object {
        private const val VERSION = "appearanceResourceVersion"
        private const val RESOURCES = "appearanceResources"
        private const val REFERENCE = "resourceSHA256"
        private const val MAX_BYTES = 8 * 1024 * 1024

        /** The importing/wire boundary must first enforce unique keys and document limits. */
        fun fromProfile(profile: JSONObject): ProfileResourceTable? {
            if (!profile.has(VERSION) && !profile.has(RESOURCES)) return null
            require(profile.opt("appearanceBank") is JSONObject) { "invalid-resource-envelope" }
            require(profile.opt(VERSION) is Number && profile.getDouble(VERSION) == 1.0) { "unsupported-resource-version" }
            val resources = profile.opt(RESOURCES) as? JSONObject
                ?: throw IllegalArgumentException("invalid-resource-envelope")
            var byteCount = 0
            val entries = resources.keys().asSequence().sorted().associateWith { digest ->
                val encoded = resources.opt(digest) as? String
                    ?: throw IllegalArgumentException("invalid-resource:$digest")
                require(encoded.length <= ((MAX_BYTES + 2) / 3) * 4) { "invalid-resource:$digest" }
                val bytes = Base64.getDecoder().decode(encoded)
                require(Base64.getEncoder().encodeToString(bytes) == encoded && sha256(bytes) == digest) { "invalid-resource:$digest" }
                require(bytes.size <= MAX_BYTES - byteCount) { "resources-too-large" }
                byteCount += bytes.size
                bytes
            }
            return ProfileResourceTable(entries).also { it.referencedIDs(profile) }
        }

        private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
