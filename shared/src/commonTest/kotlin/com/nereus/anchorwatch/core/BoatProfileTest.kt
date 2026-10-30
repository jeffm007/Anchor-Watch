package com.nereus.anchorwatch.core

import kotlin.test.*

class BoatProfileTest {
    @Test fun initialProfileMatchesIosScreenshot() {
        val b = BoatProfile()
        assertEquals("Nereus", b.name)
        assertEquals(72_841.0, kotlin.math.round(b.loadedWeight / 0.45359237))
        assertEquals(181.7, kotlin.math.round(b.frontWindage / 0.09290304 * 10) / 10)
        assertEquals(545.1, kotlin.math.round(b.sideWindage(14.326) / 0.09290304 * 10) / 10)
        assertEquals(300.0, b.rodeCarried / 0.3048, 1e-9)
        assertEquals(3.0 / 8, b.chainSize / 25.4, 1e-9)
    }
    @Test fun rodeAndSnubberSelectionsPreserveStoredLengths() {
        val b = BoatProfile(ropeLength = 30.0)
        assertEquals(121.44, b.copy(rodeType = BoatProfile.RodeType.CHAIN_AND_ROPE).rodeCarried, 1e-9)
        assertEquals(30.0, b.copy(rodeType = BoatProfile.RodeType.ROPE).rodeCarried)
        assertEquals(0.0, b.copy(hasSnubber = false).snubber)
        assertEquals(6.096, b.copy(hasSnubber = false).snubberLength)
    }
    @Test fun measuredWindageCanBeResetToEstimateAndInvalidInputsRejected() {
        val b = BoatProfile(windageArea = 40.0, sideWindageArea = 50.0)
        assertEquals(40.0, b.frontWindage); assertEquals(50.0, b.sideWindage(10.0))
        assertEquals(b.estimatedWindage, b.copy(windageArea = null).frontWindage)
        assertFailsWith<IllegalArgumentException> { BoatProfile(displacement = -1.0) }
        assertFailsWith<IllegalArgumentException> { BoatProfile(chainSize = Double.NaN) }
    }
}
