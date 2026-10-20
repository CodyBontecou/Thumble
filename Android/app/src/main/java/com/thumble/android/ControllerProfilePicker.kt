package com.thumble.android

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.util.UUID

@Composable
internal fun ControllerHeader(snapshot: ProfileSnapshot, onSelect: (UUID) -> Unit,
    connectionLabel: String, onConnection: () -> Unit, options: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
        if (maxWidth < 480.dp) {
            Column {
                ControllerProfilePicker(snapshot, onSelect, Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    options()
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onConnection) { Text(connectionLabel) }
                }
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ControllerProfilePicker(snapshot, onSelect, Modifier.weight(1f))
                options()
                TextButton(onClick = onConnection) { Text(connectionLabel) }
            }
        }
    }
}

/** The picker and adjacent-profile shortcuts share the host's profile order. */
@Composable
internal fun ControllerProfilePicker(snapshot: ProfileSnapshot, onSelect: (UUID) -> Unit, modifier: Modifier = Modifier) {
    var expanded by remember { mutableStateOf(false) }
    val profiles = snapshot.profiles
    val selectedIndex = profiles.indexOfFirst { it.id == snapshot.selectedID }
    val canStep = profiles.size > 1 && selectedIndex >= 0
    fun step(offset: Int) {
        if (canStep) onSelect(profiles[(selectedIndex + offset + profiles.size) % profiles.size].id)
    }
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) {
            OutlinedButton(onClick = { expanded = true }, enabled = profiles.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().testTag("controller-profile-picker")
                    .semantics { contentDescription = "Choose profile. ${snapshot.selected?.name.orEmpty()}" },
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp)) {
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                    Text(if (selectedIndex >= 0) "Profile ${selectedIndex + 1} of ${profiles.size}" else "Choose profile",
                        style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(snapshot.selected?.name ?: "Select a keypad", style = MaterialTheme.typography.labelLarge,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.width(8.dp))
                ProfileChevron(0)
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false },
                modifier = Modifier.widthIn(max = 360.dp).testTag("controller-profile-list"),
                containerColor = MaterialTheme.colorScheme.surface) {
                profiles.forEach { profile ->
                    DropdownMenuItem(text = {
                        Column {
                            Text(profile.name)
                            if (profile.id == snapshot.defaultID) Text("Default", style = MaterialTheme.typography.labelSmall)
                        }
                    }, leadingIcon = { RadioButton(selected = profile.id == snapshot.selectedID, onClick = null) },
                        onClick = {
                            expanded = false
                            if (profile.id != snapshot.selectedID) onSelect(profile.id)
                        })
                }
            }
        }
        IconButton(onClick = { step(-1) }, enabled = canStep,
            modifier = Modifier.testTag("controller-profile-previous").semantics { contentDescription = "Previous profile" }) {
            ProfileChevron(-1)
        }
        IconButton(onClick = { step(1) }, enabled = canStep,
            modifier = Modifier.testTag("controller-profile-next").semantics { contentDescription = "Next profile" }) {
            ProfileChevron(1)
        }
    }
}

@Composable
private fun ProfileChevron(direction: Int) {
    val color = LocalContentColor.current
    Canvas(Modifier.size(18.dp)) {
        val a: Offset
        val b: Offset
        val c: Offset
        when (direction) {
            -1 -> { a = Offset(size.width * .65f, size.height * .2f); b = Offset(size.width * .35f, size.height * .5f); c = Offset(size.width * .65f, size.height * .8f) }
            1 -> { a = Offset(size.width * .35f, size.height * .2f); b = Offset(size.width * .65f, size.height * .5f); c = Offset(size.width * .35f, size.height * .8f) }
            else -> { a = Offset(size.width * .2f, size.height * .35f); b = Offset(size.width * .5f, size.height * .65f); c = Offset(size.width * .8f, size.height * .35f) }
        }
        drawLine(color, a, b, 2.dp.toPx(), StrokeCap.Round)
        drawLine(color, b, c, 2.dp.toPx(), StrokeCap.Round)
    }
}

@Composable
internal fun ControllerOptionsIcon() {
    val color = LocalContentColor.current
    Canvas(Modifier.size(24.dp)) {
        for (fraction in listOf(.25f, .5f, .75f)) drawCircle(color, 2.dp.toPx(), Offset(size.width * .5f, size.height * fraction))
    }
}
