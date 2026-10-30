package com.nereus.anchorwatch.core

import kotlin.test.*

class SimulationTest {
    private val origin = Coordinate(28.615, -96.62)
    @Test fun holdingModesStayInsideCircleAndGenerateMovement() {
        for (mode in listOf(SimulationMode.SWING, SimulationMode.WIND_SHIFT, SimulationMode.WIDE_SWING)) {
            val points = (0..240).map { SimulationPath.position(origin, mode, it.toDouble(), 50.0)!! }
            assertTrue(points.all { Geo.distance(origin, it) < 50 })
            assertTrue(Geo.distance(points[0], points[30]) > 10)
        }
    }
    @Test fun draggingTriggersRealCircleLogicWithoutMovingAnchor() {
        for (mode in listOf(SimulationMode.DRAG, SimulationMode.SLOW_DRAG)) {
            val monitor = AnchorMonitor(); monitor.drop(origin, 0)
            for (second in 0..600) {
                val time = second * 1000L
                monitor.accept(Fix(SimulationPath.position(origin, mode, second.toDouble(), 50.0)!!, 2.0, time), time)
            }
            assertEquals(Alarm.OUTSIDE_CIRCLE, monitor.alarm)
            assertEquals(origin, monitor.anchor)
        }
    }
    @Test fun swingHasSurgeWithoutPositionJumps() {
        val points = (0..1200).map { SimulationPath.position(origin, SimulationMode.SWING, it / 5.0, 50.0)!! }
        val distances = points.map { Geo.distance(origin, it) }
        assertTrue(distances.max() - distances.min() > 5)
        assertTrue(points.zipWithNext().all { (a, b) -> Geo.distance(a, b) < 1.0 })
    }
    @Test fun headingPointsTowardAnchorAcrossCompassAndDateLine() {
        for (angle in listOf(0.0, 90.0, 180.0, 270.0)) {
            assertEquals(angle, Geo.bearing(origin, Geo.destination(origin, angle, 100.0)), 0.001)
        }
        assertEquals(90.0, Geo.bearing(Coordinate(0.0, 179.999), Coordinate(0.0, -179.999)), 0.001)
    }
    @Test fun dropoutHasUsableFixesBeforeAndAfterGap() {
        assertNotNull(SimulationPath.position(origin, SimulationMode.GPS_DROPOUT, 29.0, 50.0))
        assertNull(SimulationPath.position(origin, SimulationMode.GPS_DROPOUT, 30.0, 50.0))
        assertNull(SimulationPath.position(origin, SimulationMode.GPS_DROPOUT, 74.0, 50.0))
        assertNotNull(SimulationPath.position(origin, SimulationMode.GPS_DROPOUT, 75.0, 50.0))
    }
}
