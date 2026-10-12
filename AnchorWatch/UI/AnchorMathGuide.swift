import Foundation

/// The user-guide page that shows the maths behind the Anchor tab's load analysis.
/// Every constant is read from `AnchorMath` and `BoatMath`, and the worked example runs the real model,
/// so this page can't drift from the code.
extension UserGuideContent {
    static let anchorMath = GuideTopic(id: "anchormath", title: "How Anchoring works it out", icon: "function",
                                       blocks: AnchorMathGuide.blocks)
}

private enum AnchorMathGuide {
    typealias A = AnchorMath
    typealias B = BoatMath

    static func n(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }
    static func lbf(_ newtons: Double) -> String { String(format: "%.0f lbf", newtons / 4.44822) }
    static func ft(_ m: Double) -> String { String(format: "%.1f ft", m * 3.28084) }

    static var blocks: [GuideTopic.Block] {
        overview + windage + loads + chain + catenary + holding + limits + example + swing + drift + limitations
    }

    // MARK: The pipeline

    static let overview: [GuideTopic.Block] = [
        .text("The **Load analysis** on the Anchor tab (tap it to open) is a static force balance: how hard the wind, current and waves push the boat back, against how much of that the rode and anchor can resist. Everything is in SI units inside (metres, kilograms, newtons, m/s) and converted for display."),
        .formula("""
        Boat Profile  → A, A_u, w
        Conditions    → wind, gust, current,
                        waves, bottom, rode
        Water tab → h at high water
                  ↓
        load at gusts  H
                  ↓
        chain shape (catenary)
        → chain on bottom, pull angle
                  ↓
        anchor holding
                  ↓
        safe gust limit, rode needed
        """),
        .text("Every calculation uses the **height of the bow roller above the seabed at high water**, because that's when scope is shortest:"),
        .formula("h = depth + tide rise + bow roller height"),
    ]

    // MARK: Windage

    static let windage: [GuideTopic.Block] = [
        .heading("1. Windage area"),
        .text("The area the wind pushes on when the boat lies head to wind. If you enter a measured area in the Boat Profile it's used as is. Otherwise it's estimated from the hull and cabin seen from ahead:"),
        .formula("""
        A = f_hull × beam
              × (freeboard + cabin height)

        f_hull = \(n(B.hullFill))
          (hull and cabin aren't full
           rectangles seen from ahead)
        """),
        .text("The radar mast is small next to the flybridge and is left out."),
    ]

    // MARK: Loads

    static let loads: [GuideTopic.Block] = [
        .heading("2. Wind load"),
        .text("Standard drag on a bluff body:"),
        .formula("""
        F_wind = ½ × ρ_air × C_d × A × v²

        ρ_air = \(n(B.airDensity, 3)) kg/m³ (sea level)
        C_d   = \(n(B.dragCoefficient, 1)) (head to wind)
        v     = knots × 0.514444 (m/s)
        """),
        .tip("Load goes with the **square** of wind speed. 20 kt to 28 kt is 40% more wind but twice the load; 20 kt to 40 kt is four times the load."),
        .heading("3. Current load"),
        .text("The same formula on the underwater hull. Seawater is about 840 times denser than air, so a knot of current matters:"),
        .formula("""
        F_current = ½ × ρ_sea × C_d × A_u × v²

        A_u   = \(n(A.underwaterFill, 1)) × beam × draft
        ρ_sea = \(n(A.seawaterDensity, 0)) kg/m³
        C_d   = \(n(A.hullDragCoefficient, 1))
        """),
        .text("The row **wind / current before allowances** shows F_wind at the gust speed and F_current, before the multipliers below."),
        .heading("4. Load at gusts"),
        .text("A boat at anchor doesn't sit still. It sails from side to side, which swings the pull off the centreline and adds momentum, and waves snatch at the rode. Two multipliers allow for that:"),
        .formula("""
        H = (F_wind(gust) + F_current)
              × k_yaw × k_wave

        k_yaw  = \(n(A.yawFactor))
        k_wave = 1 + c × wave height (m)
        c = 0.5 with a snubber ≥ 5 m
        c = 1.0 without
        """),
        .text("H is the **horizontal** pull the boat puts on the rode, and it's the number in **Load in N kt gusts**. With **Current runs: With wind**, wind and current push the same way, the worst case for a boat lying head to wind. With **Across** or **Against**, the boat can lie beam-on, so the wind pushes on the **side windage** instead (about three times the front on a trawler); the current is still added on top."),
        .text("**Load now** is the same formula with the steady wind instead of the gust. The diagram draws the chain at that load (how the boat lies most of the time), with a faint dashed line for where it goes in the gusts. **Chain on the bottom** and **Pull angle** show both. Everything that decides safety (the limits, the status line and the advice) uses the gusts."),
    ]

