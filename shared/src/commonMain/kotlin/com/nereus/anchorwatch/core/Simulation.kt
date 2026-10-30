package com.nereus.anchorwatch.core

import kotlin.math.*

enum class SimulationMode(val title: String) {
    SWING("Swinging at anchor"), WIND_SHIFT("Wind shift"), DRAG("Dragging anchor"),
    GPS_DROPOUT("GPS dropout"), WIDE_SWING("Wide swing"), SLOW_DRAG("Slow drag")
}

/** Scripted position preview, not a holding-capacity or weather model. Distances are metres. */
object SimulationPath {
    fun position(origin: Coordinate, mode: SimulationMode, seconds: Double, radius: Double): Coordinate? {
        require(seconds.isFinite() && seconds >= 0 && radius.isFinite() && radius > 0)
        if (mode == SimulationMode.GPS_DROPOUT && seconds % 120 >= 30 && seconds % 120 < 75) return null
        val wide = mode == SimulationMode.WIDE_SWING || mode == SimulationMode.SLOW_DRAG
        // Multiple smooth periods create changing swing speed, gust excursions and surge.
        // Deterministic motion avoids random GPS-like jumps and repeated perfect arcs.
        val phase = seconds * 2 * PI / 120 + 0.18 * sin(seconds * 2 * PI / 197)
        val bearing = 180 + (if (wide) 140 else 55) * sin(phase) +
            4 * sin(seconds * 2 * PI / 31) + 2 * sin(seconds * 2 * PI / 13) +
            if (mode == SimulationMode.WIND_SHIFT) 110 * (seconds / 120).coerceIn(0.0, 1.0) else 0.0
        val drift = when (mode) {
            SimulationMode.DRAG -> max(0.0, seconds - 20) * radius / 40
            SimulationMode.SLOW_DRAG -> max(0.0, seconds - 60) * radius / 180
            else -> 0.0
        }
        val reach = radius * (0.64 + 0.055 * sin(seconds * 2 * PI / 47) +
            0.025 * sin(seconds * 2 * PI / 19) + 0.02 * sin(seconds * 2 * PI / 173))
        return Geo.destination(Geo.destination(origin, 180.0, drift), bearing, reach)
    }
}
