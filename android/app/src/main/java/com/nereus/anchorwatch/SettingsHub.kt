package com.nereus.anchorwatch

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nereus.anchorwatch.core.*
import java.text.NumberFormat
import java.util.Locale

private val FormGray = Color(0xFF2C2C2E)
private val FormBlue = Color(0xFF009DFF)

@Composable
internal fun SettingsHub(onSave: () -> Unit, onStop: () -> Unit, onSimulationStarted: () -> Unit, onGuide: () -> Unit, onDone: () -> Unit) {
    val context = LocalContext.current
    SettingsStore.load(context)
    var page by rememberSaveable { mutableStateOf("Settings") }
    val focus = LocalFocusManager.current
    fun back() { focus.clearFocus(); if (page == "Settings") onDone() else page = "Settings" }
    BackHandler { back() }
    Surface(Modifier.fillMaxSize(), color = Color(0xFF1C1C1E)) {
        Column {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (page != "Settings") TextButton(onClick = { back() }) { Text("‹ Back") }
                Text(if (page == "Boat Profile") "${SettingsStore.boat.name} · Boat profile" else page,
                    Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                FilledTonalButton(onClick = { focus.clearFocus(); onDone() }, colors = ButtonDefaults.filledTonalButtonColors(containerColor = Color(0xFF3A3A3C))) { Text("Done", color = Color.White) }
            }
            when (page) {
                "Boat Profile" -> BoatProfileScreen()
                "Testing" -> TestingScreen(onSave, onStop, onSimulationStarted, onGuide)
                "Settings" -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
                    Text("Settings", fontSize = 34.sp, fontWeight = FontWeight.Bold)
                    FormGroup {
                        FormLink("Quick Guide", R.drawable.settings_quick) { page = "Quick Guide" }
                        FormLink("User Guide", R.drawable.settings_guide, action = onGuide)
                        FormLink("Boat Profile", R.drawable.settings_boat) { page = "Boat Profile" }
                        FormLink("Anchorage Log", R.drawable.settings_log, divider = false) { page = "Anchorage Log" }
                    }
                    FormSection("Warnings") {
                        FormGroup {
                            FormToggle("Hide warning banners", SettingsStore.hideWarnings, SettingsStore::hideWarnings)
                            FormToggle("Silence advisory notifications", SettingsStore.silenceAdvisories, SettingsStore::silenceAdvisories)
                            FormLink("Review warnings", divider = false) { page = "Review warnings" }
                        }
                        Text("Review warnings here at any time. Hiding banners keeps weather advisories off Watch. Anchor alarms and critical monitoring problems stay active. Advisory notification delivery is not available in this preview.", color = Color.Gray, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp))
                    }
                    FormGroup {
                        FormRow {
                            Text("Gust Warning", Modifier.weight(1f))
                            Text("${SettingsStore.gustLimit} kt", color = Color.Gray)
                            Row(Modifier.padding(start = 8.dp).background(Color(0xFF3A3A3C), RoundedCornerShape(24.dp))) {
                                TextButton(onClick = { SettingsStore.gustLimit(SettingsStore.gustLimit - 5) }, enabled = SettingsStore.gustLimit > 10,
                                    modifier = Modifier.width(40.dp), contentPadding = PaddingValues(0.dp)) { Text("−", color = Color.White, fontSize = 22.sp) }
                                TextButton(onClick = { SettingsStore.gustLimit(SettingsStore.gustLimit + 5) }, enabled = SettingsStore.gustLimit < 50,
                                    modifier = Modifier.width(40.dp), contentPadding = PaddingValues(0.dp)) { Text("+", color = Color.White, fontSize = 22.sp) }
                            }
                        }
                        FormToggle("Track", SettingsStore.trackEnabled, SettingsStore::trackEnabled)
                        FormToggle("Fade Buttons", WatchSession.fadeMapControls, { WatchSession.setFadeMapControls(context, it) })
                        FormLink("Night mode", R.drawable.tool_moon) { WatchSession.nightMode = true }
                        FormToggle("Keep anchor data visible in Night mode", WatchSession.keepNightDataVisible, { WatchSession.setKeepNightDataVisible(context, it) })
                        FormRow(divider = false) {
                            Text("Units", Modifier.weight(1f))
                            FormSegments(listOf("Metric", "Feet"), if (WatchSession.useFeet) 1 else 0) { WatchSession.setUnits(context, it == 1) }
                        }
                    }
                    Text("Track also records while no anchor is set. Anchored watches always record their track.", color = Color.Gray, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp))
                    FormGroup { FormLink("Testing", R.drawable.settings_testing, false) { page = "Testing" } }
                    FormSection("") {
                        FormGroup { FormLink("About Anchor Watch", R.drawable.settings_info, false) { page = "About Anchor Watch" } }
                        Text("Version ${BuildConfig.VERSION_NAME} · Build ${BuildConfig.VERSION_CODE}", color = Color.Gray, modifier = Modifier.padding(horizontal = 12.dp))
                    }
                }
                "Quick Guide" -> PageColumn {
                    SectionCard("Start a watch") {
                        Text("1. Enable GPS on Watch and wait for a fresh, accurate fix.")
                        Text("2. Drop the anchor when it enters the water. Verify the marked position.")
                        Text("3. Enter measured depth and deployed rode on Anchor; review the alarm radius.")
                        Text("4. Keep location and notification permissions enabled, and test the siren under Testing.")
                        Text("5. Raise the anchor to end the watch. After restart, monitoring is off until explicitly resumed.")
                    }
                    SectionCard("Try without GPS") { Text("Settings → Testing → Simulation controls starts a scripted preview. The map remains labeled SIMULATION.") }
                    TextButton(onClick = onGuide) { Text("Open full User Guide") }
                }
                "Review warnings" -> PageColumn {
                    SectionCard("Monitoring") { Text(watchHeadline(), color = watchColor()); WatchSession.error?.let { Text(it) }; WatchSession.audioError?.let { Text(it) } }
                    SectionCard("Weather advisories") {
                        Text(SettingsStore.gustAdvisory ?: if (EnvironmentData.wind == null && EnvironmentData.forecast.isEmpty()) "Weather data unavailable." else "No gust warning in the available next 12 hours.")
                        Text("Gust warning: ${SettingsStore.gustLimit} kt")
                        EnvironmentData.windError?.let { Text(it) }
                    }
                }
                "Anchorage Log" -> PageColumn {
                    if (SettingsStore.log.isEmpty()) Text("No anchorages recorded yet. Real anchor drops and raises are saved here.", color = Color.Gray)
                    SettingsStore.log.forEach { entry ->
                        SectionCard(java.time.Instant.ofEpochMilli(entry.started).atZone(java.time.ZoneId.systemDefault()).format(java.time.format.DateTimeFormatter.ofPattern("MMM d, yyyy · h:mm a"))) {
                            Text(String.format(Locale.US, "%.5f, %.5f", entry.coordinate.latitude, entry.coordinate.longitude))
                            Text("${meters(entry.rode)} rode · ${meters(entry.radius)} circle")
                            Text(entry.ended?.let { "Ended " + java.time.Instant.ofEpochMilli(it).atZone(java.time.ZoneId.systemDefault()).format(java.time.format.DateTimeFormatter.ofPattern("MMM d · h:mm a")) } ?: "Open watch · monitoring may be interrupted", color = Color.Gray)
                        }
                    }
                }
                "About Anchor Watch" -> PageColumn {
                    SectionCard("Nereus Anchor Watch") {
                        Text("${BuildConfig.VERSION_NAME} · Android build ${BuildConfig.VERSION_CODE}")
                        Text("Circle monitoring, online charts, saved boat profile, manual depth and scope planning, Open-Meteo forecasts and NOAA tide predictions.")
                        Text("Boat profile inputs are saved for future load and holding calculations. The current rode graphic is a schematic.")
                        Text("MapLibre Native · © OpenStreetMap contributors · OpenSeaMap · NOAA ENC")
                    }
                }
            }
        }
    }
}

