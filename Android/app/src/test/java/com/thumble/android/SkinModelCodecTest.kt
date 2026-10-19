package com.thumble.android

import org.json.JSONObject
import org.junit.Test

class SkinModelCodecTest {
    private fun oracle()=SkinModelOracle {
        javaClass.classLoader!!.getResourceAsStream("skin-resolution/v1/native-model-oracle.json")!!.use { JSONObject(it.bufferedReader().readText()) }
    }
    @Test fun validModelsMatchNativeNormalizationAndPreserveInput() = oracle().validModelsMatchNativeNormalizationAndPreserveInput()
    @Test fun publishedPackagesMatchNativeSkinModels() {
        val native=javaClass.classLoader!!.getResourceAsStream("skin-resolution/v1/native-oracle.json")!!.use { JSONObject(it.bufferedReader().readText()) }
        oracle().publishedPackagesMatchNativeSkinModels(native) { name -> javaClass.classLoader!!.getResourceAsStream(name)!!.use { it.readBytes() } }
    }
    @Test fun malformedModelsMatchNativeRejections() = oracle().malformedModelsMatchNativeRejections()
}
