package com.nereus.anchorwatch

import java.time.Instant
import kotlin.math.cos
import kotlin.math.PI
import kotlin.math.max

internal data class TidePrediction(val time: Instant, val height: Double, val high: Boolean)
internal data class TideResult(val station: String, val distance: Double, val events: List<TidePrediction>, val source: String = "NOAA", val datum: String = "MLLW", val selectionNote: String? = null)

internal data class CurrentEvent(val time: Instant, val velocity: Double, val floodToward: Double, val ebbToward: Double) {
    val slack get() = kotlin.math.abs(velocity) < 0.1
}
internal data class CurrentResult(val station: String, val distance: Double, val events: List<CurrentEvent>)
internal data class DepthReference(val depth: Double, val measured: Instant, val station: String?, val tideHeight: Double?) {
    fun depthAt(time: Instant, tide: TideResult): Double? {
        val reference = if (station == tide.station && tideHeight != null) tideHeight else WaterMath.height(measured, tide.events)
        return reference?.let { base -> WaterMath.height(time, tide.events)?.let { max(0.0, depth + it - base) } }
    }
}
internal object WaterMath {
    data class Dashboard(val heightNow: Double?, val next: TidePrediction?, val high: TidePrediction?, val depthAtHigh: Double?, val riseToHigh: Double?)
    fun dashboard(now: Instant, tide: TideResult?, reference: DepthReference?): Dashboard {
        val height = tide?.let { height(now, it.events) }
        val next = tide?.events?.firstOrNull { it.time > now }
        val high = tide?.events?.firstOrNull { it.time > now && it.high }
        val depth = if (tide != null && height != null && high != null) reference?.depthAt(high.time, tide) else null
        return Dashboard(height, next, high, depth, if (height != null && high != null) high.height - height else null)
    }
    fun height(time: Instant, events: List<TidePrediction>): Double? {
        val i = events.indexOfLast { it.time <= time }
        if (i < 0) return null
        val a = events[i]
        if (a.time == time) return a.height
        val b = events.getOrNull(i + 1) ?: return null
        val span = (b.time.toEpochMilli() - a.time.toEpochMilli()).toDouble()
        if (span <= 0) return null
        val f = (time.toEpochMilli() - a.time.toEpochMilli()) / span
        return a.height + (b.height - a.height) * (1 - cos(PI * f)) / 2
    }
    fun flow(time: Instant, events: List<CurrentEvent>): Pair<Double, Double>? {
        val i = events.indexOfLast { it.time <= time }
        if (i < 0) return null
        val a = events[i]
        val b = events.getOrNull(i + 1) ?: return null
        val span = (b.time.toEpochMilli() - a.time.toEpochMilli()).toDouble()
        if (span <= 0) return null
        val f = (time.toEpochMilli() - a.time.toEpochMilli()) / span
        val v = a.velocity + (b.velocity - a.velocity) * (1 - cos(PI * f)) / 2
        return v to if (v >= 0) a.floodToward else a.ebbToward
    }
}
