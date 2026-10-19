package com.thumble.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith

/** Runs the same native-generated oracle against Android's own JSON implementation. */
@RunWith(AndroidJUnit4::class)
class SkinAppearanceResolverDeviceTest {
    private fun oracle() = SkinResolverOracle {
        InstrumentationRegistry.getInstrumentation().context.assets
            .open("skin-resolution/v1/native-oracle.json").use { JSONObject(it.bufferedReader().readText()) }
    }
    @Test fun nativeAppearanceAndControlCascade() =
        oracle().allNativeOrientationSchemeActionSetAndControlAppearancesMatch()
    @Test fun nativeLocalOverridesLibrariesAndAssetHydration() =
        oracle().localOverrideBaselineClearsAndAssetLibraryStagesMatchNative()
    @Test fun nativeCornerDefaultsAndLocalSilhouettes() =
        oracle().nativeCornerDefaultsClampsAndLocalSilhouettesMatch()
}
