package com.nereus.anchorwatch.core

import java.io.File
import kotlin.test.*

class ScopeFixtureTest {
    @Test fun sharedScopeFixturesMatch() {
        val rows = File(System.getProperty("anchor.fixtures"), "scope.csv").readLines().drop(1)
        assertTrue(rows.isNotEmpty())
        for (row in rows) {
            val cells = row.split(',')
            val v = cells.drop(1).map(String::toDouble)
            val s = ScopeSettings(v[0], v[1], v[2], v[3], v[4], v[5])
            assertEquals(v[6], s.suggestedRode, 1e-8, cells[0])
            assertEquals(v[7], s.suggestedRadius, 1e-8, cells[0])
        }
    }
}
