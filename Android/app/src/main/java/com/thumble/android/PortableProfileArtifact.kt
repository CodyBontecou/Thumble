package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.erdtman.jcs.JsonCanonicalizer
import java.math.BigDecimal
import java.util.UUID

internal class ProfileArtifactException(val code: String): IllegalArgumentException(
    if (code == "too-large") "The profile file exceeds the size limit." else "The profile file failed integrity or format checks.")

/** Byte-preserving portable envelope, separate from paired-host profile state. */
internal class PortableProfileArtifact private constructor(private val bytes: ByteArray,private val envelope: JSONObject,
    val contentHash: String,val activeProfileID: UUID,val defaultProfileID: UUID?,val summaries: List<Summary>) {
    data class Summary(val id: UUID,val name: String)
    val byteCount get()=bytes.size
    val rawSHA256=packageHash(bytes)
    fun rawData()=bytes.copyOf()
    fun profileSnapshot(): ProfileSnapshot {
        val profiles=envelope.getJSONArray("profiles")
        val typed=(0 until profiles.length()).map { i ->
            val raw=JSONObject(profiles.getJSONObject(i).toString())
            for(slot in listOf("customization","landscapeCustomization","portraitCustomization")) {
                val layout=raw.optJSONObject(slot) ?: continue
                raw.put(slot,PortableProfileSemantics.previewLayout(layout))
            }
            ControllerProfile.parse(raw).copy(name=raw.getString("name"))
        }
        return ProfileSnapshot(typed,activeProfileID,defaultProfileID)
    }
    override fun toString()="PortableProfileArtifact([validated])"
    companion object {
        const val MAX_BYTES=8*1024*1024
        private val uuid=Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        internal fun id(value: Any?): UUID {
            val text=value as? String ?: bad()
            if(!uuid.matches(text)) bad()
            return UUID.fromString(text)
        }
        private fun bad(): Nothing=throw ProfileArtifactException("invalid-artifact")
        private fun obj(v: Any?)=v as? JSONObject ?: bad()
        private fun text(v: Any?)=v as? String ?: bad()
        private fun integer(v: Any?): Long {
            val n=v as? Number ?: bad()
            return try { BigDecimal(n.toString()).longValueExact() } catch(_: ArithmeticException) { bad() }
        }
        fun decode(input: ByteArray): PortableProfileArtifact = try {
            if(input.size>MAX_BYTES) throw ProfileArtifactException("too-large")
            val raw=PackageJSON.objectValue(input,portable=true)
            if(raw.opt("schema")!="com.codybontecou.pocketpad.keypad-configuration" || integer(raw.opt("version"))!=4L || integer(raw.opt("artifactVersion"))!=1L) bad()
            integer(raw.opt("exportedAt"))
            val catalog=obj(raw.opt("catalogRevision"))
            if(catalog.length()!=3 || listOf("controllerTemplates","deviceFrames","generationSpec").any { integer(catalog.opt(it))!=1L }) bad()
            val hash=obj(raw.opt("contentHash"))
            val digest=text(hash.opt("value"))
            if(hash.length()!=3 || hash.opt("algorithm")!="sha256" || hash.opt("canonicalization")!="rfc8785" || !Regex("[0-9a-f]{64}").matches(digest)) bad()
            val known=setOf("schema","version","artifactVersion","exportedAt","profiles","activeProfileID","defaultProfileID","profileKeyBindings","profileOutputBindings","catalogRevision","contentHash")
            val reserved=known.map(::normalized).toSet()+setOf("keybindings","outputbindings")
            for(k in raw.keys()) if((k !in known && normalized(k) in reserved) || normalized(k) in setOf("keybindings","outputbindings")) bad()
            portableValues(raw)
            val profiles=raw.optJSONArray("profiles") ?: bad()
            if(profiles.length() !in 1..256) bad()
            val summaries=mutableListOf<Summary>();val declared=linkedMapOf<UUID,Set<UUID>>()
            repeat(profiles.length()) { index ->
                val p=obj(profiles.opt(index));if(p.has("launchTarget")) bad()
                val profileID=id(p.opt("id"));val name=text(p.opt("name"))
                if(SkinText.trim(name).isEmpty() || name.codePointCount(0,name.length)>256 || profileID in declared) bad()
                val elementIDs=mutableSetOf<UUID>()
                for(slot in listOf("customization","landscapeCustomization","portraitCustomization")) {
                    if(slot!="customization" && (!p.has(slot) || p.isNull(slot))) continue
                    val layout=obj(p.opt(slot));val elements=layout.optJSONArray("elements") ?: bad()
                    repeat(elements.length()) { elementIDs+=id(obj(elements.opt(it)).opt("id")) }
                    validateLayout(layout)
                }
                for(slot in listOf("skinBaselineCustomization","landscapeSkinBaselineCustomization","portraitSkinBaselineCustomization"))
                    if(p.has(slot) && !p.isNull(slot)) validateLayout(obj(p.get(slot)))
                optionalEnum(p,"orientationPreference",setOf("automatic","portrait","landscape"))
                optionalEnum(p,"outputMode",setOf("keyboard","controller","custom"))
                if(p.has("updatedAt") && !p.isNull("updatedAt")) integer(p.get("updatedAt"))
                PortableProfileSemantics.profile(p)
                ControllerProfile.parse(JSONObject(p.toString()))
                declared[profileID]=elementIDs;summaries+=Summary(profileID,name)
            }
            val active=id(raw.opt("activeProfileID"));if(active !in declared) bad()
            val default=if(raw.has("defaultProfileID") && !raw.isNull("defaultProfileID")) id(raw.get("defaultProfileID")) else null
            if(default!=null && default !in declared) bad()
            for((field,output) in listOf("profileKeyBindings" to false,"profileOutputBindings" to true)) {
                val maps=if(raw.has(field)) obj(raw.get(field)) else JSONObject()
                val owners=mutableSetOf<UUID>()
                for(key in maps.keys()) {
                    val owner=id(key);if(!owners.add(owner)) bad()
                    val ids=declared[owner] ?: bad();val bindings=obj(maps.get(key));if(bindings.length()>384) bad()
                    val bound=mutableSetOf<UUID>()
                    for(element in bindings.keys()) {
                        val elementID=id(element);if(!bound.add(elementID) || elementID !in ids) bad()
                        val binding=obj(bindings.get(element))
                        if(output) outputBinding(binding) else keyBinding(binding)
                    }
                }
            }
            val content=JSONObject(raw.toString()).apply { remove("exportedAt");remove("contentHash") }
            val canonical=JsonCanonicalizer(content.toString()).encodedUTF8
            if(packageHash(canonical)!=digest) bad()
            PortableProfileArtifact(input.copyOf(),raw,digest,active,default,summaries.toList())
        } catch(error: ProfileArtifactException) { throw error }
        catch(_: Exception) { bad() }

        private fun normalized(key: String)=key.filter { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' }.lowercase()
        private fun forbidden(key: String): Boolean {
            val n=normalized(key)
            return n in setOf("accountid","apikey","authorization","bookmarkdata","clientid","clientsecret","cookie","credential","credentials","data","deviceid","deviceidentifier","devicename","filepath","hostname","iconpngdata","launchtarget","pairingcode","password","path","process","processid","processidentifier","privatekey","secret","serveraddress","serverid","sessionkey","thumbnaildata","trustedclient","trustedclients") ||
                listOf("token","secret","password","privatekey","filepath","url","bookmarkdata","iconpngdata","imagedata","thumbnaildata","binarydata").any(n::endsWith) || "authorization" in n
        }
        private fun portableValues(root: JSONObject) {
            val pending=java.util.ArrayDeque<Any>();pending.add(root)
            while(pending.isNotEmpty()) when(val current=pending.removeLast()) {
                is JSONObject -> for(k in current.keys()) {
                    val child=current.get(k)
                    if(forbidden(k) && child!==JSONObject.NULL) bad()
                    pending.add(child)
                }
                is JSONArray -> repeat(current.length()) { pending.add(current.get(it)) }
            }
        }
        private fun optionalEnum(raw: JSONObject,key: String,allowed: Set<String>) {
            if(raw.has(key) && !raw.isNull(key) && text(raw.get(key)) !in allowed) bad()
        }
        internal fun keyBinding(binding: JSONObject) {
            fun stroke(value: JSONObject) {
                if(integer(value.opt("keyCode")) !in 0..65535) bad()
                if(value.has("modifiers") && value.has("modifiersRawValue")) bad()
                val field=if(value.has("modifiers")) "modifiers" else "modifiersRawValue"
                if(value.has(field) && integer(value.get(field)) !in 0..255) bad()
            }
            stroke(binding)
            if(binding.has("sequence") && !binding.isNull("sequence")) {
                val sequence=binding.get("sequence") as? JSONArray ?: bad()
                if(sequence.length()>32) bad()
                repeat(sequence.length()) { stroke(obj(sequence.get(it))) }
            }
        }
        internal fun outputBinding(binding: JSONObject) {
            if(binding.has("keyboard") && !binding.isNull("keyboard")) keyBinding(obj(binding.get("keyboard")))
            if(binding.has("gamepadButtons")) {
                val buttons=binding.get("gamepadButtons") as? JSONArray ?: bad()
                if(buttons.length()>32) bad()
                repeat(buttons.length()) { text(buttons.get(it)) }
            }
        }
        // The envelope's portable binding maps allow future enum strings. Executable
        // element bindings instead decode through the current Swift Codable model.
        private val gamepadButtons=setOf("south","east","west","north","leftShoulder","rightShoulder","leftTriggerButton","rightTriggerButton","select","start","home","leftStickPress","rightStickPress","dpadUp","dpadDown","dpadLeft","dpadRight")
        private fun typedOutput(binding: JSONObject) {
            val buttons=binding.opt("gamepadButtons") as? JSONArray ?: bad()
            repeat(buttons.length()) { if(text(buttons.get(it)) !in gamepadButtons) bad() }
            binding.opt("keyboard")?.takeUnless { it===JSONObject.NULL }?.let { value ->
                val keyboard=obj(value)
                fun stroke(raw: JSONObject) {
                    if(integer(raw.opt("keyCode")) !in 0..65535 || integer(raw.opt("modifiersRawValue")) !in 0..255) bad()
                }
                stroke(keyboard)
                keyboard.opt("sequence")?.takeUnless { it===JSONObject.NULL }?.let { sequence ->
                    val array=sequence as? JSONArray ?: bad()
                    repeat(array.length()) { stroke(obj(array.get(it))) }
                }
            }
        }
        private fun behavior(element: JSONObject,executable: Boolean) {
            for(field in listOf("button","mappedButton","builtInButton","legacySlot","inputID","defaultControlID")) if(element.has(field)) bad()
            fun optional(field: String,check: (JSONObject)->Unit) {
                element.opt(field)?.takeUnless { it===JSONObject.NULL }?.let { check(obj(it)) }
            }
            fun numbers(raw: JSONObject,vararg fields: String) { for(field in fields) {
                val value=raw.opt(field) as? Number ?: bad();if(!value.toDouble().isFinite()) bad()
            } }
            fun booleans(raw: JSONObject,vararg fields: String) { for(field in fields) if(raw.opt(field) !is Boolean) bad() }
            fun enumeration(raw: JSONObject,field: String,allowed: Set<String>) { if(text(raw.opt(field)) !in allowed) bad() }
            optional("joystickMapping") { raw -> for(direction in listOf("up","down","left","right")) typedOutput(obj(raw.opt(direction))) }
            optional("joystickOutputSettings") { raw ->
                enumeration(raw,"analogTarget",setOf("none","left_stick","right_stick"))
                booleans(raw,"sendsDigitalDirections","invertX","invertY","snapToCardinal");numbers(raw,"deadZone","sensitivity")
            }
            optional("triggerSettings") { raw ->
                enumeration(raw,"target",setOf("left","right"));enumeration(raw,"orientation",setOf("horizontal","vertical"))
                booleans(raw,"sendsDigitalButton");numbers(raw,"deadZone","sensitivity","digitalThreshold")
            }
            optional("trackpadSettings") { raw ->
                booleans(raw,"tapToClick","twoFingerScroll","naturalScrolling");numbers(raw,"sensitivity","scrollSensitivity")
            }
            if(executable) {
                optional("output",::typedOutput);optional("defaultOutput",::typedOutput)
                element.opt("partOutputs")?.takeUnless { it===JSONObject.NULL }?.let { value ->
                    val array=value as? JSONArray ?: bad();if(array.length()%2!=0) bad()
                    val seen=mutableSetOf<String>()
                    for(index in 0 until array.length() step 2) {
                        val part=text(array.get(index))
                        if(part !in setOf("primary","joystick_up","joystick_down","joystick_left","joystick_right","trigger_digital") || !seen.add(part)) bad()
                        typedOutput(obj(array.get(index+1)))
                    }
                }
            }
        }
        /** Native known-field types, declarations and appearance ownership; raw bytes stay intact. */
        internal fun validateLayout(layout: JSONObject) {
            optionalEnum(layout,"layoutMode",setOf("standard","southpaw"));optionalEnum(layout,"controlScale",setOf("compact","standard","large"))
            optionalEnum(layout,"colorSchemePreference",setOf("system","light","dark"));optionalEnum(layout,"accentStyle",setOf("monochrome","blue","green","purple","pink","amber"))
            if(layout.has("showsButtonLabels") && !layout.isNull("showsButtonLabels") && layout.get("showsButtonLabels") !is Boolean) bad()
            val elements=layout.getJSONArray("elements");if(elements.length()>128) bad()
            val declared=linkedMapOf<UUID,JSONObject>();val kinds=mutableMapOf<String,Int>()
            repeat(elements.length()) { i ->
                val e=obj(elements.get(i));val uuid=id(e.opt("id"));if(declared.put(uuid,e)!=null) bad()
                val kind=if(e.has("kind") && !e.isNull("kind")) text(e.get("kind")) else "button"
                if(kind !in SUPPORTED_CONTROL_KINDS) bad();kinds[kind]=(kinds[kind] ?: 0)+1
                if(e.has("label") && !e.isNull("label")) text(e.get("label"))
                if(e.has("layout") && !e.isNull("layout")) SkinContractCodec.validateLayout(obj(e.get("layout")))
                optionalEnum(e,"visualRole",setOf("movement","primary_action","secondary_action","utility","menu","custom","joystick","trigger","trackpad","decoration","system"))
                behavior(e,true)
                e.opt("presentation")?.takeUnless { it===JSONObject.NULL }?.let { SkinContractCodec.presentation(it) }
            }
            if((kinds["joystick"] ?: 0)>2 || (kinds["trigger"] ?: 0)>2 || (kinds["trackpad"] ?: 0)>1) bad()
            for(field in listOf("labelOverrides","buttonCustomizations")) {
                val keys=mutableSetOf<UUID>()
                val raw=layout.opt(field)
                val pairs=when(raw) {
                    null,JSONObject.NULL -> emptyList()
                    // Swift dictionaries keyed by KeypadElementID decode as pairs,
                    // even though the ownership precheck also recognizes objects.
                    is JSONArray -> { if(raw.length()%2!=0) bad();(0 until raw.length() step 2).map { text(raw.get(it)) to raw.get(it+1) } }
                    else -> bad()
                }
                for((k,value) in pairs) {
                    val uuid=id(k);if(uuid !in declared || !keys.add(uuid)) bad()
                    if(field=="labelOverrides") text(value) else SkinContractCodec.validateLayout(obj(value))
                }
            }
            layout.opt("customButtons")?.takeUnless { it===JSONObject.NULL }?.let { value ->
                val mirrors=value as? JSONArray ?: bad();val seen=mutableSetOf<UUID>()
                repeat(mirrors.length()) { index ->
                    val mirror=obj(mirrors.get(index));val uuid=id(mirror.opt("id"));val element=declared[uuid] ?: bad()
                    if(!seen.add(uuid)) bad()
                    if(mirror.has("label") && !mirror.isNull("label")) text(mirror.get("label"))
                    if(mirror.has("layout") && !mirror.isNull("layout")) SkinContractCodec.validateLayout(obj(mirror.get("layout")))
                    optionalEnum(mirror,"visualRole",setOf("movement","primary_action","secondary_action","utility","menu","custom","joystick","trigger","trackpad","decoration","system"))
                    behavior(mirror,false)
                    PortableProfileSemantics.mirror(element,mirror)
                }
            }
            for(field in listOf("topBarActivationRegion")) if(layout.has(field) && !layout.isNull(field)) SkinContractCodec.validateLayout(obj(layout.get(field)))
            layout.opt("styleLibrary")?.takeUnless { it===JSONObject.NULL }?.let { SkinModelCodec.styles(obj(it)) }
            layout.opt("artworkLayers")?.takeUnless { it===JSONObject.NULL }?.let { value ->
                val array=value as? JSONArray ?: bad();repeat(array.length()) { SkinModelCodec.artwork(obj(array.get(it))) }
            }
            PortableProfileSemantics.layout(layout,declared)
        }
    }
}