@Composable
internal fun FormSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (title.isNotEmpty()) Text(title, Modifier.padding(start = 16.dp), color = Color.Gray, fontWeight = FontWeight.Bold)
        content()
    }
}
@Composable
internal fun FormGroup(content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(24.dp), color = FormGray, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 16.dp), content = content)
    }
}
@Composable
internal fun FormRow(divider: Boolean = true, content: @Composable RowScope.() -> Unit) {
    Column {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, content = content)
        if (divider) HorizontalDivider(color = Color(0xFF414143))
    }
}
@Composable
private fun FormLink(title: String, icon: Int? = null, divider: Boolean = true, action: () -> Unit) {
    Column(Modifier.clickable(onClick = action)) {
        FormRow(divider) {
            if (icon != null) Icon(painterResource(icon), null, tint = FormBlue, modifier = Modifier.padding(end = 16.dp).size(26.dp))
            Text(title, Modifier.weight(1f), fontWeight = FontWeight.Medium)
            Text("›", color = Color.Gray, fontSize = 30.sp)
        }
    }
}
@Composable
internal fun FormToggle(title: String, value: Boolean, onChange: (Boolean) -> Unit, divider: Boolean = true) {
    FormRow(divider) {
        Text(title, Modifier.weight(1f))
        Switch(value, onCheckedChange = onChange, colors = SwitchDefaults.colors(checkedTrackColor = WatchGreen, checkedThumbColor = Color.White))
    }
}
@Composable
internal fun FormSegments(options: List<String>, selected: Int, onChange: (Int) -> Unit) {
    Row(Modifier.background(Color(0xFF3A3A3C), RoundedCornerShape(22.dp)).padding(3.dp)) {
        options.forEachIndexed { index, text ->
            Box(Modifier.background(if (selected == index) Color(0xFF68686D) else Color.Transparent, RoundedCornerShape(20.dp))
                .clickable { onChange(index) }.padding(horizontal = 12.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
                Text(text, style = MaterialTheme.typography.labelMedium, color = Color.White)
            }
        }
    }
}

@Composable
internal fun FormNumber(title: String, value: Double, unit: String, scale: Double = 1.0, optional: Boolean = false,
    divider: Boolean = true, onChange: (Double?) -> Unit) {
    val focusManager = LocalFocusManager.current
    val formatter = remember { NumberFormat.getNumberInstance(Locale.US).apply { maximumFractionDigits = 1 } }
    fun display() = if (value == 0.0) "" else formatter.format(value * scale)
    var draft by remember(unit) { mutableStateOf(display()) }
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(value, unit, focused) { if (!focused) draft = display() }
    fun commit() {
        if (draft == display()) return // Do not round an unchanged underlying SI value.
        if (draft.isBlank()) onChange(if (optional) null else 0.0)
        else draft.replace(",", "").toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 && it <= 100_000_000 }?.let { onChange(it / scale) }
        draft = display()
    }
    FormRow(divider) {
        Text(title, Modifier.weight(1f))
        BasicTextField(draft, { draft = it }, singleLine = true,
            textStyle = MaterialTheme.typography.bodyLarge.merge(TextStyle(color = Color.White, textAlign = TextAlign.End)),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
            modifier = Modifier.width(110.dp).padding(vertical = 12.dp).semantics { contentDescription = "$title in $unit" }
                .onFocusChanged { if (focused && !it.isFocused) commit(); focused = it.isFocused })
        Text(unit, Modifier.padding(start = 5.dp), color = Color.Gray)
    }
}
