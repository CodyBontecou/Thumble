package com.thumble.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp

/** Setup explains the real Android paths; it never sends controller input. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable internal fun OnboardingScreen(state: ClientState,error: String?,replay: Boolean,
    onSmartConnect: ()->Unit,onComplete: ()->Unit,onClose: ()->Unit) {
    var step by rememberSaveable { mutableIntStateOf(0) }
    val titles=listOf("Welcome","Permissions","Connect","Use Keypads")
    val scroll=key(step) { rememberScrollState() }
    val view=LocalView.current
    LaunchedEffect(step) {
        withFrameNanos { }
        view.sendAccessibilityEvent(android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
        view.announceForAccessibility("Step ${step+1} of 4, ${titles[step]}")
    }
    BackHandler(enabled=step>0 || replay) { if(step>0) step-- else onClose() }
    key(step) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().semantics { testTagsAsResourceId=true }.testTag("setup-guide")) {
            Column(Modifier.fillMaxWidth().padding(horizontal=24.dp,vertical=16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text("Thumble",style=MaterialTheme.typography.titleLarge);Text("Quick setup",style=MaterialTheme.typography.bodySmall) }
                    Column(horizontalAlignment=Alignment.End) {
                        Text("Step ${step+1} of 4",style=MaterialTheme.typography.labelMedium)
                        Text(titles[step],style=MaterialTheme.typography.titleSmall)
                    }
                }
                LinearProgressIndicator(progress={ (step+1)/4f },modifier=Modifier.fillMaxWidth().semantics {
                    contentDescription="Setup progress: Step ${step+1} of 4, ${titles[step]}"
                })
            }
            HorizontalDivider()
            Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll),contentAlignment=Alignment.TopCenter) {
                Column(Modifier.widthIn(max=720.dp).fillMaxWidth().padding(24.dp).testTag("setup-step-$step"),verticalArrangement=Arrangement.spacedBy(20.dp)) {
                    when(step) {
                        0 -> {
                            GuideHeading("Your Mac shortcuts, right under your thumbs.")
                            Text("Turn your Android phone into a programmable control surface for shortcuts, pointer actions, and virtual gamepad input on your Mac.")
                            GuideCard("Install Thumble on both devices","The Mac app handles Accessibility permission, secure pairing, and keypad editing. Your phone displays synced controls and sends each press.")
                            GuideCard("1 · Open Thumble Mac","Leave the receiver running while you use the phone keypad.")
                            GuideCard("2 · Pair securely","Scan the Mac QR code, or enter its local address and six-digit pairing code. Smart Connect remembers the Mac after your first pair.")
                            GuideCard("3 · Control the focused Mac app","Focus your editor, browser, Terminal, or game on the Mac, then press controls on your phone.")
                        }
                        1 -> {
                            GuideHeading("Allow focused permissions.")
                            Text("Your phone uses the local network to reach your Mac and the camera to scan its pairing QR code.")
                            GuideCard("Local network","Keep both devices on the same Wi-Fi. On Android versions that request local network permission, allow it when connecting. Other supported Android versions do not show this prompt.")
                            GuideCard("Camera","Camera access is requested when you tap Scan Mac QR Code. You can pair manually without camera access.")
                            GuideCard("Mac Accessibility","Enable Thumble or thumble-host in System Settings → Privacy & Security → Accessibility on your Mac so shortcuts can reach the focused app.")
                            Button(onClick=onSmartConnect,enabled=!state.connecting && !state.paired,modifier=Modifier.fillMaxWidth().testTag("setup-smart-connect")) { Text("Start Smart Connect") }
                        }
                        2 -> {
                            GuideHeading("Pair with Thumble Mac.")
                            Text("Smart Connect is available after the first pair. QR scanning and manual pairing are always available from the connection screen.")
                            GuideCard(if(state.paired) "Connected and ready" else state.status,
                                if(state.paired) "Your Mac is paired. Finish setup to open its synced keypad." else "Open Thumble Mac and find its pairing QR code and six-digit code.")
                            GuideCard("1 · Scan the Mac QR code","On your phone’s connection screen, tap Scan Mac QR Code and point the camera at Thumble Mac’s pairing card.")
                            GuideCard("2 · Or enter the address and code","Enter the WebSocket address and six-digit code shown on the Mac. You can use this option if camera access is unavailable.")
                            GuideCard("3 · Reconnect automatically","After pairing, your phone securely remembers this Mac. Smart Connect retries its saved address and nearby Wi-Fi discovery.")
                            Button(onClick=onSmartConnect,enabled=!state.connecting && !state.paired,modifier=Modifier.fillMaxWidth().testTag("setup-smart-connect")) { Text("Try Smart Connect Now") }
                        }
                        3 -> {
                            GuideHeading("Your keypad is ready when you are.")
                            Text("Create and style full keypads on the Mac. Your phone receives saved setups and supports small freeform layout edits.")
                            GuideCard("Edit on Mac","Add controls, style them, and record shortcuts in the Mac keypad editor.")
                            GuideCard("Switch setups","Tap the keypad name in the top bar to switch synced profiles or choose a default.")
                            GuideCard("Adjust your reach","Choose Edit layout from keypad options to move, resize, rotate, or delete freeform controls.")
                            GuideCard("Practice safely","Practice with a saved keypad while disconnected. Practice mode keeps presses local to your phone.")
                            GuideCard(if(state.paired) "Connected and ready" else "You can pair any time",if(state.paired) "Finish setup to open your synced keypad." else "Finish setup to open QR scanning, manual pairing, and your saved Mac connection.")
                        }
                    }
                    (error ?: state.error)?.let { Text(it,color=MaterialTheme.colorScheme.error,modifier=Modifier.testTag("setup-error").semantics { liveRegion=LiveRegionMode.Polite }) }
                    if(state.connecting) Text(state.status,modifier=Modifier.semantics { liveRegion=LiveRegionMode.Polite })
                }
            }
            HorizontalDivider()
            Column(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=8.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
                Button(onClick={ if(step==3) onComplete() else step++ },modifier=Modifier.fillMaxWidth().heightIn(min=48.dp).testTag("setup-next")) {
                    Text(if(step==3) "Open Thumble" else if(step==0) "Get Started" else "Continue")
                }
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                    if(step>0) TextButton(onClick={ step-- },modifier=Modifier.testTag("setup-back")) { Text("Back") }
                    else Spacer(Modifier.width(1.dp))
                    if(step<3) TextButton(onClick=onComplete,modifier=Modifier.testTag("setup-later")) { Text("Set Up Later") }
                    else if(replay) TextButton(onClick=onClose) { Text("Close guide") }
                }
            }
        }
    }
}
@Composable private fun GuideHeading(title: String) { Text(title,style=MaterialTheme.typography.headlineLarge,modifier=Modifier.semantics { heading() }) }
@Composable private fun GuideCard(title: String,detail: String) {
    OutlinedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text(title,style=MaterialTheme.typography.titleMedium)
            Text(detail,style=MaterialTheme.typography.bodyMedium)
        }
    }
}
