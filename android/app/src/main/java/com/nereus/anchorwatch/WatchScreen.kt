package com.nereus.anchorwatch

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nereus.anchorwatch.core.*
import java.util.Locale
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay

@Composable
internal fun WatchScreen(onStart: () -> Unit, onStop: () -> Unit, onSave: () -> Unit, onForget: () -> Unit, onSettings: () -> Unit, onGuide: () -> Unit, onTab: (String) -> Unit, showChart: Boolean = true) {
    val s = WatchSession.snapshot
    val running = WatchSession.running
    val fresh = freshFix()
    var expanded by rememberSaveable { mutableStateOf(true) }
    var menu by remember { mutableStateOf(false) }
    var raise by remember { mutableStateOf(false) }
    var dropping by remember { mutableStateOf(false) }
    var bearing by rememberSaveable { mutableStateOf("") }
    var offset by rememberSaveable { mutableStateOf("0") }
    val scope = WatchSession.scope
    var now by remember { mutableStateOf(Instant.now()) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) { now = Instant.now(); delay(30_000) }
        }
    }
    val tide = EnvironmentData.tides
    val tideCards = WaterMath.dashboard(now, tide, WaterDepth.reference?.takeIf { it.depth == scope?.depth })
    val tideTime = DateTimeFormatter.ofPattern("EEE h:mm a").withZone(ZoneId.systemDefault())
    BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
        val density = LocalDensity.current
        var headerHeight by remember { mutableStateOf(0.dp) }
        val chartHeight = (maxHeight - headerHeight - 10.dp).coerceAtLeast(180.dp)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.fillMaxWidth().onSizeChanged { headerHeight = with(density) { it.height.toDp() } }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column(Modifier.weight(1f).padding(top = 8.dp)) {
                        Text("NavAide", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.ExtraBold)
                        Text(s.fix?.let { "${if (WatchSession.simulation != null) "Simulated GPS" else "Android GPS"} ±${meters(it.accuracy, 0)} · ${((WatchSession.now() - it.time) / 1000).coerceAtLeast(0)} s ago" } ?: "Waiting for GPS…", style = MaterialTheme.typography.labelSmall, color = Color.Gray)
                    }
                    Box {
                        OutlinedButton(onClick = { menu = true }, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 2.dp), colors = ButtonDefaults.outlinedButtonColors(contentColor = watchColor())) {
                            Text((if (s.alarm != null) "ALARM" else if (s.anchor != null && running) "Alarm ON" else "Alarm OFF") + " ⌄", style = MaterialTheme.typography.labelLarge)
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            if (s.alarm != null) DropdownMenuItem(text = { Text("Silence · 60 seconds") }, onClick = { WatchSession.monitor.acknowledge(WatchSession.now()); WatchSession.publish(); menu = false })
                            DropdownMenuItem(text = { Text(if (s.anchor == null) "Drop anchor" else "Raise anchor") }, enabled = s.anchor != null || fresh, onClick = { menu = false; if (s.anchor == null) dropping = true else raise = true })
                            DropdownMenuItem(text = { Text("Night mode") }, onClick = { menu = false; WatchSession.nightMode = true })
                            DropdownMenuItem(text = { Text("Settings") }, onClick = { menu = false; onSettings() })
                            DropdownMenuItem(
                                text = { Text(if (expanded) "Collapse dashboard" else "Expand dashboard") },
                                onClick = { expanded = !expanded; menu = false })
                            DropdownMenuItem(text = { Text("User Guide") }, onClick = { menu = false; onGuide() })
                            if (running) DropdownMenuItem(text = { Text(if (WatchSession.simulation != null) "Exit simulation" else "Stop GPS and monitoring") }, onClick = { menu = false; onStop() })
                        }
                    }
                }
                if (!running) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("GPS monitoring is OFF", style = MaterialTheme.typography.bodySmall, color = Color.Gray, modifier = Modifier.padding(top = 12.dp))
                    TextButton(onClick = onStart) { Text("Enable GPS") }
                }
                if (s.alarm != null || (s.anchor != null && !fresh)) Card(colors = CardDefaults.cardColors(containerColor = Color(0xFF321B1D))) {
                    Column(Modifier.fillMaxWidth().padding(12.dp)) {
                        Text(watchHeadline(), color = watchColor(), fontWeight = FontWeight.Bold)
                        Text("Verify position and nearby hazards now.", style = MaterialTheme.typography.bodySmall)
                        if (s.alarm != null) TextButton(onClick = { WatchSession.monitor.acknowledge(WatchSession.now()); WatchSession.publish() }) { Text("Silence for 60 seconds") }
                    }
                }
                if (!SettingsStore.hideWarnings) SettingsStore.gustAdvisory?.let {
                    Text(it, color = WatchOrange, style = MaterialTheme.typography.bodySmall)
                }
                WatchSession.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                WatchSession.audioError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                if (WatchSession.simulation == null && s.anchor == null && WatchSession.recovery != null) Card {
                    Column(Modifier.padding(10.dp)) {
                        Text("Saved anchor · monitoring interrupted", style = MaterialTheme.typography.bodySmall, color = WatchOrange)
                        Row {
                            TextButton(enabled = fresh, onClick = { WatchSession.drop(WatchSession.recovery!!); onSave() }) { Text("Resume") }
                            TextButton(onClick = onForget) { Text("Discard") }
                        }
                    }
                }
                if (expanded) {
                    data class Tile(val title: String, val value: String, val detail: String, val tab: String? = null, val color: Color = Color.White)
                    val scopeRatio = scope?.let { if (WaterDepth.liveDepth(now) + it.bowHeight > 0) s.rode / (WaterDepth.liveDepth(now) + it.bowHeight) else null }
                    val tiles = listOf(
                        Tile("Wind", EnvironmentData.wind?.let { "${it.speed.toInt()} kt" } ?: "—", "Model forecast", "Weather"),
                        Tile("Depth at High Tide", tideCards.depthAtHigh?.let { meters(it) } ?: scope?.let { meters(it.depth + it.tideRise) } ?: "—",
                            when {
                                tideCards.depthAtHigh != null -> "${tideTime.format(tideCards.high!!.time)}\n${if (tideCards.riseToHigh!! >= 0) "+" else ""}${meters(tideCards.riseToHigh)} tide change"
                                scope == null -> "Set measured depth in Water"
                                tide != null -> "Manual allowance\nConfirm sounder depth in Water"
                                else -> "Manual allowance · tides unavailable"
                            }, "Water"),
                        Tile("Scope", scopeRatio?.let { String.format(Locale.US, "%.1f:1", it) } ?: "—", "${meters(s.rode, 0)} out", "Anchor"),
                        Tile("Anchor", watchHeadline(), "Circle position only", "Anchor", watchColor()),
                        Tile("Tide", tideCards.heightNow?.let { meters(it) + if (tideCards.next?.high == true) " ↑" else if (tideCards.next != null) " ↓" else "" } ?: "—",
                            buildList {
                                if (tideCards.heightNow != null) add("Est. above ${tide!!.datum}")
                                tideCards.next?.let { add("${if (it.high) "High" else "Low"} ${tideTime.format(it.time)} · ${meters(it.height)}") }
                                if (tide == null) add(if (EnvironmentData.loading) "Loading tides…" else "Tides unavailable")
                                else if (tideCards.heightNow == null) add("Prediction coverage ended")
                            }.joinToString("\n"), "Water"),
                        Tile("Distance", if (fresh && s.anchor != null) meters(s.distance, 0) else "—", "Alarm ${meters(s.radius, 0)}", color = if ((s.distance ?: 0.0) > s.radius) Color(0xFFFF453A) else Color.White)
                    )
                    tiles.chunked(if (showChart) 3 else 2).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            row.forEach { tile ->
                                Card(Modifier.weight(1f).then(if (tile.tab != null) Modifier.clickable { onTab(tile.tab) } else Modifier), shape = RoundedCornerShape(12.dp), colors = CardDefaults.cardColors(containerColor = Color(0xFF1C1C1E))) {
                                    Column(Modifier.padding(9.dp)) {
                                        Text(tile.title, style = MaterialTheme.typography.labelSmall, color = Color.Gray)
                                        Text(tile.value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = tile.color)
                                        Text(tile.detail, style = MaterialTheme.typography.labelSmall, color = Color.Gray)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            TrackingCalculations()
            if (showChart) Card(Modifier.fillMaxWidth().height(chartHeight), shape = RoundedCornerShape(18.dp), colors = CardDefaults.cardColors(containerColor = Color(0xFF1C1C1E))) {
                ChartMap(s, Modifier.fillMaxSize().padding(horizontal = 8.dp, vertical = 4.dp), onSettings = onSettings)
            }
        }
    }
    if (raise) AlertDialog(onDismissRequest = { raise = false }, title = { Text("Raise anchor?") }, text = { Text("This turns off the circle alarm and clears the saved anchor and track.") }, confirmButton = { TextButton(onClick = { onForget(); raise = false }) { Text("Raise anchor") } }, dismissButton = { TextButton(onClick = { raise = false }) { Text("Cancel") } })
    if (dropping) {
        val distance = parsedLength(offset)
        val direction = bearing.toDoubleOrNull()
        val valid = distance != null && distance.isFinite() && distance in 0.0..50.0 && (distance == 0.0 || (direction != null && direction.isFinite() && direction in 0.0..360.0))
        AlertDialog(onDismissRequest = { dropping = false }, title = { Text("Drop anchor") }, text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Mark when the anchor enters the water. Enter the distance and true bearing from phone to bow. Zero uses the phone position.")
                LengthField("Phone to bow", offset) { offset = it }
                OutlinedTextField(bearing, { bearing = it }, label = { Text("Direction to bow · ° true") }, singleLine = true)
                Text("Rode changes and map gestures never move this anchor marker. Verify the marked position against your actual drop.")
            }
        }, confirmButton = { TextButton(enabled = valid && fresh, onClick = {
            val phone = WatchSession.snapshot.fix!!.coordinate
            WatchSession.drop(if (distance == 0.0) phone else Geo.destination(phone, direction!!, distance!!))
            onSave(); dropping = false
        }) { Text("Set anchor · alarm ON") } }, dismissButton = { TextButton(onClick = { dropping = false }) { Text("Cancel") } })
    }
}
