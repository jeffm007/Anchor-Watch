package com.nereus.anchorwatch.calculations

import kotlin.math.*

/** Repeatable physical simulation, ported from iOS. Inputs and integration use SI. */
class Wiggle(private val periods: List<Double>, seed: ULong) {
    private val phases: List<Double>
    init { var x = seed * 0x9E3779B97F4A7C15uL; phases = periods.map { x = x xor (x shr 12); x = x xor (x shl 25); x = x xor (x shr 27); (x % 10_000u).toDouble() / 10_000 * 2 * PI } }
    operator fun invoke(t: Double) = periods.indices.sumOf { sin(2 * PI * t / periods[it] + phases[it]) } / periods.size
}
data class SimWeather(val wind: (Double) -> Pair<Double, Double>, val gustiness: Double, val currentMax: Double,
    val floodToward: Double, val tideRange: Double, val holdingFactor: Double = 1.0) {
    fun current(t: Double): Pair<Double, Double> { val v = currentMax * sin(2 * PI * t / (12.42 * 3600)); return abs(v) to if (v >= 0) floodToward else (floodToward + 180) % 360 }
    fun tide(t: Double) = tideRange / 2 * (1 - cos(2 * PI * t / (12.42 * 3600)))
}
class AnchorPhysics(initial: Boat, val weather: SimWeather) {
    data class Boat(val rode: Double, val depth: Double, val bowHeight: Double, val chainWeight: Double, val frontWindage: Double,
        val sideWindage: Double, val underwater: Double, val mass: Double, val bowToPhone: Double, val holding: Double)
    var boat = initial; private set
    var anchor = ModelPoint(0.0, 0.0); private set
    var bow = ModelPoint(0.0, 0.0); private set
    var velocity = ModelPoint(0.0, 0.0); private set
    var time = 0.0; private set
    private val gust = Wiggle(listOf(23.0, 47.0, 113.0, 271.0), 1u)
    private val sheer = Wiggle(listOf(61.0, 97.0, 157.0), 2u)
    private val drift = Wiggle(listOf(600.0, 1400.0, 3100.0), 3u)
    private val driftTurn = Wiggle(listOf(900.0, 2200.0, 5000.0), 4u)
    private var table: Pair<Double, List<Pair<Double, Double>>>? = null
    init {
        require(initial.mass > 0)
        val away = Math.toRadians(weather.wind(0.0).second + 180); val lie = max(0.0, initial.rode - initial.depth - initial.bowHeight) * 0.8
        bow = ModelPoint(lie * sin(away), lie * cos(away))
    }
    fun updateBoat(updated: Boat) {
        require(updated.mass > 0)
        val value = updated.copy(depth = updated.depth - weather.tide(time)); val old = boat; boat = value
        if (value.rode != old.rode || value.chainWeight != old.chainWeight || value.bowHeight != old.bowHeight) { table = null; constrainBow(boat.depth + weather.tide(time)) }
    }
    fun windNow(): Pair<Double, Double> { val w = weather.wind(time); return max(0.0, w.first * (1 + weather.gustiness * gust(time))) to w.second }
    val phone: ModelPoint get() {
        var dx = bow.x - anchor.x; var dy = bow.y - anchor.y; var d = hypot(dx, dy)
        if (d < 0.5) { val away = Math.toRadians(weather.wind(time).second + 180); dx = sin(away); dy = cos(away); d = 1.0 }
        return ModelPoint(bow.x + dx / d * boat.bowToPhone, bow.y + dy / d * boat.bowToPhone)
    }
    fun pull(distance: Double, depth: Double): Double {
        val h = depth + boat.bowHeight
        if (table == null || abs(table!!.first - h) > 0.05) table = h to catenary(boat.rode, h, boat.chainWeight)
        val rows = table!!.second
        if (distance <= rows.first().second) return 0.0
        val i = rows.indexOfFirst { it.second >= distance }
        if (i <= 0) return rows.last().first + (distance - rows.last().second) * 50_000
        val a = rows[i - 1]; val b = rows[i]; val f = (distance - a.second) / max(b.second - a.second, 1e-6)
        return a.first + f * (b.first - a.first)
    }
    private fun constrainBow(depth: Double) {
        val h = depth + boat.bowHeight; val taut = if (boat.rode > h) sqrt(boat.rode.pow(2) - h * h) else 0.0
        var ex = bow.x - anchor.x; var ey = bow.y - anchor.y; val e = hypot(ex, ey)
        if (e > taut && e > 0) {
            ex /= e; ey /= e; bow = ModelPoint(anchor.x + ex * taut, anchor.y + ey * taut)
            val out = velocity.x * ex + velocity.y * ey
            if (out > 0) velocity = ModelPoint(velocity.x - out * ex, velocity.y - out * ey)
        }
    }
    fun step(dt: Double = 1.0) {
        require(dt > 0 && dt <= 1)
        time += dt; val depth = boat.depth + weather.tide(time); val w = windNow(); val wt = Math.toRadians(w.second + 180); val wm = w.first * 0.514444
        val flow = weather.current(time); val ft = Math.toRadians(flow.second); val fm = flow.first * 0.514444
        var dx = bow.x - anchor.x; var dy = bow.y - anchor.y; val d = max(hypot(dx, dy), 1e-6); dx /= d; dy /= d
        val across = sin(atan2(dx, dy) - wt); val area = boat.frontWindage + (boat.sideWindage - boat.frontWindage) * across * across
        val windF = 0.5 * 1.225 * area * wm * wm
        var fx = windF * sin(wt); var fy = windF * cos(wt); val side = 0.35 * windF * sheer(time)
        fx += side * cos(wt); fy -= side * sin(wt)
        val wander = 40 * (0.5 + 0.5 * drift(time)); val turn = driftTurn(time) * 2 * PI; fx += wander * sin(turn); fy += wander * cos(turn)
        val rx = fm * sin(ft) - velocity.x; val ry = fm * cos(ft) - velocity.y
        val water = 0.5 * 1025 * boat.underwater * hypot(rx, ry) + 400; fx += water * rx; fy += water * ry
        val tension = pull(d, depth); fx -= tension * dx; fy -= tension * dy
        velocity = ModelPoint(velocity.x + fx / boat.mass * dt, velocity.y + fy / boat.mass * dt)
        bow = ModelPoint(bow.x + velocity.x * dt, bow.y + velocity.y * dt); constrainBow(depth)
        val hold = boat.holding * weather.holdingFactor
        if (tension > hold && hold > 0) { val creep = min(0.3, 0.05 * (tension / hold - 1)) * dt; anchor = ModelPoint(anchor.x + dx * creep, anchor.y + dy * creep) }
    }
    companion object {
        fun catenary(rode: Double, h: Double, weight: Double): List<Pair<Double, Double>> {
            val taut = if (rode > h) sqrt(rode * rode - h * h) else 0.0
            val rows = mutableListOf(0.0 to max(0.0, rode - h)); var pull = 5.0
            while (pull < 400_000) {
                val a = pull / max(weight, 1.0); val s = sqrt(h * h + 2 * a * h)
                val reach = if (s <= rode) rode - s + a * asinh(s / a) else taut
                rows.add(pull to min(reach, taut)); if (s > rode) break; pull *= 1.15
            }
            rows.add(rows.last().first * 3 to taut); return rows
        }
    }
}
