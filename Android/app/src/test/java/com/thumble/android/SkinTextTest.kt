package com.thumble.android

import org.json.JSONObject
import org.junit.Test

class SkinTextTest {
    private fun oracle()=SkinTextOracle {
        javaClass.classLoader!!.getResourceAsStream("unicode/native-text-oracle.json")!!.use { JSONObject(it.bufferedReader().readText()) }
    }
    @Test fun graphemeBoundariesMatchSwiftAcrossBothConformanceDatasets() = oracle().graphemeBoundariesMatchSwiftAcrossBothConformanceDatasets()
    @Test fun scalarCharacterSetsMatchFoundationOverTheEntireUnicodeDomain() = oracle().scalarCharacterSetsMatchFoundationOverTheEntireUnicodeDomain()
}
