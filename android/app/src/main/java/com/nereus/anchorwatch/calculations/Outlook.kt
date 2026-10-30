package com.nereus.anchorwatch.calculations

import com.nereus.anchorwatch.core.*
import java.time.Instant
import kotlin.math.*

data class ForecastWind(val time: Instant, val speed: Double, val gust: Double, val direction: Double)
data class Flow(val speed: Double, val toward: Double, val flooding: Boolean)
data class ForecastHour(val time: Instant, val speed: Double, val gust: Double, val direction: Double, val depth: Double,
    val safeGust: Double?, val status: ModelStatus, val current: Flow?, val lie: Double, val push: Double, val windPush: Double, val currentPush: Double)
data class ModelHazard(val id: String, val coordinate: Coordinate, val radius: Double, val label: String)
enum class RiskKind { SHALLOW, SCOPE, GUSTS, SWING, WIND_SHIFT, TIDE_TURN, SLACK, HAZARD }
enum class Severity { INFO, CAUTION, DANGER }
data class Risk(val kind: RiskKind, val severity: Severity, val start: Instant, val end: Instant?, val title: String, val detail: String, val subject: String = "")
data class RiskWindow(val start: Instant, val end: Instant, val least: Double)
data class HiddenRisk(val kind: RiskKind, val subject: String, val start: Instant, val end: Instant, val severity: Severity) {
    constructor(r: Risk): this(r.kind, r.subject, r.start, r.end ?: r.start, r.severity)
    fun matches(r: Risk) = r.kind == kind && r.subject == subject && (kind == RiskKind.HAZARD || (r.start <= end.plusSeconds(3600) && (r.end ?: r.start) >= start.minusSeconds(3600)))
    fun covers(r: Risk) = r.severity <= severity && matches(r)
}
object Outlook {
    fun difference(a: Double, b: Double) = abs(((a - b + 540) % 360 + 360) % 360 - 180)
    fun compass(a: Double) = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")[((a / 45).roundToInt() % 8 + 8) % 8]
    fun minPush(b: BoatProfile) = BoatMath.windLoad(b, 5.0) ?: 50.0
    fun swingRadius(rode: Double, depth: Double, bow: Double, bowToPhone: Double): Double {
        val h = depth + bow
        return (if (rode > h) sqrt(rode * rode - h * h) else 0.0) + bowToPhone
    }
    fun clearance(anchor: Coordinate, sternReach: Double, hazard: ModelHazard) = Geo.distance(anchor, hazard.coordinate) - sternReach - hazard.radius
    fun arc(bearings: List<Double>): Pair<Double, Double>? {
        val sorted = bearings.map { (it % 360 + 360) % 360 }.sorted()
        if (sorted.isEmpty()) return null
        if (sorted.size == 1) return sorted.first() to 0.0
        var gap = 360 - sorted.last() + sorted.first(); var start = sorted.first()
        sorted.zipWithNext().forEach { (a, b) -> if (b - a > gap) { gap = b - a; start = b } }
        return if (gap < 30) 0.0 to 360.0 else start to 360 - gap
    }
    fun windows(points: List<Pair<Instant, Double>>, below: Double): List<RiskWindow> {
        val result = mutableListOf<RiskWindow>(); var run: RiskWindow? = null
        fun close() { run?.let(result::add); run = null }
        points.sortedBy { it.first }.forEach { (t, v) ->
            if (!v.isFinite() || v >= below) close() else {
                val p = run
                if (p != null && t.epochSecond - p.end.epochSecond <= 3600) run = p.copy(end = t, least = min(p.least, v))
                else { close(); run = RiskWindow(t, t, v) }
            }
        }; close(); return result
    }
    fun hourly(b: BoatProfile, scope: ScopeSettings, bottom: AnchorConditions.Bottom, rode: Double,
        depths: List<Pair<Instant, Double>>, forecast: List<ForecastWind>, current: (Instant) -> Flow?, now: Instant, hours: Int = 24): List<ForecastHour> =
        forecast.filter { it.time >= now.minusSeconds(1800) && it.time <= now.plusSeconds(hours * 3600L) }.map { sample ->
            val depth = depths.minByOrNull { abs(it.first.epochSecond - sample.time.epochSecond) }?.takeIf { abs(it.first.epochSecond - sample.time.epochSecond) <= 900 }?.second ?: scope.depth
            val flow = current(sample.time)
            val toward = (sample.direction + 180) % 360
            val angle = flow?.let { difference(toward, it.toward) } ?: 0.0
            val direction = if (angle <= 45) AnchorConditions.Direction.WITH else if (angle >= 135) AnchorConditions.Direction.AGAINST else AnchorConditions.Direction.ACROSS
            val c = AnchorConditions(wind = min(sample.speed, sample.gust), gust = sample.gust, bottom = bottom, rodeOut = rode,
                current = flow?.speed ?: 0.5, direction = direction)
            val r = AnchorMath.assess(b, scope.copy(depth = depth, tideRise = 0.0), c)
            val wp = BoatMath.windLoad(b, sample.speed) ?: 0.0; val cp = flow?.let { AnchorMath.currentLoad(b, it.speed) } ?: 0.0
            val east = wp * sin(Math.toRadians(toward)) + cp * sin(Math.toRadians(flow?.toward ?: 0.0))
            val north = wp * cos(Math.toRadians(toward)) + cp * cos(Math.toRadians(flow?.toward ?: 0.0))
            ForecastHour(sample.time, sample.speed, sample.gust, sample.direction, depth, r.safeGust, r.status, flow,
                (Math.toDegrees(atan2(east, north)) + 360) % 360, hypot(east, north), wp, cp)
        }
    fun items(b: BoatProfile, scope: ScopeSettings, rode: Double, depths: List<Pair<Instant, Double>>, hourly: List<ForecastHour>,
        turns: List<Pair<Instant, Boolean>>, slacks: List<Instant>?, anchor: Coordinate?, hazards: List<ModelHazard>, now: Instant,
        length: (Double) -> String): List<Risk> {
        val result = mutableListOf<Risk>()
        if (b.draft > 0) windows(depths, b.draft + AnchorMath.keelClearance).forEach { w ->
            result += Risk(RiskKind.SHALLOW, if (w.least <= b.draft) Severity.DANGER else Severity.CAUTION, w.start, w.end,
                if (w.least <= b.draft) "Aground at low water" else "Under ${length(AnchorMath.keelClearance)} below keel", "Least ${length(w.least - b.draft)} under keel.")
        }
        windows(depths.map { it.first to rode / max(it.second + scope.bowHeight, 0.1) }, 4.0).forEach { w ->
            result += Risk(RiskKind.SCOPE, if (w.least < 3) Severity.DANGER else Severity.CAUTION, w.start, w.end,
                "Scope down to %.1f:1".format(w.least), "High water shortens scope with ${length(rode)} out. Review rode and clearance.")
        }
        var run = mutableListOf<ForecastHour>()
        fun close() {
            if (run.isEmpty()) return
            val peak = run.maxBy { it.gust }; val limit = run.mapNotNull { it.safeGust }.minOrNull()
            result += Risk(RiskKind.GUSTS, if (run.any { it.status == ModelStatus.DANGER }) Severity.DANGER else Severity.CAUTION,
                run.first().time, run.last().time.takeIf { run.size > 1 },
                "Gusts ${peak.gust.roundToInt()} kt, ${if (limit != null && peak.gust > limit) "beyond modeled ${limit.toInt()} kt limit" else "close to modeled limit"}",
                "Peak from ${compass(peak.direction)}. Review rode, shelter and actual set.")
            run = mutableListOf()
        }
        hourly.forEach { if (it.status != ModelStatus.GOOD) { if (run.lastOrNull()?.let { p -> it.time.epochSecond - p.time.epochSecond > 5400 } == true) close(); run.add(it) } else close() }; close()
        val swingTimes = mutableListOf<Instant>()
        val held = hourly.filter { it.push >= minPush(b) }; var reference = held.firstOrNull()
        held.drop(1).forEach { h -> val ref = reference ?: return@forEach
            val turn = difference(h.lie, ref.lie)
            if (turn >= 90) {
                result += Risk(RiskKind.SWING, Severity.CAUTION, h.time, null, "Boat swings about ${(turn / 10).roundToInt() * 10}°",
                    "${if (h.currentPush > h.windPush) "Current takes over" else "Wind changes to ${compass(h.direction)}"}. Anchor must turn and reset; check the new swing clears hazards.")
                swingTimes.add(h.time); reference = h
            }
        }
        val steady = hourly.filter { it.speed >= 8 }; reference = steady.firstOrNull()
        steady.drop(1).forEach { h -> val ref = reference ?: return@forEach
            if (difference(h.direction, ref.direction) >= 60) {
                if (swingTimes.none { abs(it.epochSecond - h.time.epochSecond) <= 5400 }) result += Risk(RiskKind.WIND_SHIFT, Severity.INFO, h.time, null,
                    "Wind shifts ${compass(ref.direction)} → ${compass(h.direction)}", "Check the swing still clears everything.")
                reference = h
            }
        }
        val end = now.plusSeconds(24 * 3600)
        if (slacks != null) slacks.filter { it > now && it <= end }.forEach { result += Risk(RiskKind.SLACK, Severity.INFO, it, null, "Slack water", "Predicted current turn; watch for changing swing.") }
        else turns.filter { it.first > now && it.first <= end }.forEach { (t, high) ->
            val wind = hourly.minByOrNull { abs(it.time.epochSecond - t.epochSecond) }?.speed
            result += Risk(RiskKind.TIDE_TURN, if (wind != null && wind < 6) Severity.CAUTION else Severity.INFO, t, null,
                if (high) "High water" else "Low water", "Tide height is only a proxy for a current turn. Actual slack and swing timing are unknown.")
        }
        if (anchor != null) result += hazardItems(anchor, hazards, hourly, rode, scope.bowHeight, scope.boatLength, minPush(b), b.beam, length)
        return result.sortedBy { it.start }
    }
    fun hazardItems(anchor: Coordinate, hazards: List<ModelHazard>, hourly: List<ForecastHour>, rode: Double, bow: Double, boatLength: Double,
        minPush: Double, beam: Double, length: (Double) -> String): List<Risk> = buildList {
        hazards.forEach { hazard ->
            var run = mutableListOf<Pair<Instant, Double>>()
            fun close() {
                if (run.isNotEmpty()) {
                    val least = run.minOf { it.second }
                    add(Risk(RiskKind.HAZARD, if (least <= 0) Severity.DANGER else Severity.CAUTION, run.first().first,
                        run.last().first.takeIf { run.size > 1 }, if (least <= 0) "Swing reaches ${hazard.label}" else "Swing within ${length(least)} of ${hazard.label}",
                        "Hull and forecast swing clearance includes a 5 m position allowance. Unforecast swings remain possible.", hazard.id))
                }; run = mutableListOf()
            }
            var previous: ForecastHour? = null
            hourly.sortedBy { it.time }.forEach { h ->
                fun bowReach(depth: Double): Double { val height = max(0.0, depth + bow); return if (rode > height) sqrt(rode * rode - height * height) else 0.0 }
                var br = bowReach(h.depth); var reach = br + boatLength; val p = previous
                val adjacent = p != null && h.time.epochSecond - p.time.epochSecond <= 5400
                if (adjacent) { val old = bowReach(p!!.depth); reach = max(reach, old + boatLength); br = min(br, old) }
                val distance = Geo.distance(anchor, hazard.coordinate); val bearing = Geo.bearing(anchor, hazard.coordinate)
                fun gap(at: Double): Double { val angle = Math.toRadians(bearing - at); val along = distance * cos(angle); val across = distance * sin(angle)
                    return hypot(along - along.coerceIn(br, reach), across) - hazard.radius - max(0.0, beam) / 2 - 5 }
                var least = gap(h.lie)
                if (h.push < minPush || (adjacent && p!!.push < minPush)) least = max(0.0, distance - reach) - hazard.radius - max(0.0, beam) / 2 - 5
                else if (adjacent) {
                    val delta = (h.lie - p!!.lie + 540) % 360 - 180; val steps = max(1, ceil(abs(delta)).toInt())
                    for (i in 0..steps) least = min(least, gap(p.lie + delta * i / steps) - reach * PI / 360)
                } else if (p != null) close()
                if (least < 10) run.add(h.time to least) else close()
                previous = h
            }; close()
        }
    }
    /** Contiguous provider coverage; a later point cannot bridge a missing interval. */
    fun coverage(times: List<Instant>, now: Instant, maxGap: Long, startTolerance: Long = 0): Instant? {
        val sorted = times.distinct().sorted(); val first = sorted.lastOrNull { it <= now.plusSeconds(startTolerance) } ?: return null
        if (first < now.minusSeconds(maxGap)) return null
        var end = first
        for (t in sorted.filter { it > first }) { if (t.epochSecond - end.epochSecond > maxGap) break; end = t }
        return end.takeIf { it > now }
    }
}
