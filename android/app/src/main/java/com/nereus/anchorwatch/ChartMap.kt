package com.nereus.anchorwatch

import android.content.ComponentCallbacks2
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.IntOffset
import kotlin.math.roundToInt
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.content.Context
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.platform.LocalAccessibilityManager
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.nereus.anchorwatch.core.*
import okhttp3.Cache
import okhttp3.OkHttpClient
import org.json.JSONArray
import org.json.JSONObject
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.*
import org.maplibre.android.module.http.HttpRequestUtil
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.*
import org.maplibre.android.style.layers.PropertyFactory.*
import org.maplibre.android.style.sources.GeoJsonSource
import java.io.File
import java.util.concurrent.TimeUnit

internal enum class ChartLayer(val title: String) { SEA("OpenSeaMap"), NOAA("NOAA · US waters") }

/** Camera is separate from the watch: map gestures can never change the anchor. */
private object ChartSession {
    var camera: CameraPosition? = null
    var firstFixHandled = false
    var initialized = false
    var issue by mutableStateOf<String?>(null)
    val main = Handler(Looper.getMainLooper())
    fun initialize(context: Context) {
        if (initialized) return
        MapLibre.getInstance(context.applicationContext)
        HttpRequestUtil.setOkHttpClient(OkHttpClient.Builder()
            .cache(Cache(File(context.cacheDir, "chart-http"), 100L * 1024 * 1024))
            .connectTimeout(15, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS)
            .addInterceptor { chain ->
                val request = chain.request().newBuilder().header("User-Agent", "NereusAnchorWatch/${BuildConfig.VERSION_NAME} (Android; https://github.com/jeffm007/Anchor-Watch)").build()
                try {
                    chain.proceed(request).also { response ->
                        if (!response.isSuccessful && response.code != 304) main.post { issue = "Some chart tiles are unavailable (HTTP ${response.code}). Try another layer or Retry." }
                    }
                } catch (e: java.io.IOException) {
                    main.post { issue = "Chart connection interrupted. Cached tiles may be incomplete; monitoring continues." }
                    throw e
                }
            }.build())
        initialized = true
    }
}

internal fun resetChartCamera(position: Coordinate? = null) {
    ChartSession.camera = position?.let { CameraPosition.Builder().target(it.latLng()).zoom(17.0).build() }
    ChartSession.firstFixHandled = position != null
}