    // MARK: Chain weight

    static let chain: [GuideTopic.Block] = [
        .heading("5. Chain weight in water"),
        .text("Galvanised short-link chain weighs close to 0.022 × d² kg per metre, d being the wire size in millimetres. Seawater holds up part of that weight:"),
        .formula("""
        w = \(n(A.chainMassFactor, 3)) × d²
              × (1 − ρ_sea / ρ_steel) × g
          (newtons per metre)

        1 − 1025 / 7850 = \(n(A.submergedFraction, 3))
        g = \(n(A.gravity)) m/s²

        3/8" (9.5 mm):  \(n(A.chainWeight(sizeMM: 9.525), 1)) N/m
        1/2" (12.7 mm): \(n(A.chainWeight(sizeMM: 12.7), 1)) N/m
        """),
        .text("Nylon is nearly weightless in water, so a rope rode contributes no weight to the curve."),
    ]

    // MARK: Catenary

    static let catenary: [GuideTopic.Block] = [
        .heading("6. The hanging chain (catenary)"),
        .text("A chain hanging under its own weight takes the shape of a **catenary**. The horizontal part of its tension is the same all along it, and equals the load H. The vertical part grows by w for each metre of chain above the lowest point. Measuring x from the point where the chain leaves the bottom:"),
        .formula("""
        a = H / w
          (catenary parameter, m)
        y(x) = a × (cosh(x / a) − 1)
          (chain height above the seabed)
        s = √(h² + 2 a h)
          (chain hanging, touchdown to bow)
        x_span = a × asinh(s / a)
          (horizontal distance it covers)
        lying = L − s
          (chain left on the bottom)
        """),
        .text("**Chain on the bottom** is that last line. Its value matters: while any chain lies on the bottom, the pull reaches the anchor exactly horizontal, which is how anchors are designed to hold."),
        .heading("7. When the chain lifts off"),
        .text("Setting s = L (no chain left on the bottom) and solving for H gives the largest pull this length of chain can take before it starts lifting the anchor shank:"),
        .formula("H_max = w × (L² − h²) / (2h)"),
        .text("**Chain lifts off at** turns H_max back into a wind speed: take out the multipliers and the current, and invert the wind formula:"),
        .formula("""
        F_wind_max = H_max / (k_yaw × k_wave)
                     − F_current
        v = √( F_wind_max / (½ ρ_air C_d A) )
          (m/s; ÷ 0.514444 for knots)
        """),
        .text("If current and waves alone already exceed H_max, it shows **already**."),
        .heading("8. Once the chain is off the bottom"),
        .text("With more load than H_max, the whole chain hangs as one curve from the anchor shank, and the shank is pulled upward at an angle θ. Writing u₀ = tan θ at the anchor, the chain length L and height h must satisfy:"),
        .formula("""
        u₁ = u₀ + L / a
        h  = a × ( √(1 + u₁²) − √(1 + u₀²) )
        """),
        .text("There's no closed-form answer, so the app solves for u₀ by bisection: 60 halvings, which pins it down far more finely than needed. **Pull angle at the anchor** is θ = atan(u₀)."),
        .text("For a **rope** rode the app takes the conservative view that it's a straight, weightless line: θ = asin(h / L). Chain + rope is treated as all chain while the rode out is no longer than the chain."),
        .heading("9. Rode for these gusts"),
        .text("Solving the touchdown formula for the length that just keeps chain on the bottom at load H, plus a margin so some chain still lies flat:"),
        .formula("""
        L_needed = \(n(A.rodeMargin)) × √(h² + 2 h H / w)
        """),
        .tip("Notice what this says: at high load, rode needed grows with the **square root** of depth × load, not in proportion to depth. In deep water, extra chain gives less extra holding than the scope ratio suggests; in shallow water, extra chain is very effective."),
    ]

    // MARK: Holding

