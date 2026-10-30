package com.nereus.anchorwatch

import com.nereus.anchorwatch.core.*
import java.time.Instant
import org.junit.Assert.*
import org.junit.Test

class LockScreenSummaryTest {
    private val at = Coordinate(48.6, -123.1)
    private val wall = Instant.parse("2026-10-17T18:00:00Z")
    private val fix = Fix(at, 4.0, 100_000)
    private val snapshot = MonitorSnapshot(at, fix, 50.0, 30.0, 30.48, null, MonitorStatus.HOLDING)
    private val wind = WindHour(wall, 12.0, 18.0, 90.0)
    private fun summary(s: MonitorSnapshot = snapshot, now: Long = 100_000, feet: Boolean = true,
                        weather: Coordinate = at, fetched: Instant = wall) =
        LockScreenSummary.create(s, now, feet, wind, weather, fetched, wall)

    @Test fun currentLockScreenDataIncludesDistanceStatusAndWind() {
        val result = summary()
        assertEquals("Within alarm circle", result.status)
        assertEquals("Anchor distance: 100 ft", result.distance)
        assertEquals("Wind estimate: E 12 kt · Gusts 18 kt", result.wind)
        assertFalse(result.expanded.contains("Holding"))
        assertEquals("Anchor distance: 30 m", summary(feet = false).distance)
    }
    @Test fun staleGpsNeverShowsOldDistanceOrWithinCircle() {
        val result = summary(now = 116_000)
        assertEquals("Waiting for usable GPS", result.status)
        assertTrue(result.distance.contains("unavailable"))
        assertFalse(result.distance.contains("100 ft"))
    }
    @Test fun alarmsTakePrecedenceOverHolding() {
        assertEquals("ALARM · GPS signal lost", summary(snapshot.copy(alarm = Alarm.GPS_LOST)).status)
        assertEquals("ALARM · Outside alarm circle", summary(snapshot.copy(alarm = Alarm.OUTSIDE_CIRCLE)).status)
        assertEquals("ALARM · GPS accuracy inadequate", summary(snapshot.copy(alarm = Alarm.GPS_POOR)).status)
    }
    @Test fun weatherMustBeRecentAndForThisAnchorage() {
        assertTrue(summary(fetched = wall.minusSeconds(1801)).wind.contains("stale"))
        assertEquals("Wind estimate: unavailable", summary(weather = Coordinate(49.0, -123.0)).wind)
    }
    @Test fun noAnchorDoesNotClaimMonitoringWithinCircle() {
        val result = summary(snapshot.copy(anchor = null, distance = null))
        assertEquals("GPS active · No anchor set", result.status)
        assertEquals("Anchor distance: —", result.distance)
    }
}
