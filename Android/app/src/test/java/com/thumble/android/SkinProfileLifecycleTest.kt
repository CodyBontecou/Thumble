package com.thumble.android

import org.json.JSONObject
import org.junit.Test

class SkinProfileLifecycleTest {
    @Test fun applicationReapplicationAndDetachmentMatchNative() = SkinLifecycleOracle {
        javaClass.classLoader!!.getResourceAsStream("skin-resolution/v1/native-lifecycle-oracle.json")!!.use { JSONObject(it.bufferedReader().readText()) }
    }.applicationAndDetachmentMatchNative()
}
