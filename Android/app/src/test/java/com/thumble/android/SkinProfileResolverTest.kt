package com.thumble.android

import org.json.JSONObject
import org.junit.Test

class SkinProfileResolverTest {
    private fun oracle()=SkinProfileOracle {
        javaClass.classLoader!!.getResourceAsStream("skin-resolution/v1/native-profile-oracle.json")!!.use { JSONObject(it.bufferedReader().readText()) }
    }
    @Test fun canonicalProfilesMatchNativeWithoutChangingBindingsOrInput() = oracle().canonicalProfilesMatchNativeWithoutChangingBindingsOrInput()
    @Test fun compatibilityAndArtworkGatingMatchNative() = oracle().compatibilityAndArtworkGatingMatchNative()
    @Test fun nativeCanvasCatalogAndDefaultsMatch() = oracle().nativeCanvasCatalogAndDefaultsMatch()
}
