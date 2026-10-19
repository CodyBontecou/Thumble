package com.thumble.android

import org.json.JSONObject

/** Appearance projection only. The client continues to own the original profile and bindings. */
internal data class SkinRenderProjection(
    val original: ControllerProfile?, val landscape: Boolean, val systemDark: Boolean,
    val profile: ControllerProfile?, val compatibility: SkinCompatibilityResult? = null,
    val warning: String? = null
) {
    fun matches(source: ControllerProfile?, landscape: Boolean, systemDark: Boolean) =
        // Match Compose request keys: profile equality keeps JSON source identity.
        original == source && this.landscape == landscape && this.systemDark == systemDark
}

/** Call on a worker. One decoded archive and one projection bound memory use. */
internal class SkinRenderRepository(private val loadPackage: (SkinReference) -> SkinPackage) {
    companion object {
        fun fromDirectory(root: java.io.File): SkinRenderRepository {
            val library by lazy { SkinLibrary(root) }
            return SkinRenderRepository { library.packageFor(it) }
        }
    }
    private val revision = java.util.concurrent.atomic.AtomicLong()
    private var cachedRevision = -1L
    private var reference: SkinReference? = null
    private var packageValue: SkinPackage? = null
    private var cached: SkinRenderProjection? = null

    /** Installation/removal owners must invalidate after committing a library change. */
    fun invalidate() { revision.incrementAndGet() }

    @Synchronized fun resolve(source: ControllerProfile?, landscape: Boolean, systemDark: Boolean): SkinRenderProjection {
        val currentRevision = revision.get()
        if (cachedRevision != currentRevision) {
            reference = null; packageValue = null; cached = null; cachedRevision = currentRevision
        }
        cached?.takeIf { it.matches(source, landscape, systemDark) }?.let { return it }
        fun finish(profile: ControllerProfile? = source, compatibility: SkinCompatibilityResult? = null, warning: String? = null) =
            SkinRenderProjection(source, landscape, systemDark, profile, compatibility, warning).also { cached = it }
        val raw = source?.source?.optJSONObject("skinReference") ?: return finish()
        val requested = runCatching { SkinReference.parse(raw) }.getOrNull()
            ?: return finish(warning = "This keypad has an invalid skin reference. Showing its saved appearance.")
        try {
            if (requested != reference || packageValue == null) {
                // Publish cache identity only after successful validation. Failed lookups
                // cannot accidentally reuse the previous profile's package.
                val loaded = loadPackage(requested)
                require(loaded.reference == requested && loaded.hasSkin) { "Skin identity mismatch" }
                reference = requested; packageValue = loaded
            }
            val local = JSONObject(source.layout(landscape).toString())
            // iOS applies the primary customization's preference to both orientations.
            val preference = source.source.getJSONObject("customization").optString("colorSchemePreference", "system")
            local.put("colorSchemePreference", preference)
            val scheme = source.skinColorScheme(systemDark)
            val baseline = source.source.optJSONObject(if (landscape) "landscapeSkinBaselineCustomization" else "portraitSkinBaselineCustomization")
                ?: source.source.optJSONObject("skinBaselineCustomization")
            val result = SkinProfileResolver.apply(packageValue!!, local, if (landscape) "landscape" else "portrait", scheme, baseline = baseline)
            val projected = JSONObject(source.source.toString()).put(if (landscape) "landscapeCustomization" else "portraitCustomization", result.customization)
            return finish(ControllerProfile(source.id, source.name, projected), result.compatibility,
                if (result.compatibility.status == "compatible") null else "Some skin artwork is unavailable for this layout.")
        } catch (_: Exception) {
            return finish(warning = "This keypad’s skin is unavailable. Showing its saved appearance.")
        }
    }
}
