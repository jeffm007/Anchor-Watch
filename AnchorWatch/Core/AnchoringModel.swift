import Foundation

/// What the boat is anchored in: the knobs on the Anchoring screen. Wind and current in knots, waves and depths in metres.
struct AnchorConditions: Equatable {
    enum Bottom: String, CaseIterable, Identifiable {
        case sand = "Sand", mud = "Mud", clay = "Clay", gravel = "Gravel/shell", weed = "Weed", rock = "Rock"
        var id: String { rawValue }
    }

    var wind = 15.0
    var gust = 25.0
    var current = 0.5
    var waveHeight = 0.3
    var bottom = Bottom.mud
    /// Rode let out, measured from the bow roller.
    var rodeOut = 45.0
}

/// The rode hanging from the bow under a given horizontal pull, and the anchor at the other end.
/// x runs from the anchor (0) toward the boat; y is height above the seabed. Metres.
struct RodeShape: Equatable {
    /// Points along the rode from the anchor to the bow roller.
    let points: [(x: Double, y: Double)]
    /// Rode lying flat on the bottom, from the anchor.
    let lying: Double
    /// Angle of pull at the anchor shank, degrees. Zero while some chain still lies on the bottom.
    let shankAngle: Double
    /// Horizontal distance from the anchor to the bow roller.
    var reach: Double { points.last?.x ?? 0 }

    static func == (a: RodeShape, b: RodeShape) -> Bool {
        a.lying == b.lying && a.shankAngle == b.shankAngle && a.points.count == b.points.count
            && zip(a.points, b.points).allSatisfy { $0.x == $1.x && $0.y == $1.y }
    }
}

/// Load on the anchor, broken down so the screen can show where it comes from. Newtons.
struct AnchorLoad: Equatable {
    let wind: Double
    let current: Double
    /// Wind plus current, multiplied up for waves and yawing.
    let design: Double
}

struct AnchorAssessment: Equatable {
    enum Status: Int, Comparable {
        case good, marginal, danger
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    /// Height of the bow roller above the seabed at high water.
    let height: Double
    let load: AnchorLoad
    let shape: RodeShape
    /// Horizontal pull at which the last chain lifts off the bottom. Nil for rope.
    let liftOffLoad: Double?
    /// Gust at which the chain lifts off, with today's current and waves.
    let liftOffGust: Double?
    /// Rough holding of the anchor in this bottom at the current shank angle.
    let holding: Double?
    /// Gust at which the design load reaches the anchor's holding, with a safety margin.
    let holdingGust: Double?
    /// The lower of the two gust limits.
    let safeGust: Double?
    /// Rode to keep chain on the bottom at the design load, with a margin.
    let rodeNeeded: Double?
    let status: Status
}

enum AnchorMath {
    static let seawaterDensity = 1025.0       // kg/m³
    static let gravity = 9.81
    /// Galvanised short-link chain weighs about 0.022 × d² kg per metre (d in mm).
    static let chainMassFactor = 0.022
    /// Steel loses 13% of its weight in seawater.
    static let submergedFraction = 1 - 1025.0 / 7850
    /// Underwater hull seen from ahead is far from a full beam × draft rectangle.
    static let underwaterFill = 0.6
    static let hullDragCoefficient = 1.0
    /// Boats sail about at anchor, which adds to the straight-line pull.
    static let yawFactor = 1.25
    /// Holding is divided by this before it counts as safe.
    static let holdingSafety = 1.5
    /// Extra rode beyond the bare lift-off length, so the chain keeps some on the bottom.
    static let rodeMargin = 1.15

    /// Chain weight in seawater, newtons per metre.
    static func chainWeight(sizeMM: Double) -> Double {
        chainMassFactor * sizeMM * sizeMM * submergedFraction * gravity
    }

    /// The anchor's rough holding per unit of its own weight, by type and bottom. Conservative guesses
    /// from published pull tests; real holding varies widely with how well it set.
    static func holdingRatio(_ type: BoatProfile.AnchorType, _ bottom: AnchorConditions.Bottom) -> Double {
        switch (bottom, type) {
        case (.sand, .newGeneration): return 30
        case (.sand, .plow): return 15
        case (.sand, .claw): return 12
        case (.sand, .fluke): return 40
        case (.mud, .newGeneration): return 15
        case (.mud, .plow): return 10
        case (.mud, .claw): return 6
        case (.mud, .fluke): return 25
        case (.clay, .newGeneration): return 25
        case (.clay, .plow), (.clay, .claw): return 12
        case (.clay, .fluke): return 20
        case (.gravel, .newGeneration): return 12
        case (.gravel, .plow), (.gravel, .claw): return 8
        case (.gravel, .fluke): return 5
        case (.weed, .newGeneration): return 5
        case (.weed, .plow), (.weed, .claw): return 4
        case (.weed, .fluke): return 2
        case (.rock, _): return 3
        }
    }

