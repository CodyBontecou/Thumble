package com.thumble.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SkinModelCodecDeviceTest {
    private fun oracle()=SkinModelOracle {
        InstrumentationRegistry.getInstrumentation().context.assets.open("skin-resolution/v1/native-model-oracle.json").use { JSONObject(it.bufferedReader().readText()) }
    }
    @Test fun nativeNormalizationAndInputPreservation() = oracle().validModelsMatchNativeNormalizationAndPreserveInput()
    @Test fun publishedPackageModelsMatchNative() {
        val assets=InstrumentationRegistry.getInstrumentation().context.assets
        val native=assets.open("skin-resolution/v1/native-oracle.json").use { JSONObject(it.bufferedReader().readText()) }
        oracle().publishedPackagesMatchNativeSkinModels(native) { name -> assets.open(name).use { it.readBytes() } }
    }
    @Test fun nativeMalformedModelRejections() = oracle().malformedModelsMatchNativeRejections()
}
