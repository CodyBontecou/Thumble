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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.viewinterop.AndroidView
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

class MainActivity : ComponentActivity() {
    private lateinit var session: ControllerSession
    private val state: ClientState get() = session.state
    private var localError by mutableStateOf<String?>(null)
    private var skinsOpen by mutableStateOf(false)
    private var sharedBuildsOpen by mutableStateOf(false)
    private var settingsOpen by mutableStateOf(false)
    private var guideOpen by mutableStateOf(false)
    private var completingGuide by mutableStateOf(false)
    private var launchSkinIntentHandled=false
    private fun importSkinURI(uri: android.net.Uri) {
        openSkinLibrary()
        try { SkinImportIntents.validated(uri) }
        catch(error: SkinImportException) { session.reportSkinTransferError(error.message.orEmpty());return }
        val resolver=applicationContext.contentResolver
        session.receiveSkinImport(uri.toString()) { resolver.openInputStream(uri) ?: throw SkinImportException("Could not open this skin file.") }
    }
    private fun receiveSkinIntent(value: android.content.Intent) {
        launchSkinIntentHandled=true
        if(value.action !in setOf(android.content.Intent.ACTION_VIEW,android.content.Intent.ACTION_SEND,android.content.Intent.ACTION_SEND_MULTIPLE)) return
        val shared=if(value.action==android.content.Intent.ACTION_VIEW) value.dataString?.let { session.sharedBuilds.route(it) }==true else false
        if(shared) openSharedBuilds()
        else try { SkinImportIntents.uri(value)?.let(::importSkinURI) }
        catch(error: SkinImportException) { openSkinLibrary();session.reportSkinTransferError(error.message ?: "Could not open this skin file.") }
        // Do not retain an already delivered attachment in getIntent across recreation.
        setIntent(android.content.Intent(android.content.Intent.ACTION_MAIN).setComponent(componentName))
    }
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        receiveSkinIntent(intent)
    }
    private val saveBuildDocument = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        if(uri==null) session.sharedBuilds.documentExport=null
        else session.sharedBuilds.saveDocument { contentResolver.openOutputStream(uri,"w") ?: error("Could not open destination") }
    }
    private val saveSkinDocument = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        if(uri==null) session.documentExport=null
        else if(session.documentExport==null) session.reportSkinTransferError("Choose Save file again to export this package.")
        else session.saveSkinDocument { contentResolver.openOutputStream(uri,"w") ?: error("Could not open the destination file.") }
    }
    private fun openSkinLibrary() { surface?.cancelTouches();client.surfaceChanged();settingsOpen=false;sharedBuildsOpen=false;skinsOpen=true }
    private fun openSharedBuilds() { surface?.cancelTouches();client.surfaceChanged();session.cancelSkinImport();settingsOpen=false;skinsOpen=false;sharedBuildsOpen=true }
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("skinsOpen",skinsOpen)
        outState.putBoolean("sharedBuildsOpen",sharedBuildsOpen)
        outState.putBoolean("settingsOpen",settingsOpen)
        outState.putBoolean("guideOpen",guideOpen)
        outState.putBoolean("completingGuide",completingGuide)
        outState.putBoolean("launchSkinIntentHandled",launchSkinIntentHandled)
        outState.putString("recoverableSkinImportURI",session.recoverableSkinImportURI)
        super.onSaveInstanceState(outState)
    }
    private lateinit var client: ControllerClient
    private var surface: ControllerSurface? = null
    private var pendingTarget: PairingTarget? = null
    private var pendingReconnect = false
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val skinDocument = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if(uri!=null) importSkinURI(uri)
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
        skinsOpen=savedInstanceState?.getBoolean("skinsOpen") ?: false
        sharedBuildsOpen=savedInstanceState?.getBoolean("sharedBuildsOpen") ?: false
        settingsOpen=savedInstanceState?.getBoolean("settingsOpen") ?: false
        guideOpen=savedInstanceState?.getBoolean("guideOpen") ?: false
        completingGuide=savedInstanceState?.getBoolean("completingGuide") ?: false
        launchSkinIntentHandled=savedInstanceState?.getBoolean("launchSkinIntentHandled") ?: false
        enableEdgeToEdge()
        session = ViewModelProvider(this, ControllerSession.Factory(applicationContext))[ControllerSession::class.java]
        client = session.client
        setContent {
            val current = state
            LaunchedEffect(current.paired, current.viewingSaved, current.snapshot.selectedID, current.snapshot.selected?.orientationPreference) {
                applyProfileOrientation(current)
                if (current.paired) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            val dark = isSystemInDarkTheme()
            MaterialTheme(colorScheme = if (dark) darkColorScheme(primary = Color(0xFFAAC7FF),onPrimary=Color(0xFF10141C), secondary = Color(0xFFAAC7FF),onSecondary=Color(0xFF10141C), surface = Color(0xFF10141C), background = Color(0xFF10141C)) else lightColorScheme(primary = Color(0xFF2563EB),onPrimary=Color.White, secondary = Color(0xFF2563EB),onSecondary=Color.White, surface = Color(0xFFF8FAFC), background = Color(0xFFF8FAFC))) {
                Surface(Modifier.fillMaxSize()) {
                    val openSettings = { surface?.cancelTouches(); settingsOpen=true }
                    LaunchedEffect(session.skinTransfer?.id) {
                        session.consumeSkinTransfer()?.let { transfer ->
                            try {
                                if(transfer.share) startActivity(android.content.Intent.createChooser(SkinTransferFiles.shareIntent(this@MainActivity,transfer.file),"Share skin"))
                                else { session.documentExport=transfer.file;saveSkinDocument.launch(transfer.file.name) }
                            } catch(_: Exception) { session.reportSkinTransferError("Could not open the system share or file picker. Try again.") }
                        }
                    }
                    LaunchedEffect(current.onboardingCompleted,completingGuide) {
                        if(completingGuide && current.onboardingCompleted) {
                            completingGuide=false;guideOpen=false
                            if(current.canReconnect && !current.paired && !current.connecting) reconnectSavedMac()
                        }
                    }
                    val showGuide=current.onboardingLoaded && (!current.onboardingCompleted || guideOpen)
                    if(sharedBuildsOpen) SharedBuildScreen(session.sharedBuilds, onSave={ record ->
                        session.sharedBuilds.documentExport=record
                        saveBuildDocument.launch("thumble-recovered-${record.id}.${if(record.profileFile) "json" else "zip"}")
                    }, onDone={ sharedBuildsOpen=false })
                    else if(skinsOpen) SkinLibraryScreen(session,dark,{ skinDocument.launch(arrayOf("*/*")) },{ skinsOpen=false })
                    else if(showGuide) Column(Modifier.fillMaxSize()) {
                        if(session.sharedBuilds.records.isNotEmpty() || session.sharedBuilds.error!=null)
                            TextButton(onClick={ openSharedBuilds() }) { Text("Recover saved builds") }
                        Box(Modifier.weight(1f)) {
                            OnboardingScreen(current,localError,guideOpen,
                                onSmartConnect={ if(current.canReconnect) reconnectSavedMac() else localError="Pair once with the Mac QR code to enable Smart Connect." },
                                onComplete={ localError=null;completingGuide=true;client.completeOnboarding() },
                                onClose={ guideOpen=false })
                        }
                    }
                    else if(!current.onboardingLoaded) Box(Modifier.fillMaxSize(),contentAlignment=androidx.compose.ui.Alignment.Center) { CircularProgressIndicator() }
                    else if (state.paired || state.viewingSaved) ControllerScreen(dark,openSettings) else ConnectionScreen(openSettings)
                    if(skinsOpen) session.reviewedSkin?.let { reviewed ->
                        AlertDialog(onDismissRequest={ session.cancelSkinImport() },containerColor=MaterialTheme.colorScheme.surface,title={ Text("Import skin") },
                            text={ Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                state.snapshot.selected?.let { selected -> SkinLibraryPreview(session,selected,null,dark,false,reviewed) }
                                Text(reviewed.name,style=MaterialTheme.typography.titleMedium)
                                Text("Version ${reviewed.reference.version}")
                                Text(reviewed.authorName)
                                Text(reviewed.manifestJSON().optString("summary"))
                                Text(reviewed.manifestJSON().optString("license"))
                                Text("Imports the skin without changing your keypad or bindings.")
                                if(session.installedSkins.any { it.reference==reviewed.reference }) Text("This replaces the installed copy of this version.")
                                session.skinError?.let { Text(it,color=MaterialTheme.colorScheme.error) }
                            } },
                            confirmButton={ TextButton(enabled=!session.skinBusy,onClick={ session.installReviewedSkin() }) { Text(if(session.skinBusy) "Importing…" else "Import") } },
                            dismissButton={ Column {
                                TextButton(enabled=!session.skinBusy && state.snapshot.selected!=null,onClick={ session.installReviewedSkin(true,state.snapshot.selected?.skinColorScheme(dark) ?: if(dark) "dark" else "light") }) { Text("Install & Apply") }
                                TextButton(enabled=!session.skinBusy,onClick={ session.cancelSkinImport() }) { Text("Cancel") }
                            } })
                    }
                    if (settingsOpen) KeypadSettings(state.hapticIntensity,state.preferencesError,
                        onIntensity={ client.setHapticIntensity(it) },appearance=state.snapshot.selected?.let { AppearancePreference.forProfile(it) },
                        onAppearance={ client.setAppearancePreference(it) },showBindingGlyphs=state.showBindingGlyphs,
                        onShowBindingGlyphs={ client.setShowBindingGlyphs(it) },onDismiss={ settingsOpen=false })
                }
            }
        }
        if(!launchSkinIntentHandled) receiveSkinIntent(intent)
        else savedInstanceState?.getString("recoverableSkinImportURI")?.let { uri ->
            if(session.recoverableSkinImportURI==null && session.reviewedSkin==null) {
                val parsed=android.net.Uri.parse(uri)
                if(parsed.scheme=="content" && !parsed.authority.isNullOrBlank()) importSkinURI(parsed)
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
        var address by rememberSaveable { mutableStateOf("ws://") }
        var code by rememberSaveable { mutableStateOf("") }
        Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                Text("Thumble", style = MaterialTheme.typography.headlineLarge,modifier=Modifier.weight(1f))
                TextButton(onClick=openSettings) { Text("Settings") }
            }
            Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick={ openSkinLibrary() }) { Text("Skins") }
                if(session.sharedBuilds.records.isNotEmpty() || session.sharedBuilds.error!=null)
                    OutlinedButton(onClick={ openSharedBuilds() }) { Text("Recover saved builds") }
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
            TextButton(onClick={ localError=null;surface?.cancelTouches();guideOpen=true },modifier=Modifier.testTag("open-setup-guide")) { Text("Setup guide") }
            HorizontalDivider()
            Text(if (state.needsCode) "Pairing code" else "Connect manually", style = MaterialTheme.typography.titleMedium)
            if (!state.needsCode) OutlinedTextField(address, { address = it }, label = { Text("Mac address") },
                placeholder = { Text("ws://192.168.1.10:8765") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            OutlinedTextField(code, { code = it.filter(Char::isDigit).take(6) }, label = { Text("Six-digit code") },
                singleLine = true, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            OutlinedButton(onClick = {
                localError=null
                if (state.needsCode) client.submitCode(code)
                else try { connect(PairingTarget.manual(address, code)) }
                catch (error: Exception) { localError = error.message }
            }, enabled = code.length == 6 && (!state.connecting || state.needsCode), modifier = Modifier.fillMaxWidth()) { Text("Pair with Mac") }
        }
    }
    @OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
    @Composable private fun ControllerScreen(dark: Boolean,openSettings: ()->Unit) {
        val configuration = LocalConfiguration.current
        val landscape = configuration.screenWidthDp >= configuration.screenHeightDp
        val snapshot=state.snapshot
        val profile = snapshot.selected
        if (state.layoutEditing && profile != null) {
            key(state.layoutEditToken) {
                LayoutEditorScreen(profile, state.layoutEditOrientation ?: if(landscape) LayoutOrientation.LANDSCAPE else LayoutOrientation.PORTRAIT,
                    state.layoutEditToken, client, session.skinRenderer, dark, state.error,state.layoutEditEntry)
            }
            return
        }
        val rendered by key(profile, landscape, dark, session.skinRevision) {
            produceState<SkinRenderProjection?>(null) {
                value = session.skinRenderer.resolveForDisplay(profile, landscape, dark)
            }
        }
        // A new request starts empty, including installation/removal invalidation.
        // Never accept touches against an appearance that is about to be replaced.
        val projection = rendered?.takeIf { it.matches(profile, landscape, dark) }
        var waitsForInitialSkinSync by remember(profile) { mutableStateOf(session.skinSyncInFlight>0) }
        LaunchedEffect(profile,session.skinSyncInFlight) { if(session.skinSyncInFlight==0) waitsForInitialSkinSync=false }
        val hasOwnedAppearance = landscape && profile?.source?.optJSONObject("appearanceBank") != null
        // Owned resources never wait for an installed-package synchronization job.
        val loadingSkin = if (hasOwnedAppearance) projection == null else
            profile?.source?.optJSONObject("skinReference") != null &&
                (projection == null || (waitsForInitialSkinSync && session.skinSyncInFlight>0))
        var menu by remember { mutableStateOf(false) }
        LaunchedEffect(menu) { if(menu) session.refreshSkins() }
        val unsupported = profile?.unsupportedKinds(landscape).orEmpty()
        var drawerExpanded by rememberSaveable { mutableStateOf(false) }
        ImmersiveControllerWindow(window)
        Box(Modifier.fillMaxSize().semantics { testTagsAsResourceId=true }) {
            AndroidView(factory = { context -> ControllerSurface(context).also { surface = it } },
                update = { view ->
                    view.importantForAccessibility=if(drawerExpanded) android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS else android.view.View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
                    val surfaceRevision = state.surfaceRevision
                    view.onEdge = { id, down, press -> client.edge(id, down, press, surfaceRevision) }
                    view.onPartEdge = { id, part, down, press -> client.elementEdge(id, part, down, press, surfaceRevision) }
                    view.onStick = { target, x, y, final -> client.stick(target, x, y, final, surfaceRevision) }
                    view.onTrigger = { target, value, final -> client.trigger(target, value, final, surfaceRevision) }
                    view.onPointer = { kind, x, y, button, down -> client.pointer(kind, x, y, button, down, surfaceRevision) }
                    view.onReleaseAll = { client.releaseAll() }
                    view.hapticIntensity=state.hapticIntensity
                    view.show(if (loadingSkin || session.skinBusy) null else projection?.profile ?: profile, surfaceRevision, landscape,
                        profile?.skinColorScheme(dark)=="dark",
                        if (loadingSkin || session.skinBusy) null else projection?.appearanceFrames)
                    view.showBindingPresentations(snapshot.bindingPresentations,state.showBindingGlyphs)
                }, modifier = Modifier.fillMaxSize())
            // Loading and failures remain visible even with connection chrome collapsed.
            val notice = state.error ?: session.skinError ?: when {
                session.skinBusy -> "Preparing skin…"
                loadingSkin -> "Loading keypad appearance…"
                else -> null
            }
            if (notice != null && !drawerExpanded) {
                Surface(modifier = Modifier.align(androidx.compose.ui.Alignment.BottomCenter)
                    .safeDrawingPadding().padding(12.dp), shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
                    tonalElevation = 6.dp, onClick = { surface?.cancelTouches(); drawerExpanded = true }) {
                    Text(notice, Modifier.padding(horizontal = 16.dp, vertical = 10.dp), style = MaterialTheme.typography.labelMedium)
                }
            }
            ControllerDrawer(
                expanded = drawerExpanded,
                onExpandedChange = { expanded ->
                    if (expanded) surface?.cancelTouches()
                    drawerExpanded = expanded
                },
                status = if (state.practiceMode) "Practice · Input off" else if (state.paired) "Connected" else "Saved keypad"
            ) {
                ControllerHeader(snapshot, onSelect = { selectProfile(it) },
                    connectionLabel = if (state.paired) "Disconnect" else "Connection",
                    onConnection = {
                        surface?.cancelTouches()
                        if (state.paired) client.disconnect() else client.showConnection()
                    }) {
                    Box {
                        IconButton(modifier=Modifier.testTag("keypad-options").semantics { contentDescription="Keypad options" },
                            onClick = { surface?.cancelTouches(); menu = true }) {
                            ControllerOptionsIcon()
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false },containerColor=MaterialTheme.colorScheme.surface) {
                            DropdownMenuItem(text={ Text("Setup guide") },onClick={ menu=false;surface?.cancelTouches();localError=null;guideOpen=true })
                            if(session.sharedBuilds.records.isNotEmpty() || session.sharedBuilds.error!=null)
                                DropdownMenuItem(text={ Text("Recover saved builds") },onClick={ menu=false;openSharedBuilds() })
                            DropdownMenuItem(text={ Text(if (profile?.id == snapshot.defaultID) "Default keypad" else "Make default keypad") },
                                enabled=(state.paired || state.viewingSaved) && profile != null && profile.id != snapshot.defaultID,
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
                            DropdownMenuItem(text={ Text("Skins") },onClick={ menu=false;openSkinLibrary() })
                            DropdownMenuItem(text={ Text("Import skin…") },enabled=!session.skinBusy,
                                onClick={ menu=false;skinDocument.launch(arrayOf("*/*")) })
                            session.installedSkins.forEach { installed ->
                                DropdownMenuItem(text={ Text("Apply ${installed.name} · ${installed.reference.version}") },enabled=!session.skinBusy,
                                    onClick={ menu=false;session.applySkin(installed.reference,profile?.skinColorScheme(dark) ?: if(dark) "dark" else "light") })
                            }
                            DropdownMenuItem(text={ Text("Detach skin") },enabled=!session.skinBusy && profile?.source?.optJSONObject("skinReference")!=null,
                                onClick={ menu=false;session.detachSkin(profile?.skinColorScheme(dark) ?: if(dark) "dark" else "light") })
                            HorizontalDivider()
                            DropdownMenuItem(text={ Text("Edit layout") },enabled=profile!=null && !loadingSkin && !session.skinBusy,
                                onClick={ menu=false;surface?.cancelTouches();profile?.let {
                                    client.beginLayoutEditing(it.id,if(landscape) LayoutOrientation.LANDSCAPE else LayoutOrientation.PORTRAIT)
                                } })
                            DropdownMenuItem(text={ Text("Settings") },onClick={ menu=false;openSettings() })
                        }
                    }
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
                if(state.pendingAppearanceChanges>0) Text("Appearance saved locally; waiting for Mac sync",Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.labelSmall)
                if(session.skinBusy) Text("Preparing skin…",Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.labelSmall)
                projection?.warning?.let { Text(it, Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelSmall) }
                if (unsupported.isNotEmpty()) Text("Not supported in this build: ${unsupported.joinToString()}",
                    Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
            }
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
