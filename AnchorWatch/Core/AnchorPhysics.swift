import Foundation

/// Wind, tidal current and tide over a simulated day, for the physics scenarios.
/// Times are simulated seconds since the scenario started.
struct SimWeather {
    /// Wind speed (knots), gust factor applied on top, and where it blows from (degrees true).
    var wind: (Double) -> (speed: Double, from: Double)
    /// How gusty: the instantaneous wind swings up to this fraction above and below the mean.
    var gustiness: Double
    /// Strongest tidal current (knots) and the direction the flood runs (degrees true); the ebb runs opposite.
    var currentMax: Double
    var floodToward: Double
    /// Tidal range (metres): the water goes up and down half of this either side of where it started.
    var tideRange: Double
    /// Holding of the anchor relative to what the boat profile says (a poorly set anchor is below 1).
    var holdingFactor: Double = 1

    static let tidePeriod = 12.42 * 3600

    /// Current now: speed (knots) and where it goes. Flood and ebb follow the tide, peaking between high and low.
    func current(_ t: Double) -> (speed: Double, toward: Double) {
        let v = currentMax * sin(2 * .pi * t / Self.tidePeriod)
        return (abs(v), v >= 0 ? floodToward : (floodToward + 180).truncatingRemainder(dividingBy: 360))
    }

    /// Water level change since the start (metres).
    func tide(_ t: Double) -> Double {
        tideRange / 2 * (1 - cos(2 * .pi * t / Self.tidePeriod))
    }
}

/// A smooth, repeatable wiggle in -1...1, from a few sines with fixed phases.
struct Wiggle {
    let periods: [Double]
    let phases: [Double]

    init(periods: [Double], seed: UInt64) {
        self.periods = periods
        var x = seed &* 0x9E3779B97F4A7C15
        phases = periods.map { _ in
            x ^= x >> 12; x ^= x << 25; x ^= x >> 27
            return Double(x % 10_000) / 10_000 * 2 * .pi
        }
    }

    func callAsFunction(_ t: Double) -> Double {
        zip(periods, phases).map { sin(2 * .pi * t / $0 + $1) }.reduce(0, +) / Double(periods.count)
    }
}

/// The boat on its anchor, moved by wind, current and the pull of the rode, one simulated second at a time.
/// Positions are metres east and north of where the anchor was dropped.
struct AnchorPhysics {
    struct Boat {
        var rode: Double                 // metres let out
        var depth: Double                // water depth at the start (metres)
        var bowHeight: Double
        var chainWeight: Double          // N per metre, in water
        var frontWindage: Double         // m²
        var sideWindage: Double
        var underwater: Double           // m², hull and keel seen end on
        var mass: Double                 // kg
        var bowToPhone: Double
        var holding: Double              // N the anchor can take before it creeps
    }

    var boat: Boat
    var weather: SimWeather
    /// Anchor and bow, metres east/north of the drop; bow velocity, m/s.
    var anchor = AnchorEstimate.Point(x: 0, y: 0)
    var bow = AnchorEstimate.Point(x: 0, y: 0)
    var velocity = AnchorEstimate.Point(x: 0, y: 0)
    private(set) var time = 0.0
    private let gust = Wiggle(periods: [23, 47, 113, 271], seed: 1)
    private let sheer = Wiggle(periods: [61, 97, 157], seed: 2)
    private let drift = Wiggle(periods: [600, 1_400, 3_100], seed: 3)
    private let driftTurn = Wiggle(periods: [900, 2_200, 5_000], seed: 4)
    private var table: (h: Double, rows: [(pull: Double, reach: Double)])?

    init(boat: Boat, weather: SimWeather) {
        self.boat = boat
        self.weather = weather
        // Start lying back downwind on most of the slack.
        let w = weather.wind(0)
        let away = (w.from + 180).radians
        let lie = max(0, slack(depth: boat.depth)) * 0.8
        bow = AnchorEstimate.Point(x: lie * sin(away), y: lie * cos(away))
    }

    /// Wind at the boat right now, with gusts: speed (knots) and where it's from.
    func windNow() -> (speed: Double, from: Double) {
        let w = weather.wind(time)
        return (max(0, w.speed * (1 + weather.gustiness * gust(time))), w.from)
    }

