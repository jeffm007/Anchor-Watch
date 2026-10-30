package com.nereus.anchorwatch.core

import kotlin.test.*

class AnchorMonitorTest {
    private val origin = Coordinate(28.615, -96.62)
    private fun fix(distance: Double, time: Long, accuracy: Double = 3.0) = Fix(Geo.destination(origin, 90.0, distance), accuracy, time)
    @Test fun scopeMatchesSwiftDefaults() {
        val s = ScopeSettings()
        assertEquals(21.335, s.suggestedRode, 1e-9)
        assertEquals(34.162945464911644, s.suggestedRadius, 1e-6)
        assertEquals(0.0, s.reach(2.0))
    }
    @Test fun geometryRoundTripAcrossDateLine() {
        val start = Coordinate(10.0, 179.9999)
        val end = Geo.destination(start, 90.0, 150.0)
        assertTrue(end.longitude < 0)
        assertEquals(150.0, Geo.distance(start, end), 1e-6)
    }
    @Test fun rodeChangesNeverMoveAnchorOrAlterCircle() {
        val m = AnchorMonitor(); m.drop(origin, 0)
        m.accept(fix(25.0, 1_000), 1_000)
        for (rode in listOf(100.0, 10.0, 200.0)) {
            m.setRode(rode)
            assertEquals(origin, m.anchor); assertEquals(50.0, m.radius)
            assertNull(m.snapshot(1_000).alarm)
        }
    }
    @Test fun twoFreshOutsideFixesRequiredAndAlarmSurvivesRodeEdit() {
        val m = AnchorMonitor(); m.drop(origin, 0)
        m.accept(fix(60.0, 1_000), 1_000); assertNull(m.alarm)
        m.accept(fix(60.0, 2_000), 2_000); assertEquals(Alarm.OUTSIDE_CIRCLE, m.alarm)
        m.setRode(150.0); assertEquals(Alarm.OUTSIDE_CIRCLE, m.alarm)
    }
    @Test fun staleDuplicateFutureAndPoorFixesCannotConfirmOutside() {
        val m = AnchorMonitor(); m.drop(origin, 0)
        assertTrue(m.accept(fix(60.0, 1_000), 1_000))
        assertFalse(m.accept(fix(60.0, 1_000), 2_000))
        assertFalse(m.accept(fix(60.0, 2_000), 20_000))
        assertFalse(m.accept(fix(60.0, 50_000), 20_000))
        assertFalse(m.accept(fix(60.0, 21_000, 51.0), 21_000))
        assertNull(m.alarm)
    }
    @Test fun insideFixResetsConfirmationAndAccuracyBenefitIsCapped() {
        val m = AnchorMonitor(); m.drop(origin, 0)
        m.accept(fix(60.0, 1_000), 1_000)
        m.accept(fix(20.0, 2_000), 2_000)
        m.accept(fix(70.0, 3_000, 50.0), 3_000); assertNull(m.alarm)
        m.accept(fix(70.0, 4_000, 50.0), 4_000); assertEquals(Alarm.OUTSIDE_CIRCLE, m.alarm)
    }
    @Test fun gpsLossAndPoorAccuracyAreDifferentAlarms() {
        val lost = AnchorMonitor(); lost.drop(origin, 0)
        assertEquals(Alarm.GPS_LOST, lost.tick(30_001).alarm)
        val poor = AnchorMonitor(); poor.drop(origin, 0)
        for (time in 10_000L..70_000L step 10_000) poor.accept(fix(0.0, time, 90.0), time)
        assertEquals(Alarm.GPS_POOR, poor.tick(70_000).alarm)
    }
    @Test fun acknowledgeIsTemporaryAndRaiseStopsMonitoring() {
        val m = AnchorMonitor(); m.drop(origin, 0)
        m.accept(fix(70.0, 1_000), 1_000); m.accept(fix(70.0, 2_000), 2_000)
        m.acknowledge(2_000); assertNull(m.alarm)
        m.accept(fix(70.0, 3_000), 3_000); assertNull(m.alarm)
        m.accept(fix(70.0, 63_000), 63_000); assertEquals(Alarm.OUTSIDE_CIRCLE, m.alarm)
        m.raise(); assertEquals(MonitorStatus.IDLE, m.tick(100_000).status)
    }
    @Test fun outsidePendingNeverReportedAsHolding() {
        val m = AnchorMonitor(); m.drop(origin, 0)
        m.accept(fix(60.0, 1_000), 1_000)
        assertEquals(MonitorStatus.OUTSIDE_PENDING, m.snapshot(1_000).status)
        m.gpsUnavailable(1_000)
        assertEquals(Alarm.GPS_LOST, m.alarm)
    }
    @Test fun restartingGpsCannotReusePreviousFix() {
        val m = AnchorMonitor()
        m.accept(fix(0.0, 1_000), 1_000)
        m.resetMeasurements()
        assertNull(m.fix)
    }
    @Test fun anchorMovePreservesWatchAndRequiresFreshOutsideEvidence() {
        val m = AnchorMonitor(); m.drop(origin, 0); m.setRode(80.0)
        m.accept(fix(70.0, 1_000), 1_000)
        val corrected = Geo.destination(origin, 270.0, 10.0)
        m.moveAnchor(corrected)
        assertEquals(corrected, m.anchor)
        assertEquals(50.0, m.radius); assertEquals(80.0, m.rode)
        assertEquals(fix(70.0, 1_000), m.fix)
        m.accept(fix(70.0, 2_000), 2_000); assertNull(m.alarm)
        m.accept(fix(70.0, 3_000), 3_000); assertEquals(Alarm.OUTSIDE_CIRCLE, m.alarm)
        m.moveAnchor(origin); assertEquals(Alarm.OUTSIDE_CIRCLE, m.alarm)
        m.raise()
        assertFailsWith<IllegalStateException> { m.moveAnchor(origin) }
    }
    @Test fun followingRadiusUsesDeployedRodeAndDepthWithinMonitorLimits() {
        val s = ScopeSettings(depth = 3.0, bowHeight = 1.0, boatLength = 10.0, margin = 2.0)
        assertEquals(kotlin.math.sqrt(100.0 - 16.0) + 7.0, s.alarmRadius(10.0), 1e-9)
        assertTrue(s.alarmRadius(20.0) > s.alarmRadius(10.0))
        assertTrue(s.copy(depth = 5.0).alarmRadius(10.0) < s.alarmRadius(10.0))
        assertEquals(10.0, s.alarmRadius(0.0))
        assertEquals(300.0, s.alarmRadius(1_000.0))
        assertFailsWith<IllegalArgumentException> { s.alarmRadius(Double.NaN) }
    }
    @Test fun invalidInputsRejected() {
        assertFailsWith<IllegalArgumentException> { Coordinate(Double.NaN, 0.0) }
        assertFailsWith<IllegalArgumentException> { ScopeSettings(depth = -1.0) }
        assertFailsWith<IllegalArgumentException> { AnchorMonitor().setRadius(Double.NaN) }
    }
}