@Composable
internal fun ChartMap(snapshot: MonitorSnapshot, modifier: Modifier = Modifier, onSettings: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var layer by remember { mutableStateOf(WatchSession.chartLayer) }
    var layersOpen by remember { mutableStateOf(false) }
    var retry by remember { mutableIntStateOf(0) }
    val controller = remember(context) { ChartController(context) }
    var controlsVisible by remember { mutableStateOf(true) }
    var touching by remember { mutableStateOf(false) }
    var interaction by remember { mutableIntStateOf(0) }
    val lifecycleState by owner.lifecycle.currentStateFlow.collectAsState()
    val timeout = LocalAccessibilityManager.current?.calculateRecommendedTimeoutMillis(5_000L, containsIcons = true, containsText = true, containsControls = true) ?: 5_000L
    fun reveal() { controlsVisible = true; interaction++ }
    SideEffect {
        controller.onMapTouch = { down -> touching = down; reveal() }
    }
    LaunchedEffect(interaction, touching, layersOpen, WatchSession.fadeMapControls, lifecycleState, timeout) {
        controlsVisible = true
        if (WatchSession.fadeMapControls && !touching && !layersOpen && lifecycleState == Lifecycle.State.RESUMED) {
            delay(timeout)
            controlsVisible = false
        }
    }
    DisposableEffect(controller, owner) {
        val observer = LifecycleEventObserver { _, event -> controller.lifecycle(event) }
        owner.lifecycle.addObserver(observer)
        val memory = object : ComponentCallbacks2 {
            override fun onConfigurationChanged(config: Configuration) = Unit
            override fun onLowMemory() { controller.view.onLowMemory() }
            @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
            override fun onTrimMemory(level: Int) { if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) onLowMemory() }
        }
        context.applicationContext.registerComponentCallbacks(memory)
        onDispose {
            owner.lifecycle.removeObserver(observer)
            context.applicationContext.unregisterComponentCallbacks(memory)
            controller.destroy()
        }
    }
    Column(modifier) {
        if (snapshot.fix == null && snapshot.anchor == null) Text("Browse map · GPS not acquired", style = MaterialTheme.typography.labelSmall)
        ChartSession.issue?.let { issue ->
            Row(Modifier.fillMaxWidth()) {
                Text(issue, Modifier.weight(1f), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = { ChartSession.issue = null; retry++ }) { Text("Retry") }
            }
        }
        Hazards.dragOrigin?.let { original ->
            Hazards.marks.firstOrNull { it.id == original.id }?.let { moved ->
                Text("Moved ${meters(Geo.distance(original.coordinate, moved.coordinate))}" +
                    (snapshot.fix?.let { " · boat ${meters(Geo.distance(it.coordinate, moved.coordinate))}" } ?: ""), style = MaterialTheme.typography.labelSmall)
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(12.dp))) {
            AndroidView(factory = { controller.view }, modifier = Modifier.fillMaxSize(), update = {
                Hazards.marks.toList() // Observe persisted edits and drag previews.
                CalculationEngine.result // subscribe map rendering to calculation changes
                controller.update(snapshot, WatchSession.track.toList(), layer, retry)
            })
            controller.measureLabels.forEach { label ->
                key(label.id) {
                    var labelSize by remember { mutableStateOf(IntSize.Zero) }
                    Surface(color = Color(0xEE1C1C1E), shape = RoundedCornerShape(16.dp),
                        modifier = Modifier.onSizeChanged { labelSize = it }.offset {
                            IntOffset(label.x.roundToInt().coerceIn(0, (controller.view.width - labelSize.width).coerceAtLeast(0)),
                                label.y.roundToInt().coerceIn(0, (controller.view.height - labelSize.height).coerceAtLeast(0)))
                        }) {
                        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                            Text(label.text, color = if (label.id == "boat" || label.id == "hazard") WatchOrange else Color.White,
                                style = MaterialTheme.typography.labelSmall,
                                modifier = Modifier.pointerInput(controller, label.id) {
                                    detectDragGestures(onDragStart = { controller.onMapTouch?.invoke(true) },
                                        onDragEnd = { controller.onMapTouch?.invoke(false) },
                                        onDragCancel = { controller.onMapTouch?.invoke(false) }) { change, delta ->
                                        change.consume(); controller.moveLabel(label.id, delta.x, delta.y)
                                    }
                                }.padding(horizontal = 10.dp, vertical = 10.dp))
                            TextButton(onClick = { controller.closeLabel(label.id) },
                                modifier = Modifier.size(36.dp).semantics { contentDescription = "Close ${label.id} measurement" },
                                contentPadding = PaddingValues(0.dp)) { Text("×", color = Color.White) }
                        }
                    }
                }
            }
            Column(Modifier.align(androidx.compose.ui.Alignment.TopStart).fillMaxWidth()) {
                SimulationBanner()
                Text(if (layer == ChartLayer.SEA) "© OpenStreetMap contributors · OpenSeaMap" else "© OpenStreetMap contributors · NOAA ENC",
                    Modifier.padding(end = 72.dp).background(Color(0xDDFFFFFF)).padding(3.dp),
                    color = Color.Black, style = MaterialTheme.typography.labelSmall)
            }
        }
        androidx.compose.animation.AnimatedVisibility(visible = controlsVisible, modifier = Modifier.fillMaxWidth(),
            enter = expandVertically(tween(600)) + fadeIn(tween(600)),
            exit = shrinkVertically(tween(600)) + fadeOut(tween(600))) {
                Surface(modifier = Modifier.padding(top = 6.dp, bottom = 6.dp), shape = RoundedCornerShape(28.dp), color = Color(0xEE1C1C1E), tonalElevation = 0.dp) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                        @Composable fun tool(symbol: Int, label: String, enabled: Boolean = true, action: () -> Unit) {
                            IconButton(enabled = enabled && controlsVisible, modifier = Modifier.weight(1f).semantics { contentDescription = label }, onClick = { reveal(); action() }) {
                                Icon(painterResource(symbol), contentDescription = null, modifier = Modifier.size(23.dp), tint = MaterialTheme.colorScheme.primary.copy(alpha = if (enabled) 1f else 0.35f))
                            }
                        }
                        tool(R.drawable.tool_settings, "Map settings") { onSettings() }
                        tool(R.drawable.tool_moon, "Night mode") { WatchSession.nightMode = true }
                        tool(R.drawable.nav_watch, "Chart layers") { layersOpen = true }
                        tool(R.drawable.tool_locate, if (freshFix()) "Center on my boat" else "Center on last GPS fix", snapshot.fix != null) { snapshot.fix?.let { controller.center(it.coordinate) } }
                        tool(R.drawable.nav_anchor, "Center on anchor", snapshot.anchor != null) { snapshot.anchor?.let { controller.center(it) } }
                        tool(R.drawable.tool_plus, "Zoom in") { controller.zoom(1.0) }
                        tool(R.drawable.tool_minus, "Zoom out") { controller.zoom(-1.0) }
                    }
                }
        }
    }
    HazardEditor(context)
    if (layersOpen) AlertDialog(onDismissRequest = { layersOpen = false; reveal() }, title = { Text("Chart layers") }, text = {
        Column {
            ChartLayer.entries.forEach { item ->
                TextButton(onClick = { layer = item; WatchSession.setChartLayer(context, item); ChartSession.issue = null; layersOpen = false; reveal() }) {
                    Text((if (item == layer) "✓ " else "") + item.title)
                }
            }
            TextButton(onClick = {}, enabled = false) { Text("Google Maps · API key setup required") }
            Text("OpenSeaMap shows community seamarks. NOAA displays US electronic charts where available. Coverage and updates vary; verify with onboard charts.")
            Text("Online maps request the viewed area from OpenStreetMap, OpenSeaMap or NOAA. No offline download is provided.", style = MaterialTheme.typography.bodySmall)
        }
    }, confirmButton = { TextButton(onClick = { layersOpen = false; reveal() }) { Text("Close") } })
}

