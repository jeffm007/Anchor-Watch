package com.nereus.anchorwatch

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.nereus.anchorwatch.core.*
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.*

private val NightRed = Color(0xFFD91A14)
private fun Context.nightActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.nightActivity()
    else -> null
}

@Composable
internal fun NightModeScreen(onExit: () -> Unit) {
    val context = LocalContext.current
    val activity = context.nightActivity()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var time by remember { mutableStateOf(Instant.now()) }
    var taps by remember { mutableIntStateOf(0) }
    var showExit by remember { mutableStateOf(false) }
    BackHandler(onBack = onExit)
    LaunchedEffect(taps) {
        if (taps > 0) { showExit = true; delay(5_000); showExit = false }
    }
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) { time = Instant.now(); delay(1_000) }
        }
    }
    DisposableEffect(activity, lifecycle) {
        val window = activity?.window
        val keptAwake = window?.attributes?.flags?.and(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0
        val previousInsets = window?.decorView?.let { ViewCompat.getRootWindowInsets(it) }
        val statusVisible = previousInsets?.isVisible(WindowInsetsCompat.Type.statusBars()) ?: true
        val navigationVisible = previousInsets?.isVisible(WindowInsetsCompat.Type.navigationBars()) ?: true
        val bars = window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        val previousBehavior = bars?.systemBarsBehavior
        fun restore() {
            if (!keptAwake) window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            bars?.let {
                if (statusVisible) it.show(WindowInsetsCompat.Type.statusBars()) else it.hide(WindowInsetsCompat.Type.statusBars())
                if (navigationVisible) it.show(WindowInsetsCompat.Type.navigationBars()) else it.hide(WindowInsetsCompat.Type.navigationBars())
                previousBehavior?.let { behavior -> it.systemBarsBehavior = behavior }
            }
        }
        fun dim() {
            window?.let {
                it.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            bars?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            bars?.hide(WindowInsetsCompat.Type.systemBars())
        }
        val observer = LifecycleEventObserver { _, event ->
            when (event) { Lifecycle.Event.ON_RESUME -> dim(); Lifecycle.Event.ON_PAUSE -> restore(); else -> Unit }
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) dim()
        onDispose { lifecycle.removeObserver(observer); restore() }
    }
    val s = WatchSession.snapshot
    val fresh = freshFix()
    val clock = DateTimeFormatter.ofPattern("h:mm a").withZone(ZoneId.systemDefault())
    val tide = EnvironmentData.tides?.events?.firstOrNull { it.time > time }
    Surface(Modifier.fillMaxSize(), color = Color.Black, contentColor = NightRed) {
        BoxWithConstraints(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures(onTap = { taps++ }) }) {
            val twoPane = maxWidth > maxHeight || maxWidth >= 600.dp
            val dashboard: @Composable (Modifier) -> Unit = { modifier ->
                Column(modifier.verticalScroll(rememberScrollState()).padding(20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (WatchSession.simulation != null) Text("SIMULATION · ${WatchSession.simulation!!.title}" +
                        if (WatchSession.simulationPaused) " · PAUSED" else "", color = NightRed, style = MaterialTheme.typography.labelLarge)
                    Text(watchHeadline().uppercase(), color = NightRed, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Black)
                    Text(when {
                        !WatchSession.running -> "GPS monitoring is OFF"
                        s.anchor == null -> "GPS active · no anchor set"
                        !fresh -> "Verify GPS freshness and position"
                        else -> "Circle monitoring · verify position and nearby hazards"
                    }, color = NightRed, style = MaterialTheme.typography.bodySmall)
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(if (fresh && s.anchor != null) meters(s.distance, 0) else "—", color = NightRed,
                            fontSize = 68.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace, maxLines = 1)
                        Text("from the anchor · alarm at ${meters(s.radius, 0)}", color = NightRed, style = MaterialTheme.typography.bodyMedium)
                    }
                    if (!twoPane) NightRadar(s, fresh)
                    val wind = EnvironmentData.wind
                    Text(buildList {
                        wind?.let {
                            val compass = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")[(round(it.direction / 45).toInt() % 8 + 8) % 8]
                            add("${it.speed.roundToInt()} kt $compass")
                        }
                        tide?.let { add("${if (it.high) "High" else "Low"} ${clock.format(it.time)}") }
                        add(clock.format(time))
                        s.fix?.let { add("±${meters(it.accuracy, 0)}" + if (!fresh) " · stale" else "") }
                    }.joinToString("   ·   "), color = NightRed, style = MaterialTheme.typography.bodySmall)
                    WatchSession.error?.let { Text(it, color = NightRed) }
                    WatchSession.audioError?.let { Text("Siren unavailable: $it", color = NightRed, fontWeight = FontWeight.Bold) }
                    if (s.alarm != null) {
                        Text(watchHeadline(), color = NightRed, fontWeight = FontWeight.Bold)
                        Button(onClick = { WatchSession.monitor.acknowledge(WatchSession.now()); WatchSession.publish() },
                            modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth(), shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = NightRed, contentColor = Color.Black)) {
                            Text("SILENCE · 60 seconds", fontWeight = FontWeight.Bold, modifier = Modifier.padding(vertical = 10.dp))
                        }
                    }
                    Row(Modifier.widthIn(max = 420.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Keep anchor data visible", Modifier.weight(1f), color = NightRed)
                        Switch(checked = WatchSession.keepNightDataVisible,
                            onCheckedChange = { WatchSession.setKeepNightDataVisible(context, it) },
                            colors = SwitchDefaults.colors(checkedTrackColor = NightRed, checkedThumbColor = Color.Black))
                    }
                    Text(if (WatchSession.keepNightDataVisible) "Dims after 30 minutes; readings stay visible. Touch to brighten. Leave Nereus open; the side button still locks the phone."
                        else "Dims after 30 minutes and goes black after 2 hours. Touch to restore.",
                        color = NightRed, style = MaterialTheme.typography.bodySmall)
                    if (showExit) OutlinedButton(onClick = onExit, border = androidx.compose.foundation.BorderStroke(1.dp, NightRed),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = NightRed)) { Text("Exit night mode") }
                }
            }
            if (twoPane) {
                Row(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxHeight().padding(20.dp), contentAlignment = Alignment.Center) {
                        NightRadar(s, fresh, Modifier.fillMaxSize())
                    }
                    dashboard(Modifier.weight(1f).fillMaxHeight())
                }
            } else dashboard(Modifier.fillMaxSize())
        }
    }
}

