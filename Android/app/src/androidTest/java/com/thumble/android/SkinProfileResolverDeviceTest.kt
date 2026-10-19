package com.thumble.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SkinProfileResolverDeviceTest {
    private fun oracle()=SkinProfileOracle {
        InstrumentationRegistry.getInstrumentation().context.assets.open("skin-resolution/v1/native-profile-oracle.json").use { JSONObject(it.bufferedReader().readText()) }
    }
    @Test fun canonicalProfilesAndInputDeclarations() = oracle().canonicalProfilesMatchNativeWithoutChangingBindingsOrInput()
    @Test fun compatibilityAndAlignedArtwork() = oracle().compatibilityAndArtworkGatingMatchNative()
    @Test fun canvasCatalogAndNativeDefaults() = oracle().nativeCanvasCatalogAndDefaultsMatch()
}
