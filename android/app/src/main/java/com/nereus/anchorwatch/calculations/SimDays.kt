package com.nereus.anchorwatch.calculations

import kotlin.math.*
enum class SimulationDay(val title: String) {
    CALM("Calm and variable"), SEA_BREEZE("Sea breeze"), FRONT("Passing front"), AGAINST_TIDE("Wind against tide"), GALE("Gale / weak set");
    fun weather(): SimWeather {
        val light = Wiggle(listOf(420.0, 1300.0, 3700.0), 11u); val veer = Wiggle(listOf(1800.0, 5400.0, 11000.0), 12u)
        fun ramp(t: Double, a: Double, b: Double): Double { val x = ((t / 3600 - a) / (b - a)).coerceIn(0.0, 1.0); return x * x * (3 - 2 * x) }
        return when (this) {
            CALM -> SimWeather({ t -> max(0.0, 1.4 + 1.3 * light(t)) to (200 + 150 * veer(t) + 360) % 360 }, 0.4, 0.3, 80.0, 2.4)
            SEA_BREEZE -> SimWeather({ t -> val breeze = ramp(t, 4.0, 6.5) * (1 - ramp(t, 11.0, 14.0)); val calm = max(0.0, 1.5 + 1.2 * light(t))
                (calm * (1 - breeze) + (13 + 2 * light(t)) * breeze) to (270 + 15 * veer(t) * breeze + 140 * veer(t) * (1 - breeze) + 360) % 360 }, 0.25, 0.4, 80.0, 2.4)
            FRONT -> SimWeather({ t -> val build = ramp(t, 5.0, 8.0); val shift = ramp(t, 9.5, 11.0); val ease = ramp(t, 14.0, 20.0)
                max(0.0, 8 + 12 * build * (1 - ease) - 3 * shift * ease + 1.5 * light(t)) to (170 + 30 * build + 100 * shift + 8 * veer(t)) % 360 }, 0.35, 0.3, 80.0, 2.4)
            AGAINST_TIDE -> SimWeather({ t -> (10 + 1.5 * light(t)) to (360 + 10 * veer(t)) % 360 }, 0.2, 1.2, 0.0, 3.0)
            GALE -> SimWeather({ t -> (10 + 22 * ramp(t, 1.0, 6.0) * (1 - ramp(t, 16.0, 22.0)) + 2 * light(t)) to (220 + 10 * veer(t)) % 360 }, 0.3, 0.3, 80.0, 2.4, 0.6)
        }
    }
}
