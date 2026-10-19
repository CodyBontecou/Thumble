package com.thumble.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SkinContractCodecDeviceTest {
    private fun oracle()=SkinContractOracle {
        InstrumentationRegistry.getInstrumentation().context.assets.open("skin-resolution/v1/native-contract-oracle.json").use { JSONObject(it.bufferedReader().readText()) }
    }
    @Test fun nativeTypedContractsAndNormalization() = oracle().typedContractsAndNormalizationMatchNative()
    @Test fun nativeNestedContractRejections() = oracle().malformedNestedContractsMatchNativeRejections()
    @Test fun malformedContractReplacementPreservesInstalledArchive() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        oracle().malformedReplacementPreservesInstalledArchive(java.io.File(context.noBackupFilesDir,"contract-${java.util.UUID.randomUUID()}"))
    }
    @Test fun nativePackageCompatibilityValidation() = oracle().packageCompatibilityValidationMatchesNativeAfterDecodeNormalization()
}
