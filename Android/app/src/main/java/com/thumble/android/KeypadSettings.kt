package com.thumble.android

import android.view.ViewTreeObserver
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable internal fun KeypadSettings(intensity: Double, error: String?, onIntensity: (Double)->Unit, onDismiss: ()->Unit) {
    AlertDialog(onDismissRequest=onDismiss,containerColor=MaterialTheme.colorScheme.surface,title={ Text("Keypad settings") },
        text={
            val view=LocalView.current
            val preview=remember(view) { AndroidKeypadHaptics(view) }
            DisposableEffect(view) {
                val observer=view.viewTreeObserver
                val focus=ViewTreeObserver.OnWindowFocusChangeListener { focused -> if (!focused) preview.cancel() }
                observer.addOnWindowFocusChangeListener(focus)
                onDispose { if (observer.isAlive) observer.removeOnWindowFocusChangeListener(focus);preview.cancel() }
            }
            LaunchedEffect(intensity) { preview.cancel() }
            Column(Modifier.fillMaxWidth().semantics { testTagsAsResourceId=true }.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text("Haptic intensity",style=MaterialTheme.typography.titleSmall)
                Text("Scales each control’s feedback while preserving its relative strength. Your phone’s vibration settings still apply.",style=MaterialTheme.typography.bodyMedium)
                Column(Modifier.selectableGroup()) {
                    HapticIntensity.levels.forEach { level ->
                        Row(Modifier.fillMaxWidth().heightIn(min=48.dp).testTag("haptic-intensity-${(level*100).toInt()}")
                            .semantics { contentDescription=HapticIntensity.label(level) }.selectable(selected=intensity == level,
                            onClick={ onIntensity(level) },role=Role.RadioButton).padding(horizontal=8.dp),verticalAlignment=Alignment.CenterVertically) {
                            RadioButton(selected=intensity == level,onClick=null)
                            Text(HapticIntensity.label(level),Modifier.padding(start=12.dp))
                        }
                    }
                }
                error?.let { Text(it,color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodyMedium) }
                OutlinedButton(onClick={ preview.play(KeypadHaptic(style="medium",pattern="double",intensity=.72,sharpness=.56),intensity) },enabled=intensity>0) {
                    Text("Test Haptic")
                }
            }
        },confirmButton={ TextButton(onClick=onDismiss) { Text("Done") } })
}