    /// Where the phone is (amidships, behind the bow, away from the anchor), metres east/north of the drop.
    var phone: AnchorEstimate.Point {
        var dx = bow.x - anchor.x, dy = bow.y - anchor.y
        var d = (dx * dx + dy * dy).squareRoot()
        if d < 0.5 {
            let away = (weather.wind(time).from + 180).radians
            dx = sin(away); dy = cos(away); d = 1
        }
        return AnchorEstimate.Point(x: bow.x + dx / d * boat.bowToPhone, y: bow.y + dy / d * boat.bowToPhone)
    }

    // MARK: The rode

    /// Inside this distance from the anchor the chain just hangs: no pull at all.
    func slack(depth: Double) -> Double { boat.rode - (depth + boat.bowHeight) }

    /// Horizontal pull of the rode with the bow `distance` metres from the anchor (catenary chain on a flat bottom).
    mutating func pull(at distance: Double, depth: Double) -> Double {
        let h = depth + boat.bowHeight
        if table == nil || abs(table!.h - h) > 0.05 { table = (h, Self.catenary(rode: boat.rode, height: h, weight: boat.chainWeight)) }
        let rows = table!.rows
        guard distance > rows[0].reach else { return 0 }
        guard let i = rows.firstIndex(where: { $0.reach >= distance }), i > 0 else {
            // Past the table: stretched taut, rising steeply.
            let last = rows[rows.count - 1]
            return last.pull + (distance - last.reach) * 50_000
        }
        let a = rows[i - 1], b = rows[i]
        let f = (distance - a.reach) / max(b.reach - a.reach, 1e-6)
        return a.pull + f * (b.pull - a.pull)
    }

    /// Reach (horizontal distance anchor to bow) for a range of pulls.
    static func catenary(rode: Double, height h: Double, weight w: Double) -> [(pull: Double, reach: Double)] {
        let taut = rode > h ? (rode * rode - h * h).squareRoot() : 0
        var rows: [(pull: Double, reach: Double)] = [(0, max(0, rode - h))]
        var pull = 5.0
        while pull < 400_000 {
            let a = pull / max(w, 1)
            let s = (h * h + 2 * a * h).squareRoot()          // chain hanging off the bottom
            let reach = s <= rode ? (rode - s) + a * asinh(s / a) : taut
            rows.append((pull, min(reach, taut)))
            if s > rode { break }
            pull *= 1.15
        }
        // Once the chain lifts right off, the last bit to taut takes a lot more pull.
        rows.append((rows.last!.pull * 3, taut))
        return rows
    }

    // MARK: Stepping

    /// Moves everything on by `dt` simulated seconds.
    mutating func step(_ dt: Double = 1) {
        time += dt
        let depth = boat.depth + weather.tide(time)
        let w = windNow()
        let windTo = (w.from + 180).radians
        let windMS = w.speed * 0.514444
        let flow = weather.current(time)
        let flowTo = flow.toward.radians
        let flowMS = flow.speed * 0.514444

        var dx = bow.x - anchor.x, dy = bow.y - anchor.y
        let d = max((dx * dx + dy * dy).squareRoot(), 1e-6)
        dx /= d; dy /= d

        // Wind: front windage head to wind, more of the side as the boat lies across it.
        let across = sin(atan2(dx, dy) - windTo)
        let area = boat.frontWindage + (boat.sideWindage - boat.frontWindage) * across * across
        let windF = 0.5 * 1.225 * area * windMS * windMS
        var fx = windF * sin(windTo), fy = windF * cos(windTo)

        // A boat at anchor sails about: a sideways push that comes and goes with the wind.
        let side = 0.35 * windF * sheer(time)
        fx += side * cos(windTo); fy -= side * sin(windTo)

        // In a calm she wanders slowly on whatever the water and air are doing.
        let wander = 40.0 * (0.5 + 0.5 * drift(time))
        let turn = driftTurn(time) * 2 * .pi
        fx += wander * sin(turn); fy += wander * cos(turn)

        // Water: the current pushes, and drags against the boat's own movement.
        let rx = flowMS * sin(flowTo) - velocity.x, ry = flowMS * cos(flowTo) - velocity.y
        let rel = (rx * rx + ry * ry).squareRoot()
        let water = 0.5 * AnchorMath.seawaterDensity * AnchorMath.hullDragCoefficient * boat.underwater * rel + 400
        fx += water * rx; fy += water * ry

        // The rode pulls the bow back toward the anchor.
        let tension = pull(at: d, depth: depth)
        fx -= tension * dx; fy -= tension * dy

        velocity.x += fx / boat.mass * dt
        velocity.y += fy / boat.mass * dt
        bow.x += velocity.x * dt
        bow.y += velocity.y * dt

        // The rode can't stretch past taut: hold the bow on the circle and take out the outward speed.
        let h = depth + boat.bowHeight
        let taut = boat.rode > h ? (boat.rode * boat.rode - h * h).squareRoot() : 0
        var ex = bow.x - anchor.x, ey = bow.y - anchor.y
        let e = (ex * ex + ey * ey).squareRoot()
        if e > taut, e > 0 {
            ex /= e; ey /= e
            bow = AnchorEstimate.Point(x: anchor.x + ex * taut, y: anchor.y + ey * taut)
            let out = velocity.x * ex + velocity.y * ey
            if out > 0 { velocity.x -= out * ex; velocity.y -= out * ey }
        }

        // More pull than the anchor holds: it creeps toward the boat.
        let hold = boat.holding * weather.holdingFactor
        if tension > hold, hold > 0 {
            let creep = min(0.3, 0.05 * (tension / hold - 1)) * dt
            anchor.x += dx * creep
            anchor.y += dy * creep
        }
    }
}

