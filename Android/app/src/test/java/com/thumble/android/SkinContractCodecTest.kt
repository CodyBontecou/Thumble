package com.thumble.android

import org.json.JSONObject
import org.junit.Test

class SkinContractCodecTest {
    private fun oracle()=SkinContractOracle {
        javaClass.classLoader!!.getResourceAsStream("skin-resolution/v1/native-contract-oracle.json")!!.use { JSONObject(it.bufferedReader().readText()) }
    }
    @Test fun typedContractsAndNormalizationMatchNative() = oracle().typedContractsAndNormalizationMatchNative()
    @Test fun malformedNestedContractsMatchNativeRejections() = oracle().malformedNestedContractsMatchNativeRejections()
    @Test fun packageCompatibilityValidationMatchesNativeAfterDecodeNormalization() = oracle().packageCompatibilityValidationMatchesNativeAfterDecodeNormalization()
}