    static var holding: [GuideTopic.Block] {
        let types = BoatProfile.AnchorType.allCases
        let short: [BoatProfile.AnchorType: String] = [.newGeneration: "NewGen", .plow: "Plow", .claw: "Claw", .fluke: "Fluke"]
        let header = "×weight".padding(toLength: 13, withPad: " ", startingAt: 0)
            + types.map { (short[$0] ?? $0.rawValue).padding(toLength: 7, withPad: " ", startingAt: 0) }.joined()
        let rows = AnchorConditions.Bottom.allCases.map { bottom in
            bottom.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
                + types.map { String(format: "%-7.0f", A.holdingRatio($0, bottom)) }.joined()
        }
        return [
            .heading("10. Anchor holding (rough)"),
            .text("Holding is taken as a multiple of the anchor's weight, set by anchor type and bottom. These ratios are conservative readings of published pull tests, and they are the least certain numbers in the app: the same anchor can hold twice or half as much depending on how well it set."),
            .formula(([header] + rows).joined(separator: "\n")),
            .formula("""
            holding = ratio × anchor weight (kg)
                        × g × efficiency(θ)

            efficiency(θ) = max(0.1, 1 − θ / 20°)
              (100% flat, 50% at 10°,
               never below 10%)
            """),
            .text("That's the number in **Anchor holding (rough)**: it drops as soon as the chain starts lifting the shank."),
        ]
    }

    // MARK: Limits and status

    static let limits: [GuideTopic.Block] = [
        .heading("11. Safe gust limit"),
        .text("Two gust speeds, and the lower one wins:"),
        .bullets([
            "**Chain lift-off gust** (section 7): above it, the anchor starts being pulled upward.",
            "**Holding gust**: the gust at which H reaches holding ÷ \(n(A.holdingSafety, 1)), with holding taken flat (efficiency 100%), since below lift-off the pull is flat.",
        ]),
        .text("**Set gust warning to N kt** copies it into Settings (clamped to 10–50 kt), so the wind warnings on the main screen fire at your boat's real limit."),
        .heading("12. The status line"),
        .formula("""
        At risk of dragging, if any of:
          H > holding
          θ ≥ 10°
          rode out ≤ h

        Marginal, if any of:
          H > holding / \(n(A.holdingSafety, 1))
          θ > 0° (chain lifting the shank)

        Holding well: none of the above
        """),
    ]

    // MARK: Worked example

