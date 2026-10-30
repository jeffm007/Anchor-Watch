package com.nereus.anchorwatch

import com.nereus.anchorwatch.core.Coordinate
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.time.Instant

class EnvironmentClientTest {
    @Test fun canadianStationsMustPublishHighLowPredictions() {
        val rows = JSONArray("""[
            {"id":"sidney","officialName":"Sidney","latitude":48.65,"longitude":-123.39,"timeSeries":[{"code":"wlp-hilo"}]},
            {"id":"observed","officialName":"Observed only","latitude":48.6,"longitude":-123.3,"timeSeries":[{"code":"wlo"}]}
        ]""")
        val stations = EnvironmentClient.parseChsStations(rows)
        assertEquals(1, stations.size)
        assertTrue(stations.single().canadian)
        assertEquals("sidney", stations.single().id)
    }
    @Test fun canadianExtremesSortedAndClassifiedByAlternatingHeights() {
        val events = EnvironmentClient.parseChsEvents(JSONArray("""[
            {"eventDate":"2026-10-17T12:00:00.000Z","value":3.0},
            {"eventDate":"2026-10-17T00:00:00Z","value":2.5},
            {"eventDate":"2026-10-17T06:00:00Z","value":0.5},
            {"eventDate":"2026-10-17T18:00:00Z","value":1.0}
        ]"""))
        assertEquals(listOf(true, false, true, false), events.map { it.high })
        assertTrue(events.zipWithNext().all { it.first.time < it.second.time })
    }
    @Test fun locationRoutingKeepsSimulationsSeparateFromPhoneGps() {
        val gps = Coordinate(49.0, -123.0)
        val anchor = Coordinate(48.0, -123.0)
        assertEquals(gps, environmentPoint(null, null, gps))
        assertEquals(anchor, environmentPoint(null, anchor, gps))
        for (harbor in SimulationHarbor.entries) assertEquals(harbor.coordinate, environmentPoint(harbor.coordinate, anchor, gps))
        assertNull(environmentPoint(null, null, null))
    }
    /** Opt in explicitly; ordinary builds never depend on provider availability. */
    @Test fun liveWeatherAndTidesAtBothHarbors() = runBlocking {
        assumeTrue(System.getenv("NEREUS_LIVE_CHECK") == "1")
        val client = EnvironmentClient()
        for (harbor in SimulationHarbor.entries) {
            val now = Instant.now()
            val (wind, forecast) = client.weather(harbor.coordinate, now)
            assertTrue(wind.speed.isFinite() && wind.gust.isFinite() && wind.direction.isFinite())
            assertTrue(kotlin.math.abs(wind.time.epochSecond - now.epochSecond) < 2 * 3600)
            assertTrue(forecast.size >= 20)
            assertTrue(forecast.last().time > now.plusSeconds(20 * 3600))
            val tide = client.tides(harbor.coordinate, now)
            assertTrue(tide.distance <= 25_000)
            assertNotNull(WaterMath.height(now, tide.events))
            assertTrue(tide.events.last().time > now.plusSeconds(24 * 3600))
            if (harbor == SimulationHarbor.SIDNEY) assertEquals("Canadian Hydrographic Service", tide.source)
            else {
                assertEquals("NOAA", tide.source)
                assertTrue(tide.station.contains("9449834"))
            }
            println("${harbor.title}: weather ${forecast.size} hours; ${tide.source} / ${tide.station}; ${tide.events.size} tide events, through ${tide.events.last().time}")
        }
    }
}
