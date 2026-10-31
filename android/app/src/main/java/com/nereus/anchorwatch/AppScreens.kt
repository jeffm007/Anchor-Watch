package com.nereus.anchorwatch

import android.media.AudioManager
import android.media.ToneGenerator
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.nereus.anchorwatch.core.*
import com.nereus.anchorwatch.calculations.*
import java.util.Locale
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay

internal val WatchGreen = Color(0xFF30D158)
internal val WatchOrange = Color(0xFFFF9F0A)
internal fun meters(value: Double?, digits: Int = 1): String = value?.let {
    String.format(Locale.US, "%.${digits}f %s", if (WatchSession.useFeet) it / 0.3048 else it, if (WatchSession.useFeet) "ft" else "m")
} ?: "—"
internal fun number(value: Double) = String.format(Locale.US, "%.1f", if (WatchSession.useFeet) value / 0.3048 else value)
internal fun parsedLength(value: String) = value.toDoubleOrNull()?.let { if (WatchSession.useFeet) it * 0.3048 else it }
internal fun editedLength(value: String, original: Double): Double? = if (value == number(original)) original else parsedLength(value)
internal val lengthUnit get() = if (WatchSession.useFeet) "ft" else "m"
internal fun freshFix(): Boolean = WatchSession.running && WatchSession.snapshot.fix?.let { WatchSession.now() - it.time <= 15_000 } == true
internal fun watchHeadline(): String {
    val s = WatchSession.snapshot
    return when {
        !WatchSession.running -> "Alarm OFF"
        s.alarm == Alarm.OUTSIDE_CIRCLE -> "Outside circle"
        s.alarm == Alarm.GPS_LOST -> "GPS lost"
        s.alarm == Alarm.GPS_POOR -> "GPS inaccurate"
        s.anchor == null -> "Alarm OFF"
        !freshFix() -> "GPS interrupted"
        s.status == MonitorStatus.OUTSIDE_PENDING -> "Outside · confirming"
        else -> "Holding"
    }
}
internal fun watchColor(): Color = when {
    WatchSession.snapshot.alarm != null -> Color(0xFFFF453A)
    WatchSession.snapshot.anchor != null && freshFix() && WatchSession.snapshot.status == MonitorStatus.HOLDING -> WatchGreen
    WatchSession.running -> WatchOrange
    else -> Color.Gray
}

