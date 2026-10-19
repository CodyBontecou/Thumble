package com.thumble.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SkinTextDeviceTest {
    private fun oracle()=SkinTextOracle {
        InstrumentationRegistry.getInstrumentation().context.assets.open("unicode/native-text-oracle.json").use { JSONObject(it.bufferedReader().readText()) }
    }
    @Test fun nativeGraphemeBoundaries() = oracle().graphemeBoundariesMatchSwiftAcrossBothConformanceDatasets()
    @Test fun nativeScalarCharacterSets() = oracle().scalarCharacterSetsMatchFoundationOverTheEntireUnicodeDomain()
}
