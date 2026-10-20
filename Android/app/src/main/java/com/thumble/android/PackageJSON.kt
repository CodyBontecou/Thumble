package com.thumble.android

import org.json.JSONObject

/** Package compatibility adapter; the retained JSON parser has no skin dependency. */
internal object PackageJSON {
    fun objectValue(bytes: ByteArray, portable: Boolean = false): JSONObject = try {
        StrictJSON.objectValue(bytes, portable)
    } catch (error: StrictJSONException) {
        throw SkinPackageException(error.message ?: "invalid-json")
    }
}
