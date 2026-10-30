package com.nereus.anchorwatch

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.BatteryManager
import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nereus.anchorwatch.calculations.*
import kotlin.math.*

private fun modelColor(status: ModelStatus) = when (status) { ModelStatus.GOOD -> WatchGreen; ModelStatus.MARGINAL -> WatchOrange; ModelStatus.DANGER -> Color(0xFFFF453A) }
internal fun force(newtons: Double?) = newtons?.let { if (WatchSession.useFeet) "%.0f lbf".format(it / 4.44822) else "%.0f kgf".format(it / 9.80665) } ?: "—"
@Composable internal fun AnchoringCalculations() {
    val r = CalculationEngine.result
    SectionCard("Planning scenario · estimated capacity") {
        val a = r?.assessment
        if (a == null) Text("Confirm water depth and enter boat windage and anchor weight before assessing modeled capacity.", color = WatchOrange)
        else {
            Text(when (a.status) { ModelStatus.GOOD -> "Within modeled limits"; ModelStatus.MARGINAL -> "Close to modeled limits"; ModelStatus.DANGER -> "Beyond modeled limits" }, color = modelColor(a.status), fontWeight = FontWeight.Bold)
            Text("Estimated gust limit ${a.safeGust?.let { "%.0f kt".format(it) } ?: "unavailable"}", style = MaterialTheme.typography.titleLarge)
            Text("This model uses the conditions below. It does not confirm that the anchor is holding or that the circle alarm is ready.", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
            a.safeGust?.let { limit -> TextButton(onClick = { SettingsStore.gustLimit(limit.toInt()) }) { Text("Set gust warning to ${limit.toInt().coerceIn(10,50)} kt") } }
        }
    }
}

@Composable internal fun AnchoringCalculationDetails() {
    val r = CalculationEngine.result
    SectionCard("Scenario inputs") {
        val c = ModelSettings.scenario
        Choice("Seabed", ModelSettings.bottom.title, AnchorConditions.Bottom.entries.map { it.title }) { ModelSettings.update(c.copy(bottom = AnchorConditions.Bottom.entries[it])) }
        NumericAdjustment("Wind", c.wind, 0.0..100.0, 1.0, 1.0, "kt") { ModelSettings.update(c.copy(wind = it)) }
        NumericAdjustment("Gust", c.gust, 0.0..150.0, 1.0, 1.0, "kt") { ModelSettings.update(c.copy(gust = it)) }
        NumericAdjustment("Current", c.current, 0.0..10.0, 0.1, 0.1, "kt") { ModelSettings.update(c.copy(current = it)) }
        NumericAdjustment("Wave height", c.waveHeight, 0.0..10.0, 0.5, 0.1) { ModelSettings.update(c.copy(waveHeight = it)) }
        Choice("Current relative to wind", c.direction.title, AnchorConditions.Direction.entries.map { it.title }) { ModelSettings.update(c.copy(direction = AnchorConditions.Direction.entries[it])) }
        TextButton(enabled = EnvironmentData.wind != null, onClick = {
            val w = EnvironmentData.wind ?: return@TextButton
            val flow = EnvironmentData.currents?.let { WaterMath.flow(java.time.Instant.now(), it.events) }
            val direction = flow?.let { val angle = Outlook.difference((w.direction + 180) % 360, it.second)
                if (angle <= 45) AnchorConditions.Direction.WITH else if (angle >= 135) AnchorConditions.Direction.AGAINST else AnchorConditions.Direction.ACROSS } ?: c.direction
            ModelSettings.update(c.copy(wind = w.speed, gust = w.gust, current = flow?.first?.let { abs(it) * SettingsStore.currentFactor } ?: c.current, direction = direction))
        }) { Text("Use current weather and tide-current estimates") }
        Text("Wind/gust/current are scenario inputs until you choose the provider estimates. Wave height and seabed are always assumptions you must check.", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
        FormSegments(listOf("Low tide", "Now", "High tide"), ModelSettings.tideStage) { ModelSettings.tideStage = it }
        Text("Modeled water depth ${r?.let { meters(it.scope.depth) } ?: "—"}. Without tide-adjusted depth, low uses entered depth and high uses the manual allowance.", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
    }
    r?.assessment?.let { a ->
        SectionCard("Loads and rode") {
            Text("Design pull ${force(a.load.design)} · reaching anchor ${force(a.anchorLoad)}")
            Text("Wind ${force(a.load.wind)} · current ${force(a.load.current)} · chain friction ${force(a.chainFriction)}")
            Text("Estimated holding ${force(a.holding)} · safety factor ${AnchorMath.holdingSafety}")
            Text("Chain on bottom ${meters(a.shape.lying)} · shank angle %.1f°".format(a.shape.shankAngle))
            Text("Chain lift-off ${force(a.liftOffLoad)} · ${a.liftOffGust?.let { "%.0f kt".format(it) } ?: "not chain-only"}")
            if (r.scenario.rodeOut > SettingsStore.boat.rodeCarried) Text("Entered deployed rode exceeds the boat's carried rode. Verify Boat Profile and actual rode.", color = WatchOrange)
            a.rodeNeeded?.let { Text("Rode to retain bottom contact ${meters(it)}") }
            BoatMath.deepestWater(SettingsStore.boat, r.scope.scopeRatio, r.scope.bowHeight)?.let { Text("Deepest water at selected scope with carried rode ${meters(it)}") }
            AnchorMath.suggestions(SettingsStore.boat, r.scope, r.scenario, a) { meters(it) }.forEach { Text(it, style = MaterialTheme.typography.bodyMedium) }
        }
    }
    ForecastCalculations()
}
@Composable private fun Choice(title: String, selected: String, options: List<String>, choose: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box { TextButton(onClick = { open = true }) { Text("$title: $selected ⌄") }
        DropdownMenu(open, { open = false }) { options.forEachIndexed { i, value -> DropdownMenuItem(text = { Text(value) }, onClick = { choose(i); open = false }) } }
    }
}
@Composable internal fun ForecastCalculations() {
    val r = CalculationEngine.result
    SectionCard("Anchorage forecast · next 24 hours") {
        Text(r?.coverage ?: "Collecting forecast inputs…", style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        if (r == null || r.hours.isEmpty()) Text("No modeled wind outlook yet. Confirm depth and boat profile and load weather data.")
        else {
            val caution = r.risks.filter { it.severity >= Severity.CAUTION }
            if (caution.isEmpty()) Text(if (r.complete) "No modeled depth, scope, gust or hazard exceedance found in the next 24 hours." else "No exceedance found in the available inputs. Unassessed conditions remain.", color = if (r.complete) WatchGreen else WatchOrange)
            r.risks.forEach { risk ->
                Column(Modifier.padding(vertical = 5.dp)) {
                    Text(risk.title, color = when (risk.severity) { Severity.DANGER -> Color(0xFFFF453A); Severity.CAUTION -> WatchOrange; else -> Color.White }, fontWeight = FontWeight.SemiBold)
                    Text(localTime(risk.start) + (risk.end?.let { " – ${localTime(it)}" } ?: ""), color = Color.Gray, style = MaterialTheme.typography.labelSmall)
                    Text(risk.detail, style = MaterialTheme.typography.bodySmall)
                }
            }
            Text("Bottom ${ModelSettings.bottom.title}; forecast wave assumption ${meters(0.3)}. Missing current uses the iOS scenario default of 0.5 kt for loads; missing depth uses entered depth. These assumptions are not measurements.", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
        }
    }
    if (r != null && r.hours.isNotEmpty()) SectionCard("Hourly modeled gust limits") {
        r.hours.forEach { h -> Text("${localTime(h.time)} · gust ${h.gust.roundToInt()} kt / limit ${h.safeGust?.roundToInt() ?: "—"} kt · depth ${meters(h.depth)}", color = modelColor(h.status), style = MaterialTheme.typography.bodySmall) }
    }
    SectionCard("Barometer") {
        Text(PressureMonitor.readings.lastOrNull()?.let { "%.1f hPa".format(it.hPa) } ?: if (PressureMonitor.available) "Collecting pressure readings…" else "No handset barometer available")
        val change = r?.pressureChange
        Text(change?.let { "%+.1f hPa over 3 hours · %s".format(it, when (PressureTrend.level(it)) {
            PressureTrend.Level.STEADY -> "no rapid fall"; PressureTrend.Level.FALLING_QUICKLY -> "falling quickly"; PressureTrend.Level.FALLING_FAST -> "falling very fast · gale risk"
        }) } ?: "Needs at least 2.4 hours of onboard history for a three-hour trend.", color = if (change != null && change <= -3) WatchOrange else Color.Gray)
    }
}
@Composable internal fun TrackingCalculations() {
    val r = CalculationEngine.result ?: return
    if (WatchSession.snapshot.anchor == null) return
    var expanded by remember { mutableStateOf(false) }
    r.drift?.let { Text("Possible anchor drift · ${meters(it.distance)}. Check actual movement now.", color = Color(0xFFFF453A), fontWeight = FontWeight.Bold) }
    r.distanceTrend?.let { Text("Moving beyond prior reach · check for dragging", color = WatchOrange) }
    TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "Hide swing analysis" else "Swing analysis and retrieval") }
    if (!expanded) return
    if (WatchSession.snapshot.anchor != null) SectionCard("Swing and anchor position") {
        Text("Modeled phone swing radius ${meters(r.swingRadius)}")
        r.nearestHazard?.let { Text("Full-swing clearance to ${it.first}: ${meters(it.second)}", color = if (it.second <= 0) Color(0xFFFF453A) else if (it.second < 10) WatchOrange else Color.Gray) }
        val e = r.estimate.estimate
        if (e == null) Text(r.estimate.uncertainty?.let { "Estimate too uncertain: ±${meters(it)}" } ?: "Collecting swing evidence: %.1f / 20 minutes after settling".format(r.estimate.minutes), color = Color.Gray)
        else {
            Text("Estimated anchor: %.5f, %.5f".format(e.center.latitude, e.center.longitude))
            Text("Error ellipse ±${meters(e.semiMajor)} × ${meters(e.semiMinor)} · %.0f° axis".format(e.majorBearing))
            Text("${if (e.method == AnchorEstimate.Method.FREE) "Free circle fit" else "Radius-constrained fit"} · %.0f° swing · ${e.pointsUsed} edge samples".format(e.arc))
            Text(when (e.windAgrees) { true -> "Wind cross-check agrees"; false -> "Wind cross-check disagrees; verify position"; null -> "Wind cross-check unavailable" }, color = if (e.windAgrees == false) WatchOrange else Color.Gray)
            Text("The estimate does not move the marked anchor.", style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        }
        r.drift?.let { Text("Inferred anchor drift: ${meters(it.distance)} toward %.0f° · %.1f m/min".format(it.bearing, it.metersPerMinute), color = Color(0xFFFF453A), fontWeight = FontWeight.Bold) }
        r.distanceTrend?.let { Text("Boat moving beyond prior reach: %.1f m/min. Check for dragging.".format(it), color = WatchOrange) }
        if (r.drift == null && r.distanceTrend == null) Text("No confirmed drift signal. This does not prove holding.", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
    }
    r.retrieval?.let { guide -> SectionCard("Retrieval guidance") {
        Text("Bow to anchor ${meters(guide.distance)} · %.0f° true".format(guide.bearing))
        Text(guide.steer, style = MaterialTheme.typography.titleMedium)
        Text("GPS course is used only above 0.25 m/s. Without course, the bow is assumed to lie toward the anchor. Verify aboard.", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
    } }
}
@Composable internal fun ReadinessCalculations() {
    val context = LocalContext.current
    val audio = context.getSystemService(AudioManager::class.java)
    val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_ALARM).coerceAtLeast(1)
    val volume = audio.getStreamVolume(AudioManager.STREAM_ALARM).toDouble() / maximum
    val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
    val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
    val charging = (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
    val notifications = (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) && context.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled()
    SectionCard("Phone readiness") {
        Text("Alarm volume ${(volume * 100).roundToInt()}%", color = if (volume < 0.2) Color(0xFFFF453A) else if (volume < 0.5) WatchOrange else WatchGreen)
        if (level >= 0) { val percent = level * 100.0 / scale.coerceAtLeast(1)
            Text("Battery %.0f%%${if (charging) " · charging" else " · not charging"}".format(percent), color = if (!charging && percent <= 15) Color(0xFFFF453A) else if (!charging && percent < 30) WatchOrange else WatchGreen) }
        Text(if (notifications) "Notifications permitted" else "Notifications disabled", color = if (notifications) WatchGreen else WatchOrange)
        WatchSession.snapshot.fix?.let { fix ->
            Text("GPS ±${meters(fix.accuracy)}" + if (!freshFix()) " · stale" else "", color = if (!freshFix() || fix.accuracy > 50) Color(0xFFFF453A) else if (fix.accuracy > 8) WatchOrange else WatchGreen)
            if (WatchSession.snapshot.radius < fix.accuracy * 2.5) Text("Circle is small for this GPS accuracy; false alarms are more likely.", color = WatchOrange)
        } ?: Text("Waiting for GPS", color = WatchOrange)
        WatchSession.audioError?.let { Text("Siren unavailable: $it", color = Color(0xFFFF453A)) }
        Text("Test the siren and verify its audio route on this phone. Android foreground monitoring and battery restrictions must be checked aboard.", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
    }
}
