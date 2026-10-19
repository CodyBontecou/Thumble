package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.math.BigInteger

internal fun packageHash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
    .joinToString("") { "%02x".format(it) }

internal data class SkinReference(val identifier: String,val version: String) {
    init {
        require(identifier==identifier.trim().lowercase() && validSkinIdentifier(identifier))
        require(version==version.trim() && SkinVersion.parse(version)!=null)
    }
    companion object {
        fun parse(json: JSONObject): SkinReference = SkinReference(json.getString("identifier").trim().lowercase(),json.getString("version").trim())
    }
}
internal fun validSkinIdentifier(value: String): Boolean {
    val parts=value.split('.')
    return parts.size>=3 && parts.all { part -> part.isNotEmpty() && Character.isLetter(part.codePointAt(0)) &&
        part.codePoints().allMatch { Character.isLetterOrDigit(it) || it==45 || it==95 } }
}

/** Native version semantics include natural numeric ordering inside prerelease labels. */
internal class SkinVersion private constructor(val major: Long,val minor: Long,val patch: Long,val prerelease: String?): Comparable<SkinVersion> {
    override fun compareTo(other: SkinVersion): Int {
        for ((a,b) in listOf(major to other.major,minor to other.minor,patch to other.patch)) if (a!=b) return a.compareTo(b)
        if (prerelease==null) return if (other.prerelease==null) 0 else 1
        if (other.prerelease==null) return -1
        val a=Regex("[0-9]+|[^0-9]+").findAll(prerelease).map { it.value }.toList()
        val b=Regex("[0-9]+|[^0-9]+").findAll(other.prerelease).map { it.value }.toList()
        for (i in 0 until minOf(a.size,b.size)) {
            val result=if (a[i][0].isDigit() && b[i][0].isDigit()) BigInteger(a[i]).compareTo(BigInteger(b[i]))
                else a[i].compareTo(b[i],ignoreCase=true)
            if (result!=0) return result
        }
        return a.size.compareTo(b.size)
    }
    companion object {
        fun parse(value: String): SkinVersion? {
            val release=value.substringBefore('+').split('-',limit=2)
            val core=release[0].split('.')
            if (core.size!=3 || release.size==2 && release[1].isEmpty()) return null
            val numbers=core.map { it.toLongOrNull()?.takeIf { n -> n>=0 } ?: return null }
            return SkinVersion(numbers[0],numbers[1],numbers[2],release.getOrNull(1))
        }
    }
}

/** Archive bytes and assets are immutable to callers. No profile/binding adoption occurs here. */
internal class SkinPackage internal constructor(
    private val raw: ByteArray,private val manifest: JSONObject,private val skin: JSONObject?,
    private val profile: JSONObject?,private val assets: Map<String,ByteArray>,private val previews: Map<String,ByteArray>
) {
    val reference=SkinReference.parse(manifest)
    val name: String get()=manifest.getString("name")
    val authorName: String get()=manifest.optJSONObject("author")?.optString("name").orEmpty()
    val hasSkin get()=skin!=null
    val archiveSHA256=packageHash(raw)
    fun archiveBytes()=raw.copyOf()
    fun manifestJSON()=JSONObject(manifest.toString())
    fun skinJSON()=skin?.let { JSONObject(it.toString()) }
    fun profileJSON()=profile?.let { JSONObject(it.toString()) }
    fun asset(id: String)=assets[id]?.copyOf()
    fun preview(id: String)=previews[id]?.copyOf()
    val assetIDs get()=assets.keys.toSet()
    override fun toString()="SkinPackage(${reference.identifier}@${reference.version})"
}