private data class MeasureLabel(val id: String, val text: String, val x: Float, val y: Float)

private class ChartController(private val context: Context) {
    val view: MapView
    var onMapTouch: ((Boolean) -> Unit)? = null
    private var map: MapLibreMap? = null
    private var snapshot = WatchSession.snapshot
    private var track = emptyList<Fix>()
    private var requestedLayer: ChartLayer? = null
    private var requestedRetry = -1
    private var started = false
    private var resumed = false
    private var destroyed = false
    private var gestureInProgress = false
    private var draggedHazard: Hazard? = null
    private var measuredHazardId: String? = null
    private var anchorPreview: Coordinate? = null
    private var dragStart: Coordinate? = null
    private var dragGrab = android.graphics.PointF()
    private var measuredAnchor: Coordinate? = null
    private var measuredSimulation: SimulationMode? = null
    private var boatMeasureVisible = false
    private var movedMeasureVisible = false
    private val labelShifts = mutableMapOf<String, Pair<Double, Double>>()
    var measureLabels by mutableStateOf(emptyList<MeasureLabel>()); private set
    fun closeLabel(id: String) {
        when (id) {
            "hazard" -> measuredHazardId = null
            "boat" -> boatMeasureVisible = false
            else -> movedMeasureVisible = false
        }
        map?.style?.let(::render)
    }
    fun moveLabel(id: String, dx: Float, dy: Float) {
        val ready = map ?: return
        val label = measureLabels.firstOrNull { it.id == id } ?: return
        val from = ready.projection.fromScreenLocation(android.graphics.PointF(label.x, label.y))
        val to = ready.projection.fromScreenLocation(android.graphics.PointF(label.x + dx, label.y + dy))
        val shift = labelShifts[id] ?: (0.0 to 0.0)
        labelShifts[id] = (shift.first + to.latitude - from.latitude) to (shift.second + to.longitude - from.longitude)
        ready.style?.let(::render)
    }
    init {
        ChartSession.initialize(context)
        view = MapView(context, MapLibreMapOptions.createFromAttributes(context).textureMode(true))
        view.onCreate(null)
        view.setOnTouchListener { v, event ->
            if (anchorPreview != null) {
                v.parent?.requestDisallowInterceptTouchEvent(true)
                when (event.actionMasked) {
                    MotionEvent.ACTION_MOVE -> map?.projection?.fromScreenLocation(
                        android.graphics.PointF(event.x + dragGrab.x, event.y + dragGrab.y))?.let {
                        anchorPreview = Coordinate(it.latitude, it.longitude)
                        map?.style?.let(::render)
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        val at = anchorPreview
                        anchorPreview = null
                        if (event.actionMasked == MotionEvent.ACTION_UP && at != null && WatchSession.monitor.anchor == dragStart) {
                            WatchSession.moveAnchor(context, at)
                            snapshot = WatchSession.snapshot
                            measuredAnchor = at
                        }
                        dragStart = null
                        map?.uiSettings?.isScrollGesturesEnabled = true
                        map?.uiSettings?.isZoomGesturesEnabled = true
                        v.parent?.requestDisallowInterceptTouchEvent(false)
                        map?.style?.let(::render)
                        onMapTouch?.invoke(false)
                    }
                }
                return@setOnTouchListener true
            }
            val drag = draggedHazard
            if (drag != null) {
                v.parent?.requestDisallowInterceptTouchEvent(true)
                when (event.actionMasked) {
                    MotionEvent.ACTION_MOVE -> map?.projection?.fromScreenLocation(android.graphics.PointF(event.x, event.y))?.let {
                        Hazards.put(drag.copy(coordinate = Coordinate(it.latitude, it.longitude)))
                        map?.style?.let(::render)
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        if (event.actionMasked == MotionEvent.ACTION_CANCEL) Hazards.put(drag)
                        Hazards.save(context); draggedHazard = null; Hazards.dragOrigin = null
                        map?.uiSettings?.isScrollGesturesEnabled = true
                        map?.uiSettings?.isZoomGesturesEnabled = true
                        v.parent?.requestDisallowInterceptTouchEvent(false)
                        map?.style?.let(::render)
                        onMapTouch?.invoke(false)
                    }
                }
                return@setOnTouchListener true
            }
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> onMapTouch?.invoke(true)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> onMapTouch?.invoke(false)
            }
            v.parent?.requestDisallowInterceptTouchEvent(event.actionMasked != MotionEvent.ACTION_UP && event.actionMasked != MotionEvent.ACTION_CANCEL)
            false
        }
        view.addOnDidFailLoadingMapListener { ChartSession.issue = "Chart could not load. Check connection and retry; GPS monitoring is independent." }
        view.getMapAsync { ready ->
            if (destroyed) return@getMapAsync
            map = ready
            ready.uiSettings.isAttributionEnabled = true
            ready.cameraPosition = ChartSession.camera ?: CameraPosition.Builder()
                .target((snapshot.anchor ?: snapshot.fix?.coordinate ?: Coordinate(28.615, -96.62)).latLng()).zoom(14.0).build()
            ready.addOnCameraIdleListener {
                ready.style?.let(::render)
                ChartSession.camera = ready.cameraPosition
                // Resizing the map for its toolbar must not restart the visibility timer.
                if (gestureInProgress) { gestureInProgress = false; onMapTouch?.invoke(false) }
            }
            ready.addOnMapClickListener { at ->
                onMapTouch?.invoke(false)
                val hazard = hazardAt(at)
                if (hazard != null) Hazards.editing = hazard
                hazard != null
            }
            ready.addOnCameraMoveListener { ready.style?.let(::render) }
            ready.addOnMapLongClickListener { at ->
                val anchor = snapshot.anchor
                val touch = ready.projection.toScreenLocation(at)
                val tip = anchor?.let { ready.projection.toScreenLocation(it.latLng()) }
                val density = context.resources.displayMetrics.density
                val original = WatchSession.originalAnchor
                val originalTip = original?.let { ready.projection.toScreenLocation(it.latLng()) }
                fun symbolDistance(p: android.graphics.PointF) = kotlin.math.hypot(
                    (touch.x - p.x).toDouble(), (touch.y - (p.y - 16 * density)).toDouble())
                val pressedOriginal = anchor != null && original != null && originalTip != null &&
                    Geo.distance(original, anchor) >= 0.5 &&
                    kotlin.math.abs(touch.x - originalTip.x) < 28 * density &&
                    touch.y > originalTip.y - 64 * density && touch.y < originalTip.y + 20 * density &&
                    (tip == null || symbolDistance(originalTip) < symbolDistance(tip))
                // Include the visible symbol above the geographic tip, preserving the grab offset.
                if (!pressedOriginal && anchor != null && tip != null && kotlin.math.abs(touch.x - tip.x) < 28 * density &&
                    touch.y > tip.y - 64 * density && touch.y < tip.y + 20 * density) {
                    dragStart = anchor; anchorPreview = anchor; measuredAnchor = anchor; measuredSimulation = WatchSession.simulation
                    dragGrab = android.graphics.PointF(tip.x - touch.x, tip.y - touch.y)
                    boatMeasureVisible = true; movedMeasureVisible = true
                    ready.uiSettings.isScrollGesturesEnabled = false
                    ready.uiSettings.isZoomGesturesEnabled = false
                    view.parent?.requestDisallowInterceptTouchEvent(true)
                    view.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
                    ready.style?.let(::render)
                    onMapTouch?.invoke(true)
                    return@addOnMapLongClickListener true
                }
                if (pressedOriginal) {
                    WatchSession.clearOriginalAnchor(context)
                    movedMeasureVisible = false
                    labelShifts.remove("moved")
                    view.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
                    ready.style?.let(::render)
                    onMapTouch?.invoke(false)
                    return@addOnMapLongClickListener true
                }
                val hazard = hazardAt(at)
                if (hazard != null) {
                    draggedHazard = hazard; Hazards.dragOrigin = hazard
                    measuredHazardId = hazard.id; labelShifts.remove("hazard")
                    ready.uiSettings.isScrollGesturesEnabled = false
                    ready.uiSettings.isZoomGesturesEnabled = false
                    view.parent?.requestDisallowInterceptTouchEvent(true)
                    ready.style?.let(::render)
                    onMapTouch?.invoke(true)
                    return@addOnMapLongClickListener true
                } else Hazards.editing = Hazard(coordinate = Coordinate(at.latitude, at.longitude))
                onMapTouch?.invoke(false)
                true
            }
            ready.addOnCameraMoveStartedListener { reason ->
                if (reason == MapLibreMap.OnCameraMoveStartedListener.REASON_API_GESTURE) { ChartSession.firstFixHandled = true; gestureInProgress = true; onMapTouch?.invoke(true) }
            }
            // update() can run before the asynchronous map is ready.
            val pending = requestedLayer ?: WatchSession.chartLayer
            requestedLayer = null
            update(snapshot, track, pending, requestedRetry)
        }
    }
    private fun hazardAt(at: LatLng): Hazard? {
        val projection = map?.projection ?: return null
        val tap = projection.toScreenLocation(at)
        return Hazards.marks.filter { !it.hidden }.minByOrNull { h ->
            val p = projection.toScreenLocation(h.coordinate.latLng()); kotlin.math.hypot((tap.x - p.x).toDouble(), (tap.y - p.y).toDouble())
        }?.takeIf { h -> val p = projection.toScreenLocation(h.coordinate.latLng()); kotlin.math.hypot((tap.x - p.x).toDouble(), (tap.y - p.y).toDouble()) < 28 * context.resources.displayMetrics.density }
    }
    private fun cancelAnchorDrag() {
        anchorPreview = null; dragStart = null
        map?.uiSettings?.isScrollGesturesEnabled = true
        map?.uiSettings?.isZoomGesturesEnabled = true
        onMapTouch?.invoke(false)
    }
    fun lifecycle(event: Lifecycle.Event) {
        if (destroyed) return
        if (event == Lifecycle.Event.ON_PAUSE && anchorPreview != null) {
            cancelAnchorDrag()
            map?.style?.let(::render)
        }
        when (event) {
            Lifecycle.Event.ON_START -> if (!started) { view.onStart(); started = true }
            Lifecycle.Event.ON_RESUME -> if (!resumed) { view.onResume(); resumed = true }
            Lifecycle.Event.ON_PAUSE -> if (resumed) { view.onPause(); resumed = false }
            Lifecycle.Event.ON_STOP -> if (started) { view.onStop(); started = false }
            Lifecycle.Event.ON_DESTROY -> destroy()
            else -> Unit
        }
    }
    fun destroy() {
        if (destroyed) return
        cancelAnchorDrag()
        draggedHazard?.let { Hazards.put(it) }; Hazards.dragOrigin = null
        ChartSession.camera = map?.cameraPosition ?: ChartSession.camera
        if (resumed) view.onPause()
        if (started) view.onStop()
        onMapTouch = null
        view.onDestroy(); destroyed = true
    }
    fun center(point: Coordinate) { map?.animateCamera(CameraUpdateFactory.newLatLngZoom(point.latLng(), 17.0)); ChartSession.firstFixHandled = true }
    fun zoom(delta: Double) { map?.let { it.animateCamera(CameraUpdateFactory.zoomTo((it.cameraPosition.zoom + delta).coerceIn(2.0, 20.0))) } }
    fun update(current: MonitorSnapshot, points: List<Fix>, layer: ChartLayer, retry: Int) {
        if (anchorPreview != null && (current.anchor != dragStart || measuredSimulation != WatchSession.simulation)) cancelAnchorDrag()
        if (current.anchor == null || measuredSimulation != WatchSession.simulation ||
            (anchorPreview == null && measuredAnchor != null && measuredAnchor != current.anchor)) {
            boatMeasureVisible = false; movedMeasureVisible = false; measuredAnchor = null
            measureLabels = measureLabels.filter { it.id == "hazard" }
            labelShifts.remove("boat"); labelShifts.remove("moved")
        }
        snapshot = current; track = points
        val ready = map
        if (ready == null) { requestedLayer = layer; requestedRetry = retry; return }
        if (requestedLayer != layer || requestedRetry != retry) {
            requestedLayer = layer; requestedRetry = retry
            ready.setStyle(Style.Builder().fromJson(chartStyle(layer))) { style ->
                if (destroyed) return@setStyle
                listOf("model-ellipse", "model-drift", "model-swing", "radius", "accuracy", "trail", "tether", "anchor-moved", "anchor-measure", "hazard-measure", "anchor-original", "anchor", "phone", "hazard-points", "hazard-zones").forEach { style.addSource(GeoJsonSource(it, emptyFeatures())) }
                style.addLayer(FillLayer("estimate-fill", "model-ellipse").withProperties(fillColor("#64D2FF"), fillOpacity(0.15f)))
                style.addLayer(LineLayer("estimate-line", "model-ellipse").withProperties(lineColor("#64D2FF"), lineWidth(2f), lineDasharray(arrayOf(2f, 2f))))
                style.addLayer(LineLayer("drift-line", "model-drift").withProperties(lineColor("#FF453A"), lineWidth(3f)))
                style.addLayer(LineLayer("swing-line", "model-swing").withProperties(lineColor("#BF5AF2"), lineWidth(1f), lineDasharray(arrayOf(4f, 4f))))
                style.addLayer(FillLayer("circle-fill", "radius").withProperties(fillColor("#49c5ff"), fillOpacity(0.08f)))
                style.addLayer(LineLayer("circle-line", "radius").withProperties(lineColor("#49c5ff"), lineWidth(2f)))
                style.addLayer(FillLayer("accuracy-fill", "accuracy").withProperties(fillColor("#49c5ff"), fillOpacity(0.18f)))
                style.addLayer(LineLayer("track-line", "trail").withProperties(lineColor("#BF5AF2"), lineWidth(1.25f), lineOpacity(0.85f), lineCap("round"), lineJoin("round")))
                style.addLayer(LineLayer("tether-line", "tether").withProperties(lineColor("#FF9500"), lineWidth(1.5f), lineCap("round"), lineDasharray(arrayOf(0.01f, 2.5f))))
                style.addLayer(LineLayer("anchor-moved-line", "anchor-moved").withProperties(lineColor("#FFFFFF"), lineWidth(2f)))
                style.addLayer(LineLayer("hazard-measure-line", "hazard-measure").withProperties(lineColor("#FFD60A"), lineWidth(1.5f)))
                style.addLayer(LineLayer("anchor-measure-line", "anchor-measure").withProperties(lineColor("#FFD60A"), lineWidth(1.5f)))
                style.addImage("original-anchor-symbol", mapMarker(anchor = true, faded = true))
                style.addLayer(SymbolLayer("anchor-original-mark", "anchor-original").withProperties(
                    iconImage("original-anchor-symbol"), iconSize(markerZoomScale()), iconAnchor("bottom"),
                    iconOpacity(0.5f), iconAllowOverlap(true), iconIgnorePlacement(true)))
                style.addLayer(FillLayer("hazard-fill", "hazard-zones").withProperties(fillColor("#FF453A"), fillOpacity(0.15f)))
                style.addLayer(LineLayer("hazard-border", "hazard-zones").withProperties(lineColor("#FF453A"), lineWidth(1.5f)))
                HazardKind.entries.forEach { kind -> style.addImage("hazard-${kind.name}", hazardMarker(kind)) }
                style.addLayer(SymbolLayer("hazard-mark", "hazard-points").withProperties(iconImage(Expression.get("icon")), iconSize(0.5f), iconAllowOverlap(true), iconIgnorePlacement(true)))
                style.addImage("anchor-symbol", mapMarker(anchor = true))
                style.addImage("boat-symbol", mapMarker(anchor = false))
                style.addLayer(SymbolLayer("anchor-point", "anchor").withProperties(iconImage("anchor-symbol"), iconSize(markerZoomScale()), iconAnchor("bottom"), iconAllowOverlap(true), iconIgnorePlacement(true)))
                style.addLayer(SymbolLayer("phone-point", "phone").withProperties(iconImage("boat-symbol"), iconSize(markerZoomScale()), iconAnchor("center"), iconRotationAlignment("map"), iconAllowOverlap(true), iconIgnorePlacement(true)))
                render(style)
            }
        } else ready.style?.let(::render)
        if (!ChartSession.firstFixHandled && current.fix != null) {
            ready.moveCamera(CameraUpdateFactory.newLatLngZoom(current.fix!!.coordinate.latLng(), 16.0))
            ChartSession.firstFixHandled = true
        }
    }
    private fun render(style: Style) {
        if (!style.isFullyLoaded) return
        fun source(id: String, geometry: JSONObject?) {
            style.getSourceAs<GeoJsonSource>(id)?.setGeoJson(if (geometry == null) emptyFeatures() else JSONObject().put("type", "Feature").put("properties", JSONObject()).put("geometry", geometry).toString())
        }
        fun hazardsSource(id: String, zones: Boolean) {
            val features = Hazards.marks.filter { !it.hidden }.map { h -> JSONObject().put("type", "Feature").put("properties", JSONObject().put("label", h.label).put("icon", "hazard-${h.kind.name}"))
                .put("geometry", if (zones) polygon(h.coordinate, h.radius) else point(h.coordinate)) }
            style.getSourceAs<GeoJsonSource>(id)?.setGeoJson(JSONObject().put("type", "FeatureCollection").put("features", JSONArray(features)).toString())
        }
        hazardsSource("hazard-points", false); hazardsSource("hazard-zones", true)
        val anchor = anchorPreview ?: snapshot.anchor
        source("anchor", anchor?.let(::point))
        val boat = snapshot.fix?.coordinate
        val original = WatchSession.originalAnchor ?: dragStart
        fun line(a: Coordinate?, b: Coordinate?) = if (a == null || b == null) null else
            JSONObject().put("type", "LineString").put("coordinates", JSONArray(listOf(coordinate(a), coordinate(b))))
        val model = CalculationEngine.result
        source("model-swing", anchor?.let { a -> model?.let { polygon(a, it.swingRadius + (WatchSession.scope?.boatLength ?: 0.0) / 2) } })
        source("model-drift", model?.drift?.let { line(it.from, it.to) })
        source("model-ellipse", model?.estimate?.estimate?.let { e ->
            val bearing = Math.toRadians(e.majorBearing)
            val ring = (0..72).map { i ->
                val t = i * 2 * kotlin.math.PI / 72
                val major = e.semiMajor * kotlin.math.cos(t); val minor = e.semiMinor * kotlin.math.sin(t)
                val p = com.nereus.anchorwatch.calculations.ModelPoint(major * kotlin.math.sin(bearing) + minor * kotlin.math.cos(bearing), major * kotlin.math.cos(bearing) - minor * kotlin.math.sin(bearing))
                coordinate(com.nereus.anchorwatch.calculations.AnchorEstimate.coordinate(p, e.center))
            }
            JSONObject().put("type", "Polygon").put("coordinates", JSONArray(listOf(ring)))
        })
        val moved = anchor != null && original != null && Geo.distance(original, anchor) >= 0.5
        source("anchor-moved", if (movedMeasureVisible && moved) line(original, anchor) else null)
        source("anchor-original", if (moved) original?.let(::point) else null)
        source("anchor-measure", if (boatMeasureVisible) line(boat, anchor) else null)
        val labels = mutableListOf<MeasureLabel>()
        fun label(id: String, a: Coordinate, b: Coordinate, text: String) {
            val middle = Geo.destination(a, Geo.bearing(a, b), Geo.distance(a, b) / 2)
            val shift = labelShifts[id] ?: (0.0 to 0.0)
            val p = map?.projection?.toScreenLocation(LatLng((middle.latitude + shift.first).coerceIn(-85.0, 85.0), middle.longitude + shift.second)) ?: return
            labels.add(MeasureLabel(id, text, p.x, p.y))
        }
        fun distanceBearing(from: Coordinate, to: Coordinate): String {
            val bearing = Geo.bearing(from, to)
            val compass = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")[(kotlin.math.round(bearing / 45).toInt() % 8 + 8) % 8]
            return "${meters(Geo.distance(from, to))} · $compass ${"%03d".format(kotlin.math.round(bearing).toInt() % 360)}° T"
        }
        if (boatMeasureVisible && boat != null && anchor != null) {
            label("boat", boat, anchor, "New ${distanceBearing(boat, anchor)}")
        }
        val hazard = Hazards.marks.firstOrNull { it.id == measuredHazardId && !it.hidden }
        if (hazard == null) measuredHazardId = null
        source("hazard-measure", if (hazard != null) line(boat, hazard.coordinate) else null)
        if (boat != null && hazard != null) {
            label("hazard", boat, hazard.coordinate, "${hazard.label} · ${distanceBearing(boat, hazard.coordinate)}")
        }
        if (movedMeasureVisible && moved) label("moved", original, anchor, meters(Geo.distance(original, anchor)))
        measureLabels = labels
        source("phone", boat?.let(::point))
        source("tether", if (boat != null && anchor != null) JSONObject().put("type", "LineString")
            .put("coordinates", JSONArray(listOf(coordinate(boat), coordinate(anchor)))) else null)
        style.getLayerAs<SymbolLayer>("phone-point")?.setProperties(iconRotate(
            if (boat != null && anchor != null) Geo.bearing(boat, anchor).toFloat() else 0f))
        source("radius", anchor?.let { polygon(it, snapshot.radius) })
        source("accuracy", snapshot.fix?.let { polygon(it.coordinate, it.accuracy) })
        source("trail", if (track.size < 2) null else JSONObject().put("type", "LineString").put("coordinates", JSONArray(track.map { coordinate(it.coordinate) })))
    }
}

