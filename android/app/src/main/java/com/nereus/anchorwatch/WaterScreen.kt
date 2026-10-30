package com.nereus.anchorwatch

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
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
import kotlinx.coroutines.delay
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.*

private val WaterBlue = Color(0xFF009AFF)
private val WaterGray = Color(0xFF8E8E93)
private val WaterCard = Color(0xFF1C1C1E)
private fun waterTime(time: Instant) = DateTimeFormatter.ofPattern("EEE h:mm a").withZone(ZoneId.systemDefault()).format(time)
private fun ratio(value: Double) = String.format(Locale.US, "%.1f:1", value)

@Composable
internal fun WaterScreen() {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) { while (true) { now = Instant.now(); delay(30_000) } } }
    val scope = WatchSession.scope ?: WatchSession.boatGeometry
    val confirmed = WatchSession.scope != null
    val depth = WaterDepth.liveDepth(now)
    val tide = EnvironmentData.tides
    val hours = SettingsStore.tideWindowHours
    val factor = SettingsStore.currentFactor
    val until = now.plusSeconds(24 * 3600)
    val times = ((0..96).map { now.plusSeconds(it * 900L) } + tide?.events.orEmpty().filter { it.time >= now && it.time <= until }.map { it.time }).distinct().sorted()
    val points = if (confirmed) times.mapNotNull { t -> WaterDepth.estimated(t)?.let { t to it } } else emptyList()
    // A legacy/manual depth may predate sounder timestamps. Keep the chart visible
    // with an explicitly labeled preview without turning that value into a measurement.
    val previewReference = if (confirmed && WaterDepth.reference == null && tide != null)
        DepthReference(scope.depth, now, tide.station, WaterMath.height(now, tide.events)) else null
    val chartPoints = if (points.size > 1) points else times.mapNotNull { t ->
        tide?.let { previewReference?.depthAt(t, it) }?.let { t to it }
    }
    val low = points.minByOrNull { it.second }
    val high = points.maxByOrNull { it.second }
    val nextHigh = tide?.events?.firstOrNull { it.time > now && it.high }
    val highDepth = nextHigh?.let { WaterDepth.estimated(it.time) } ?: (depth + scope.tideRise)
    val plan = scope.copy(depth = highDepth, tideRise = 0.0)
    val suggested = WatchSession.suggestedWatchRadius()
    fun setDepth(value: Double) {
        WatchSession.setScope(context, scope.copy(depth = value))
        WaterDepth.confirm(context, value)
        now = Instant.now()
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
        FormSection("Water depth below the surface") {
            WaterGroup {
                WaterStepper(depth, "Water depth", 44) { setDepth(it) }
                WaterNote("Use depth from the water surface to the seabed. Correct sounder readings shown below the keel or transducer before entering.")
                WaterRule()
                WaterNote(WaterDepth.detail(now))
                WaterRule()
                WaterAction("Confirm this depth as a new sounder reading") { setDepth(depth) }
            }
        }
        FormSection("Depth at the anchorage, next 24 hours") {
            WaterGroup {
                DepthChart(chartPoints, tide?.events.orEmpty(), SettingsStore.boat.draft)
                if (chartPoints.size > 1) {
                    if (points.size < 2) WaterNote("Preview assumes the entered depth is the depth now. Confirm a sounder reading above to use this forecast for your anchorage.")
                } else WaterNote(if (!confirmed || WaterDepth.reference == null) "Confirm a sounder reading to show tide-adjusted depth." else "Depth forecast unavailable. Tide predictions must cover the sounder reading and forecast times.")
            }
            WaterNote(WaterDepth.detail(now) + " From the depth you set and the nearest station predictions. Red is your keel; orange dashed is ${meters(0.6096)} under it.")
        }
        FormSection("Outlook") {
            WaterGroup {
                WaterValue("Depth now", if (confirmed) meters(depth) else "Confirm depth")
                if (low != null && high != null) {
                    val clearance = low.second - SettingsStore.boat.draft
                    WaterValue("Lowest, ${waterTime(low.first)}", "${meters(low.second)} · ${meters(clearance)} under keel", stacked = true,
                        color = if (clearance <= 0) Color.Red else if (clearance < 0.6096) WatchOrange else WaterGray)
                    WaterValue("Highest, ${waterTime(high.first)}", meters(high.second))
                    val atHigh = WatchSession.snapshot.rode / (high.second + scope.bowHeight).coerceAtLeast(0.001)
                    val atLow = WatchSession.snapshot.rode / (low.second + scope.bowHeight).coerceAtLeast(0.001)
                    WaterValue("Scope with ${meters(WatchSession.snapshot.rode, 0)} out", "${ratio(atHigh)} at high · ${ratio(atLow)} at low", stacked = true)
                    WaterNote(when {
                        clearance <= 0 -> "Predicted water reaches the keel near ${waterTime(low.first)}. Check depth and anchorage clearance."
                        clearance < 0.6096 -> "Less than ${meters(0.6096)} predicted under the keel near ${waterTime(low.first)}."
                        atHigh < 4 -> "Scope drops to ${ratio(atHigh)} at high water. Review deployed rode and swing clearance."
                        else -> "No depth or scope issue found through ${waterTime(points.last().first)}. Later conditions are not assessed here."
                    }, if (clearance < 0.6096 || atHigh < 4) WatchOrange else WaterGray)
                } else WaterNote("Depth and scope outlook needs a confirmed sounder reading and tide coverage.")
            }
        }
        FormSection("Current") {
            WaterGroup {
                val current = EnvironmentData.currents
                if (current != null) {
                    WaterStation(current.station, "${String.format(Locale.US, "%.0f", current.distance / 1000)} km away · NOAA current predictions")
                    WaterMath.flow(now, current.events)?.let { (velocity, toward) ->
                        WaterValue("Here now (estimated)", if (abs(velocity * factor) < 0.1) "Slack" else
                            "${String.format(Locale.US, "%.1f", abs(velocity) * factor)} kt toward ${compass(toward)} (${if (velocity >= 0) "flood" else "ebb"})", stacked = true)
                    }
                    current.events.filter { it.time > now }.take(4).forEach { e ->
                        WaterValue(if (e.slack) "Slack" else if (e.velocity >= 0) "Strongest flood" else "Strongest ebb",
                            waterTime(e.time) + if (e.slack) "" else " · ${String.format(Locale.US, "%.1f", abs(e.velocity) * factor)} kt ${compass(if (e.velocity >= 0) e.floodToward else e.ebbToward)}")
                    }
                    WaterNote("Estimated anchorage speed = station prediction × ${(factor * 100).toInt()}%. This scaling is an assumption.")
                    WaterValue("Current here vs the station", "${(factor * 100).toInt()}%", divider = false)
                    Row(Modifier.fillMaxWidth().padding(bottom = 10.dp), horizontalArrangement = Arrangement.Center) {
                        FormSegments(listOf("100%", "50%", "25%"), listOf(1.0, 0.5, 0.25).indexOf(factor)) { SettingsStore.currentFactor(listOf(1.0, 0.5, 0.25)[it]) }
                    }
                } else WaterNote(EnvironmentData.currentError ?: if (EnvironmentData.loading) "Loading current predictions…" else "Current predictions not loaded; waiting for a location.")
                WaterAction("Retry current data", enabled = !EnvironmentData.loading) { EnvironmentData.refresh++ }
            }
            WaterNote("Stations are mostly in channels, where currents can run harder than at a sheltered anchorage. Use 100% if anchored in the channel itself.")
        }
        FormSection("Tide") {
            WaterGroup {
                WaterNote(environmentLocationLabel())
                if (EnvironmentData.loading) WaterNote("Refreshing environmental data…")
                if (tide != null) {
                    tide.selectionNote?.let { WaterNote(it, WatchOrange) }
                    EnvironmentData.tideError?.let { WaterNote("Refresh failed: $it. Showing previously fetched predictions.", WatchOrange) }
                    WaterStation(tide.station, "${String.format(Locale.US, "%.0f", tide.distance / 1000)} km away · ${tide.source} · heights above ${tide.datum}")
                    WaterMath.height(now, tide.events)?.let { WaterValue("Right now (estimated)", meters(it)) }
                    tide.events.filter { it.time > now }.take(4).forEach { e -> WaterValue(if (e.high) "High" else "Low", "${waterTime(e.time)} · ${meters(e.height)}") }
                    Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalArrangement = Arrangement.Center) {
                        FormSegments(listOf("6 h", "12 h", "24 h"), listOf(6, 12, 24).indexOf(hours)) { SettingsStore.tideWindowHours(listOf(6, 12, 24)[it]) }
                    }
                    val base = WaterMath.height(now, tide.events)
                    val end = now.plusSeconds(hours * 3600L)
                    val candidates = tide.events.filter { it.time > now && it.time <= end }.map { it.height } + listOfNotNull(WaterMath.height(end, tide.events), base)
                    val rise = base?.let { (candidates.maxOrNull()!! - it).coerceAtLeast(0.0) }
                    if (rise != null) WaterAction("Use tide data: +${meters(rise)}", enabled = confirmed) { WatchSession.setScope(context, scope.copy(tideRise = rise)) }
                    WaterRule()
                    EnvironmentData.tideFetched?.let { WaterNote("${tide.source} / tides · ${tide.station} · fetched ${localTime(it)} · predictions through ${waterTime(tide.events.last().time)}") }
                } else WaterNote(EnvironmentData.tideError ?: if (EnvironmentData.loading) "Loading tide predictions…" else "Tide predictions not loaded; waiting for a location.")
                WaterAction("Refresh tide data", enabled = !EnvironmentData.loading) { EnvironmentData.refresh++ }
                WaterRule()
                WaterNote("Stations are selected by distance, not by matching the local tide regime. Verify these predictions for your anchorage before using tide-adjusted depth. Predictions do not include storm surge.")
                WaterRule()
                WaterStepper(scope.tideRise, "Expected tide rise", 30, "expected rise above this depth ($lengthUnit)", enabled = confirmed) {
                    WatchSession.setScope(context, scope.copy(tideRise = it))
                }
                WaterValue("Depth to cover at high water", if (confirmed) meters(highDepth, 0) else "Confirm depth", divider = false)
            }
        }
        FormSection("Scope") {
            WaterGroup {
                Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalArrangement = Arrangement.Center) {
                    FormSegments(listOf("3:1", "5:1", "7:1", "10:1"), listOf(3.0, 5.0, 7.0, 10.0).indexOf(scope.scopeRatio)) {
                        if (confirmed) WatchSession.setScope(context, scope.copy(scopeRatio = listOf(3.0, 5.0, 7.0, 10.0)[it]))
                    }
                }
                WaterRule()
                WaterValue("Rode to pay out", if (confirmed) meters(plan.suggestedRode, 0) else "Confirm depth", bold = true)
                val boat = SettingsStore.boat
                val available = when (boat.rodeType) {
                    BoatProfile.RodeType.ALL_CHAIN -> boat.chainLength
                    BoatProfile.RodeType.CHAIN_AND_ROPE -> boat.chainLength + boat.ropeLength
                    BoatProfile.RodeType.ROPE -> boat.ropeLength
                }
                if (confirmed && plan.suggestedRode > available) WaterNote("That's ${meters(plan.suggestedRode - available)} more rode than the boat carries.", WatchOrange)
                WaterValue("Suggested alarm radius", if (confirmed) meters(suggested, 0) else "—")
                WaterAction("Use suggested radius", enabled = confirmed) { WatchSession.setRadiusFollowing(context, true) }
                WaterRule()
                WaterNote("Rode = ratio × (depth + tide + ${meters(scope.bowHeight, 0)} bow height). Change the bow height and boat length in Settings → Boat Profile.")
            }
        }
        if (WatchSession.simulation != null) WaterNote("Live provider data is for the simulation location; it does not drive scripted boat motion.", WatchOrange)
        Spacer(Modifier.height(12.dp))
    }
}