internal object SkinPackageCodec {
    private val roles=setOf("movement","primary_action","secondary_action","utility","menu","custom","joystick","trigger","trackpad","decoration","system")
    private val accents=setOf("monochrome","blue","green","purple","pink","amber")
    private val shapes=setOf("rounded_rectangle","rectangle","capsule","circle","ellipse","polygon","star")
    private val orientations=setOf("portrait","landscape")
    private val actions=setOf("base","left-trigger","right-trigger","both-triggers")
    private fun check(ok: Boolean,code: String) { if (!ok) throw SkinPackageException(code) }
    private fun JSONObject.text(key: String): String = get(key) as? String ?: throw SkinPackageException("invalid-json-type")
    private fun JSONObject.array(key: String): JSONArray = get(key) as? JSONArray ?: throw SkinPackageException("invalid-json-type")
    private fun JSONObject.obj(key: String): JSONObject = get(key) as? JSONObject ?: throw SkinPackageException("invalid-json-type")
    private fun JSONObject.optionalText(key: String): String? = if (!has(key) || isNull(key)) null else text(key)
    private fun JSONObject.integer(key: String): Long {
        val n=get(key) as? Number ?: throw SkinPackageException("invalid-json-type")
        check(n.toDouble().isFinite() && n.toDouble()==n.toLong().toDouble(),"invalid-json-type")
        return n.toLong()
    }
    private fun enum(value: String?,allowed: Set<String>) { check(value==null || value in allowed,"unsupported-enum") }
    fun decode(bytes: ByteArray): SkinPackage {
        check(bytes.size<=PackageArchive.MAX_ARCHIVE,"archive-too-large")
        try { return decodeVerified(bytes.copyOf()) }
        catch (e: SkinPackageException) { throw e }
        catch (_: Exception) { throw SkinPackageException("invalid-package") }
    }
    private fun decodeVerified(raw: ByteArray): SkinPackage {
        val archive=PackageArchive.index(raw)
        val manifest=PackageJSON.objectValue(archive.extract("manifest.json",1_000_000))
        check(manifest.text("schema").trim()=="com.codybontecou.pocketpad.skin-package","unsupported-schema")
        check(manifest.integer("schemaVersion") in 1..2,"unsupported-schema-version")
        val reference=SkinReference.parse(manifest)
        manifest.put("identifier",reference.identifier).put("version",reference.version)
        manifest.put("name",manifest.text("name").trim().take(100));check(manifest.text("name").isNotEmpty(),"missing-name")
        val author=manifest.obj("author");author.put("name",author.text("name").trim().ifBlank { "Unknown Creator" }.take(80))
        manifest.put("summary",manifest.text("summary").trim().take(500));manifest.put("license",manifest.text("license").trim().take(100))
        val tags=manifest.array("tags");repeat(tags.length()) { check(tags.get(it) is String,"invalid-json-type") }
        val kind=manifest.text("kind");enum(kind,setOf("skin","layout","pack"))
        val skinPath=manifest.optionalText("skinPath")?.trim()
        val profilePath=manifest.optionalText("profilePath")?.trim()
        check(kind=="layout" || skinPath!=null,"missing-skin")
        check(kind!="skin" || profilePath==null,"unexpected-profile")
        check(kind=="skin" || profilePath!=null,"missing-profile")
        val assetDescriptors=manifest.array("assets");val previewDescriptors=manifest.array("previews")
        val allowed=mutableSetOf("manifest.json","README.md","LICENSE","LICENSE.txt")
        listOfNotNull(skinPath,profilePath).forEach { check(PackageArchive.safePath(it),"unsafe-entry");allowed.add(it) }
        for (array in listOf(assetDescriptors,previewDescriptors)) repeat(array.length()) {
            val descriptor=array.getJSONObject(it)
            val path=descriptor.text("path").trim()
            check(PackageArchive.safePath(path),"unsafe-entry");allowed.add(path)
        }
        check(archive.paths.all { it in allowed },"unexpected-entry")
        fun document(path: String?,hashField: String,limit: Int): JSONObject? {
            if (path==null) return null
            val bytes=archive.extract(path,limit)
            check(manifest.text(hashField).trim().lowercase()==packageHash(bytes),"corrupt-entry")
            return PackageJSON.objectValue(bytes)
        }
        val skin=document(skinPath,"skinSHA256",4_000_000)?.let(SkinModelCodec::skin)
        val profile=document(profilePath,"profileSHA256",8_000_000)
        val assets=resources(assetDescriptors,"assets",archive)
        val previews=resources(previewDescriptors,"previews",archive)
        val rawCompatibility=manifest.opt("compatibility")
        if(rawCompatibility!=null && rawCompatibility!==JSONObject.NULL) {
            check(rawCompatibility is JSONObject,"invalid-compatibility")
            manifest.put("compatibility",SkinContractCodec.compatibility(rawCompatibility as JSONObject))
        }
        validateCompatibility(manifest)
        skin?.let { validateSkin(it,assets.keys,manifest) }
        // Layout/pack payloads remain inert. Profile import/adoption requires its
        // own canonical artifact validation and user action; installing never runs it.
        return SkinPackage(raw,manifest,skin,profile,assets,previews)
    }
    private fun resources(descriptors: JSONArray,root: String,archive: PackageArchive.Index): Map<String,ByteArray> {
        val data=linkedMapOf<String,ByteArray>();val paths=mutableSetOf<String>()
        repeat(descriptors.length()) {
            val descriptor=descriptors.getJSONObject(it)
            val id=normalizedStyleID(descriptor.text("id"));val path=descriptor.text("path").trim()
            check(id.isNotEmpty() && id !in data,"duplicate-resource-id")
            check(paths.add(path),"duplicate-resource-path");check(PackageArchive.safePath(path,root),"unsafe-resource-path")
            val extension=path.substringAfterLast('.').lowercase()
            if (root=="assets") {
                val type=descriptor.text("contentType").trim().take(100).lowercase()
                check((type.startsWith("image/") || type=="application/pdf") && extension !in setOf("app","appex","bundle","command","dylib","exe","js","mach-o","node","o","out","plugin","py","sh","so","swift"),"executable-asset")
                enum(descriptor.text("role"),setOf("background","icon","texture","reference"))
            } else {
                check(extension in setOf("avif","gif","heic","heif","jpeg","jpg","png","tif","tiff","webp"),"invalid-preview-content")
                enum(descriptor.text("orientation"),orientations)
                enum(descriptor.optionalText("colorScheme"),setOf("light","dark"))
            }
            val bytes=archive.extract(path)
            check(descriptor.integer("byteCount").coerceAtLeast(0)==bytes.size.toLong() &&
                descriptor.text("sha256").trim().lowercase()==packageHash(bytes),"resource-integrity-mismatch")
            descriptor.put("id",id).put("path",path)
            data[id]=bytes
        }
        return data
    }
    private fun validateCompatibility(manifest: JSONObject) {
        val raw=manifest.opt("compatibility")
        if (raw==null || raw===JSONObject.NULL) return
        check(raw is JSONObject,"invalid-compatibility");val c=raw as JSONObject
        check(manifest.integer("schemaVersion")==2L,"compatibility-requires-v2")
        val mode=c.text("mode");enum(mode,setOf("universal","template_aligned","captured_controller"))
        val requested=c.array("orientations");check(requested.length()>0,"missing-compatible-orientation")
        repeat(requested.length()) { enum(requested.getString(it),orientations) }
        val minimum=if(c.isNull("minimumAspectRatio")) null else c.opt("minimumAspectRatio")
        val maximum=if(c.isNull("maximumAspectRatio")) null else c.opt("maximumAspectRatio")
        for (aspect in listOfNotNull(minimum,maximum)) check(aspect is Number && aspect.toDouble() in .25..4.0,"invalid-aspect-range")
        if (minimum is Number && maximum is Number) check(minimum.toDouble()<=maximum.toDouble(),"invalid-aspect-range")
        val templates=c.array("templates");val ids=mutableSetOf<String>()
        check(mode!="template_aligned" || templates.length()>0,"missing-template-requirement")
        repeat(templates.length()) { index ->
            val t=templates.getJSONObject(index);val id=t.text("templateID").trim().lowercase()
            check(id.isNotEmpty(),"invalid-template-requirement");check(ids.add(SkinText.canonicalKey(id)),"duplicate-template-requirement")
            val lower=t.integer("minimumRevision");check(lower>=1,"invalid-template-revision-range")
            if (t.has("maximumRevision") && !t.isNull("maximumRevision")) check(t.integer("maximumRevision")>=lower,"invalid-template-revision-range")
        }
        val requiredRoles=c.array("requiredRoles");repeat(requiredRoles.length()) { enum(requiredRoles.getString(it),roles) }
        val features=c.array("requiredFeatures");repeat(features.length()) { enum(features.getString(it),setOf("action_set_layers","artwork_layers","nine_slice_images","bitmap_control_states")) }
        if (mode=="captured_controller") validateCaptured(c.obj("capturedGeometry"), (0 until requested.length()).map { requested.getString(it) }.toSet())
        else check(!c.has("capturedGeometry") || c.isNull("capturedGeometry"),"unexpected-captured-geometry")
    }
    private fun validateCaptured(geometry: JSONObject,requested: Set<String>) {
        val variants=geometry.array("variants");check(variants.length() in 1..2,"invalid-captured-geometry")
        val seen=mutableSetOf<String>()
        repeat(variants.length()) { index ->
            val v=variants.getJSONObject(index);check(seen.add(v.text("orientation")),"invalid-captured-geometry")
            for (key in listOf("canvasWidth","canvasHeight")) check(v.getDouble(key) in 240.0..1800.0,"invalid-captured-geometry")
            val safe=v.obj("safeAreaInsets");for (key in listOf("top","leading","bottom","trailing")) check(safe.getDouble(key) in 0.0..0.45,"invalid-captured-geometry")
            val controls=v.array("controls");check(controls.length()<=256,"invalid-captured-geometry")
            val ids=mutableSetOf<String>()
            repeat(controls.length()) { i ->
                val control=controls.getJSONObject(i);val id=control.text("id")
                check(id.isNotEmpty() && id.toByteArray().size<=128 && ids.add(SkinText.canonicalKey(id)),"invalid-captured-geometry")
                val f=control.obj("frame");val x=f.getDouble("x");val y=f.getDouble("y");val w=f.getDouble("width");val h=f.getDouble("height")
                check(x>=0 && y>=0 && w>0 && h>0 && x+w<=1.000001 && y+h<=1.000001,"invalid-captured-geometry")
                if (control.has("rotationDegrees") && !control.isNull("rotationDegrees")) check(control.getDouble("rotationDegrees") in -180.0..180.0,"invalid-captured-geometry")
            }
        }
        check(seen==requested,"invalid-captured-geometry")
    }
    private fun validateSkin(skin: JSONObject,assets: Set<String>,manifest: JSONObject) {
        val base=skin.obj("base");val variants=skin.array("variants");val appearances=mutableListOf(base)
        val variantIDs=mutableSetOf<String>();val accepted=mutableListOf<JSONObject>()
        var actionSet=false
        repeat(variants.length()) {
            val v=variants.getJSONObject(it);val id=normalizedStyleID(v.text("id"))
            enum(v.optionalText("orientation"),orientations);enum(v.optionalText("colorScheme"),setOf("light","dark"));enum(v.optionalText("actionSet"),actions)
            actionSet=actionSet || v.optionalText("actionSet")!=null
            if (id.isNotEmpty() && variantIDs.add(id)) { v.put("id",id);accepted.add(v);appearances.add(v.obj("appearance")) }
        }
        if (actionSet) check(manifest.optJSONObject("compatibility")?.optJSONArray("requiredFeatures")?.let { list -> (0 until list.length()).any { list.optString(it)=="action_set_layers" } }==true,"missing-action-set-feature")
        fun fill(value: JSONObject?) {
            if (value?.optString("kind")=="image") value.optJSONObject("image")?.optionalText("assetID")?.let { check(normalizedStyleID(it) in assets,"missing-asset-reference") }
        }
        fun icon(value: JSONObject?) {
            if (value==null) return
            enum(value.text("source"),setOf("sf_symbol","text","asset"))
            if (value.text("source")=="asset") check(normalizedStyleID(value.text("value")) in assets,"missing-asset-reference")
        }
        fun visual(value: JSONObject?) {
            if (value==null) return
            icon(value.optJSONObject("icon"))
            for (state in listOf("normal","pressed","active","disabled")) value.optJSONObject(state)?.let {
                fill(it.optJSONObject("fillStyle"));icon(it.optJSONObject("content")?.optJSONObject("icon"))
            }
        }
        for (a in appearances) {
            enum(a.optionalText("accentStyle"),accents)
            if (a.has("showsButtonLabels") && !a.isNull("showsButtonLabels")) check(a.get("showsButtonLabels") is Boolean,"invalid-json-type")
            fill(a.optJSONObject("backgroundFillStyle"))
            val controls=mutableListOf<JSONObject>();a.optJSONObject("defaultControl")?.let { controls.add(it) }
            val roleRules=a.array("roleRules");repeat(roleRules.length()) { val rule=roleRules.getJSONObject(it);enum(rule.text("role"),roles);controls.add(rule.obj("appearance")) }
            val buttonRules=a.array("buttonRules");repeat(buttonRules.length()) { val rule=buttonRules.getJSONObject(it);java.util.UUID.fromString(rule.text("button"));controls.add(rule.obj("appearance")) }
            for (control in controls) { enum(control.optionalText("shape"),shapes);enum(control.optionalText("accentStyle"),accents);enum(control.optionalText("joystickVisualStyle"),setOf("pad","thumbstick"));icon(control.optJSONObject("icon"));visual(control.optJSONObject("visualStyle")) }
            val styles=a.obj("styleLibrary").array("styles");repeat(styles.length()) { style -> visual(styles.getJSONObject(style).optJSONObject("visualStyle")) }
            a.optJSONArray("artworkLayers")?.let { layers -> repeat(layers.length()) { fill(layers.getJSONObject(it).optJSONObject("fillStyle")) } }
        }
        // Native validation resolves the base action set, including explicit
        // base-bank variants, before checking style references.
        for (orientation in orientations) for (scheme in listOf("light","dark")) {
            val appearance=SkinAppearanceResolver.appearance(skin,orientation,scheme,"base")
            val tokens=appearance.getJSONObject("styleLibrary").getJSONArray("styles")
            val styleIDs=(0 until tokens.length()).map { tokens.getJSONObject(it).getString("id") }.toSet()
            val controls=mutableListOf<JSONObject>()
            appearance.optJSONObject("defaultControl")?.let(controls::add)
            for(field in listOf("roleRules","buttonRules")) {
                val rules=appearance.getJSONArray(field)
                repeat(rules.length()) { controls.add(rules.getJSONObject(it).getJSONObject("appearance")) }
            }
            check(controls.mapNotNull { it.optionalText("styleID") }.all { it in styleIDs },"missing-style-reference")
        }
    }
}