/// The day each physics scenario plays out, as weather. Wind directions are where it blows from.
enum SimDays {
    private static let light = Wiggle(periods: [420, 1_300, 3_700], seed: 11)
    private static let veer = Wiggle(periods: [1_800, 5_400, 11_000], seed: 12)

    /// Smooth step from 0 to 1 between hours `a` and `b`.
    private static func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let x = min(1, max(0, (t / 3600 - a) / (b - a)))
        return x * x * (3 - 2 * x)
    }

    /// Light and variable all night: 0-3 knots wandering round the compass, with a weak tide.
    static let calm = SimWeather(
        wind: { t in (max(0, 1.4 + 1.3 * light(t)), (200 + 150 * veer(t) + 360).truncatingRemainder(dividingBy: 360)) },
        gustiness: 0.4, currentMax: 0.3, floodToward: 80, tideRange: 2.4)

    /// Calm morning, a westerly sea breeze builds to about 13 knots after midday, then dies at dusk.
    static let seaBreeze = SimWeather(
        wind: { t in
            let breeze = ramp(t, 4, 6.5) * (1 - ramp(t, 11, 14))
            let calm = max(0, 1.5 + 1.2 * light(t))
            return (calm * (1 - breeze) + (13 + 2 * light(t)) * breeze,
                    (270 + 15 * veer(t) * breeze + 140 * veer(t) * (1 - breeze) + 360).truncatingRemainder(dividingBy: 360))
        },
        gustiness: 0.25, currentMax: 0.4, floodToward: 80, tideRange: 2.4)

    /// Southerly 8 knots, building to 20 gusting 30 from the south-west, then a front veers it north-west.
    static let front = SimWeather(
        wind: { t in
            let build = ramp(t, 5, 8), shift = ramp(t, 9.5, 11), ease = ramp(t, 14, 20)
            let speed = 8 + 12 * build * (1 - ease) - 3 * shift * ease + 1.5 * light(t)
            let from = 170 + 30 * build + 100 * shift + 8 * veer(t)
            return (max(0, speed), from.truncatingRemainder(dividingBy: 360))
        },
        gustiness: 0.35, currentMax: 0.3, floodToward: 80, tideRange: 2.4)

    /// Steady 10 knots from the north against a 1.2 knot tide that floods north and ebbs south.
    static let windAgainstTide = SimWeather(
        wind: { t in (10 + 1.5 * light(t), (360 + 10 * veer(t)).truncatingRemainder(dividingBy: 360)) },
        gustiness: 0.2, currentMax: 1.2, floodToward: 0, tideRange: 3)

    /// Builds to 32 knots gusting into the 40s from the south-west, enough to drag a poorly set anchor.
    static let gale = SimWeather(
        wind: { t in (10 + 22 * ramp(t, 1, 6) * (1 - ramp(t, 16, 22)) + 2 * light(t), (220 + 10 * veer(t)).truncatingRemainder(dividingBy: 360)) },
        gustiness: 0.3, currentMax: 0.3, floodToward: 80, tideRange: 2.4, holdingFactor: 0.6)
}
