package com.thumble.android

import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ControllerActionSetTest {
    private val id = UUID.fromString("10f00000-0000-0000-0000-000000000001")
    private val other = UUID.fromString("10f00000-0000-0000-0000-000000000002")
    private val left = setOf("leftTriggerButton"); private val right = setOf("rightTriggerButton")
    @Test fun everyPressKeepsItsDownBindingAndMatchingIdentityUntilUp() {
        val state = ControllerActionSetInputs()
        state.record(id, InputPart.PRIMARY, true, 1, left)
        state.record(id, InputPart.PRIMARY, true, 1, right) // Repeat after rebind must not change a hold.
        assertEquals(ControllerActionSet.LEFT, state.actionSet)
        state.record(id, InputPart.PRIMARY, true, 2, right)
        assertEquals(ControllerActionSet.BOTH, state.actionSet)
        state.record(id, InputPart.JOYSTICK_UP, false, 1, emptySet())
        assertEquals(ControllerActionSet.BOTH, state.actionSet)
        state.record(id, InputPart.PRIMARY, false, 1, emptySet())
        assertEquals(ControllerActionSet.RIGHT, state.actionSet)
        state.record(id, InputPart.PRIMARY, false, 2, left)
        assertEquals(ControllerActionSet.BASE, state.actionSet)
        state.record(other, InputPart.PRIMARY, true, 1, emptySet())
        state.record(other, InputPart.PRIMARY, true, 1, left) // Empty down is still an owned press.
        assertEquals(ControllerActionSet.BASE, state.actionSet)
    }
    @Test fun partsAndFingersCombineAndResetClearsAllOwners() {
        val state = ControllerActionSetInputs()
        state.record(id, InputPart.JOYSTICK_UP, true, 4, left)
        state.record(id, InputPart.TRIGGER_DIGITAL, true, 4, right)
        state.record(other, InputPart.PRIMARY, true, 5, left)
        state.record(id, InputPart.JOYSTICK_UP, false, 4, emptySet())
        assertEquals(ControllerActionSet.BOTH, state.actionSet)
        state.record(other, InputPart.PRIMARY, false, 5, emptySet())
        assertEquals(ControllerActionSet.RIGHT, state.actionSet)
        state.record("left", .9); assertEquals(ControllerActionSet.BOTH, state.actionSet)
        state.reset(); assertEquals(ControllerActionSet.BASE, state.actionSet)
        state.record(id, InputPart.TRIGGER_DIGITAL, false, 4, right)
        assertEquals(ControllerActionSet.BASE, state.actionSet)
    }
    @Test fun analogThresholdIsStrictFiniteAndIndependentOfDigitalHolds() {
        val state = ControllerActionSetInputs()
        for (value in listOf(.0, -.1, .5, Double.NaN, Double.POSITIVE_INFINITY)) {
            state.record("left", value); assertEquals(ControllerActionSet.BASE, state.actionSet)
        }
        state.record("left", .50001); assertEquals(ControllerActionSet.LEFT, state.actionSet)
        state.record("right", 1.0); assertEquals(ControllerActionSet.BOTH, state.actionSet)
        state.record(id, InputPart.PRIMARY, true, 0, right)
        state.record("right", Double.NaN); assertEquals(ControllerActionSet.BOTH, state.actionSet)
        state.record("left", .5); assertEquals(ControllerActionSet.RIGHT, state.actionSet)
        state.record("unknown", 1.0); assertEquals(ControllerActionSet.RIGHT, state.actionSet)
        state.record(id, InputPart.PRIMARY, false, 0, emptySet()); assertEquals(ControllerActionSet.BASE, state.actionSet)
    }
    private fun binding(vararg buttons: String) = JSONObject().put("gamepadButtons", JSONArray(buttons.toList()))
    @Test fun displayBindingsUseOnlyDeclaredOutputsAndSuppressKeyboardProfiles() {
        val element = JSONObject().put("id", id.toString()).put("kind", "button").put("label", "LT")
            .put("layout", JSONObject()).put("defaultOutput", binding("leftTriggerButton"))
            .put("presentation", JSONObject().put("legend", "RT"))
        val raw = JSONObject().put("id", other.toString()).put("customization", JSONObject().put("elements", JSONArray().put(element)))
        val profile = ControllerProfile.parse(raw)
        assertTrue(ActionSetBindings.from(profile, true).buttons(id, InputPart.PRIMARY).isEmpty())
        raw.put("outputMode", "custom")
        assertTrue(ActionSetBindings.from(profile, true).buttons(id, InputPart.PRIMARY).isEmpty())
        element.put("output", binding("leftTriggerButton", "rightTriggerButton", "south"))
        assertEquals(left + right, ActionSetBindings.from(profile, true).buttons(id, InputPart.PRIMARY))
        raw.put("outputMode", "keyboard")
        assertTrue(ActionSetBindings.from(profile, true).buttons(id, InputPart.PRIMARY).isEmpty())
        raw.put("outputMode", "controller"); element.put("output", binding())
        assertTrue(ActionSetBindings.from(profile, true).buttons(id, InputPart.PRIMARY).isEmpty())
    }
    @Test fun partBindingsRespectExplicitClearsAndLegacyJoystickDirections() {
        val element = JSONObject().put("id", id.toString()).put("kind", "joystick").put("layout", JSONObject())
            .put("partOutputs", JSONArray().put("joystick_up").put(binding()).put("trigger_digital").put(binding("rightTriggerButton")))
            .put("joystickMapping", JSONObject().put("up", binding("leftTriggerButton")).put("down", binding("leftTriggerButton")))
        val profile = ControllerProfile.parse(JSONObject().put("id", other.toString()).put("outputMode", "custom")
            .put("customization", JSONObject().put("elements", JSONArray().put(element))))
        val bindings = ActionSetBindings.from(profile, true)
        assertTrue(bindings.buttons(id, InputPart.JOYSTICK_UP).isEmpty())
        assertEquals(left, bindings.buttons(id, InputPart.JOYSTICK_DOWN))
        assertEquals(right, bindings.buttons(id, InputPart.TRIGGER_DIGITAL))
        // Binding snapshots are independent of later source edits.
        element.put("partOutputs", JSONArray()); assertEquals(right, bindings.buttons(id, InputPart.TRIGGER_DIGITAL))
    }
    @Test fun allPreparedSchemeFramesMatchSharedNativeBankAndAreReusedAcrossRequests() {
        val fixture = javaClass.classLoader!!.getResourceAsStream("profile-resources/v1/fixture.json")!!.use { JSONObject(it.bufferedReader().readText()) }
        val source = ControllerProfile.parse(fixture.getJSONObject("pooledProfile"))
        val repository = SkinRenderRepository { error("No package") }
        for (scheme in listOf("light", "dark")) {
            val first = repository.resolve(source, true, scheme == "dark")
            val frames = first.appearanceFrames!!
            for (action in ControllerActionSet.entries) {
                val frame = frames[action]
                assertEquals("$scheme/${action.key}", frame.faces.single().normal.getJSONObject("icon").getString("value"))
                assertEquals("$scheme/${action.key}", frame.faces.single().engaged.getJSONObject("icon").getString("value"))
                val next = repository.resolve(source, true, scheme == "dark", action.key)
                assertSame(frames, next.appearanceFrames)
                assertSame(frame.layout, next.profile!!.layout(true))
            }
        }
    }
}
