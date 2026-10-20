package com.thumble.android

import android.view.Window
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import kotlinx.coroutines.delay

/** Keep the native controller canvas full size; system bars can still be revealed from an edge. */
@Composable
internal fun ImmersiveControllerWindow(window: Window) {
    DisposableEffect(window) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        val previousBehavior = controller.systemBarsBehavior
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
        onDispose {
            controller.systemBarsBehavior = previousBehavior
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }
}

/** An overlay, never a layout inset: revealing controls must not move held keypad targets. */
@Composable
internal fun BoxScope.ControllerDrawer(
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    status: String,
    content: @Composable ColumnScope.() -> Unit
) {
    var handleVisible by remember { mutableStateOf(true) }
    val reveal = {
        onExpandedChange(true)
    }
    BackHandler(expanded) { onExpandedChange(false) }
    LaunchedEffect(expanded, status) {
        handleVisible = true
        if (!expanded) {
            delay(2500)
            handleVisible = false
        }
    }
    val handleAlpha by animateFloatAsState(if (handleVisible) 1f else 0f, label = "Controller handle")
    val threshold = with(LocalDensity.current) { 18.dp.toPx() }
    val handleGesture = Modifier.pointerInput(expanded, threshold) {
        var distance = 0f
        detectVerticalDragGestures(
            onDragStart = { distance = 0f },
            onVerticalDrag = { change, amount -> change.consume(); distance += amount },
            onDragEnd = {
                if (distance > threshold) reveal()
                else if (distance < -threshold) onExpandedChange(false)
            }
        )
    }
    // This layer consumes touches only while the drawer is open. Gameplay outside
    // the compact closed handle goes straight to the Android controller view.
    if (expanded) Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.scrim.copy(alpha = 0.32f))
        .testTag("controller-drawer-dismiss").clickable { onExpandedChange(false) })

    BoxWithConstraints(Modifier.align(Alignment.TopCenter).fillMaxSize()) {
        val panelMaxHeight = maxHeight * 0.85f
        AnimatedVisibility(
            visible = expanded,
            modifier = Modifier.align(Alignment.TopCenter).safeDrawingPadding().widthIn(max = 640.dp),
            enter = slideInVertically(spring(dampingRatio = 0.86f, stiffness = Spring.StiffnessMedium)) { -it } + fadeIn(),
            exit = slideOutVertically(spring(dampingRatio = 0.86f, stiffness = Spring.StiffnessMedium)) { -it } + fadeOut()
        ) {
            Surface(shape = RoundedCornerShape(bottomStart = 24.dp, bottomEnd = 24.dp),
                tonalElevation = 6.dp, shadowElevation = 8.dp,
                modifier = Modifier.fillMaxWidth().heightIn(max = panelMaxHeight).testTag("controller-drawer")) {
                Column {
                    Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()), content = content)
                    Box(Modifier.align(Alignment.CenterHorizontally).width(88.dp).height(48.dp)
                        .then(handleGesture).testTag("controller-drawer-close")
                        .semantics { contentDescription = "Hide connection controls" }
                        .clickable(role = Role.Button) { onExpandedChange(false) }, contentAlignment = Alignment.Center) {
                        val chevronColor = MaterialTheme.colorScheme.onSurfaceVariant
                        Canvas(Modifier.size(20.dp, 10.dp)) {
                            val stroke = 2.dp.toPx()
                            drawLine(chevronColor, Offset(0f, size.height), Offset(size.width / 2, 0f), stroke, StrokeCap.Round)
                            drawLine(chevronColor, Offset(size.width / 2, 0f), Offset(size.width, size.height), stroke, StrokeCap.Round)
                        }
                    }
                }
            }
        }
        if (!expanded) Box(Modifier.align(Alignment.TopCenter).safeDrawingPadding()
            .width(72.dp).height(44.dp).then(handleGesture).testTag("controller-drawer-reveal")
            .semantics { contentDescription = "Show connection controls, $status. Swipe down or tap." }
            .clickable(role = Role.Button, onClick = reveal), contentAlignment = Alignment.TopCenter) {
            Surface(Modifier.padding(top = 6.dp).alpha(handleAlpha), shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f)) {
                Box(Modifier.size(48.dp, 20.dp), contentAlignment = Alignment.Center) {
                    Box(Modifier.size(28.dp, 4.dp).background(MaterialTheme.colorScheme.onSurfaceVariant, RoundedCornerShape(2.dp)))
                }
            }
        }
    }
}
