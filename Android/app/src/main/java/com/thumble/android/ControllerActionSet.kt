package com.thumble.android

import java.util.UUID
import org.json.JSONObject

internal enum class ControllerActionSet(val key: String) {
    BASE("base"), LEFT("left-trigger"), RIGHT("right-trigger"), BOTH("both-triggers")
}
internal data class ActionSetInput(val elementID: UUID, val part: InputPart)

/** Display-only bindings. Never infer executable outputs from labels, hints, roles or defaults. */
internal class ActionSetBindings private constructor(private val inputs: Map<ActionSetInput, Set<String>>) {
    fun buttons(id: UUID, part: InputPart): Set<String> = inputs[ActionSetInput(id, part)].orEmpty()
    companion object {
        fun from(profile: ControllerProfile, landscape: Boolean): ActionSetBindings {
            if (profile.source.optString("outputMode", "keyboard") == "keyboard") return ActionSetBindings(emptyMap())
            val result = linkedMapOf<ActionSetInput, Set<String>>()
            for (element in AppearanceJSON.objects(profile.layout(landscape).optJSONArray("elements"))) {
                val id = UUID.fromString(element.getString("id"))
                fun record(part: InputPart, raw: JSONObject?) {
                    val buttons = raw?.optJSONArray("gamepadButtons")
                    result[ActionSetInput(id, part)] = (0 until (buttons?.length() ?: 0)).map { buttons!!.getString(it) }
                        .filter { it in setOf("leftTriggerButton", "rightTriggerButton") }.toSet()
                }
                record(InputPart.PRIMARY, element.optJSONObject("output"))
                val parts = element.swiftMap("partOutputs")
                for ((part, key) in listOf(InputPart.JOYSTICK_UP to "joystick_up", InputPart.JOYSTICK_DOWN to "joystick_down",
                    InputPart.JOYSTICK_LEFT to "joystick_left", InputPart.JOYSTICK_RIGHT to "joystick_right", InputPart.TRIGGER_DIGITAL to "trigger_digital")) {
                    val raw = parts[key.uppercase()] as? JSONObject ?: if (element.optString("kind") == "joystick")
                        element.optJSONObject("joystickMapping")?.optJSONObject(key.removePrefix("joystick_")) else null
                    record(part, raw)
                }
            }
            return ActionSetBindings(result)
        }
    }
}

/** UI-thread input mirror. Each press remembers its trigger choice until its matching up. */
internal class ControllerActionSetInputs {
    private data class Owner(val input: ActionSetInput, val press: Long)
    private val digital = mutableMapOf<Owner, Set<String>>()
    private val analog = mutableSetOf<String>()
    val actionSet: ControllerActionSet get() {
        val left = "left" in analog || digital.values.any { "leftTriggerButton" in it }
        val right = "right" in analog || digital.values.any { "rightTriggerButton" in it }
        return if (left) { if (right) ControllerActionSet.BOTH else ControllerActionSet.LEFT }
            else if (right) ControllerActionSet.RIGHT else ControllerActionSet.BASE
    }
    fun record(id: UUID, part: InputPart, down: Boolean, press: Long, buttons: Set<String>) {
        val owner = Owner(ActionSetInput(id, part), press)
        if (down) digital.putIfAbsent(owner, buttons.filter { it in setOf("leftTriggerButton", "rightTriggerButton") }.toSet())
        else digital.remove(owner)
    }
    fun record(target: String, value: Double) {
        if (target !in setOf("left", "right")) return
        if (value.isFinite() && value > .5) analog.add(target) else analog.remove(target)
    }
    fun reset() { digital.clear(); analog.clear() }
}
