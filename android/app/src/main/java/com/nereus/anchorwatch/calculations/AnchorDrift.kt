package com.nereus.anchorwatch.calculations

import com.nereus.anchorwatch.core.*
import kotlin.math.*

object AnchorDrift {
    data class Sample(val minute: Double, val center: Coordinate, val semiMajor: Double)
    data class Drift(val distance: Double, val bearing: Double, val metersPerMinute: Double, val minutes: Double, val from: Coordinate, val to: Coordinate)
    fun rollingSample(track: List<Fix>, dropped: Long, mark: Coordinate, radius: Double, timeScale: Double = 1.0): Sample? {
        val scale = max(timeScale, 1.0); val latest = track.lastOrNull()?.time ?: return null
        val from = latest - (15 * 60_000 / scale).toLong()
        if (from < dropped + 2 * 60_000 / scale) return null
        val fit = AnchorEstimate.fit(track.filter { it.time >= from }, mark, radius, 15.0, timeScale = scale).estimate ?: return null
        if (fit.method != AnchorEstimate.Method.FREE) return null
        return Sample((latest - dropped) * scale / 60_000, fit.center, fit.semiMajor)
    }
    fun assess(samples: List<Sample>): Drift? {
        val last = samples.lastOrNull() ?: return null
        val recent = samples.filter { last.minute - it.minute <= 20 }
        if (recent.size < 5) return null
        val ref = recent.first().center; val points = recent.map { AnchorEstimate.local(it.center, ref) }; val times = recent.map { it.minute }
        val tm = times.average(); val stt = times.sumOf { (it - tm).pow(2) }; if (stt <= 0) return null
        val xm = points.map { it.x }.average(); val ym = points.map { it.y }.average()
        val vx = times.indices.sumOf { (times[it] - tm) * (points[it].x - xm) } / stt
        val vy = times.indices.sumOf { (times[it] - tm) * (points[it].y - ym) } / stt
        val speed = hypot(vx, vy); val span = times.last() - times.first(); val distance = speed * span
        if (distance < max(5.0, 1.5 * recent.map { it.semiMajor }.average()) || speed <= 0) return null
        val along = points.map { (it.x - xm) * vx / speed + (it.y - ym) * vy / speed }
        val total = along.sumOf { it * it }; val residual = times.indices.sumOf { (along[it] - speed * (times[it] - tm)).pow(2) }
        if (total <= 0 || 1 - residual / total < 0.6) return null
        val start = ModelPoint(xm + vx * (times.first() - tm), ym + vy * (times.first() - tm))
        val end = ModelPoint(xm + vx * (times.last() - tm), ym + vy * (times.last() - tm))
        return Drift(distance, (Math.toDegrees(atan2(vx, vy)) + 360) % 360, speed, span, AnchorEstimate.coordinate(start, ref), AnchorEstimate.coordinate(end, ref))
    }
    fun distanceTrend(samples: List<Pair<Double, Double>>, accuracy: Double = 0.0): Double? {
        val last = samples.lastOrNull() ?: return null; val recent = samples.filter { last.first - it.first <= 3 }; val before = samples.filter { last.first - it.first > 3 }
        if (recent.size < 6 || last.first - recent.first().first < 2.4) return null
        val earlier = before.maxOfOrNull { it.second } ?: return null
        if (last.second <= earlier + max(3.0, accuracy / 2)) return null
        val mx = recent.map { it.first }.average(); val my = recent.map { it.second }.average()
        val sxy = recent.sumOf { (it.first - mx) * (it.second - my) }; val sxx = recent.sumOf { (it.first - mx).pow(2) }; val syy = recent.sumOf { (it.second - my).pow(2) }
        if (sxx <= 0 || syy <= 0) return null
        val slope = sxy / sxx; val r2 = sxy * sxy / (sxx * syy)
        return slope.takeIf { it >= 1 && r2 >= 0.6 }
    }
}
data class RetrievalGuide(val distance: Double, val bearing: Double, val relative: Double?, val overAnchor: Boolean) {
    companion object {
        fun make(phone: Coordinate, anchor: Coordinate, bowOffset: Double, depth: Double, speed: Double?, course: Double?): RetrievalGuide {
            val heading = course?.takeIf { (speed ?: 0.0) >= 0.25 && it >= 0 }
            val bow = Geo.destination(phone, heading ?: Geo.bearing(phone, anchor), bowOffset)
            val distance = Geo.distance(bow, anchor); val bearing = Geo.bearing(bow, anchor)
            return RetrievalGuide(distance, bearing, heading?.let { (bearing - it + 540) % 360 - 180 }, distance <= max(depth * 0.5, 4.0))
        }
    }
    val steer get() = if (overAnchor) "Over anchor · rode up and down" else relative?.let {
        if (abs(it) <= 10) "Anchor dead ahead" else "Turn ${if (it < 0) "port" else "starboard"} ${abs(it).roundToInt()}°"
    } ?: "Anchor ${Outlook.compass(bearing)} · ${bearing.roundToInt()}° true"
}
object PressureTrend {
    data class Reading(val time: Long, val hPa: Double)
    fun change(readings: List<Reading>, now: Long, hours: Double = 3.0): Double? {
        val latest = readings.lastOrNull() ?: return null; val target = now - hours * 3600_000
        val then = readings.minByOrNull { abs(it.time - target) } ?: return null
        if (latest.time - then.time < hours * 3600_000 * 0.8) return null
        return latest.hPa - then.hPa
    }
    enum class Level { STEADY, FALLING_QUICKLY, FALLING_FAST }
    fun level(change: Double?) = if (change == null) Level.STEADY else if (-change >= 6) Level.FALLING_FAST else if (-change >= 3) Level.FALLING_QUICKLY else Level.STEADY
}
