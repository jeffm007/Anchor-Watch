package com.nereus.anchorwatch

import android.content.Context
import android.os.SystemClock
import androidx.compose.runtime.*
import com.nereus.anchorwatch.core.*
import com.nereus.anchorwatch.calculations.*

internal enum class SimulationHarbor(val title: String, val coordinate: Coordinate) {
    ROCHE("Roche Harbor, WA", Coordinate(48.6118, -123.1575)),
    SIDNEY("Sidney Harbour, BC", Coordinate(48.6500, -123.3900))
}

/** Updated only on the main thread, including service/location callbacks. */
internal object WatchSession {
    private var liveOriginalAnchor by mutableStateOf<Coordinate?>(null)
    private var simulationOriginalAnchor by mutableStateOf<Coordinate?>(null)
    val originalAnchor get() = if (simulation != null) simulationOriginalAnchor else liveOriginalAnchor
    fun clearOriginalAnchor(context: Context) {
        // Promote the corrected position so the next correction measures from here.
        val current = monitor.anchor ?: return
        if (simulation != null) simulationOriginalAnchor = current else liveOriginalAnchor = current
        save(context)
    }
    fun moveAnchor(context: Context, at: Coordinate) {
        val previous = monitor.anchor ?: return
        if (simulation != null) {
            if (simulationOriginalAnchor == null) simulationOriginalAnchor = previous
        } else if (liveOriginalAnchor == null) liveOriginalAnchor = previous
        CalculationEngine.reset(now())
        monitor.moveAnchor(at)
        save(context)
    }
    private var liveRadiusFollows by mutableStateOf(false)
    private var simulationRadiusFollows by mutableStateOf(true)
    val radiusFollowsRode get() = if (simulation != null) simulationRadiusFollows else liveRadiusFollows
    private fun followRadius() {
        val settings = scope ?: return
        if (radiusFollowsRode) monitor.setRadius(suggestedWatchRadius())
    }
    fun suggestedWatchRadius(): Double {
        val settings = scope ?: boatGeometry
        val now = java.time.Instant.now()
        val low = (0..144).mapNotNull { WaterDepth.estimated(now.plusSeconds(it * 600L)) }.minOrNull() ?: WaterDepth.liveDepth(now)
        return (Outlook.swingRadius(monitor.rode, low, settings.bowHeight, settings.boatLength / 2) + settings.margin).coerceIn(10.0, 300.0)
    }
    fun refreshFollowingRadius(value: Double) {
        if (scope != null && radiusFollowsRode && kotlin.math.abs(monitor.radius - value) > 0.05) { monitor.setRadius(value.coerceIn(10.0, 300.0)); publish() }
    }
    fun setRadiusFollowing(context: Context, follow: Boolean) {
        if (simulation != null) simulationRadiusFollows = follow else liveRadiusFollows = follow
        if (follow) followRadius()
        save(context)
    }
    fun setRadiusByHand(context: Context, value: Double) {
        monitor.setRadius(value)
        if (simulation != null) simulationRadiusFollows = false else liveRadiusFollows = false
        save(context)
    }
    fun setRode(context: Context, value: Double) {
        monitor.setRode(value); followRadius(); save(context)
    }
    private val liveMonitor = AnchorMonitor()
    private var previewMonitor: AnchorMonitor? = null
    val monitor get() = previewMonitor ?: liveMonitor
    var gpsSpeed by mutableStateOf<Double?>(null)
    var gpsCourse by mutableStateOf<Double?>(null)
    var physicsDay by mutableStateOf<SimulationDay?>(null); private set
    private var physics: AnchorPhysics? = null
    private fun physicalBoat(): AnchorPhysics.Boat {
        val b = SettingsStore.boat; val s = scope ?: boatGeometry
        val c = ModelSettings.scenario.copy(rodeOut = monitor.rode)
        val r = AnchorMath.assess(b, s, c)
        val allChain = b.rodeType == BoatProfile.RodeType.ALL_CHAIN || (b.rodeType == BoatProfile.RodeType.CHAIN_AND_ROPE && monitor.rode <= b.chainLength)
        return AnchorPhysics.Boat(monitor.rode, s.depth, s.bowHeight, if (allChain) AnchorMath.chainWeight(b.chainSize) else 0.0,
            BoatMath.windage(b) ?: 0.0, BoatMath.sideWindage(b, s.boatLength) ?: 0.0, b.beam * b.draft * 0.6,
            b.loadedWeight.coerceAtLeast(1.0), s.boatLength / 2, r.holding ?: 0.0)
    }
    fun startPhysics(day: SimulationDay) {
        check(scope != null && SettingsStore.boat.displacement > 0 && SettingsStore.boat.anchorWeight > 0 && BoatMath.windage(SettingsStore.boat) != null)
        startSimulation(SimulationMode.SWING)
        physicsDay = day; physics = AnchorPhysics(physicalBoat(), day.weather())
    }
    var simulationServiceRunning by mutableStateOf(false)
    var simulation by mutableStateOf<SimulationMode?>(null); private set
    var simulationSpeed by mutableStateOf(5); private set
    var simulationSeconds by mutableStateOf(0.0); private set
    var simulationPaused by mutableStateOf(false); private set
    private var savedTrack = emptyList<Fix>()
    var simulationHarbor by mutableStateOf(SimulationHarbor.ROCHE); private set
    val simulationOrigin get() = simulationHarbor.coordinate
    fun changeSimulationHarbor(harbor: SimulationHarbor) {
        if (harbor == simulationHarbor) return
        simulationHarbor = harbor
        val day = physicsDay
        simulation?.let { if (day != null) startPhysics(day) else startSimulation(it) }
    }
    fun changeSimulationSpeed(speed: Int) { require(speed in listOf(1, 5, 20)); simulationSpeed = speed }
    fun toggleSimulationPause() { simulationPaused = !simulationPaused }
    fun startSimulation(mode: SimulationMode) {
        check(!running || simulation != null)
        if (simulation == null) savedTrack = track.toList()
        physics = null; physicsDay = null; gpsSpeed = null; gpsCourse = null
        CalculationEngine.reset(now())
        WaterDepth.resetDemo()
        simulationRadiusFollows = true
        simulationOriginalAnchor = simulationOrigin
        previewMonitor = AnchorMonitor().apply { setRadius(50.0); setRode(40.0); drop(simulationOrigin, now()) }
        simulation = mode; simulationSeconds = 0.0; simulationPaused = false
        track.clear(); error = null; running = true
        resetChartCamera(simulationOrigin)
        simulationStep(0.0)
    }
    fun simulationStep(realSeconds: Double) {
        val mode = simulation ?: return
        if (simulationPaused) return
        simulationSeconds += realSeconds * simulationSpeed
        val physical = physics
        val position = if (physical != null) {
            physical.updateBoat(physicalBoat().copy(depth = physical.boat.depth + physical.weather.tide(physical.time)))
            var remaining = realSeconds * simulationSpeed
            while (remaining > 0) { val dt = minOf(0.2, remaining); physical.step(dt); remaining -= dt }
            AnchorEstimate.coordinate(physical.phone, simulationOrigin)
        } else SimulationPath.position(simulationOrigin, mode, simulationSeconds, 50.0)
        if (position != null) {
            val last = monitor.fix
            gpsCourse = last?.takeIf { Geo.distance(it.coordinate, position) > 0.01 }?.let { Geo.bearing(it.coordinate, position) }
            gpsSpeed = last?.takeIf { now() > it.time }?.let { Geo.distance(it.coordinate, position) / ((now() - it.time) / 1000.0) }
            monitor.accept(Fix(position, 2.0, now()), now())
        }
        else monitor.gpsUnavailable(now())
        publish()
    }
    fun stopSimulation() {
        if (simulation == null) return
        physics = null; physicsDay = null; CalculationEngine.reset()
        simulation = null; previewMonitor = null; running = false
        track.clear(); track.addAll(savedTrack); savedTrack = emptyList()
        liveMonitor.raise(); liveOriginalAnchor = null; simulationOriginalAnchor = null; liveMonitor.resetMeasurements(); resetChartCamera(); publish()
    }
    var snapshot by mutableStateOf(monitor.snapshot(now())); private set
    var nightMode by mutableStateOf(false)
    var keepNightDataVisible by mutableStateOf(true); private set
    fun setKeepNightDataVisible(context: Context, keep: Boolean) {
        keepNightDataVisible = keep
        context.getSharedPreferences("watch", Context.MODE_PRIVATE).edit().putBoolean("keepNightDataVisible", keep).apply()
    }
    var running by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var audioError by mutableStateOf<String?>(null)
    var fadeMapControls by mutableStateOf(true); private set
    fun setFadeMapControls(context: Context, fade: Boolean) {
        fadeMapControls = fade
        context.getSharedPreferences("watch", Context.MODE_PRIVATE).edit().putBoolean("fadeMapControls", fade).apply()
    }
    var chartLayer by mutableStateOf(ChartLayer.SEA); private set
    var boatGeometry by mutableStateOf(ScopeSettings()); private set
    var scope by mutableStateOf<ScopeSettings?>(null); private set
    fun setBoatGeometry(context: Context, value: ScopeSettings) {
        boatGeometry = value
        if (scope != null) setScope(context, scope!!.copy(boatLength = value.boatLength, bowHeight = value.bowHeight))
        else context.getSharedPreferences("watch", Context.MODE_PRIVATE).edit()
            .putString("bow", value.bowHeight.toString()).putString("boatLength", value.boatLength.toString()).apply()
    }
    var useFeet by mutableStateOf(true); private set
    val track = mutableStateListOf<Fix>()
    var recovery by mutableStateOf<Coordinate?>(null); private set
    fun now() = SystemClock.elapsedRealtime()
    fun publish() {
        snapshot = monitor.tick(now())
        if (monitor.anchor != null || SettingsStore.trackEnabled) snapshot.fix?.let { fix ->
            val last = track.lastOrNull()
            if (last == null || (fix.time > last.time && (Geo.distance(last.coordinate, fix.coordinate) >= 0.5 || fix.time - last.time >= 10_000))) {
                track.add(fix)
                if (track.size > 2_000) track.removeAt(0)
            }
        }
    }
    fun drop(at: Coordinate) { CalculationEngine.reset(now()); if (simulation != null) simulationOriginalAnchor = at else liveOriginalAnchor = at; track.clear(); monitor.drop(at, now()); if (simulation == null) SettingsStore.dropped(at, monitor.rode, monitor.radius); publish() }
    fun setChartLayer(context: Context, layer: ChartLayer) {
        chartLayer = layer
        context.getSharedPreferences("watch", Context.MODE_PRIVATE).edit().putString("chartLayer", layer.name).apply()
    }
    fun setUnits(context: Context, feet: Boolean) {
        useFeet = feet
        context.getSharedPreferences("watch", Context.MODE_PRIVATE).edit().putBoolean("feet", feet).apply()
    }
    fun setScope(context: Context, value: ScopeSettings) {
        if (scope == null || scope?.depth != value.depth) WaterDepth.confirm(context, value.depth)
        scope = value
        boatGeometry = value
        followRadius()
        save(context)
        context.getSharedPreferences("watch", Context.MODE_PRIVATE).edit()
            .putBoolean("depthConfirmed", true).putString("depth", value.depth.toString())
            .putString("tideRise", value.tideRise.toString()).putString("bow", value.bowHeight.toString())
            .putString("boatLength", value.boatLength.toString()).putString("ratio", value.scopeRatio.toString())
            .putString("margin", value.margin.toString()).apply()
    }
    fun load(context: Context) {
        keepNightDataVisible = context.getSharedPreferences("watch", Context.MODE_PRIVATE).getBoolean("keepNightDataVisible", true)
        if (simulation != null) return
        ModelSettings.load(context)
        SettingsStore.load(context)
        WaterDepth.load(context)
        Hazards.load(context)
        val prefs = context.getSharedPreferences("watch", Context.MODE_PRIVATE)
        liveRadiusFollows = prefs.getBoolean("radiusFollowsRode", false)
        fadeMapControls = prefs.getBoolean("fadeMapControls", true)
        chartLayer = runCatching { ChartLayer.valueOf(prefs.getString("chartLayer", ChartLayer.SEA.name)!!) }.getOrDefault(ChartLayer.SEA)
        useFeet = prefs.getBoolean("feet", true)
        boatGeometry = runCatching { ScopeSettings(
            bowHeight = prefs.getString("bow", "1.219")!!.toDouble(),
            boatLength = prefs.getString("boatLength", "14.326")!!.toDouble()) }.getOrDefault(ScopeSettings())
        if (prefs.getBoolean("depthConfirmed", false)) scope = runCatching {
            ScopeSettings(prefs.getString("depth", "3.048")!!.toDouble(), prefs.getString("tideRise", "0")!!.toDouble(),
                prefs.getString("bow", "1.219")!!.toDouble(), prefs.getString("boatLength", "14.326")!!.toDouble(),
                prefs.getString("ratio", "5")!!.toDouble(), prefs.getString("margin", "6.096")!!.toDouble())
        }.getOrNull()
        liveOriginalAnchor = runCatching {
            Coordinate(prefs.getString("originalLatitude", null)!!.toDouble(), prefs.getString("originalLongitude", null)!!.toDouble())
        }.getOrNull()
        recovery = if (prefs.getBoolean("anchored", false)) runCatching {
            Coordinate(prefs.getString("latitude", "")!!.toDouble(), prefs.getString("longitude", "")!!.toDouble())
        }.getOrNull() else null
        if (monitor.anchor == null) {
            runCatching { monitor.setRadius(prefs.getFloat("radius", 50f).toDouble()) }
            runCatching { monitor.setRode(prefs.getFloat("rode", 30f).toDouble()) }
        }
        publish()
    }
    fun save(context: Context) {
        if (simulation != null) { publish(); return }
        val a = monitor.anchor ?: recovery
        context.getSharedPreferences("watch", Context.MODE_PRIVATE).edit()
            .putBoolean("radiusFollowsRode", liveRadiusFollows)
            .putBoolean("anchored", a != null)
            .putString("latitude", a?.latitude?.toString())
            .putString("longitude", a?.longitude?.toString())
            .putString("originalLatitude", liveOriginalAnchor?.latitude?.toString())
            .putString("originalLongitude", liveOriginalAnchor?.longitude?.toString())
            .putFloat("radius", monitor.radius.toFloat()).putFloat("rode", monitor.rode.toFloat()).apply()
        recovery = a
        publish()
    }
    fun clearSaved(context: Context) { CalculationEngine.reset(); if (simulation == null) SettingsStore.ended(); if (simulation != null) simulationOriginalAnchor = null else liveOriginalAnchor = null; if (simulation != null) { monitor.raise(); track.clear(); publish(); return }; monitor.raise(); recovery = null; track.clear(); Hazards.hideAll(context); save(context) }
}
