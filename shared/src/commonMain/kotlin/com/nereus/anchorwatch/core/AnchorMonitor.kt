package com.nereus.anchorwatch.core

import kotlin.math.*

data class Coordinate(val latitude: Double, val longitude: Double) {
    init { require(latitude.isFinite() && latitude in -90.0..90.0 && longitude.isFinite() && longitude in -180.0..180.0) }
}
object Geo {
    const val EARTH_RADIUS = 6_371_008.8
    fun distance(a: Coordinate, b: Coordinate): Double {
        val lat1 = a.latitude * PI / 180
        val lat2 = b.latitude * PI / 180
        val h = sin((lat2 - lat1) / 2).pow(2) + cos(lat1) * cos(lat2) * sin((b.longitude - a.longitude) * PI / 360).pow(2)
        return 2 * EARTH_RADIUS * asin(sqrt(h.coerceIn(0.0, 1.0)))
    }
    /** Initial true bearing, clockwise from north. Coincident positions use north. */
    fun bearing(from: Coordinate, to: Coordinate): Double {
        val lat1 = from.latitude * PI / 180
        val lat2 = to.latitude * PI / 180
        val deltaLon = (to.longitude - from.longitude) * PI / 180
        return (atan2(sin(deltaLon) * cos(lat2), cos(lat1) * sin(lat2) -
            sin(lat1) * cos(lat2) * cos(deltaLon)) * 180 / PI + 360) % 360
    }
    fun destination(start: Coordinate, bearing: Double, meters: Double): Coordinate {
        require(bearing.isFinite() && meters.isFinite() && meters >= 0)
        val delta = meters / EARTH_RADIUS
        val theta = bearing * PI / 180
        val lat1 = start.latitude * PI / 180
        val lat2 = asin((sin(lat1) * cos(delta) + cos(lat1) * sin(delta) * cos(theta)).coerceIn(-1.0, 1.0))
        val lon = start.longitude + atan2(sin(theta) * sin(delta) * cos(lat1), cos(delta) - sin(lat1) * sin(lat2)) * 180 / PI
        return Coordinate(lat2 * 180 / PI, ((lon + 540) % 360) - 180)
    }
}

data class ScopeSettings(
    val depth: Double = 3.048, val tideRise: Double = 0.0,
    val bowHeight: Double = 1.219, val boatLength: Double = 14.326,
    val scopeRatio: Double = 5.0, val margin: Double = 6.096
) {
    init {
        require(listOf(depth, tideRise, bowHeight, boatLength, margin).all { it.isFinite() && it >= 0 })
        require(scopeRatio.isFinite() && scopeRatio >= 1)
    }
    val height get() = depth + tideRise + bowHeight
    val suggestedRode get() = scopeRatio * height
    val suggestedRadius get() = reach(suggestedRode) + boatLength / 2 + margin
    /** Circle geometry for deployed rode, bounded to the monitor's supported radius. */
    fun alarmRadius(actualRode: Double): Double = (reach(actualRode) + boatLength / 2 + margin).coerceIn(10.0, 300.0)
    fun reach(actualRode: Double): Double {
        require(actualRode.isFinite() && actualRode >= 0)
        return sqrt(max(0.0, actualRode * actualRode - height * height))
    }
}

/** All timestamps use one caller-supplied monotonic clock, in milliseconds. */
data class Fix(val coordinate: Coordinate, val accuracy: Double, val time: Long)
enum class Alarm { OUTSIDE_CIRCLE, GPS_LOST, GPS_POOR }
enum class MonitorStatus { IDLE, ACQUIRING, HOLDING, OUTSIDE_PENDING, GPS_INTERRUPTED, ALARM }
data class MonitorSnapshot(
    val anchor: Coordinate?, val fix: Fix?, val radius: Double, val rode: Double,
    val distance: Double?, val alarm: Alarm?, val status: MonitorStatus
)

