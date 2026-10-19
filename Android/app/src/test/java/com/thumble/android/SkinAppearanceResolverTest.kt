package com.thumble.android

import org.json.JSONObject
import org.junit.Test

class SkinAppearanceResolverTest {
    private fun oracle() = SkinResolverOracle {
        javaClass.classLoader!!.getResourceAsStream("skin-resolution/v1/native-oracle.json")!!.use {
            JSONObject(it.bufferedReader().readText())
        }
    }
    @Test fun allNativeOrientationSchemeActionSetAndControlAppearancesMatch() =
        oracle().allNativeOrientationSchemeActionSetAndControlAppearancesMatch()
    @Test fun localOverrideBaselineClearsAndAssetLibraryStagesMatchNative() =
        oracle().localOverrideBaselineClearsAndAssetLibraryStagesMatchNative()
    @Test fun editingAResolvedAppearanceDoesNotMutatePackageOrLocalInput() {
        val icon = JSONObject().put("source", "text").put("value", "Package").put("placement","center").put("scale",1).put("renderingMode","template")
        val fill = JSONObject().put("kind", "solid").put("color", JSONObject().put("red", .5).put("green",.4).put("blue",.3).put("alpha",1))
        val skin = JSONObject().put("base", JSONObject().put("backgroundFillStyle", fill)
            .put("defaultControl", JSONObject().put("icon", icon)).put("roleRules",org.json.JSONArray())
            .put("buttonRules",org.json.JSONArray()).put("styleLibrary",JSONObject().put("styles",org.json.JSONArray())))
        val originalSkin = skin.toString()
        val appearance = SkinAppearanceResolver.appearance(skin, "portrait", "light")
        appearance.getJSONObject("backgroundFillStyle").getJSONObject("color").put("red", .8)
        appearance.getJSONObject("defaultControl").getJSONObject("icon").put("value", "Preview")
        org.junit.Assert.assertEquals(originalSkin, skin.toString())

        val local = JSONObject().put("icon", JSONObject().put("source", "text").put("value", "Local"))
        val originalLocal = local.toString()
        val result = SkinAppearanceResolver.applyControl(JSONObject(), local)
        result.getJSONObject("icon").put("value", "Editor")
        org.junit.Assert.assertEquals(originalLocal, local.toString())
    }
    @Test fun nativeCornerDefaultsClampsAndLocalSilhouettesMatch() =
        oracle().nativeCornerDefaultsClampsAndLocalSilhouettesMatch()
}
