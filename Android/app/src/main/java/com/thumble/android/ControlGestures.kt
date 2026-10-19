package com.thumble.android

import java.util.UUID
import kotlin.math.abs
import kotlin.math.hypot

internal data class Contact(val pointer: Int, val point: Vector)
internal data class LocalContact(val x: Double, val y: Double, val width: Double, val height: Double)
internal enum class TouchPhase { DOWN, MOVE, UP, CANCEL }

/** UI-thread gesture ownership, in density-independent units. No networking or Android APIs. */
internal class ControlGestures(
    private val hit: (Vector, UUID?) -> Control?,
    private val local: (Control, Vector) -> LocalContact,
    button: (UUID, Boolean, Long) -> Unit,
    private val element: (UUID, InputPart, Boolean, Long) -> Unit,
    private val stick: (String, Double, Double, Boolean) -> Unit,
    private val trigger: (String, Double, Boolean) -> Unit,
    private val pointer: (String, Double, Double, String?, Boolean?) -> Unit
) {
    private val buttons = TouchRouter(button)
    private val owners = linkedMapOf<Int, Control>()
    private val positions = mutableMapOf<Int, Vector>()
    private val retiredPointers = mutableSetOf<Int>()
    private val joystickTokens = mutableMapOf<UUID, MutableMap<InputPart, Long>>()
    private val triggerTokens = mutableMapOf<UUID, Long>()
    private val triggerControls = mutableMapOf<UUID, Control>()
    val joystickVectors = mutableMapOf<UUID, Vector>()
    val triggerValues = mutableMapOf<UUID, Double>()
    private var nextPress = 0L
    private data class Pad(val control: Control, val starts: MutableMap<Int, Vector>, val began: Long,
        var previous: Vector? = null, var maximum: Int = 0, var moved: Boolean = false)
    private val pads = mutableMapOf<UUID, Pad>()

    fun handle(phase: TouchPhase, changed: Int, contacts: List<Contact>, time: Long) {
        if (phase == TouchPhase.CANCEL) { cancel(); return }
        val previous = positions.toMap()
        contacts.forEach { positions[it.pointer] = it.point }
        for (contact in contacts) {
            if (contact.pointer in retiredPointers) {
                if (phase == TouchPhase.UP && contact.pointer == changed) {
                    retiredPointers.remove(contact.pointer); positions.remove(contact.pointer)
                }
                continue
            }
            if (phase != TouchPhase.MOVE && contact.pointer != changed) continue
            if (phase == TouchPhase.MOVE && previous[contact.pointer] == contact.point && owners[contact.pointer] == null && buttons.target(contact.pointer) == null) continue
            if (phase == TouchPhase.UP && contact.pointer == changed) release(contact.pointer, time, true)
            else update(contact.pointer, contact.point, time)
        }
        // Centroids are computed once, after all pointers' coordinates are updated.
        for (pad in pads.values) {
            updateSlop(pad)
            val center = centroid(pad.control.id) ?: continue
            if (phase == TouchPhase.MOVE) pad.previous?.let { old ->
                val settings = TrackpadSettings.parse(pad.control.source.optJSONObject("trackpadSettings"))
                val count = owners.values.count { it.id == pad.control.id }
                val delta = Vector(center.x - old.x, center.y - old.y)
                if (count >= 2) {
                    if (settings.scroll) {
                        val scale = settings.scrollSensitivity * if (settings.natural) 1 else -1
                        pointer("scroll", delta.x * scale, delta.y * scale, null, null)
                    }
                } else pointer("move", delta.x * settings.sensitivity, delta.y * settings.sensitivity, null, null)
            }
            pad.previous = center
        }
    }

    private fun update(id: Int, point: Vector, time: Long) {
        val previous = owners[id]
        if (previous != null) {
            when (previous.kind) {
                "joystick" -> updateJoystick(previous, point)
                "trigger" -> updateTriggerPoint(previous, point)
            }
            return
        }
        val control = hit(point, buttons.target(id))
        if (control?.kind == "button") { buttons.move(id, control.id); return }
        buttons.move(id, null)
        if (control == null) return
        if (control.kind in setOf("joystick", "trigger") && owners.values.any { it.id == control.id }) return
        owners[id] = control
        when (control.kind) {
            "joystick" -> updateJoystick(control, point)
            "trigger" -> updateTriggerPoint(control, point)
            "trackpad" -> {
                val pad = pads.getOrPut(control.id) { Pad(control, mutableMapOf(), time) }
                pad.starts[id] = point
                pad.maximum = maxOf(pad.maximum, owners.values.count { it.id == control.id })
                pad.previous = centroid(control.id)
            }
        }
    }

    private fun updateJoystick(control: Control, point: Vector) {
        val location = local(control, point)
        val vector = Vector((location.x - location.width / 2) / (location.width / 2).coerceAtLeast(1.0),
            (location.y - location.height / 2) / (location.height / 2).coerceAtLeast(1.0)).radialClamp()
        if (joystickVectors[control.id] == vector) return
        joystickVectors[control.id] = vector
        val settings = JoystickSettings.parse(control.source.optJSONObject("joystickOutputSettings"))
        val directions = if (settings.digital) directions(vector) else emptySet()
        val tokens = joystickTokens.getOrPut(control.id) { linkedMapOf() }
        for (ended in tokens.keys.toList().filter { it !in directions }) element(control.id, ended, false, tokens.remove(ended)!!)
        for (began in directions.filter { it !in tokens }) {
            val token = ++nextPress; tokens[began] = token; element(control.id, began, true, token)
        }
        settings.target?.let { target ->
            val transformed = settings.transform(vector)
            stick(target, transformed.x, transformed.y, vector.neutral)
        }
    }

    private fun updateTriggerPoint(control: Control, point: Vector) {
        val settings = TriggerSettings.parse(control.source.optJSONObject("triggerSettings"))
        val location = local(control, point)
        val raw = if (settings.horizontal) location.x / location.width.coerceAtLeast(1.0)
            else 1 - location.y / location.height.coerceAtLeast(1.0)
        updateTrigger(control, settings.transform(raw), true)
    }

    fun updateTrigger(control: Control, value: Double, active: Boolean) {
        val settings = TriggerSettings.parse(control.source.optJSONObject("triggerSettings"))
        val amount = if (active && value.isFinite()) value.coerceIn(0.0, 1.0) else 0.0
        if (triggerValues[control.id] == amount && active) return
        triggerControls[control.id] = control
        triggerValues[control.id] = amount
        trigger(settings.target, amount, !active || amount < .001)
        val pressed = settings.digital && active && amount >= settings.threshold
        val token = triggerTokens[control.id]
        if (pressed && token == null) {
            val next = ++nextPress; triggerTokens[control.id] = next
            element(control.id, InputPart.TRIGGER_DIGITAL, true, next)
        } else if (!pressed && token != null) {
            triggerTokens.remove(control.id)
            element(control.id, InputPart.TRIGGER_DIGITAL, false, token)
        }
    }

    fun accessibilityDirection(control: Control, part: InputPart) {
        retireCapture(control.id)
        val settings = JoystickSettings.parse(control.source.optJSONObject("joystickOutputSettings"))
        val token = ++nextPress
        if (settings.digital) { element(control.id, part, true, token); element(control.id, part, false, token) }
        val raw = when (part) {
            InputPart.JOYSTICK_UP -> Vector(0.0, -1.0); InputPart.JOYSTICK_DOWN -> Vector(0.0, 1.0)
            InputPart.JOYSTICK_LEFT -> Vector(-1.0, 0.0); InputPart.JOYSTICK_RIGHT -> Vector(1.0, 0.0)
            else -> Vector()
        }
        settings.target?.let { target ->
            val vector = settings.transform(raw)
            stick(target, vector.x, vector.y, false); stick(target, 0.0, 0.0, true)
        }
    }
    fun accessibilityTrigger(control: Control, value: Double) {
        retireCapture(control.id)
        updateTrigger(control, value, value > 0)
    }
    private fun retireCapture(control: UUID) {
        owners.filterValues { it.id == control }.keys.toList().forEach { pointer ->
            retiredPointers.add(pointer)
            release(pointer, 0, false)
        }
    }
    fun click(button: String) {
        pointer("button", 0.0, 0.0, button, true); pointer("button", 0.0, 0.0, button, false)
    }
    fun accessibilityClick(control: Control, button: String) {
        retireCapture(control.id)
        click(button)
    }

    private fun release(id: Int, time: Long, allowsTap: Boolean) {
        buttons.move(id, null)
        val control = owners.remove(id)
        if (control != null) when (control.kind) {
            "joystick" -> {
                joystickTokens.remove(control.id)?.forEach { (part, token) -> element(control.id, part, false, token) }
                joystickVectors.remove(control.id)
                JoystickSettings.parse(control.source.optJSONObject("joystickOutputSettings")).target?.let { stick(it, 0.0, 0.0, true) }
            }
            "trigger" -> updateTrigger(control, 0.0, false)
            "trackpad" -> pads[control.id]?.let { pad ->
                // An ending pointer must still contribute to tap-slop detection.
                updateSlop(pad)
                pad.starts.remove(id)
                if (owners.values.none { it.id == control.id }) {
                    val settings = TrackpadSettings.parse(control.source.optJSONObject("trackpadSettings"))
                    if (allowsTap && settings.tap && !pad.moved && time - pad.began <= 320) click(if (pad.maximum >= 2) "right" else "left")
                    pads.remove(control.id)
                } else pad.previous = centroid(control.id)
            }
        }
        positions.remove(id)
    }
    private fun updateSlop(pad: Pad) {
        if (pad.moved) return
        pad.moved = pad.starts.any { (id, start) -> positions[id]?.let { hypot(it.x - start.x, it.y - start.y) > 14 } == true }
    }
    private fun centroid(control: UUID): Vector? {
        val element = owners.values.firstOrNull { it.id == control } ?: return null
        val points = owners.filterValues { it.id == control }.keys.mapNotNull { positions[it] }
            .map { local(element, it).let { p -> Vector(p.x, p.y) } }
        if (points.isEmpty()) return null
        return Vector(points.sumOf { it.x } / points.size, points.sumOf { it.y } / points.size)
    }
    fun cancel() {
        owners.keys.toList().forEach { release(it, 0, false) }
        triggerControls.values.toList().forEach { if ((triggerValues[it.id] ?: 0.0) > 0) updateTrigger(it, 0.0, false) }
        buttons.cancel(); positions.clear(); retiredPointers.clear(); pads.clear(); joystickVectors.clear()
        triggerValues.clear(); triggerControls.clear(); triggerTokens.clear(); joystickTokens.clear()
    }
    fun pressedIDs(): Set<UUID> = buttons.pressedIDs() + owners.values.map { it.id } + triggerValues.filterValues { it > .001 }.keys
    private fun directions(vector: Vector): Set<InputPart> = buildSet {
        if (vector.y <= -.34) add(InputPart.JOYSTICK_UP)
        if (vector.y >= .34) add(InputPart.JOYSTICK_DOWN)
        if (vector.x <= -.34) add(InputPart.JOYSTICK_LEFT)
        if (vector.x >= .34) add(InputPart.JOYSTICK_RIGHT)
    }
}