    static var example: [GuideTopic.Block] {
        let boat = BoatProfile()
        let scope = ScopeSettings(depth: 6.096, tideRise: 0, bowHeight: 1.219, boatLength: 14.326, scopeRatio: 5, margin: 5)
        var c = AnchorConditions()
        c.wind = 15; c.gust = 25; c.current = 0.5; c.waveHeight = 0.3048; c.bottom = .mud; c.rodeOut = 45.72
        let r = A.assess(boat, scope: scope, c)
        let area = B.windage(boat) ?? 0
        let w = A.chainWeight(sizeMM: boat.chainSize)
        let kWave = A.waveFactor(height: c.waveHeight, snubber: boat.snubber)
        let hMax = r.liftOffLoad ?? 0
        let lifted = r.load.design > hMax
        let fullHolding = boat.anchorWeight * A.gravity * A.holdingRatio(boat.anchorType, c.bottom)

        return [
            .heading("13. Worked example"),
            .text("Nereus with the Boat Profile defaults (\(ft(boat.chainLength)) of 3/8\" chain, a \(String(format: "%.0f", boat.anchorWeight * 2.20462)) lb claw anchor) in 20 ft of water over mud, 150 ft of chain out, gusts to 25 kt, 0.5 kt of current and 1 ft waves. These numbers are calculated by the app as you read them."),
            .formula("""
            h = 6.10 + 0 + 1.22
              = \(n(r.height)) m (\(ft(r.height)))

            A = \(n(B.hullFill)) × \(n(boat.beam)) × (\(n(boat.freeboard)) + \(n(boat.cabinHeight)))
              = \(n(area, 1)) m²

            F_wind = ½ × 1.225 × 1.0 × \(n(area, 1))
                     × (25 × 0.5144)²
                   = \(n(r.load.wind, 0)) N (\(lbf(r.load.wind)))

            A_u = 0.6 × \(n(boat.beam)) × \(n(boat.draft))
                = \(n(A.underwaterFill * boat.beam * boat.draft)) m²

            F_current = ½ × 1025 × 1.0 × \(n(A.underwaterFill * boat.beam * boat.draft))
                        × (0.5 × 0.5144)²
                      = \(n(r.load.current, 0)) N (\(lbf(r.load.current)))

            H = (\(n(r.load.wind, 0)) + \(n(r.load.current, 0))) × \(n(A.yawFactor)) × \(n(kWave, 3))
              = \(n(r.load.design, 0)) N (\(lbf(r.load.design)))

            w = 0.022 × 9.525² × 0.869 × 9.81
              = \(n(w)) N/m

            H_max = \(n(w)) × (45.72² − \(n(r.height))²)
                    / (2 × \(n(r.height)))
                  = \(n(hMax, 0)) N (\(lbf(hMax)))
            """),
            .text(lifted
                  ? "H (\(n(r.load.design, 0)) N) is more than H_max (\(n(hMax, 0)) N), so the whole chain is off the bottom. Bisection gives a pull angle at the anchor of **\(n(r.shape.shankAngle, 1))°**, so holding efficiency is \(n(A.angleEfficiency(r.shape.shankAngle) * 100, 0))%."
                  : "H (\(n(r.load.design, 0)) N) is less than H_max (\(n(hMax, 0)) N), so \(ft(r.shape.lying)) of chain still lies on the bottom and the pull at the anchor is flat."),
            .formula("""
            holding (flat)
              = \(n(A.holdingRatio(boat.anchorType, c.bottom), 0)) × \(n(boat.anchorWeight, 1)) × 9.81
              = \(n(fullHolding, 0)) N (\(lbf(fullHolding)))

            holding (at θ)
              = \(n(fullHolding, 0)) × \(n(A.angleEfficiency(r.shape.shankAngle)))
              = \(n(r.holding ?? 0, 0)) N (\(lbf(r.holding ?? 0)))

            rode needed
              = \(n(A.rodeMargin)) × √(\(n(r.height))² + 2 × \(n(r.height))
                       × \(n(r.load.design, 0)) / \(n(w)))
              = \(n(r.rodeNeeded ?? 0, 1)) m (\(ft(r.rodeNeeded ?? 0)))

            lift-off gust    = \(r.liftOffGust.map { n($0, 1) + " kt" } ?? "—")
            holding gust     = \(r.holdingGust.map { n($0, 1) + " kt" } ?? "—")
              (H = holding ÷ \(n(A.holdingSafety, 1)))
            safe gust limit  = \(r.safeGust.map { n($0, 1) + " kt" } ?? "—")
            """),
            .text("With the claw anchor's low rating in mud, holding rather than chain is the limit here. Measured values in the Boat Profile, and the real bottom, will change this a lot."),
        ]
    }

    // MARK: Finding the anchor from the swing

    typealias S = AnchorEstimate

