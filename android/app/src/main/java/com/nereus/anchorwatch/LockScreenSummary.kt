package com.nereus.anchorwatch

import com.nereus.anchorwatch.core.*
import com.nereus.anchorwatch.calculations.Outlook
import java.time.Instant
import java.util.Locale
import kotlin.math.roundToInt

/** Pure presentation policy: never present an old GPS distance or another location's wind as current. */
internal data class LockScreenSummary(val status: String, val distance: String, val wind: String) {
    val compact get() = "$status · $distance"
    val expanded get() = "$status\n$distance\n$wind"
    companion object {
        fun create(snapshot: MonitorSnapshot, now: Long, feet: Boolean, wind: WindHour?,
                   weatherPoint: Coordinate?, weatherFetched: Instant?, wallTime: Instant): LockScreenSummary {
            val fresh = snapshot.fix?.let { now - it.time in 0..15_000 && it.accuracy <= 50 } == true
            val status = when (snapshot.alarm) {
                Alarm.OUTSIDE_CIRCLE -> "ALARM · Outside alarm circle"
                Alarm.GPS_LOST -> "ALARM · GPS signal lost"
                Alarm.GPS_POOR -> "ALARM · GPS accuracy inadequate"
                null -> when {
                    snapshot.anchor == null -> "GPS active · No anchor set"
                    !fresh -> "Waiting for usable GPS"
                    snapshot.status == MonitorStatus.HOLDING -> "Within alarm circle"
                    snapshot.status == MonitorStatus.OUTSIDE_PENDING -> "Outside circle · Confirming GPS"
                    else -> "Waiting for usable GPS"
                }
            }
            val distanceMeters = snapshot.distance
            val distance = when {
                snapshot.anchor == null -> "Anchor distance: —"
                !fresh || distanceMeters == null -> "Anchor distance: unavailable · GPS not current"
                else -> "Anchor distance: ${String.format(Locale.US, "%.0f", distanceMeters / if (feet) 0.3048 else 1.0)} ${if (feet) "ft" else "m"}"
            }
            val at = snapshot.anchor ?: snapshot.fix?.takeIf { fresh }?.coordinate
            val nearby = at != null && weatherPoint != null && Geo.distance(at, weatherPoint) <= 2_000
            val recent = weatherFetched != null && wallTime.epochSecond - weatherFetched.epochSecond in 0..1800 &&
                wind != null && wallTime.epochSecond - wind.time.epochSecond in -300..3600
            val weather = when {
                wind == null || !nearby -> "Wind estimate: unavailable"
                !recent -> "Wind estimate: stale · Open app to refresh"
                else -> "Wind estimate: ${Outlook.compass(wind.direction)} ${wind.speed.roundToInt()} kt · Gusts ${wind.gust.roundToInt()} kt"
            }
            return LockScreenSummary(status, distance, weather)
        }
    }
}