private fun Coordinate.latLng() = LatLng(latitude, longitude)
private fun coordinate(c: Coordinate) = JSONArray(listOf(c.longitude, c.latitude))
private fun point(c: Coordinate) = JSONObject().put("type", "Point").put("coordinates", coordinate(c))
private fun polygon(center: Coordinate, radius: Double): JSONObject {
    val ring = JSONArray((0..72).map { coordinate(Geo.destination(center, (it % 72) * 5.0, radius)) })
    return JSONObject().put("type", "Polygon").put("coordinates", JSONArray().put(ring))
}
private fun emptyFeatures() = "{\"type\":\"FeatureCollection\",\"features\":[]}"

/** NOAA uses the same Web Mercator export endpoint as the iOS chart. */
private fun chartStyle(layer: ChartLayer): String {
    val noaa = "https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/MapServer/export?bbox={bbox-epsg-3857}&bboxSR=3857&imageSR=3857&size=256,256&format=png32&transparent=true&f=image"
    val sources = JSONObject()
    val layers = JSONArray().put(JSONObject().put("id", "background").put("type", "background").put("paint", JSONObject().put("background-color", "#b9d9e9")))
    fun raster(id: String, url: String, maxZoom: Int, attribution: String) {
        sources.put(id, JSONObject().put("type", "raster").put("tiles", JSONArray().put(url)).put("tileSize", 256).put("maxzoom", maxZoom).put("attribution", attribution))
        layers.put(JSONObject().put("id", "$id-layer").put("type", "raster").put("source", id))
    }
    raster("osm", "https://tile.openstreetmap.org/{z}/{x}/{y}.png", 19, "© <a href='https://www.openstreetmap.org/copyright'>OpenStreetMap</a> contributors")
    if (layer == ChartLayer.SEA) raster("seamarks", "https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png", 18, "<a href='https://www.openseamap.org'>OpenSeaMap</a>")
    else raster("noaa", noaa, 20, "<a href='https://nauticalcharts.noaa.gov'>NOAA ENC</a>")
    return JSONObject().put("version", 8).put("sources", sources).put("layers", layers).toString()
}