private fun compass(degrees: Double): String = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")[(round(degrees / 45).toInt() % 8 + 8) % 8]
@Composable private fun WaterGroup(content: @Composable ColumnScope.() -> Unit) {
    Surface(color = WaterCard, shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 16.dp), content = content)
    }
}
@Composable private fun WaterRule() { HorizontalDivider(color = Color(0xFF38383A)) }
@Composable private fun WaterNote(text: String, color: Color = WaterGray) {
    Text(text, Modifier.padding(vertical = 10.dp), color = color, style = MaterialTheme.typography.bodySmall)
}
@Composable private fun WaterStation(name: String, detail: String) {
    Column(Modifier.padding(vertical = 12.dp)) { Text(name, fontWeight = FontWeight.Bold); Text(detail, color = WaterGray, style = MaterialTheme.typography.bodySmall) }
    WaterRule()
}
@Composable private fun WaterValue(label: String, value: String, stacked: Boolean = false, color: Color = WaterGray, bold: Boolean = false, divider: Boolean = true) {
    if (stacked) Column(Modifier.padding(vertical = 12.dp)) { Text(label, fontWeight = if (bold) FontWeight.Bold else FontWeight.Medium); Text(value, color = color, style = MaterialTheme.typography.bodyMedium) }
    else Row(Modifier.fillMaxWidth().padding(vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), fontWeight = if (bold) FontWeight.Bold else FontWeight.Medium)
        Text(value, color = color, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.End)
    }
    if (divider) WaterRule()
}
@Composable private fun WaterAction(text: String, enabled: Boolean = true, action: () -> Unit) {
    TextButton(onClick = action, enabled = enabled, contentPadding = PaddingValues(vertical = 12.dp)) { Text(text, color = if (enabled) WaterBlue else WaterGray, style = MaterialTheme.typography.bodySmall) }
}
@Composable private fun WaterStepper(value: Double, label: String, size: Int, caption: String? = null, enabled: Boolean = true, onChange: (Double) -> Unit) {
    val focus = LocalFocusManager.current
    var editing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf(number(value)) }
    LaunchedEffect(value, WatchSession.useFeet, editing) { if (!editing) draft = number(value) }
    fun commit() {
        editedLength(draft, value)?.takeIf { it.isFinite() && it in 0.0..1000.0 }?.let(onChange)
        draft = number(value)
    }
    val step = if (WatchSession.useFeet) 0.3048 else 0.5
    Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        StepCircle("−", "Decrease $label", enabled) { focus.clearFocus(); onChange((value - step).coerceAtLeast(0.0)) }
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                BasicTextField(draft, { draft = it }, enabled = enabled, singleLine = true,
                    textStyle = TextStyle(color = Color.White, fontSize = size.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
                    modifier = Modifier.widthIn(max = 180.dp).weight(1f, fill = false).semantics { contentDescription = "$label in $lengthUnit" }
                        .onFocusChanged { if (editing && !it.isFocused) commit(); editing = it.isFocused })
                if (caption == null) Text(lengthUnit, color = WaterGray, modifier = Modifier.padding(start = 8.dp))
            }
            caption?.let { Text(it, color = WaterGray, style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.Center) }
        }
        StepCircle("+", "Increase $label", enabled) { focus.clearFocus(); onChange((value + step).coerceAtMost(1000.0)) }
    }
}
@Composable private fun StepCircle(symbol: String, description: String, enabled: Boolean, action: () -> Unit) {
    TextButton(onClick = action, enabled = enabled, modifier = Modifier.size(48.dp).semantics { contentDescription = description }, contentPadding = PaddingValues(8.dp)) {
        Box(Modifier.size(30.dp).background(if (enabled) WaterBlue else Color.DarkGray, CircleShape), contentAlignment = Alignment.Center) {
            Text(symbol, color = Color.Black, fontSize = 24.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable private fun DepthChart(points: List<Pair<Instant, Double>>, events: List<TidePrediction>, draft: Double) {
    val unit = lengthUnit
    val scale = if (WatchSession.useFeet) 1 / 0.3048 else 1.0
    val summary = if (points.size > 1) "Depth forecast. Lowest ${meters(points.minOf { it.second })}, highest ${meters(points.maxOf { it.second })}. Keel ${meters(draft)}." else "Depth chart awaiting a sounder reading and tide predictions."
    Canvas(Modifier.fillMaxWidth().height(240.dp).padding(vertical = 12.dp).semantics { contentDescription = summary }) {
        val left = 2.dp.toPx(); val top = 32.dp.toPx(); val right = size.width - 30.dp.toPx(); val bottom = size.height - 25.dp.toPx()
        val maximum = max(max((points.maxOfOrNull { it.second } ?: draft * 2) * 1.15, draft + 0.6096), 1.0)
        val chartStart = points.firstOrNull()?.first ?: Instant.now()
        val start = chartStart.toEpochMilli()
        val end = start + 24 * 3600_000L
        fun x(t: Instant) = left + (right - left) * ((t.toEpochMilli() - start).toDouble() / (end - start)).toFloat()
        fun y(d: Double) = bottom - (bottom - top) * (d / maximum).toFloat()
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.rgb(142, 142, 147); textSize = 10.sp.toPx() }
        fun label(text: String, x: Float, y: Float, align: android.graphics.Paint.Align = android.graphics.Paint.Align.LEFT, color: Int = android.graphics.Color.rgb(142,142,147)) {
            paint.textAlign = align; paint.color = color
            drawContext.canvas.nativeCanvas.drawText(text, x, y, paint)
        }
        for (i in 0..4) {
            val d = maximum * i / 4
            drawLine(Color.Gray.copy(alpha = 0.2f), Offset(left, y(d)), Offset(right, y(d)), 1.dp.toPx())
            label(String.format(Locale.US, "%.0f", d * scale), right + 5.dp.toPx(), y(d) + 3.dp.toPx())
        }
        label("depth ($unit)", right, 10.dp.toPx(), android.graphics.Paint.Align.RIGHT)
        val hour = DateTimeFormatter.ofPattern("h a").withZone(ZoneId.systemDefault())
        for (i in 1..3) {
            val t = chartStart.plusSeconds(i * 6 * 3600L); val px = x(t)
            drawLine(Color.Gray.copy(alpha = 0.2f), Offset(px, top), Offset(px, bottom), 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 3.dp.toPx())))
            label(hour.format(t), px, bottom + 18.dp.toPx(), android.graphics.Paint.Align.CENTER)
        }
        if (points.size < 2) {
            label("Awaiting depth and tide data", (left + right) / 2, (top + bottom) / 2, android.graphics.Paint.Align.CENTER)
            return@Canvas
        }
        val line = Path().apply { points.forEachIndexed { i, p -> if (i == 0) moveTo(x(p.first), y(p.second)) else lineTo(x(p.first), y(p.second)) } }
        val area = Path().apply { addPath(line); lineTo(x(points.last().first), bottom); lineTo(x(points.first().first), bottom); close() }
        drawPath(area, Brush.verticalGradient(listOf(WaterBlue.copy(alpha = 0.5f), WaterBlue.copy(alpha = 0.06f)), startY = top, endY = bottom))
        drawPath(line, WaterBlue, style = Stroke(2.dp.toPx()))
        if (draft > 0) {
            drawLine(Color.Red.copy(alpha = 0.8f), Offset(left, y(draft)), Offset(right, y(draft)), 1.dp.toPx())
            drawLine(WatchOrange.copy(alpha = 0.7f), Offset(left, y(draft + 0.6096)), Offset(right, y(draft + 0.6096)), 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())))
            label("Keel ${meters(draft)}", left, y(draft) - 4.dp.toPx(), color = android.graphics.Color.rgb(255,80,80))
        }
        events.filter { it.time >= points.first().first && it.time <= points.last().first }.forEach { event ->
            val depth = points.minByOrNull { abs(it.first.toEpochMilli() - event.time.toEpochMilli()) }?.second ?: return@forEach
            val px = x(event.time); val py = y(depth)
            drawCircle(if (event.high) Color.Cyan else WatchOrange, 3.dp.toPx(), Offset(px, py))
            val labelY = if (event.high) py - 18.dp.toPx() else py + 16.dp.toPx()
            val safeX = px.coerceIn(left + 30.dp.toPx(), right - 30.dp.toPx())
            label(if (event.high) "High" else "Low", safeX, labelY, android.graphics.Paint.Align.CENTER)
            label(DateTimeFormatter.ofPattern("h:mm a").withZone(ZoneId.systemDefault()).format(event.time), safeX, labelY + 11.dp.toPx(), android.graphics.Paint.Align.CENTER)
        }
    }
}
