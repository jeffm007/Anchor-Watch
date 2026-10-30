package com.nereus.anchorwatch

import com.nereus.anchorwatch.calculations.*
import com.nereus.anchorwatch.core.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import kotlin.math.*

class CalculationParityTest {
    private val boat = BoatProfile()
    private val scope = ScopeSettings(depth = 6.0, bowHeight = 1.5, boatLength = 14.3, scopeRatio = 5.0, margin = 5.0)
    @Test fun matches27UnmodifiedIosAssessments() {
        val rows = javaClass.classLoader!!.getResourceAsStream("ios-anchoring-fixtures.csv")!!.bufferedReader().readLines()
        assertEquals(27, rows.size)
        rows.forEach { row ->
            val p = row.split(','); val type = BoatProfile.RodeType.entries.first { it.title == p[0] }; val bottom = AnchorConditions.Bottom.entries.first { it.title == p[1] }
            val r = AnchorMath.assess(boat.copy(rodeType = type), scope, AnchorConditions(wind = 10.0, gust = p[2].toDouble(), current = 0.7, waveHeight = 0.5,
                bottom = bottom, rodeOut = 45.0, direction = AnchorConditions.Direction.ACROSS))
            val actual = listOf(r.load.design, r.anchorLoad, r.shape.reach, r.shape.lying, r.shape.shankAngle, r.safeGust ?: -1.0, r.holding ?: -1.0)
            actual.forEachIndexed { i, v -> assertEquals("$row field $i", p[i + 3].toDouble(), v, 1e-6) }
            assertEquals(p[10].toInt(), r.status.ordinal)
        }
    }
    @Test fun chainLiftOffAndNeededAreInverses() {
        val w = AnchorMath.chainWeight(10.0)
        assertEquals(50.0, AnchorMath.chainNeeded(AnchorMath.liftOffLoad(50.0, 8.0, w), 8.0, w), 1e-6)
    }
    private fun arcLength(shape: RodeShape) = shape.points.zipWithNext().sumOf { (a, b) -> hypot(b.x - a.x, b.y - a.y) }
    @Test fun catenaryPreservesLengthAndBowHeight() {
        val w = AnchorMath.chainWeight(10.0)
        for (load in listOf(1000.0, AnchorMath.liftOffLoad(60.0, 8.0, w) * 3)) {
            val shape = AnchorMath.shape(60.0, 8.0, load, w, 400)
            assertEquals(8.0, shape.points.last().y, 0.01)
            assertEquals(60.0, arcLength(shape), 0.05)
        }
    }
    @Test fun ropeAndMixedRodeCannotClaimChainLiftOffLimit() {
        for (type in listOf(BoatProfile.RodeType.ROPE, BoatProfile.RodeType.CHAIN_AND_ROPE)) {
            val r = AnchorMath.assess(boat.copy(rodeType = type, chainLength = 20.0), scope, AnchorConditions(rodeOut = 45.0))
            assertNull(r.liftOffGust); assertEquals(0.0, r.shape.lying, 0.0); assertTrue(r.shape.shankAngle > 0); assertEquals(r.holdingGust, r.safeGust)
        }
    }
    @Test fun steadyWindChangesDiagramButNotGustLimit() {
        val c = AnchorConditions(wind = 5.0, gust = 25.0, rodeOut = 60.0)
        val a = AnchorMath.assess(boat, scope, c); val b = AnchorMath.assess(boat, scope, c.copy(wind = 20.0))
        assertTrue(a.steadyShape.lying > b.steadyShape.lying); assertEquals(a.safeGust, b.safeGust)
    }
    @Test fun gustInvertsDesignLoadAndCurrentCanExceedLimitAlone() {
        val pull = AnchorMath.load(boat, 30.0, 1.0, 0.5).design
        assertEquals(30.0, AnchorMath.gust(pull, boat, 1.0, 0.5)!!, 1e-6)
        assertEquals(0.0, AnchorMath.gust(1.0, boat, 3.0, 0.5)!!, 0.0)
    }
    @Test fun freeCircleFitRecoversShiftedAnchorAndWaitsForEvidence() {
        val mark = Coordinate(48.61, -123.15)
        val center = AnchorEstimate.coordinate(ModelPoint(5.0, 3.0), mark)
        val track = (0..180).map { i -> Fix(Geo.destination(center, i * 2.0, 40.0), 2.0, 120_000L + i * 10_000) }
        assertNull(AnchorEstimate.evaluate(track.take(15), 0, mark, 40.0, null, null).estimate)
        val e = AnchorEstimate.evaluate(track, 0, mark, 40.0, null, null).estimate!!
        assertEquals(AnchorEstimate.Method.FREE, e.method); assertTrue(Geo.distance(center, e.center) < 0.1)
        assertEquals(40.0, e.radius, 0.1); assertTrue(e.semiMajor >= 2.0)
    }
    @Test fun constrainedFitCannotSupplyDriftEvidence() {
        val mark = Coordinate(48.61, -123.15)
        val track = (0..200).map { i -> Fix(Geo.destination(mark, 30 + 15 * sin(i / 20.0), 40.0), 2.0, i * 10_000L) }
        assertNull(AnchorDrift.rollingSample(track, 0, mark, 40.0))
    }
    @Test fun driftDistinguishesSteadyTranslationFromWander() {
        val mark = Coordinate(48.61, -123.15)
        val moving = (0..20).map { AnchorDrift.Sample(it.toDouble(), Geo.destination(mark, 90.0, it.toDouble()), 2.0) }
        val drift = AnchorDrift.assess(moving)!!
        assertEquals(20.0, drift.distance, 0.1); assertEquals(90.0, drift.bearing, 0.1)
        assertNull(AnchorDrift.assess(moving.mapIndexed { i, s -> s.copy(center = Geo.destination(mark, 90.0, 2 * sin(i.toDouble()) + 2)) }))
    }
    @Test fun distanceTrendMustBreakPriorReach() {
        val samples = (0..40).map { it / 5.0 to 20.0 + it / 5.0 * 2 }
        assertNotNull(AnchorDrift.distanceTrend(samples))
        assertNull(AnchorDrift.distanceTrend((0..40).map { it / 5.0 to 20 + 3 * sin(it.toDouble()) }))
    }
    @Test fun quietWindRequiresFullSwingHazardClearance() {
        val now = Instant.parse("2026-10-17T00:00:00Z"); val mark = Coordinate(48.61, -123.15)
        val h = ForecastHour(now, 0.0, 0.0, 0.0, 5.0, 20.0, ModelStatus.GOOD, null, 0.0, 0.0, 0.0, 0.0)
        val hazard = ModelHazard("rock", Geo.destination(mark, 180.0, 45.0), 5.0, "Rock")
        assertTrue(Outlook.hazardItems(mark, listOf(hazard), listOf(h), 45.0, 1.5, 14.3, 50.0, 4.7) { "$it m" }.any { it.severity == Severity.DANGER })
    }
    @Test fun forecastCoverageCannotBridgeMissingHours() {
        val now = Instant.parse("2026-10-17T00:30:00Z")
        val times = listOf(now.minusSeconds(1800), now.plusSeconds(1800), now.plusSeconds(4 * 3600))
        assertEquals(times[1], Outlook.coverage(times, now, 5400))
        assertNull(Outlook.coverage(listOf(now.plusSeconds(1800)), now, 5400))
    }
    @Test fun compassArcWrapsNorth() { val arc = Outlook.arc(listOf(350.0, 10.0))!!; assertEquals(350.0, arc.first, 0.0); assertEquals(20.0, arc.second, 0.0) }
    @Test fun retrievalRejectsStationaryGpsCourse() {
        val mark = Coordinate(48.61, -123.15); val phone = Geo.destination(mark, 180.0, 30.0)
        val guide = RetrievalGuide.make(phone, mark, 7.0, 6.0, 0.1, 180.0)
        assertNull(guide.relative); assertEquals(23.0, guide.distance, 0.1)
    }
    @Test fun pressureRequiresHistoryAndAppliesIosThresholds() {
        assertNull(PressureTrend.change(listOf(PressureTrend.Reading(0, 1010.0), PressureTrend.Reading(3600_000, 1004.0)), 3600_000))
        val change = PressureTrend.change(listOf(PressureTrend.Reading(0, 1010.0), PressureTrend.Reading(3 * 3600_000, 1004.0)), 3 * 3600_000)!!
        assertEquals(PressureTrend.Level.FALLING_FAST, PressureTrend.level(change))
    }
    @Test fun physicalSimulationStaysWithinTautRodeAndIsRepeatable() {
        val b = AnchorPhysics.Boat(45.0, 6.0, 1.5, AnchorMath.chainWeight(10.0), 17.0, 50.0, 4.5, 33000.0, 7.0, 10000.0)
        val a = AnchorPhysics(b, SimulationDay.FRONT.weather()); val z = AnchorPhysics(b, SimulationDay.FRONT.weather())
        repeat(1200) { a.step(0.2); z.step(0.2) }
        assertEquals(a.phone, z.phone)
        val height = b.depth + a.weather.tide(a.time) + b.bowHeight
        assertTrue(hypot(a.bow.x - a.anchor.x, a.bow.y - a.anchor.y) <= sqrt(b.rode * b.rode - height * height) + 1e-6)
    }
    @Test fun matchesIosPhysicalSimulationPositions() {
        val rows = javaClass.classLoader!!.getResourceAsStream("ios-physics-fixtures.csv")!!.bufferedReader().readLines().map { it.split(',') }
        for ((name, day) in listOf("front" to SimulationDay.FRONT, "gale" to SimulationDay.GALE, "calm" to SimulationDay.CALM)) {
            val b = AnchorPhysics.Boat(45.0, 6.0, 1.5, AnchorMath.chainWeight(10.0), 17.0, 50.0, 4.5, 33000.0, 7.0, 10000.0)
            val p = AnchorPhysics(b, day.weather())
            for (second in 1..3600) {
                p.step()
                rows.firstOrNull { it[0] == name && it[1].toInt() == second }?.let { row ->
                    assertEquals("$name $second east", row[2].toDouble(), p.phone.x, 1e-6)
                    assertEquals("$name $second north", row[3].toDouble(), p.phone.y, 1e-6)
                    assertEquals(row[4].toDouble(), p.anchor.x, 1e-6); assertEquals(row[5].toDouble(), p.anchor.y, 1e-6)
                }
            }
        }
    }
    @Test fun rollingFitsDoNotReportAStationarySwingAsAnchorDrift() {
        val mark = Coordinate(48.61, -123.15)
        val track = (0..480).map { i -> Fix(Geo.destination(mark, i * 15.0, 40 + 1.5 * sin(i / 7.0)), 2.0, i * 5000L) }
        val centers = (17..40).mapNotNull { minute -> AnchorDrift.rollingSample(track.filter { it.time <= minute * 60_000 }, 0, mark, 40.0) }
        assertTrue(centers.size >= 5)
        assertNull(AnchorDrift.assess(centers))
    }
}