@Composable
private fun NightRadar(s: MonitorSnapshot, fresh: Boolean, modifier: Modifier = Modifier.widthIn(max = 320.dp).fillMaxWidth().aspectRatio(1f)) {
    val track = WatchSession.track.toList()
    val scope = WatchSession.scope
    val swing = scope?.reach(s.rode) ?: 0.0
    Box(modifier, contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize().clipToBounds().semantics { contentDescription = "North-up anchorage radar. Solid alarm circle, dashed rode reach, anchor and recent boat track." }) {
            val anchor = s.anchor ?: return@Canvas
            val extent = max(s.radius, max(swing, 1.0))
            val scale = (min(size.width, size.height) / 2 - 18.dp.toPx()) / extent.toFloat()
            fun project(at: Coordinate): Offset {
                val distance = Geo.distance(anchor, at)
                val angle = Math.toRadians(Geo.bearing(anchor, at))
                return center + Offset((sin(angle) * distance * scale).toFloat(), (-cos(angle) * distance * scale).toFloat())
            }
            drawCircle(NightRed, (s.radius * scale).toFloat(), center, style = Stroke(2.dp.toPx()))
            if (swing > 0) drawCircle(NightRed.copy(alpha = 0.5f), (swing * scale).toFloat(), center,
                style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 5.dp.toPx()))))
            val speed = if (WatchSession.simulation != null) WatchSession.simulationSpeed else 1
            val recent = track.filter { (WatchSession.now() - it.time) * speed <= 1_800_000L }
            if (recent.size > 1) {
                val path = Path().apply { recent.forEachIndexed { i, fix -> val p = project(fix.coordinate); if (i == 0) moveTo(p.x, p.y) else lineTo(p.x, p.y) } }
                drawPath(path, NightRed.copy(alpha = 0.6f), style = Stroke(1.5.dp.toPx()))
            }
            if (fresh) s.fix?.let { drawCircle(NightRed, 5.dp.toPx(), project(it.coordinate)) }
        }
        if (s.anchor != null) {
            Icon(androidx.compose.ui.res.painterResource(R.drawable.nav_anchor), "Anchor", tint = NightRed, modifier = Modifier.size(24.dp))
            Text("N", Modifier.align(Alignment.TopCenter), color = NightRed.copy(alpha = 0.7f), fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelSmall)
        } else Text("No anchor set", color = NightRed.copy(alpha = 0.7f))
    }
}