    static let swing: [GuideTopic.Block] = [
        .heading("14. Finding the anchor from the swing"),
        .text("Where you marked the anchor is a guess: GPS error, which way the bow pointed, and how far the anchor dragged while it set. Once the boat has swung for a while, the track itself says where the anchor is."),
        .text("At anchor the phone moves on (or inside) a circle **centred on the anchor**. Its radius is the rode's reach plus the bow-to-phone distance, because the bow points at the anchor. The outer edge of the track traces that circle; fit a circle to it and the centre is the anchor."),
        .heading("Step 1: wait for enough track"),
        .bullets([
            "The first \(Int(S.settleMinutes)) minutes after the drop are ignored, while the anchor sets and you back down.",
            "Nothing is shown until there are \(Int(S.minMinutes)) minutes and \(S.minPoints) track points after that.",
            "The fit reruns once a minute.",
        ]),
        .heading("Step 2: flatten the chart"),
        .text("Over a few hundred metres the earth is flat enough to work in metres east (x) and north (y) of the anchor mark:"),
        .formula("""
        x = Δlongitude × R⊕ × cos(latitude)
        y = Δlatitude × R⊕
        R⊕ = 6,371 km (angles in radians)
        """),
        .heading("Step 3: keep only the outer edge"),
        .text("In a lull the chain sags and the boat creeps toward the anchor, so most points are inside the circle. Only the moments the rode was stretched out lie on it."),
        .formula("""
        Split the track into \(Int(S.sliceDegrees))° slices
        round the current centre guess.
        In each slice keep the farthest
        \(Int(S.edgeFraction * 100))% of points (at least one).

        arc = 360° − largest run of empty
              slices
        """),
        .heading("Step 4: fit the circle"),
        .text("A geometric least-squares fit: find the centre c (and radius r) that make the edge points' distances from c as close to r as possible."),
        .formula("""
        eᵢ = |pᵢ − c| − r
        minimise  Σ wᵢ eᵢ²
        """),
        .text("It's solved by **Gauss–Newton**: start at the anchor mark, linearise, solve the 2×2 or 3×3 normal equations for a step, repeat until the step is under a millimetre (at most 30 times)."),
        .formula("""
        ∂eᵢ/∂cx = −(xᵢ − cx) / dᵢ
        ∂eᵢ/∂cy = −(yᵢ − cy) / dᵢ
        ∂eᵢ/∂r  = −1
        (JᵀWJ) Δ = −JᵀW e
        """),
        .text("**Huber weights** stop a stray fix, or a moment lying sideways to wind against tide, from dragging the answer:"),
        .formula("""
        k  = \(n(S.huberK, 1)) × max(0.5, 1.4826 × median|e|)
        wᵢ = 1          if |eᵢ| ≤ k
        wᵢ = k / |eᵢ|   otherwise
        """),
        .bullets([
            "**Free fit** (centre and radius) when the edge covers \(Int(S.freeFitArc))° of swing or more.",
            "**Fixed radius** below that: r is held at the scope calculator's reach plus half the boat length, and only the centre moves. A short arc can't tell a big circle from a small one, but with r known it still finds the centre.",
            "Steps 3 and 4 run three times, re-picking the edge round each new centre.",
        ]),
        .tip("A free fit also measures the radius. If it comes out well short of the scope calculator's, you have less rode out, or less reach, than you think."),
        .heading("Step 5: how sure is it?"),
        .text("The fit's covariance gives an error ellipse round the centre:"),
        .formula("""
        σ² = Σ wᵢ eᵢ² / (n − p)
        Cov(c) = σ² (JᵀWJ)⁻¹   (2×2 part)
        """),
        .bullets([
            "Neighbouring fixes share the same slowly-drifting GPS error, so they aren't independent. The covariance is multiplied by **points ÷ occupied slices**, treating each slice as one measurement.",
            "A fixed-radius fit adds **(\(Int(S.modelRadiusError * 100))% of r)²** along the swing direction, since the rode out may not be what the scope calculator thinks.",
        ]),
        .formula("""
        m = (Cxx + Cyy) / 2
        s = √( ((Cxx − Cyy)/2)² + Cxy² )
        a = \(n(S.confidenceScale)) × √(m + s)   long axis
        b = \(n(S.confidenceScale)) × √(m − s)   short axis
        θ = ½ atan2(2Cxy, Cxx − Cyy)
        """),
        .text("The \(n(S.confidenceScale)) scales a one-sigma ellipse to cover about two times in three, the same as the GPS ± figure. Both axes are at least \(n(S.floorMeters, 0)) m, because GPS error drifts too slowly to average away. If the long axis is over \(n(S.maxSemiMajor, 0)) m, nothing is shown: \"Not enough swing yet\"."),
        .heading("Step 6: wind cross-check"),
        .text("With \(n(S.windMinKnots, 0)) kt or more of forecast wind, the anchor should lie upwind of the boat, a radius away:"),
        .formula("""
        boat = mean position, last \(Int(S.windWindowSeconds)) s
        anchor_wind = boat + r × (sin θw, cos θw)
          (θw = direction the wind is from)
        agrees if |anchor_wind − c|
                   ≤ max(\(n(S.windTolerance, 0)) m, 2a)
        """),
        .text("If it doesn't agree, the panel says to give it more time. The fit isn't changed: the wind forecast is coarse, and the boat may be lying to current."),
        .heading("15. Using the estimate"),
        .bullets([
            "A **purple ring with an anchor** on the chart marks the estimate, inside its dashed purple error ellipse. Tap it for the ± and how many minutes of swing went in.",
            "If the estimate is within its own ± of your mark, the panel says the swing **agrees**.",
            "Otherwise it says how far and which way, with **Move there**. That moves the anchor mark (and the alarm circle) to the estimate; the dotted orange circle becomes the ellipse's long axis.",
            "This fit uses the whole swing since the drop, so a dragging anchor blurs it rather than tracking it. Section 16 watches for that.",
        ]),
    ]