/** Shared camera expression keeps both markers growing smoothly, with bounded sizes. */
private fun markerZoomScale(): Expression = Expression.interpolate(
    Expression.linear(), Expression.zoom(),
    Expression.stop(14, 0.3), Expression.stop(17, 0.5), Expression.stop(20, 0.9)
)

/** Transparent symbols; boat points toward the marked anchor; orientation is not a measured heading. */
private fun mapMarker(anchor: Boolean, faded: Boolean = false): Bitmap {
    val bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888).apply {
        // MapLibre uses bitmap density to derive logical icon size.
        density = android.util.DisplayMetrics.DENSITY_DEFAULT
    }
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.style = Paint.Style.STROKE
    paint.strokeCap = Paint.Cap.ROUND
    paint.strokeJoin = Paint.Join.ROUND
    paint.strokeWidth = 4f
    if (anchor) {
        paint.color = if (faded) android.graphics.Color.rgb(142, 142, 147) else android.graphics.Color.rgb(255, 59, 48)
        canvas.drawCircle(32f, 15f, 5f, paint)
        canvas.drawLine(32f, 20f, 32f, 49f, paint)
        canvas.drawLine(23f, 27f, 41f, 27f, paint)
        val arms = Path().apply { moveTo(14f, 35f); cubicTo(15f, 47f, 26f, 50f, 32f, 50f); cubicTo(38f, 50f, 49f, 47f, 50f, 35f) }
        canvas.drawPath(arms, paint)
        canvas.drawLine(14f, 35f, 22f, 39f, paint)
        canvas.drawLine(50f, 35f, 42f, 39f, paint)
        // The tip reaches the bitmap's bottom-center, the marker's geographic anchor.
        // This keeps the tether attached to the tip at every zoom level.
        paint.style = Paint.Style.FILL
        canvas.drawPath(Path().apply {
            moveTo(27f, 49f)
            lineTo(32f, 64f)
            lineTo(37f, 49f)
            close()
        }, paint)
    } else {
        val hull = Path().apply { moveTo(32f, 10f); cubicTo(20f, 20f, 17f, 34f, 20f, 51f); lineTo(44f, 51f); cubicTo(47f, 34f, 44f, 20f, 32f, 10f); close() }
        paint.style = Paint.Style.FILL
        paint.color = android.graphics.Color.rgb(23, 74, 139)
        canvas.drawPath(hull, paint)
        paint.style = Paint.Style.STROKE
        paint.color = android.graphics.Color.WHITE
        paint.strokeWidth = 2f
        canvas.drawPath(hull, paint)
        paint.style = Paint.Style.FILL
        paint.color = android.graphics.Color.rgb(23, 35, 49)
        canvas.drawRoundRect(24f, 27f, 40f, 44f, 3f, 3f, paint)
        paint.color = android.graphics.Color.rgb(195, 220, 235)
        canvas.drawRoundRect(26f, 29f, 38f, 36f, 2f, 2f, paint)
        paint.color = android.graphics.Color.WHITE
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1.3f
        canvas.drawLine(32f, 14f, 32f, 23f, paint)
        canvas.drawLine(24f, 46f, 40f, 46f, paint)
        canvas.drawLine(23f, 49f, 41f, 49f, paint)
        canvas.drawLine(32f, 29f, 32f, 36f, paint)
        canvas.drawLine(22f, 30f, 21f, 43f, paint)
        canvas.drawLine(42f, 30f, 43f, 43f, paint)
    }
    return bitmap
}