@Composable
internal fun NereusApp(onStart: () -> Unit, onStop: () -> Unit, onSave: () -> Unit, onForget: () -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val context = LocalContext.current
    LaunchedEffect(lifecycle, WatchSession.scope, SettingsStore.boat, ModelSettings.scenario, ModelSettings.tideStage,
        EnvironmentData.wind, EnvironmentData.forecast, EnvironmentData.tides, EnvironmentData.currents, SettingsStore.currentFactor,
        CalculationEngine.droppedAt, WatchSession.simulation, WatchSession.simulationSpeed, WatchSession.simulationHarbor, Hazards.marks.toList()) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) { CalculationEngine.refresh(); delay(if (WatchSession.simulation != null) minOf(15_000L, 60_000L / WatchSession.simulationSpeed) else 15_000L) }
        }
    }
    DisposableEffect(lifecycle, context) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) PressureMonitor.start(context)
            else if (event == Lifecycle.Event.ON_PAUSE) PressureMonitor.stop()
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) PressureMonitor.start(context)
        onDispose { lifecycle.removeObserver(observer); PressureMonitor.stop() }
    }
    LaunchedEffect(WatchSession.simulation, lifecycle) {
        if (WatchSession.simulation != null) lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) { delay(200); if (!WatchSession.simulationServiceRunning) WatchSession.simulationStep(0.2) }
        }
    }
    val dataPoint = environmentPoint(
        WatchSession.simulation?.let { WatchSession.simulationOrigin },
        WatchSession.snapshot.anchor, WatchSession.snapshot.fix?.coordinate)
    val latestDataPoint by rememberUpdatedState(dataPoint)
    val dataKey = dataPoint?.let { "${(it.latitude * 100).toInt()}:${(it.longitude * 100).toInt()}" }
    LaunchedEffect(dataKey, WatchSession.simulation, WatchSession.simulationHarbor, EnvironmentData.refresh) {
        if (dataPoint == null) EnvironmentData.clear()
        else lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) { latestDataPoint?.let { EnvironmentData.fetch(it) }; delay(15 * 60 * 1000L) }
        }
    }
    LaunchedEffect(WatchSession.simulation) {
        if (WatchSession.simulation != null) {
            if (android.os.Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                WatchSession.error = "Allow NavAide notifications in Android Settings to show simulation data on the lock screen."
            } else runCatching { context.startForegroundService(android.content.Intent(context, MonitoringService::class.java)) }
                .onFailure { WatchSession.error = "Simulation lock-screen service could not start: ${it.message}" }
        }
    }
    var selected by rememberSaveable { mutableStateOf("Watch") }
    var page by rememberSaveable { mutableStateOf<String?>(null) }
    MaterialTheme(colorScheme = darkColorScheme(primary = Color(0xFF0A84FF), secondary = Color(0xFF64D2FF), background = Color.Black,
        surface = Color(0xFF1C1C1E), surfaceContainer = Color(0xFF1C1C1E), surfaceContainerHigh = Color(0xFF2C2C2E),
        surfaceContainerHighest = Color(0xFF1C1C1E), surfaceVariant = Color(0xFF1C1C1E), onSurfaceVariant = Color(0xFF8E8E93),
        secondaryContainer = Color(0xFF2C2C2E), onSecondaryContainer = Color.White, outline = Color(0xFF48484A))) {
        Box(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            // Landscape handsets and expanded/foldable windows share the same two-pane layout.
            val twoPane = (maxWidth > maxHeight || maxWidth >= 600.dp) && page == null
            Scaffold(containerColor = Color.Black, contentWindowInsets = WindowInsets(0), bottomBar = {
                if (!twoPane && page != "Settings") AppTabs(selected, page) { selected = it; page = null }
            }) { padding ->
                Row(Modifier.fillMaxSize().padding(padding).windowInsetsPadding(WindowInsets.statusBars)) {
                    if (twoPane) {
                        Card(Modifier.weight(1f).fillMaxHeight().navigationBarsPadding().padding(start = 12.dp, end = 6.dp, bottom = 12.dp),
                            shape = RoundedCornerShape(18.dp), colors = CardDefaults.cardColors(containerColor = Color(0xFF1C1C1E))) {
                            ChartMap(WatchSession.snapshot, Modifier.fillMaxSize().padding(horizontal = 8.dp, vertical = 4.dp), onSettings = { page = "Settings" })
                        }
                    }
                    Column(Modifier.weight(1f).fillMaxHeight()) {
                        if ((page != null || selected != "Watch") && page != "Settings") {
                            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                                if (page != null) TextButton(onClick = { page = null }) { Text("‹ Back") }
                                else TextButton(onClick = { page = "Guide" }) { Text("User Guide") }
                                Text(page ?: if (selected == "Anchor") "Anchoring" else selected, Modifier.padding(top = 15.dp), style = MaterialTheme.typography.titleMedium)
                                TextButton(onClick = { page = "Settings" }) { Text("Settings") }
                            }
                            if (WatchSession.snapshot.alarm != null) Card(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clickable { selected = "Watch"; page = null }) {
                                Text(watchHeadline() + " · Return to Watch", Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error)
                            }
                        }
                        if (!twoPane && (page != null || selected != "Watch")) SimulationBanner()
                        Box(Modifier.weight(1f)) {
                            when (page ?: selected) {
                                "Watch" -> WatchScreen(onStart, onStop, onSave, onForget, onSettings = { page = "Settings" }, onGuide = { page = "Guide" }, onTab = { selected = it }, showChart = !twoPane)
                                "Anchor" -> AnchoringScreen(onSave)
                                "Water" -> WaterScreen()
                                "Weather" -> WeatherScreen()
                                "Settings" -> SettingsHub(onSave, onStop, onSimulationStarted = { selected = "Watch"; page = null }, onGuide = { page = "Guide" }, onDone = { page = null })
                                "Guide" -> GuideScreen()
                            }
                        }
                        if (twoPane) AppTabs(selected, page) { selected = it; page = null }
                    }
                }
            }
        }
        if (WatchSession.nightMode) NightModeScreen(onExit = { WatchSession.nightMode = false })
        }
    }
}