/** Circle monitoring only. It does not infer seabed holding capacity or move an anchor. */
class AnchorMonitor {
    var anchor: Coordinate? = null; private set
    var radius = 50.0; private set
    var rode = 30.0; private set
    var fix: Fix? = null; private set
    var alarm: Alarm? = null; private set
    private var started = 0L
    private var lastArrival: Long? = null
    private var newestMeasurement: Long? = null
    private var outsideCount = 0
    private var acknowledged: Alarm? = null
    private var acknowledgedAt = 0L

    fun accept(candidate: Fix, now: Long): Boolean {
        lastArrival = now
        if (!candidate.accuracy.isFinite() || candidate.accuracy < 0 ||
            candidate.time > now + 2_000 || now - candidate.time > 15_000 ||
            newestMeasurement?.let { candidate.time <= it } == true) return false
        newestMeasurement = candidate.time
        if (candidate.accuracy > 50) return false
        fix = candidate
        val a = anchor ?: return true
        val distance = Geo.distance(a, candidate.coordinate)
        val benefit = min(candidate.accuracy, radius * 0.3)
        if (distance - benefit > radius) outsideCount++ else if (distance <= radius) {
            outsideCount = 0
            acknowledged = null
        }
        if (outsideCount >= 2) trigger(Alarm.OUTSIDE_CIRCLE, now)
        return true
    }
    fun resetMeasurements() {
        check(anchor == null)
        fix = null; newestMeasurement = null; lastArrival = null
    }
    fun drop(at: Coordinate, now: Long) {
        check(anchor == null)
        anchor = at
        started = now
        lastArrival = now
        outsideCount = 0
        alarm = null
        acknowledged = null
    }
    /** A manual correction requires fresh outside evidence without clearing a latched alarm. */
    fun moveAnchor(at: Coordinate) {
        check(anchor != null)
        anchor = at
        outsideCount = 0
    }
    fun raise() {
        anchor = null; alarm = null; outsideCount = 0; acknowledged = null
    }
    fun setRadius(value: Double) {
        require(value.isFinite() && value in 10.0..300.0)
        if (radius == value) return
        radius = value
        // Require new evidence after editing the circle; an existing alarm remains latched.
        outsideCount = 0
    }
    fun setRode(value: Double) {
        require(value.isFinite() && value in 0.0..1_000.0)
        rode = value
        // Physical reach changes; the observed anchor, circle and alarm do not.
    }
    fun gpsUnavailable(now: Long) {
        if (anchor != null) trigger(Alarm.GPS_LOST, now)
    }
    fun acknowledge(now: Long) {
        acknowledged = alarm
        acknowledgedAt = now
        alarm = null
    }
    private fun trigger(reason: Alarm, now: Long) {
        if (acknowledged == reason && now - acknowledgedAt < 60_000) return
        if (alarm != Alarm.OUTSIDE_CIRCLE) alarm = reason
    }
    fun tick(now: Long): MonitorSnapshot {
        if (anchor != null) {
            if (now - (lastArrival ?: started) > 30_000) trigger(Alarm.GPS_LOST, now)
            else if (now - (fix?.time ?: started) > 60_000) trigger(Alarm.GPS_POOR, now)
        }
        return snapshot(now)
    }
    fun snapshot(now: Long): MonitorSnapshot {
        val status = when {
            anchor == null -> MonitorStatus.IDLE
            alarm != null -> MonitorStatus.ALARM
            fix == null -> MonitorStatus.ACQUIRING
            now - fix!!.time > 15_000 -> MonitorStatus.GPS_INTERRUPTED
            Geo.distance(anchor!!, fix!!.coordinate) > radius -> MonitorStatus.OUTSIDE_PENDING
            else -> MonitorStatus.HOLDING
        }
        return MonitorSnapshot(anchor, fix, radius, rode, anchor?.let { a -> fix?.let { Geo.distance(a, it.coordinate) } }, alarm, status)
    }
}