private fun hazardMarker(kind: HazardKind): Bitmap {
    val b = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888).apply { density = android.util.DisplayMetrics.DENSITY_DEFAULT }
    val c = Canvas(b)
    val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.rgb(255, 69, 58); style = Paint.Style.STROKE; strokeWidth = 3f; strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND }
    val path = Path()
    when (kind) {
        HazardKind.ROCK -> { path.moveTo(7f, 36f); path.lineTo(17f, 13f); path.lineTo(27f, 24f); path.lineTo(34f, 17f); path.lineTo(42f, 36f); path.close() }
        HazardKind.SHOAL -> { for (y in listOf(16f, 25f, 34f)) { path.moveTo(7f, y); path.cubicTo(18f, y-9, 28f, y+9, 41f, y) } }
        HazardKind.DOCK -> { path.moveTo(8f, 10f); path.lineTo(40f, 10f); path.moveTo(24f, 10f); path.lineTo(24f, 40f); path.moveTo(12f, 10f); path.lineTo(12f, 24f); path.moveTo(36f, 10f); path.lineTo(36f, 24f) }
        HazardKind.BOAT -> { path.moveTo(24f, 6f); path.quadTo(8f, 18f, 12f, 40f); path.lineTo(36f, 40f); path.quadTo(40f, 18f, 24f, 6f); path.close() }
        HazardKind.OTHER -> { path.moveTo(24f, 6f); path.lineTo(44f, 40f); path.lineTo(4f, 40f); path.close(); path.moveTo(24f, 18f); path.lineTo(24f, 28f); path.moveTo(24f, 34f); path.lineTo(24f, 35f) }
    }
    p.color = android.graphics.Color.WHITE; p.strokeWidth = 6f; c.drawPath(path, p)
    p.color = android.graphics.Color.rgb(255, 69, 58); p.strokeWidth = 3f; c.drawPath(path, p)
    return b
}