    /// Holding lost as the pull at the shank lifts off horizontal: about half at 10°.
    static func angleEfficiency(_ degrees: Double) -> Double {
        max(0.1, 1 - degrees / 20)
    }

    /// Waves snatch at the rode; a snubber of 5 m or more takes out about half of it.
    static func waveFactor(height: Double, snubber: Double) -> Double {
        1 + height * (snubber >= 5 ? 0.5 : 1.0)
    }

    static func currentLoad(_ b: BoatProfile, knots: Double) -> Double {
        let area = b.beam * b.draft * underwaterFill
        let v = knots * 0.514444
        return 0.5 * seawaterDensity * hullDragCoefficient * area * v * v
    }

    static func load(_ b: BoatProfile, wind: Double, current: Double, waveHeight: Double) -> AnchorLoad {
        let w = BoatMath.windLoad(b, knots: wind) ?? 0
        let c = currentLoad(b, knots: current)
        let design = (w + c) * yawFactor * waveFactor(height: waveHeight, snubber: b.snubberLength)
        return AnchorLoad(wind: w, current: c, design: design)
    }

    /// Wind speed that brings the design load up to `limit`, holding current and waves fixed.
    static func gust(reaching limit: Double, _ b: BoatProfile, current: Double, waveHeight: Double) -> Double? {
        guard let area = BoatMath.windage(b), area > 0 else { return nil }
        let windShare = limit / (yawFactor * waveFactor(height: waveHeight, snubber: b.snubberLength)) - currentLoad(b, knots: current)
        guard windShare > 0 else { return 0 }
        return (windShare / (0.5 * BoatMath.airDensity * BoatMath.dragCoefficient * area)).squareRoot() / 0.514444
    }

    /// Pull at which a chain of `length` just lifts entirely off the bottom, with the bow `height` above it.
    static func liftOffLoad(length: Double, height: Double, weight: Double) -> Double {
        guard length > height, height > 0 else { return 0 }
        return weight * (length * length - height * height) / (2 * height)
    }

    /// Chain length that keeps the last of it on the bottom under `load`.
    static func chainNeeded(load: Double, height: Double, weight: Double) -> Double {
        guard weight > 0 else { return height }
        return (height * height + 2 * height * load / weight).squareRoot()
    }

    /// Shape of a chain rode of `length` hanging between the seabed and a bow `height` up, under horizontal pull `load`.
    /// Rope is drawn as a straight line, which is close enough for nylon that has little weight in water.
    static func shape(length: Double, height: Double, load: Double, weight: Double, samples: Int = 40) -> RodeShape {
        guard length > height, height > 0 else {
            // Not enough rode to reach the bottom: hangs straight down.
            return RodeShape(points: [(0, max(0, height - length)), (0, height)], lying: 0, shankAngle: 90)
        }
        guard weight > 0 else {
            let reach = (length * length - height * height).squareRoot()
            return RodeShape(points: [(0, 0), (reach, height)], lying: 0, shankAngle: atan2(height, reach) * 180 / .pi)
        }
        let a = max(load, 1) / weight      // catenary parameter
        let suspended = (height * height + 2 * a * height).squareRoot()

        if suspended <= length {
            // Some chain lies flat; the rest hangs as a catenary from the touchdown point.
            let lying = length - suspended
            let span = a * asinh(suspended / a)
            let points = [(x: 0.0, y: 0.0)] + (0...samples).map { i -> (x: Double, y: Double) in
                let x = span * Double(i) / Double(samples)
                return (lying + x, a * (cosh(x / a) - 1))
            }
            return RodeShape(points: points, lying: lying, shankAngle: 0)
        }

        // All chain is off the bottom: find the slope at the anchor (u0 = tan θ) that fits the length and height.
        func rise(_ u0: Double) -> Double {
            let u1 = u0 + length / a
            return a * ((1 + u1 * u1).squareRoot() - (1 + u0 * u0).squareRoot())
        }
        var lo = 0.0, hi = 1.0
        while rise(hi) < height && hi < 1e6 { hi *= 2 }
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if rise(mid) < height { lo = mid } else { hi = mid }
        }
        let u0 = (lo + hi) / 2
        let x0 = a * asinh(u0)
        let x1 = a * asinh(u0 + length / a)
        let points = (0...samples).map { i -> (x: Double, y: Double) in
            let x = x0 + (x1 - x0) * Double(i) / Double(samples)
            return (x - x0, a * (cosh(x / a) - cosh(x0 / a)))
        }
        return RodeShape(points: points, lying: 0, shankAngle: atan(u0) * 180 / .pi)
    }

