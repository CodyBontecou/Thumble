package com.thumble.android

import org.json.JSONObject

internal data class ControlFaces(val normal: JSONObject, val engaged: JSONObject)
internal data class ControllerPaintFrame(val layout: JSONObject, val controls: List<Control>, val faces: List<ControlFaces>)

/** Complete worker-prepared paint for one scheme. Input callbacks only select an existing frame. */
internal class ControllerAppearanceFrames private constructor(
    private val frames: Map<ControllerActionSet, ControllerPaintFrame>, val bindings: ActionSetBindings
) {
    operator fun get(action: ControllerActionSet) = frames.getValue(action)
    val all: Collection<ControllerPaintFrame> get() = frames.values
    companion object {
        fun prepare(source: ControllerProfile, layout: JSONObject, bank: ProfileAppearanceBank, scheme: String): ControllerAppearanceFrames {
            val frames = ControllerActionSet.entries.associateWith { action ->
                val resolved = bank.resolve(layout, scheme, action.key)
                resolved.put("colorSchemePreference", source.source.getJSONObject("customization").optString("colorSchemePreference", "system"))
                val profile = ControllerProfile(source.id, source.name, JSONObject().put("customization", resolved))
                val controls = profile.controls(true)
                ControllerPaintFrame(resolved, controls, controls.map { control ->
                    ControlFaces(ControlPresentation.resolve(control, resolved, PresentationState.NORMAL, scheme == "dark"),
                        ControlPresentation.resolve(control, resolved, if (control.kind in setOf("joystick", "trigger", "trackpad"))
                            PresentationState.ACTIVE else PresentationState.PRESSED, scheme == "dark"))
                })
            }
            val base = frames.getValue(ControllerActionSet.BASE).controls.map { it.id to it.kind }
            require(frames.values.all { it.controls.map { control -> control.id to control.kind } == base }) { "appearance-changed-input-membership" }
            return ControllerAppearanceFrames(frames, ActionSetBindings.from(source, true))
        }
    }
}
