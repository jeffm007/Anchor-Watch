package com.nereus.anchorwatch

import android.content.Context
import androidx.compose.runtime.*
import java.time.Instant

/** A measured sounder reference is independent of manual future tide allowance. */
internal object WaterDepth {
    private var live by mutableStateOf<DepthReference?>(null)
    private var demo by mutableStateOf<DepthReference?>(null)
    val reference get() = if (WatchSession.simulation != null) demo else live
    fun resetDemo() { demo = null }
    fun load(context: Context) {
        val p = context.getSharedPreferences("water", Context.MODE_PRIVATE)
        live = runCatching { DepthReference(p.getString("depth", null)!!.toDouble(), Instant.ofEpochMilli(p.getLong("time", 0)),
            p.getString("station", null), p.getString("tide", null)?.toDouble()) }.getOrNull()
    }
    fun confirm(context: Context, depth: Double) {
        val now = Instant.now()
        val tide = EnvironmentData.tides
        val value = DepthReference(depth, now, tide?.station, tide?.let { WaterMath.height(now, it.events) })
        if (WatchSession.simulation != null) { demo = value; return }
        live = value
        context.getSharedPreferences("water", Context.MODE_PRIVATE).edit().putString("depth", depth.toString())
            .putLong("time", now.toEpochMilli()).putString("station", value.station).putString("tide", value.tideHeight?.toString()).apply()
    }
    fun estimated(time: Instant): Double? = EnvironmentData.tides?.let { tide ->
        reference?.takeIf { it.depth == WatchSession.scope?.depth }?.depthAt(time, tide)
    }
    fun liveDepth(time: Instant) = estimated(time) ?: (WatchSession.scope ?: WatchSession.boatGeometry).depth
    fun detail(time: Instant): String {
        val ref = reference ?: return "Reading time unknown. Confirm a new sounder reading to follow the tide."
        return if (estimated(time) != null) "Estimated now from sounder reading at ${localTime(ref.measured)}, adjusted using ${EnvironmentData.tides!!.station}."
        else "Sounder reading from ${localTime(ref.measured)}. Tide adjustment unavailable; showing the entered depth."
    }
}
