package com.nereus.anchorwatch

import android.content.Context
import androidx.compose.runtime.*
import com.nereus.anchorwatch.core.*
import com.nereus.anchorwatch.calculations.*
import java.time.Instant
import kotlin.math.*

internal object ModelSettings {
    var bottom by mutableStateOf(AnchorConditions.Bottom.MUD); private set
    var scenario by mutableStateOf(AnchorConditions()); private set
    var tideStage by mutableIntStateOf(1)
    private var context: Context? = null
    fun load(c: Context) {
        if (context != null) return
        context = c.applicationContext; val p = c.getSharedPreferences("calculationInputs", Context.MODE_PRIVATE)
        bottom = runCatching { AnchorConditions.Bottom.valueOf(p.getString("bottom", "MUD")!!) }.getOrDefault(AnchorConditions.Bottom.MUD)
        fun n(key: String, fallback: Double) = p.getString(key, null)?.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 } ?: fallback
        scenario = AnchorConditions(wind = n("wind", 15.0), gust = n("gust", 25.0), current = n("current", 0.5), waveHeight = n("wave", 0.3), bottom = bottom,
            direction = runCatching { AnchorConditions.Direction.valueOf(p.getString("direction", "WITH")!!) }.getOrDefault(AnchorConditions.Direction.WITH))
    }
    fun update(c: AnchorConditions) {
        scenario = c; bottom = c.bottom
        context?.getSharedPreferences("calculationInputs", Context.MODE_PRIVATE)?.edit()?.putString("bottom", c.bottom.name)
            ?.putString("wind", c.wind.toString())?.putString("gust", c.gust.toString())?.putString("current", c.current.toString())
            ?.putString("wave", c.waveHeight.toString())?.putString("direction", c.direction.name)?.apply()
    }
}
internal data class CalculationResult(val scope: ScopeSettings, val scenario: AnchorConditions, val assessment: AnchorAssessment?,
    val hours: List<ForecastHour>, val risks: List<Risk>, val coverage: String, val complete: Boolean,
    val estimate: AnchorEstimate.Evaluation, val drift: AnchorDrift.Drift?, val distanceTrend: Double?, val retrieval: RetrievalGuide?,
    val swingRadius: Double, val nearestHazard: Pair<String, Double>?, val pressureChange: Double?)
