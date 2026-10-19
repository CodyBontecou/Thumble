package com.thumble.android

import android.Manifest
import android.content.pm.PackageManager
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.enableEdgeToEdge
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.ViewModelProvider
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.viewinterop.AndroidView
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private lateinit var session: ControllerSession
    private val state: ClientState get() = session.state
    private var localError by mutableStateOf<String?>(null)
    private lateinit var client: ControllerClient
    private var surface: ControllerSurface? = null
    private var pendingTarget: PairingTarget? = null
    private var pendingReconnect = false
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val skinDocument = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if(uri!=null) {
            val resolver=applicationContext.contentResolver
            session.prepareSkinImport { resolver.openInputStream(uri) ?: error("Could not open the selected skin package.") }
        }
    }
    private val scan = registerForActivityResult(ScanContract()) { result ->
        result.contents?.let { raw ->
            try { connect(PairingTarget.parse(raw)) }
            catch (error: Exception) { localError = error.message ?: "Could not read this QR code." }
        }
    }
    private val camera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) launchScanner() else localError = "Camera permission is needed to scan. You can also enter the Mac address below."
    }
    private val localNetwork = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val target = pendingTarget; pendingTarget = null
        val reconnect = pendingReconnect; pendingReconnect = false
        if (granted) {
            observeNetwork()
            if (target != null) client.connect(target) else if (reconnect) client.reconnect()
        } else localError = "Allow local network access to connect to your Mac."
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        session = ViewModelProvider(this, ControllerSession.Factory(applicationContext))[ControllerSession::class.java]
        client = session.client
        setContent {
            val current = state
            var settingsOpen by rememberSaveable { mutableStateOf(false) }
            LaunchedEffect(current.paired, current.viewingSaved, current.snapshot.selectedID, current.snapshot.selected?.orientationPreference) {
                applyProfileOrientation(current)
                if (current.paired) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            val dark = isSystemInDarkTheme()
            MaterialTheme(colorScheme = if (dark) darkColorScheme(primary = Color(0xFFAAC7FF), secondary = Color(0xFFAAC7FF), surface = Color(0xFF10141C), background = Color(0xFF10141C)) else lightColorScheme(primary = Color(0xFF2563EB), secondary = Color(0xFF2563EB), surface = Color(0xFFF8FAFC), background = Color(0xFFF8FAFC))) {
                Surface(Modifier.fillMaxSize()) {
                    val openSettings = { surface?.cancelTouches(); settingsOpen=true }
                    if (state.paired || state.viewingSaved) ControllerScreen(dark,openSettings) else ConnectionScreen(openSettings)
                    session.reviewedSkin?.let { reviewed ->
                        AlertDialog(onDismissRequest={ session.cancelSkinImport() },containerColor=MaterialTheme.colorScheme.surface,title={ Text("Import skin") },
                            text={ Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                Text(reviewed.name,style=MaterialTheme.typography.titleMedium)
                                Text("Version ${reviewed.reference.version}")
                                Text(reviewed.authorName)
                                Text("Imports the skin without changing your keypad or bindings.")
                                if(session.installedSkins.any { it.reference==reviewed.reference }) Text("This replaces the installed copy of this version.")
                                session.skinError?.let { Text(it,color=MaterialTheme.colorScheme.error) }
                            } },
                            confirmButton={ TextButton(enabled=!session.skinBusy,onClick={ session.installReviewedSkin() }) { Text(if(session.skinBusy) "Importing…" else "Import") } },
                            dismissButton={ TextButton(enabled=!session.skinBusy,onClick={ session.cancelSkinImport() }) { Text("Cancel") } })
                    }
                    if (settingsOpen) KeypadSettings(state.hapticIntensity,state.preferencesError,
                        onIntensity={ client.setHapticIntensity(it) },onDismiss={ settingsOpen=false })
                }
            }
        }
    }
    internal val connectionState: ClientState get() = state
    internal fun showSavedKeypad() = client.viewSavedKeypad()
    internal fun selectProfile(id: java.util.UUID) {
        surface?.cancelTouches()
        client.selectProfile(id)
    }

    internal fun connect(target: PairingTarget) {
        localError = null
        // String constant keeps this slice buildable with SDK 35; enforced when targeting 37+.
        if (Build.VERSION.SDK_INT >= 37 && checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") != PackageManager.PERMISSION_GRANTED) {
            pendingTarget = target
            localNetwork.launch("android.permission.ACCESS_LOCAL_NETWORK")
        } else client.connect(target)
    }
    private fun applyProfileOrientation(value: ClientState) {
        val preference = if (value.paired || value.viewingSaved) value.snapshot.selected?.orientationPreference else "automatic"
        val requested = when (preference) {
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        if (requestedOrientation != requested) {
            surface?.cancelTouches()
            client.surfaceChanged()
            requestedOrientation = requested
        }
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        surface?.cancelTouches()
        if (::client.isInitialized) client.surfaceChanged()
        super.onConfigurationChanged(newConfig)
    }
    private fun reconnectSavedMac() {
        if (Build.VERSION.SDK_INT >= 37 && checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") != PackageManager.PERMISSION_GRANTED) {
            pendingReconnect = true
            localNetwork.launch("android.permission.ACCESS_LOCAL_NETWORK")
        } else client.reconnect()
    }
    private fun observeNetwork() {
        if (networkCallback != null) return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { client.networkAvailable() }
        }
        runCatching { getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(callback) }
            .onSuccess { networkCallback = callback }
    }
    private fun launchScanner() = scan.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
        .setPrompt("Scan the QR code in Thumble Mac").setBeepEnabled(false).setOrientationLocked(false))
    @Composable private fun ConnectionScreen(openSettings: ()->Unit) {
        var address by remember { mutableStateOf("ws://") }
        var code by remember { mutableStateOf("") }
        Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                Text("Thumble", style = MaterialTheme.typography.headlineLarge,modifier=Modifier.weight(1f))
                TextButton(onClick=openSettings) { Text("Settings") }
            }
            Text("Your Mac, at your fingertips", style = MaterialTheme.typography.titleMedium)
            Text("Open Thumble on your Mac, then scan its pairing QR code. Keep both devices on the same Wi-Fi.")
            Button(onClick = {
                if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) launchScanner()
                else camera.launch(Manifest.permission.CAMERA)
            }, enabled = !state.connecting, modifier = Modifier.fillMaxWidth()) { Text("Scan Mac QR Code") }
            if (state.connecting) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(state.status)
                TextButton(onClick = { client.disconnect() }) { Text("Cancel") }
            }
            if (localError != null || state.error != null) Text(localError ?: state.error.orEmpty(), color = MaterialTheme.colorScheme.error)
            if (state.snapshot.selected != null) {
                OutlinedButton(onClick = { showSavedKeypad() }, modifier = Modifier.fillMaxWidth()) { Text("Practice with saved keypad") }
            }
            if (state.canReconnect && !state.needsCode) {
                OutlinedButton(onClick = { reconnectSavedMac() }, enabled = !state.connecting, modifier = Modifier.fillMaxWidth()) {
                    Text("Reconnect to saved Mac")
                }
                TextButton(onClick = { pendingReconnect = false; pendingTarget = null; client.forgetMac() }) { Text("Forget saved Mac") }
            }
            HorizontalDivider()
            Text(if (state.needsCode) "Pairing code" else "Connect manually", style = MaterialTheme.typography.titleMedium)
            if (!state.needsCode) OutlinedTextField(address, { address = it }, label = { Text("Mac address") },
                placeholder = { Text("ws://192.168.1.10:8765") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(code, { code = it.filter(Char::isDigit).take(6) }, label = { Text("Six-digit code") },
                singleLine = true, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            OutlinedButton(onClick = {
                if (state.needsCode) client.submitCode(code)
                else try { connect(PairingTarget.manual(address, code)) }
                catch (error: Exception) { localError = error.message }
            }, enabled = code.length == 6 && (!state.connecting || state.needsCode), modifier = Modifier.fillMaxWidth()) { Text("Pair with Mac") }
        }
    }
    @Composable private fun ControllerScreen(dark: Boolean,openSettings: ()->Unit) {
        val configuration = LocalConfiguration.current
        val landscape = configuration.screenWidthDp >= configuration.screenHeightDp
        val profile = state.snapshot.selected
        val rendered by key(profile, landscape, dark, session.skinRevision) {
            produceState<SkinRenderProjection?>(null) {
                value = withContext(Dispatchers.IO) { session.skinRenderer.resolve(profile, landscape, dark) }
            }
        }
        // A new request starts empty, including installation/removal invalidation.
        // Never accept touches against an appearance that is about to be replaced.
        val projection = rendered?.takeIf { it.matches(profile, landscape, dark) }
        var waitsForInitialSkinSync by remember(profile) { mutableStateOf(session.skinSyncInFlight>0) }
        LaunchedEffect(profile,session.skinSyncInFlight) { if(session.skinSyncInFlight==0) waitsForInitialSkinSync=false }
        val loadingSkin = profile?.source?.optJSONObject("skinReference") != null &&
            (projection == null || (waitsForInitialSkinSync && session.skinSyncInFlight>0))
        var menu by remember { mutableStateOf(false) }
        LaunchedEffect(menu) { if(menu) session.refreshSkins() }
        val unsupported = profile?.unsupportedKinds(landscape).orEmpty()
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Box {
                    TextButton(onClick = { surface?.cancelTouches(); menu = true }) { Text(profile?.name ?: "Keypad") }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false },containerColor=MaterialTheme.colorScheme.surface) {
                        state.snapshot.profiles.forEach { item -> DropdownMenuItem(text = { Text(item.name + if (item.id == state.snapshot.defaultID) " · Default" else "") },
                            onClick = { selectProfile(item.id); menu = false }) }
                        HorizontalDivider()
                        DropdownMenuItem(text={ Text(if (profile?.id == state.snapshot.defaultID) "Default keypad" else "Make default keypad") },
                            enabled=(state.paired || state.viewingSaved) && profile != null && profile.id != state.snapshot.defaultID,
                            onClick={ profile?.let { client.setDefaultProfile(it.id) };menu=false })
                        val canRotate=state.paired && ProfileActions.ORIENTATION_CAPABILITY in state.capabilities
                        for ((preference,label) in listOf("automatic" to "Automatic rotation","portrait" to "Portrait only","landscape" to "Landscape only")) {
                            DropdownMenuItem(text={ Text(label) },leadingIcon={ RadioButton(selected=profile?.orientationPreference == preference,onClick=null,enabled=canRotate) },
                                enabled=canRotate,onClick={ surface?.cancelTouches();client.setOrientationPreference(preference);menu=false })
                        }
                        profile?.launchTargetName?.let { target ->
                            DropdownMenuItem(text={ Text("Launch $target on Mac") },enabled=state.paired,
                                onClick={ surface?.cancelTouches();client.launchProfileTarget();menu=false })
                        }
                        HorizontalDivider()
                        DropdownMenuItem(text={ Text("Import skin…") },enabled=!session.skinBusy,
                            onClick={ menu=false;skinDocument.launch(arrayOf("*/*")) })
                        session.installedSkins.forEach { installed ->
                            DropdownMenuItem(text={ Text("Apply ${installed.name} · ${installed.reference.version}") },enabled=!session.skinBusy,
                                onClick={ menu=false;session.applySkin(installed.reference,profile?.skinColorScheme(dark) ?: if(dark) "dark" else "light") })
                        }
                        DropdownMenuItem(text={ Text("Detach skin") },enabled=!session.skinBusy && profile?.source?.optJSONObject("skinReference")!=null,
                            onClick={ menu=false;session.detachSkin(profile?.skinColorScheme(dark) ?: if(dark) "dark" else "light") })
                        HorizontalDivider()
                        DropdownMenuItem(text={ Text("Settings") },onClick={ menu=false;openSettings() })
                    }
                }
                TextButton(onClick = {
                    surface?.cancelTouches()
                    if (state.paired) client.disconnect() else client.showConnection()
                }) { Text(if (state.paired) "Disconnect" else "Connection") }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(if (state.practiceMode) "Practice mode · on" else "Practice mode · off", Modifier.padding(top = 14.dp))
                Switch(checked = state.practiceMode, enabled = state.paired,
                    modifier = Modifier.semantics { contentDescription = "Practice mode" }, onCheckedChange = { surface?.cancelTouches(); client.setPracticeMode(it) })
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Column(Modifier.weight(1f)) {
                    Text(if (state.udpEnabled && state.udpAvailable) "UDP + WebSocket mirror" else "WebSocket fallback", style = MaterialTheme.typography.labelMedium)
                    Text("Sent: UDP ${state.udpFrames} · WS ${state.webSocketFrames}", style = MaterialTheme.typography.labelSmall)
                }
                Row {
                    Text("UDP", Modifier.padding(top = 14.dp), style = MaterialTheme.typography.labelMedium)
                    Switch(checked = state.udpEnabled, modifier = Modifier.semantics { contentDescription = "UDP transport" }, onCheckedChange = { client.setUDPEnabled(it) })
                }
            }
            state.error?.let { Text(it, Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error) }
            if (loadingSkin) Text("Loading keypad appearance…", Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelSmall)
            session.skinError?.let { Text(it, Modifier.padding(horizontal=16.dp),color=MaterialTheme.colorScheme.error) }
            if(state.pendingSkinChanges>0) Text("${state.pendingSkinChanges} ${if(state.pendingSkinChanges==1) "skin change" else "skin changes"} waiting for Mac sync",Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.labelSmall)
            if(session.skinBusy) Text("Preparing skin…",Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.labelSmall)
            projection?.warning?.let { Text(it, Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelSmall) }
            if (unsupported.isNotEmpty()) Text("Not supported in this build: ${unsupported.joinToString()}",
                Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
            AndroidView(factory = { context -> ControllerSurface(context).also { surface = it } },
                update = { view ->
                    val surfaceRevision = state.surfaceRevision
                    view.onEdge = { id, down, press -> client.edge(id, down, press, surfaceRevision) }
                    view.onPartEdge = { id, part, down, press -> client.elementEdge(id, part, down, press, surfaceRevision) }
                    view.onStick = { target, x, y, final -> client.stick(target, x, y, final, surfaceRevision) }
                    view.onTrigger = { target, value, final -> client.trigger(target, value, final, surfaceRevision) }
                    view.onPointer = { kind, x, y, button, down -> client.pointer(kind, x, y, button, down, surfaceRevision) }
                    view.onReleaseAll = { client.releaseAll() }
                    view.hapticIntensity=state.hapticIntensity
                    view.show(if (loadingSkin || session.skinBusy) null else projection?.profile ?: profile, surfaceRevision, landscape, dark)
                }, modifier = Modifier.fillMaxWidth().weight(1f))
        }
    }
    override fun onPause() {
        surface?.cancelTouches()
        if (::client.isInitialized) client.surfaceChanged()
        super.onPause()
    }
    override fun onStart() {
        super.onStart()
        if (::client.isInitialized && (Build.VERSION.SDK_INT < 37 ||
            checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") == PackageManager.PERMISSION_GRANTED)) {
            observeNetwork()
            client.resume()
        }
    }
    override fun onStop() {
        networkCallback?.let { callback -> runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(callback) } }
        networkCallback = null
        if (::client.isInitialized && !isChangingConfigurations) client.suspend()
        super.onStop()
    }
}
