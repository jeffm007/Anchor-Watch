package com.nereus.anchorwatch

import androidx.compose.runtime.*
import com.nereus.anchorwatch.core.*
import kotlinx.coroutines.*
import java.time.*
import java.time.format.DateTimeFormatter

internal object EnvironmentData {
    var wind by mutableStateOf<WindHour?>(null); private set
    var forecast by mutableStateOf<List<WindHour>>(emptyList()); private set
    var tides by mutableStateOf<TideResult?>(null); private set
    var currents by mutableStateOf<CurrentResult?>(null); private set
    var currentError by mutableStateOf<String?>(null); private set
    var windError by mutableStateOf<String?>(null); private set
    var tideError by mutableStateOf<String?>(null); private set
    var fetched by mutableStateOf<Instant?>(null); private set
    var windFetched by mutableStateOf<Instant?>(null); private set
    var tideFetched by mutableStateOf<Instant?>(null); private set
    var loading by mutableStateOf(false); private set
    var point by mutableStateOf<Coordinate?>(null); private set
    var refresh by mutableIntStateOf(0)
    private val client = EnvironmentClient()
    private var generation = 0L
    fun clear() {
        generation++
        point = null; currents = null; currentError = null; wind = null; forecast = emptyList(); tides = null
        fetched = null; windFetched = null; tideFetched = null; windError = null; tideError = null; loading = false
    }
    suspend fun fetch(at: Coordinate) {
        // Never retain another anchorage's values. Same-location refreshes keep the last usable data.
        if (point != at) clear()
        val request = ++generation
        loading = true; point = at
        windError = null; tideError = null; currentError = null
        try {
            supervisorScope {
                launch {
                    val result = capture { client.weather(at) }
                    if (generation == request) result.fold({ wind = it.first; forecast = it.second; windFetched = Instant.now() }, { windError = it.message ?: "Weather unavailable" })
                }
                launch {
                    val result = capture { client.tides(at) }
                    if (generation == request) result.fold({ tides = it; tideFetched = Instant.now() }, { tideError = it.message ?: "Tides unavailable" })
                }
                launch {
                    val result = capture { client.currents(at) }
                    if (generation == request) result.fold({ currents = it }, { currentError = it.message ?: "Currents unavailable" })
                }
            }
            if (generation == request) fetched = listOfNotNull(windFetched, tideFetched).maxOrNull()
        } finally { if (generation == request) loading = false }
    }
}
internal fun localTime(time: Instant): String = DateTimeFormatter.ofPattern("EEE h:mm a z").withZone(ZoneId.systemDefault()).format(time)

/** Simulated fixes never fall through to the real phone's GPS or saved anchorage. */
internal fun environmentPoint(simulation: Coordinate?, anchor: Coordinate?, gps: Coordinate?): Coordinate? = simulation ?: anchor ?: gps

internal fun environmentLocationLabel(): String {
    val source = when {
        WatchSession.simulation != null -> "Simulation · ${WatchSession.simulationHarbor.title}"
        WatchSession.snapshot.anchor != null -> "Anchor location"
        EnvironmentData.point != null -> "Phone GPS location"
        else -> "Waiting for a location"
    }
    return source + (EnvironmentData.point?.let { String.format(java.util.Locale.US, " · %.4f, %.4f", it.latitude, it.longitude) } ?: "")
}