internal object CalculationEngine {
    var result by mutableStateOf<CalculationResult?>(null); private set
    var droppedAt by mutableStateOf<Long?>(null); private set
    private val centers = mutableListOf<AnchorDrift.Sample>()
    private var lastMinute = -1
    private var confirmations = 0
    private var referenceAnchor: Coordinate? = null
    fun reset(dropped: Long? = null) { droppedAt = dropped; centers.clear(); lastMinute = -1; confirmations = 0; referenceAnchor = null; result = null }
    fun refresh(now: Instant = Instant.now()) {
        val s = WatchSession.scope ?: WatchSession.boatGeometry
        val b = SettingsStore.boat; val monitor = WatchSession.snapshot
        val tide = EnvironmentData.tides
        val live = WaterDepth.liveDepth(now)
        val depths = if (WatchSession.scope != null) (0..144).mapNotNull { i -> val t = now.plusSeconds(i * 600L); WaterDepth.estimated(t)?.let { t to it } } else emptyList()
        val low = depths.minOfOrNull { it.second } ?: live
        val high = WaterMath.dashboard(now, tide, WaterDepth.reference?.takeIf { it.depth == WatchSession.scope?.depth }).depthAtHigh ?: live + s.tideRise
        val depth = when (ModelSettings.tideStage) { 0 -> low; 2 -> high; else -> live }
        val planning = s.copy(depth = depth, tideRise = 0.0)
        val scenario = ModelSettings.scenario.copy(bottom = ModelSettings.bottom, rodeOut = monitor.rode)
        val known = WatchSession.scope != null && BoatMath.windage(b) != null && b.anchorWeight > 0
        val assessment = if (known) AnchorMath.assess(b, planning, scenario) else null
        val hourly = if (known) Outlook.hourly(b, s.copy(depth = live), ModelSettings.bottom, monitor.rode, depths,
            EnvironmentData.forecast.map { ForecastWind(it.time, it.speed, it.gust, it.direction) }, current = { time ->
                EnvironmentData.currents?.let { WaterMath.flow(time, it.events) }?.let { (v, toward) -> Flow(abs(v) * SettingsStore.currentFactor, toward, v >= 0) }
            }, now = now) else emptyList()
        val hazards = Hazards.marks.filter { !it.hidden }.map { ModelHazard(it.id, it.coordinate, it.radius, it.label) }
        val risks = Outlook.items(b, s, monitor.rode, depths, hourly, tide?.events.orEmpty().map { it.time to it.high },
            EnvironmentData.currents?.events?.filter { it.slack }?.map { it.time }, monitor.anchor, hazards, now) { meters(it) }
        val windThrough = Outlook.coverage(EnvironmentData.forecast.map { it.time }, now, 5400)
        val tideThrough = if (depths.isNotEmpty()) depths.last().first else null
        val currentThrough = EnvironmentData.currents?.let { Outlook.coverage(it.events.map { e -> e.time }, now, 18 * 3600) }
        val ends = listOfNotNull(windThrough, tideThrough, currentThrough)
        val uncertain = EnvironmentData.windError != null || EnvironmentData.tideError != null || EnvironmentData.currentError != null
        val complete = ends.size == 3 && ends.all { it >= now.plusSeconds(24 * 3600) } && !uncertain
        val coverage = buildList {
            add(ends.minOrNull()?.let { "Available inputs through ${localTime(it)}" } ?: "No current forecast coverage")
            if (windThrough == null) add("wind unavailable")
            if (tideThrough == null) add("confirmed tide-adjusted depth unavailable")
            if (currentThrough == null) add("current unavailable")
            if (uncertain) add("refresh not confirmed")
            add(if (complete) "24-hour horizon" else "partial horizon")
        }.joinToString(" · ")
        val radius = Outlook.swingRadius(monitor.rode, low, s.bowHeight, s.boatLength / 2)
        WatchSession.refreshFollowingRadius(radius + s.margin)
        val anchor = monitor.anchor
        if (referenceAnchor != anchor) { centers.clear(); confirmations = 0; lastMinute = -1; referenceAnchor = anchor }
        val scale = if (WatchSession.simulation != null) WatchSession.simulationSpeed.toDouble() else 1.0
        val drop = droppedAt
        val track = WatchSession.track.toList()
        val estimate = if (anchor != null && drop != null && freshFix()) AnchorEstimate.evaluate(track, drop, anchor, radius,
            EnvironmentData.wind?.direction, EnvironmentData.wind?.speed, scale) else AnchorEstimate.Evaluation()
        var drift = result?.drift
        if (anchor != null && drop != null && freshFix()) {
            val minute = (((track.lastOrNull()?.time ?: drop) - drop) * scale / 60_000).toInt()
            if (minute != lastMinute) {
                lastMinute = minute
                val sample = AnchorDrift.rollingSample(track, drop, anchor, radius, scale)
                if (sample != null) { centers.add(sample); centers.removeAll { sample.minute - it.minute > 30 } }
                val found = if (sample != null) AnchorDrift.assess(centers) else null
                confirmations = if (found != null) confirmations + 1 else 0
                drift = if (confirmations >= 3) found else null
            }
        } else { drift = null; confirmations = 0 }
        val trend = if (anchor != null && drop != null && freshFix()) AnchorDrift.distanceTrend(track.filter { (it.time - drop) * scale >= 120_000 }
            .map { (it.time - drop) * scale / 60_000 to Geo.distance(anchor, it.coordinate) }, monitor.fix?.accuracy ?: 0.0) else null
        val retrieval = if (anchor != null && freshFix()) monitor.fix?.let { RetrievalGuide.make(it.coordinate, anchor, s.boatLength / 2, live,
            WatchSession.gpsSpeed, WatchSession.gpsCourse) } else null
        val nearest = anchor?.let { a -> hazards.map { it.label to Outlook.clearance(a, radius + s.boatLength / 2, it) }.minByOrNull { it.second } }
        result = CalculationResult(planning, scenario, assessment, hourly, risks, coverage, complete, estimate, drift, trend, retrieval, radius, nearest,
            PressureTrend.change(PressureMonitor.readings.toList(), System.currentTimeMillis()))
    }
}