    static func assess(_ b: BoatProfile, scope s: ScopeSettings, _ c: AnchorConditions) -> AnchorAssessment {
        let height = s.designDepth + s.bowHeight
        let load = self.load(b, wind: c.gust, current: c.current, waveHeight: c.waveHeight)
        let allChain = b.rodeType == .allChain || (b.rodeType == .chainAndRope && c.rodeOut <= b.chainLength)
        let weight = allChain && b.chainSize > 0 ? chainWeight(sizeMM: b.chainSize) : 0
        let shape = self.shape(length: c.rodeOut, height: height, load: load.design, weight: weight)

        let liftOff = weight > 0 ? liftOffLoad(length: c.rodeOut, height: height, weight: weight) : nil
        let liftOffGust = liftOff.flatMap { gust(reaching: $0, b, current: c.current, waveHeight: c.waveHeight) }

        let anchorWeight = b.anchorWeight * gravity
        let fullHolding = anchorWeight > 0 ? anchorWeight * holdingRatio(b.anchorType, c.bottom) : nil
        let holding = fullHolding.map { $0 * angleEfficiency(shape.shankAngle) }
        // The holding limit assumes the rode keeps the pull flat, so use full holding for the gust that reaches it.
        let holdingGust = fullHolding.flatMap { gust(reaching: $0 / holdingSafety, b, current: c.current, waveHeight: c.waveHeight) }
        let safeGust = [liftOffGust, holdingGust].compactMap { $0 }.min()

        let rodeNeeded = weight > 0 ? chainNeeded(load: load.design, height: height, weight: weight) * rodeMargin : nil

        var status = AnchorAssessment.Status.good
        if let holding, load.design > holding / holdingSafety { status = .marginal }
        if shape.shankAngle > 0 { status = max(status, .marginal) }
        if let holding, load.design > holding || shape.shankAngle >= 10 || c.rodeOut <= height { status = .danger }

        return AnchorAssessment(height: height, load: load, shape: shape, liftOffLoad: liftOff, liftOffGust: liftOffGust,
                                holding: holding, holdingGust: holdingGust, safeGust: safeGust, rodeNeeded: rodeNeeded,
                                status: status)
    }

    /// Plain-language advice for the conditions, worst first.
    static func suggestions(_ b: BoatProfile, scope s: ScopeSettings, _ c: AnchorConditions, _ r: AnchorAssessment, units: Units) -> [String] {
        var tips: [String] = []
        let carried = BoatMath.rodeCarried(b)

        if c.rodeOut <= r.height {
            tips.append("The rode doesn't reach the bottom at high water. Let out at least \(units.format(r.height * 3)).")
        }
        if let needed = r.rodeNeeded, needed > c.rodeOut {
            if carried > 0, needed > carried {
                let deepest = max(0, carried / rodeMargin - s.bowHeight)
                tips.append("Even all \(units.format(carried)) of chain lifts off in these gusts. Look for water under about \(units.format(deepest)), or set a second anchor.")
            } else {
                tips.append("Let out \(units.format(needed - c.rodeOut)) more (\(units.format(needed)) in all) to keep chain on the bottom at \(Int(c.gust)) kt.")
            }
        }
        if r.shape.shankAngle > 0 {
            tips.append(String(format: "The rode pulls up on the anchor at %.0f°, which cuts its holding to about %.0f%%.",
                               r.shape.shankAngle, angleEfficiency(r.shape.shankAngle) * 100))
        }
        if let holding = r.holding, r.load.design > holding / holdingSafety {
            tips.append("Expected holding in \(c.bottom.rawValue.lowercased()) is close to the load. Back down hard to set it, consider a second anchor, or move to a better bottom.")
        }
        if c.bottom == .rock || c.bottom == .weed {
            tips.append("\(c.bottom.rawValue) bottoms are unreliable. Dive or watch the anchor set before trusting it.")
        }
        if c.waveHeight >= 0.5 && b.snubberLength < 5 {
            tips.append("Rig a nylon snubber of at least \(units.format(6)): waves are snatching at all-chain rode.")
        }
        if c.current >= 1.5 {
            tips.append("Strong current: expect the boat to lie to the current, not the wind, at slack-wind times. Allow for a full swing.")
        }
        if s.tideRise > 0 {
            tips.append("Figures are at high water (+\(units.formatTenths(s.tideRise)) tide), when scope is shortest.")
        }
        if tips.isEmpty || r.status == .good {
            if let safe = r.safeGust {
                tips.append("Holding well. This setup is good to about \(Int(safe)) kt gusts.")
            }
        }
        return tips
    }
}