    // MARK: Drag detection

    typealias Dr = AnchorDrift

    static let drift: [GuideTopic.Block] = [
        .heading("16. Is the anchor dragging?"),
        .text("The drag alarm only sounds once the boat leaves the circle. An anchor that's slowly ploughing downwind can take a long time to get there. This check watches the **anchor** instead of the boat, and can warn much sooner."),
        .heading("Rolling fits"),
        .text("Once a minute, the swing fit from section 14 is run again on just the last **\(Int(Dr.rollingMinutes)) minutes** of track (after the \(Int(AnchorEstimate.settleMinutes))-minute settle). Each gives a centre cₖ at time tₖ, with its error ellipse's long axis aₖ. They're kept for \(Int(Dr.windowMinutes * 2)) minutes."),
        .text("A holding anchor's centres scatter round one spot. A dragging anchor's centres march steadily one way."),
        .heading("A line through the centres"),
        .text("Take the centres from the last **\(Int(Dr.windowMinutes)) minutes** (at least \(Dr.minSamples)), in metres east and north, and fit a straight line against time by least squares. Its slope is the anchor's velocity:"),
        .formula("""
        t̄ = mean time, x̄, ȳ = mean position
        vx = Σ (tₖ − t̄)(xₖ − x̄) / Σ (tₖ − t̄)²
        vy = Σ (tₖ − t̄)(yₖ − ȳ) / Σ (tₖ − t̄)²

        speed = √(vx² + vy²)       (m/min)
        moved = speed × (t_last − t_first)
        bearing = atan2(vx, vy)
        """),
        .heading("Three tests, all must pass"),
        .formula("""
        1. Big enough:
           moved ≥ \(n(Dr.minMeters, 0)) m

        2. Bigger than the fits' own error:
           moved ≥ \(n(Dr.significance, 1)) × mean(aₖ)

        3. Steady, not wandering:
           uₖ = (cₖ − c̄) · v̂   (along the drift)
           R² = 1 − Σ(uₖ − speed (tₖ − t̄))²
                    / Σ uₖ²
           R² ≥ \(n(Dr.minSteadiness, 1))
        """),
        .text("Test 3 is what stops a boat that's sailing about, or an anchor fit that wobbles with the wind, from looking like drag: big moves back and forth have no steady direction, so the line explains little of them."),
        .heading("Confirm, then warn"),
        .bullets([
            "The rolling windows overlap, so one fit showing drift isn't much evidence. Drift has to be found in **\(Dr.confirmations) fits in a row** before the warning appears.",
            "The warning is a **red banner** at the top of the screen: how far, which way, and how fast (per 10 minutes). A **red arrow** on the chart runs from where the anchor was to where it is now.",
            "It clears as soon as a fit no longer shows drift, and when you raise or drop the anchor.",
            "It's a warning, not the siren: the boat may still be well inside the circle. Check your position and be ready to re-anchor; the drag alarm still sounds if the boat leaves the circle.",
        ]),
        .tip("In the simulator, the **Slow drag** scenario holds for 25 minutes, then creeps the anchor downwind at 0.6 m a minute. At 60× the warning appears a little over half a minute after the drop."),
    ]

    // MARK: Limitations

    static let limitations: [GuideTopic.Block] = [
        .heading("17. What the model leaves out"),
        .bullets([
            "**It's static.** Real loads come in surges as the boat sails about and pitches. The yaw and wave multipliers stand in for that; they aren't a dynamic simulation.",
            "**No stretch.** Chain and snubber elasticity, which soften shock loads, aren't modelled beyond the wave factor.",
            "**Flat bottom.** A seabed sloping up toward the anchor helps; one sloping away (or a ledge) makes things worse.",
            "**Wind and current in line.** Wind against current, or across it, changes how the boat lies.",
            "**Guessed coefficients.** Drag coefficients, the hull fill factors and especially the holding ratios are reasonable round numbers, not measurements of Nereus.",
        ]),
        .warning("Use these numbers to compare choices (more chain, a different spot, a second anchor), not as a promise that the anchor will hold. Set it well, back down on it, and keep the drag alarm on."),
    ]
}
