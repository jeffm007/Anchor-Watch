package com.nereus.anchorwatch

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class WaterMathTest {
    private val start = Instant.parse("2026-10-17T00:00:00Z")
    private val tides = listOf(TidePrediction(start, 1.0, false), TidePrediction(start.plusSeconds(21600), 3.0, true))
    @Test fun tideInterpolationRequiresCoverageAndKeepsExtremes() {
        assertNull(WaterMath.height(start.minusSeconds(1), tides))
        assertNull(WaterMath.height(start.plusSeconds(21601), tides))
        assertEquals(1.0, WaterMath.height(start, tides)!!, 1e-9)
        assertEquals(3.0, WaterMath.height(start.plusSeconds(21600), tides)!!, 1e-9)
        assertEquals(2.0, WaterMath.height(start.plusSeconds(10800), tides)!!, 1e-9)
    }
    @Test fun sounderUsesTideDifferencesAndCanRebaseOnlyWithOriginalCoverage() {
        val reading = DepthReference(5.0, start, "A", 1.0)
        assertEquals(7.0, reading.depthAt(start.plusSeconds(21600), TideResult("A", 0.0, tides))!!, 1e-9)
        val shifted = tides.map { it.copy(height = it.height + 10) }
        assertEquals(7.0, reading.depthAt(start.plusSeconds(21600), TideResult("B", 0.0, shifted))!!, 1e-9)
        assertNull(reading.depthAt(start.plusSeconds(21600), TideResult("B", 0.0, shifted.drop(1))))
    }
    @Test fun fallingTideCannotProduceNegativeWaterDepth() {
        val reading = DepthReference(0.5, start.plusSeconds(21600), "A", 3.0)
        assertEquals(0.0, reading.depthAt(start, TideResult("A", 0.0, tides))!!, 1e-9)
    }
    @Test fun currentTracksSignedVelocityAndDirectionWithoutExtrapolating() {
        val events = listOf(CurrentEvent(start, -2.0, 90.0, 270.0), CurrentEvent(start.plusSeconds(3600), 0.0, 90.0, 270.0))
        val flow = WaterMath.flow(start.plusSeconds(1800), events)!!
        assertEquals(-1.0, flow.first, 1e-9)
        assertEquals(270.0, flow.second, 1e-9)
        assertNull(WaterMath.flow(start.minusSeconds(1), events))
        assertNull(WaterMath.flow(start.plusSeconds(3601), events))
    }
    @Test fun dashboardSeparatesStationHeightFromWaterDepth() {
        val tide = TideResult("A", 0.0, tides)
        val result = WaterMath.dashboard(start.plusSeconds(10800), tide, DepthReference(5.0, start, "A", 1.0))
        assertEquals(2.0, result.heightNow!!, 1e-9)
        assertEquals(7.0, result.depthAtHigh!!, 1e-9)
        assertEquals(1.0, result.riseToHigh!!, 1e-9)
        assertTrue(result.next!!.high)
    }
    @Test fun dashboardRequiresSounderReferenceForHighWaterDepth() {
        val result = WaterMath.dashboard(start, TideResult("A", 0.0, tides), null)
        assertNotNull(result.heightNow)
        assertNull(result.depthAtHigh)
    }
    @Test fun expiredTidesCannotProduceHighWaterDepth() {
        val result = WaterMath.dashboard(start.plusSeconds(30000), TideResult("A", 0.0, tides), DepthReference(5.0, start, "A", 1.0))
        assertNull(result.heightNow)
        assertNull(result.depthAtHigh)
        assertNull(result.next)
    }
}
