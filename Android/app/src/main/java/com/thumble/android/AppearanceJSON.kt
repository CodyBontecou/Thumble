package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject

/** Detached containers, shared immutable scalars. Never stringify embedded image data to copy a model. */
internal object AppearanceJSON {
    fun copy(value: Any?): Any? = when (value) {
        is JSONObject -> JSONObject().also { result -> value.keys().forEach { result.put(it, copy(value.get(it))) } }
        is JSONArray -> JSONArray().also { result -> repeat(value.length()) { result.put(copy(value.get(it))) } }
        else -> value
    }
    fun objectCopy(value: JSONObject) = copy(value) as JSONObject
    fun value(owner: JSONObject?, key: String): Any? = owner?.opt(key)?.takeUnless { it === JSONObject.NULL }
    fun set(owner: JSONObject, key: String, value: Any?) {
        if (value == null || value === JSONObject.NULL) owner.remove(key) else owner.put(key, copy(value))
    }
    fun same(left: Any?, right: Any?): Boolean {
        val a = left.takeUnless { it === JSONObject.NULL }; val b = right.takeUnless { it === JSONObject.NULL }
        return when {
            a == null || b == null -> a == null && b == null
            a is Number && b is Number -> a.toDouble() == b.toDouble()
            a is JSONObject && b is JSONObject -> {
                val keys = a.keys().asSequence().toSet()
                keys == b.keys().asSequence().toSet() && keys.all { same(a.opt(it), b.opt(it)) }
            }
            a is JSONArray && b is JSONArray -> a.length() == b.length() && (0 until a.length()).all { same(a.opt(it), b.opt(it)) }
            else -> a == b
        }
    }
    fun objects(array: JSONArray?): List<JSONObject> = if (array == null) emptyList() else
        (0 until array.length()).map { array.getJSONObject(it) }
    fun rows(values: List<JSONObject>) = JSONArray().also { result -> values.forEach { result.put(it) } }
}
