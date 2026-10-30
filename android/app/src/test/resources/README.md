The CSV fixtures were generated on 2026-10-17 by executing the sibling iOS Swift implementations, not by the Android code.

- ios-anchoring-fixtures.csv: all-chain, mixed and rope × sand/mud/rock × 10/25/50 kt gust. Defaults: Nereus BoatProfile; scope depth 6 m, bow 1.5 m, LOA 14.3 m, ratio 5, margin 5 m; wind 10 kt, current 0.7 kt across wind, waves 0.5 m, rode 45 m. Fields: rode type, bottom, gust, design load N, anchor load N, reach m, lying chain m, shank angle degrees, safe gust kt, holding N, status ordinal. Sources: AnchorWatch/Core/AnchoringModel.swift, BoatProfile.swift, ScopeCalculator.swift.
- ios-physics-fixtures.csv: front/gale/calm at 600/1200/3600 one-second steps. Boat: rode 45 m, depth 6 m, bow 1.5 m, 10 mm chain weight from AnchorMath, front/side windage 17/50 m², underwater area 4.5 m², mass 33000 kg, bow-to-phone 7 m, holding 10000 N. Fields: day, elapsed seconds, phone east/north m, anchor east/north m. Source: AnchorWatch/Core/AnchorPhysics.swift and its SimDays/Wiggle implementations.

CalculationParityTest checks every numeric field to 1e-6. Other tests cover invariants and failure conditions independently of these fixtures.