@Composable
private fun AppTabs(selected: String, page: String?, onSelect: (String) -> Unit) {
    NavigationBar(Modifier.fillMaxWidth().padding(horizontal = 12.dp).clip(RoundedCornerShape(30.dp)),
        containerColor = Color(0xFF1C1C1E), tonalElevation = 0.dp) {
        listOf("Watch" to R.drawable.nav_watch, "Anchor" to R.drawable.nav_anchor, "Water" to R.drawable.nav_water, "Weather" to R.drawable.nav_weather).forEach { (title, icon) ->
            NavigationBarItem(selected = selected == title && page == null, onClick = { onSelect(title) },
                icon = { Icon(painterResource(icon), contentDescription = null, modifier = Modifier.size(20.dp)) }, label = { Text(title) },
                colors = NavigationBarItemDefaults.colors(selectedIconColor = MaterialTheme.colorScheme.primary,
                    selectedTextColor = MaterialTheme.colorScheme.primary, indicatorColor = Color(0xFF29292C)))
        }
    }
}

@Composable
internal fun SimulationBanner(modifier: Modifier = Modifier) {
    WatchSession.simulation?.let { simulation ->
        Text("SIMULATION: ${WatchSession.physicsDay?.title ?: simulation.title} · ${WatchSession.simulationHarbor.title} · ${WatchSession.simulationSeconds.toInt()} s · ${WatchSession.simulationSpeed}×" +
            if (WatchSession.simulationPaused) " · PAUSED" else "",
            modifier.fillMaxWidth().background(Color(0xDD422D12)).padding(8.dp),
            color = WatchOrange, style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
internal fun PageColumn(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
}
@Composable
internal fun SectionCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, color = Color.Gray, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 12.dp))
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = Color(0xFF1C1C1E))) {
            Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
        }
    }
}
@Composable
internal fun LengthField(label: String, value: String, change: (String) -> Unit) {
    OutlinedTextField(value, change, label = { Text("$label ($lengthUnit)") }, modifier = Modifier.fillMaxWidth(), singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
}

@Composable
internal fun TestingScreen(onSave: () -> Unit, onStop: () -> Unit, onSimulationStarted: () -> Unit, onGuide: () -> Unit) {
    val context = LocalContext.current
    // Rebuild field text on unit changes; saved values always remain metres.
    var radius by remember(WatchSession.useFeet, WatchSession.simulation) { mutableStateOf(number(WatchSession.monitor.radius)) }
    var rode by remember(WatchSession.useFeet, WatchSession.simulation) { mutableStateOf(number(WatchSession.monitor.rode)) }
    var saved by remember { mutableStateOf(false) }
    val r = editedLength(radius, WatchSession.monitor.radius); val length = editedLength(rode, WatchSession.monitor.rode)
    val valid = r != null && r.isFinite() && r in 10.0..300.0 && length != null && length.isFinite() && length in 0.0..1_000.0
    HazardEditor(context)
    PageColumn {
        SectionCard("Simulation controls") {
            Text("Scripted track preview at the selected harbor. Starts with a demo anchor and 50 m circle. Continues while locked when notifications are allowed; simulated alarms are visual, without a siren. Saved real anchor and monitoring settings are preserved.")
            SimulationHarbor.entries.forEach { harbor ->
                FilterChip(selected = WatchSession.simulationHarbor == harbor,
                    onClick = { WatchSession.changeSimulationHarbor(harbor) }, label = { Text(harbor.title) })
            }
            if (WatchSession.running && WatchSession.simulation == null) {
                Text("Stop live GPS monitoring before starting a simulation.")
                TextButton(onClick = onStop) { Text("Stop GPS and monitoring") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(1, 5, 20).forEach { speed -> FilterChip(selected = WatchSession.simulationSpeed == speed,
                    onClick = { WatchSession.changeSimulationSpeed(speed) }, label = { Text("${speed}×") }) }
            }
            SimulationMode.entries.forEach { mode ->
                TextButton(enabled = !WatchSession.running || WatchSession.simulation != null, onClick = {
                    WatchSession.startSimulation(mode); onSimulationStarted()
                }) { Text(mode.title) }
            }
            Text("Physics scenarios · boat profile and tackle inputs. Confirm depth in Water first. Scenario wind/current/tide drive the simulated boat; provider weather remains live data at the harbor.")
            SimulationDay.entries.forEach { day ->
                TextButton(enabled = (!WatchSession.running || WatchSession.simulation != null) && WatchSession.scope != null && SettingsStore.boat.displacement > 0 && SettingsStore.boat.anchorWeight > 0 && BoatMath.windage(SettingsStore.boat) != null,
                    onClick = { WatchSession.startPhysics(day); onSimulationStarted() }) { Text(day.title) }
            }
            if (WatchSession.simulation != null) {
                TextButton(onClick = { WatchSession.toggleSimulationPause() }) { Text(if (WatchSession.simulationPaused) "Resume simulation" else "Pause simulation") }
                TextButton(onClick = { WatchSession.physicsDay?.let { WatchSession.startPhysics(it) } ?: WatchSession.startSimulation(WatchSession.simulation!!); onSimulationStarted() }) { Text("Restart scenario") }
                TextButton(onClick = { WatchSession.stopSimulation() }) { Text("Exit simulation") }
            }
        }
        SectionCard("Saved hazards") {
            Text("Long-press empty chart to add a hazard. Tap a mark to edit; long-press and drag to move. A live readout shows distance and true bearing from the boat. Drag its text to reposition it or tap × to close it. Raising the anchor hides marks for later restoration.")
            Hazards.marks.toList().forEach { h ->
                Text(h.label + if (h.hidden) " · hidden" else "")
                Row {
                    TextButton(onClick = { Hazards.put(h.copy(hidden = !h.hidden)); Hazards.save(context) }) { Text(if (h.hidden) "Restore" else "Hide") }
                    TextButton(onClick = { Hazards.editing = h }) { Text("Edit") }
                }
            }
        }
        SectionCard("Display") {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Column(Modifier.weight(1f)) {
                    Text("Fade map controls")
                    Text("Touch the chart to show its tools. Hide after 5 seconds of inactivity.", style = MaterialTheme.typography.bodySmall)
                }
                Switch(checked = WatchSession.fadeMapControls, onCheckedChange = { WatchSession.setFadeMapControls(context, it) })
            }
            Row {
                FilterChip(selected = WatchSession.useFeet, onClick = { WatchSession.setUnits(context, true); saved = false }, label = { Text("Feet") })
                Spacer(Modifier.width(12.dp))
                FilterChip(selected = !WatchSession.useFeet, onClick = { WatchSession.setUnits(context, false); saved = false }, label = { Text("Metres") })
            }
        }
        SectionCard("Circle alarm & rode") {
            LengthField("Circle radius", radius) { radius = it; saved = false }
            LengthField("Actual rode out", rode) { rode = it; saved = false }
            Text("Circle: ${meters(10.0, 0)}–${meters(300.0, 0)}. Rode: 0–${meters(1_000.0, 0)}.", style = MaterialTheme.typography.bodySmall)
            Text("Changing rode preserves the anchor and any latched alarm. The circle updates only when Radius follows rode and depth is enabled on Anchor.")
            Button(enabled = valid, onClick = { val radiusChanged = r != WatchSession.monitor.radius; WatchSession.setRode(context, length!!); if (radiusChanged) WatchSession.setRadiusByHand(context, r!!); onSave(); saved = true }) { Text(if (saved) "Saved" else "Save changes") }
        }
        SectionCard("Alarm sound") {
            TextButton(onClick = {
                runCatching {
                    val tone = ToneGenerator(AudioManager.STREAM_ALARM, 100)
                    if (!tone.startTone(ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 1_000)) WatchSession.audioError = "Test sound could not start."
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ tone.release() }, 1_200)
                }.onFailure { WatchSession.audioError = "Test sound failed." }
            }) { Text("Test siren · 1 second") }
            val audio = context.getSystemService(AudioManager::class.java)
            Text("Alarm volume ${audio.getStreamVolume(AudioManager.STREAM_ALARM)} / ${audio.getStreamMaxVolume(AudioManager.STREAM_ALARM)}. Check Do Not Disturb, sound routing and battery controls on the phone.")
            WatchSession.audioError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
        ReadinessCalculations()
        SectionCard("Help & About") {
            TextButton(onClick = onGuide) { Text("User Guide") }
            Text("NavAide\n${BuildConfig.VERSION_NAME} · Android build ${BuildConfig.VERSION_CODE}", fontWeight = FontWeight.SemiBold)
            Text("Android preview: circle monitoring, online chart, manual depth and scope planning. Open-Meteo forecasts and Tide predictions are available. Modeled holding capacity, wind/current loads, catenary rode, forecast risks, swing clearance, anchor estimation and drift analysis are available.")
            Text("Maps: MapLibre Native · © OpenStreetMap contributors · OpenSeaMap · NOAA ENC. Online map requests reveal the viewed area to map providers. Weather and tide requests use your selected GPS, anchor or simulation location.", style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun LengthSlider(value: String, maxMeters: Double, onChange: (String) -> Unit) {
    val m = parsedLength(value)?.takeIf { it.isFinite() } ?: 0.0
    Slider(value = m.toFloat().coerceIn(0f, maxMeters.toFloat()), onValueChange = { onChange(number(it.toDouble())) }, valueRange = 0f..maxMeters.toFloat())
}

@Composable
private fun AnchoringScreen(onSave: () -> Unit) {
    val context = LocalContext.current
    val s = WatchSession.scope ?: WatchSession.boatGeometry
    var bow by remember(WatchSession.useFeet, WatchSession.simulation) { mutableStateOf(number(s.bowHeight)) }
    var boat by remember(WatchSession.useFeet, WatchSession.simulation) { mutableStateOf(number(s.boatLength)) }
    var margin by remember(WatchSession.useFeet, WatchSession.simulation) { mutableStateOf(number(s.margin)) }
    var ratio by remember { mutableStateOf(s.scopeRatio.toString()) }
    val b = editedLength(bow, s.bowHeight); val l = editedLength(boat, s.boatLength); val m = editedLength(margin, s.margin); val r = ratio.toDoubleOrNull()
    val valid = b != null && b.isFinite() && b in 0.0..30.0 && l != null && l.isFinite() && l in 0.0..100.0 && m != null && m.isFinite() && m in 0.0..100.0 && r != null && r.isFinite() && r in 1.0..20.0
    val preview = if (valid && WatchSession.scope != null) s.copy(bowHeight = b!!, boatLength = l!!, margin = m!!, scopeRatio = r!!) else null
    var saved by remember { mutableStateOf(false) }
    PageColumn {
        if (WatchSession.snapshot.anchor != null) SectionCard("Monitoring") { Text("Circle alarm ON · " + watchHeadline(), color = watchColor()); Text("Position within a circle does not prove the anchor is holding.") }
        AnchoringCalculations()
        Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = Color(0xFF1C1C1E))) {
            RodeDiagram(scope = preview ?: s, rode = WatchSession.snapshot.rode)
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                NumericAdjustment("Water depth below surface", s.depth, 0.0..maxOf(30.48, s.depth), 1.0, 0.5) {
                    WatchSession.setScope(context, s.copy(depth = it))
                }
                HorizontalDivider(color = Color(0xFF363638))
                Text("Entered sounder depth. High-water allowance: ${meters(s.tideRise)}.", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
                Text("At high water: ${meters(s.depth + s.tideRise)}", color = Color.Gray, style = MaterialTheme.typography.bodyMedium)
                HorizontalDivider(color = Color(0xFF363638))
                NumericAdjustment("Rode out", WatchSession.snapshot.rode, 0.3048..maxOf(10.0, SettingsStore.boat.rodeCarried, WatchSession.snapshot.rode), 5.0, 1.0) {
                    WatchSession.setRode(context, it)
                }
                HorizontalDivider(color = Color(0xFF363638))
                NumericAdjustment("Alarm radius", WatchSession.snapshot.radius, 10.0..300.0, 5.0, 1.0) {
                    WatchSession.setRadiusByHand(context, it)
                }
                HorizontalDivider(color = Color(0xFF363638))
                Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text("Radius follows rode and depth", Modifier.weight(1f))
                    Switch(checked = WatchSession.radiusFollowsRode, enabled = WatchSession.scope != null, onCheckedChange = { WatchSession.setRadiusFollowing(context, it) },
                        colors = SwitchDefaults.colors(checkedTrackColor = WatchGreen, checkedThumbColor = Color.White))
                }
                HorizontalDivider(color = Color(0xFF363638))
                Text(if (WatchSession.scope == null) "Enter measured water depth to enable radius following."
                    else if (WatchSession.radiusFollowsRode)
                    "Changing deployed rode or entered depth updates the alarm radius. Enter a radius to keep it fixed. Uses the shallowest tide-adjusted depth available, or entered depth when tide adjustment is unavailable."
                    else "Alarm radius is fixed until you edit it or enable automatic updates.",
                    color = Color.Gray, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(bottom = 16.dp))
            }
        }
        AnchoringCalculationDetails()
        SectionCard("Scope planning") {
            if (preview == null) Text("Set your measured depth in Water, then check the boat dimensions below.")
            else {
                Text("Suggested rode ${meters(preview.suggestedRode)}", style = MaterialTheme.typography.titleLarge)
                Text("Suggested circle ${meters(preview.suggestedRadius)}", style = MaterialTheme.typography.titleMedium)
                Text("${String.format(Locale.US, "%.1f:1", preview.scopeRatio)} × (depth ${meters(preview.depth + preview.tideRise)} + bow ${meters(preview.bowHeight)}). Circle includes taut reach, half boat length and margin.")
                Text("Suggested scope geometry is separate from the modeled load and holding assessment above.", color = WatchOrange)
            }
            NumericAdjustment("Scope ratio", r?.takeIf { it.isFinite() } ?: s.scopeRatio, 1.0..20.0, 0.1, 0.1, unitOverride = ":1") {
                ratio = String.format(Locale.US, "%.2f", it); saved = false
            }
            NumericAdjustment("Bow height above water", b ?: s.bowHeight, 0.0..30.0, 0.5, 0.1) { bow = String.format(Locale.US, "%.4f", if (WatchSession.useFeet) it / 0.3048 else it); saved = false }
            NumericAdjustment("Boat length · phone amidships", l ?: s.boatLength, 0.0..100.0, 1.0, 0.5) { boat = String.format(Locale.US, "%.4f", if (WatchSession.useFeet) it / 0.3048 else it); saved = false }
            NumericAdjustment("Extra circle margin", m ?: s.margin, 0.0..100.0, 1.0, 0.5) { margin = String.format(Locale.US, "%.4f", if (WatchSession.useFeet) it / 0.3048 else it); saved = false }
            Button(enabled = preview != null, onClick = { WatchSession.setScope(context, preview!!); saved = true }) { Text(if (saved) "Plan saved" else "Save plan") }
            Text("Suggested lengths do not change actual rode or the active circle. Enter what you really deployed in Settings.", style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun EnvironmentStatus() {
    if (WatchSession.simulation != null) Text("Real-world data at the simulation location; it does not drive the scripted boat motion.", color = WatchOrange)
    Text(environmentLocationLabel(), style = MaterialTheme.typography.bodySmall)
    if (EnvironmentData.point == null) Text("Enable GPS or start a simulation to choose a location.")
    if (EnvironmentData.loading) Text("Refreshing…")
    EnvironmentData.windFetched?.let { Text("Weather fetched ${localTime(it)}", style = MaterialTheme.typography.bodySmall) }
    TextButton(onClick = { EnvironmentData.refresh++ }, enabled = !EnvironmentData.loading) { Text("Refresh data") }
}
@Composable
private fun WeatherScreen() {
    PageColumn {
        ForecastCalculations()
        SectionCard("Wind & gusts · Open-Meteo") {
            EnvironmentStatus()
            EnvironmentData.windError?.let { Text(it, color = WatchOrange) }
            EnvironmentData.wind?.let { w ->
                Text(String.format(Locale.US, "%.0f kt · gusts %.0f kt", w.speed, w.gust), style = MaterialTheme.typography.headlineMedium)
                Text("From ${w.direction.toInt()}° true · ${localTime(w.time)}")
            }
            Text("Weather-model estimates, not a measurement aboard. The gust warning threshold is in Settings; modeled gust limits and forecast risks appear above.")
        }
        SectionCard("Next 24 hours · wind / gusts") {
            EnvironmentData.forecast.filter { it.time <= java.time.Instant.now().plusSeconds(24 * 3600) }.forEach { w -> Text("${localTime(w.time)} · ${w.speed.toInt()} / ${w.gust.toInt()} kt · ${w.direction.toInt()}°") }
            Text("Weather data: Open-Meteo.com · CC BY 4.0", style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun GuideScreen() {
    PageColumn {
        SectionCard("Start an anchor watch") {
            Text("1. Enable GPS on Watch. Grant precise location and notifications. Check accuracy, freshness and your actual position on the chart.")
            Text("2. Enter measured depth and expected tide rise in Water. Review scope and boat dimensions in Anchor. Rode is all chain and/or rope between anchor and bow; scope is rode divided by water depth plus bow height.")
            Text("3. Mark Drop anchor when the anchor enters the water. Enter the phone-to-bow distance and true bearing if known. Marking after backing away records the wrong anchor location.")
            Text("4. Set actual rode and an appropriate alarm circle in Settings. Check clearance to shore, hazards and nearby boats throughout the whole swing. Set and check the anchor physically before relying on the watch.")
            Text("5. Test the siren on the real phone, including its locked screen and audio route. Leave GPS monitoring enabled. The Android preview does not restart itself after force-stop or reboot.")
        }
        SectionCard("Read the dashboard") {
            Text("Night mode: tap the moon under the chart, or choose Night mode from the Alarm menu or Settings. The dim red screen shows anchor distance, alarm radius, recent track, wind and next tide. Monitoring continues. Tap anywhere to reveal Exit night mode for five seconds, or use Android Back. Brightness is restored when you exit or leave the app.")
            Text("Open the Alarm menu and choose Collapse dashboard or Expand dashboard to hide or show the six-card grid.")
            Text("Holding means a fresh usable GPS fix is inside the circle. It is not confirmation of seabed holding. Two fixes beyond the circle, allowing a capped GPS error, trigger an outside-circle alarm.")
            Text("GPS interrupted, lost or inaccurate means position protection is degraded. Restore a clear sky view, location access and power, and maintain a direct watch.")
            Text("Changing rode never moves the anchor or silences a latched alarm. Panning or zooming the map only changes the view. Dark blue is the boat, purple is its track, and red is the marked anchor.")
        }
        SectionCard("Calculated advice") {
            Text("Anchor offers seabed, wind/gust, current, wave and tide-stage scenario controls. Confirm depth and the boat profile before interpreting modeled gust limits. The rode drawing uses the modeled steady-load catenary. Forecast risks include depth, scope, gusts, heading changes and hull clearance to marked hazards, with explicit coverage limits.")
            Text("Anchor estimation waits two settling minutes and 20 more minutes of swing with at least 30 fixes. Only free-radius rolling fits supply anchor-drift evidence; three consecutive significant, steady fits are needed. A separate three-minute distance trend can flag movement beyond prior reach. Estimates never move the marked anchor. Modeled warnings are advisory displays; the existing circle/GPS siren remains the active alarm mechanism.")
            Text("Watch → Swing analysis and retrieval shows the model swing radius, approximate anchor/error ellipse, drift and bow-to-anchor guidance. GPS course is ignored below 0.25 m/s. The handset barometer records pressure when the app or GPS monitoring runs; the three-hour trend needs at least 2.4 hours of history. Verify sound, charging, permissions and actual conditions aboard.")
        }
        SectionCard("If an alarm sounds") {
            Text("Check actual movement using independent GPS, chart and visual bearings. Assess nearby hazards immediately. Alert the crew and prepare the engine and safe maneuvering options. Silence only acknowledges sound temporarily; it does not resolve the cause.")
            Text("If dragging is confirmed, take control before reaching danger: recover and reset in suitable ground or move to a safer location as conditions allow. Additional rode helps only if scope and swing clearance permit. Do not move the app's anchor marker to hide real dragging.")
        }
        SectionCard("Hazards") {
            Text("Long-press empty chart to mark a rock, shoal, dock, other boat or other hazard. Set its keep-clear radius and optional name. Tap a symbol to edit or remove it. Long-press an existing mark and drag to reposition it; the red circle follows and distances are shown. Raising a real anchor hides saved hazards; simulation leaves saved real hazards visible. Restore them under Settings → Saved hazards. These marks are visual planning aids; they do not trigger a proximity siren.")
        }
        SectionCard("Weather & tides") {
            Text("Weather shows Open-Meteo model wind, gusts and a 24-hour forecast. Water shows nearby NOAA or Canadian Hydrographic Service high/low predictions within 25 km. Times use the phone's time zone; tide heights are metres/feet above the displayed station datum, not depth at the boat. Check the named station and fetched time. Data refreshes every 15 minutes while visible, with manual Refresh. Water also shows NOAA current predictions, scaled to 100%, 50% or 25% of station speed. Confirm a sounder reading to enable its tide-adjusted depth chart and outlook. Predictions do not include storm surge. During simulation, live provider data is for the demo location and does not control motion. Choose a tide allowance from the next 6, 12 or 24 hours, or enter it manually.")
        }
        SectionCard("Chart & emulator review") {
            Text("Settings → Testing → Simulation controls offers six scripted movement scenarios with 1×, 5× and 20× speed. Stop live GPS first, then choose a mode. A demo anchor is set at the selected Roche Harbor or Sidney location. Simulation runs only while the app is visible; use Pause/Resume in Settings → Testing → Simulation controls. Exit simulation before enabling real GPS. Five physical weather scenarios are also available after confirming depth: calm, sea breeze, passing front, wind against tide and gale. Their scripted environmental inputs drive simulated motion; provider data remains live for the selected harbor. Touch the map to reveal its controls below the chart. The map shrinks slightly to make room, then expands as the controls fade after a pause. Turn off Fade map controls in Settings to keep them visible. Choose OpenSeaMap or NOAA from the map icon. The dark blue boat symbol marks the GPS position (or last fix), and the red anchor marks the drop position. Both symbols grow smoothly as you zoom in. The boat points toward the marked anchor; this is illustrative, not a measured compass heading. A dotted orange tether connects the boat to the pointed tip of the anchor. Long-press the anchor and drag to correct its position; release to save, or cancel the gesture to keep its previous position. A white line measures from the original drop and a yellow line shows distance and true bearing from the boat. Drag either readout to reposition it; tap its × to hide that readout and its measuring line. A new anchor drag shows both again. A faded grey anchor marks the original drop even after the readouts close. Long-press that grey anchor to remove it and its moved-distance measurement; future moves measure from the corrected position. A purple track records movement while an anchor is set; dropping a new anchor starts a new track. Pinch/pan to explore; My boat and Anchor recenter the view. NOAA coverage is US waters. Missing tiles are not evidence of safe water. Verify chart details against suitable onboard navigation sources.")
            Text("In emulator Extended Controls → Location, send 28.615, −96.62, enable GPS and drop at the fix. Change longitude to −96.619 to move about 98 m east and trigger a 50 m circle alarm. Switch tabs and fold/unfold to review layouts while monitoring continues.")
            Text("This Android guide describes build ${BuildConfig.VERSION_CODE}. Open-Meteo wind forecasts and nearby Tide predictions are available. Open Anchor for modeled loads and holding, Weather for hourly limits and risk windows, and Watch → Swing analysis and retrieval for anchor estimates, drift evidence and bow guidance.")
        }
    }
}
