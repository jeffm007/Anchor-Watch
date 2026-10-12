import CoreLocation

/// Fake GPS so the app can be developed away from the boat.
///
/// The boat sits `rode` metres from a hidden pivot (the real anchor), sheering
/// back and forth in the wind. Scenarios layer on wind shifts, a dragging
/// anchor, or a GPS outage. `speed` is simulated seconds per real second.
@MainActor
final class SimulatedLocationSource: LocationSource {
    enum Scenario: String, CaseIterable, Identifiable {
        case swinging = "Swinging at anchor"
        case windShift = "Wind shift"
        case dragging = "Dragging anchor"
        case gpsDropout = "GPS dropout"
        /// Wind clocking well round and back, with lulls: gives the swing fit a wide arc to work with.
        case wideSwing = "Wide swing (anchor finding)"
        /// Wide swing, then from 25 simulated minutes the anchor creeps downwind: tests the drag warning.
        case slowDrag = "Slow drag (drag warning)"
        // Physics: 24 hours of wind, tidal current and tide acting on the boat and its rode (`AnchorPhysics`).
        case calmNight = "Calm night (light & variable)"
        case seaBreeze = "Sea breeze day"
        case frontPasses = "Front passes (wind shift)"
        case windAgainstTide = "Wind against tide"
        case gale = "Gale (anchor drags)"
        var id: String { rawValue }

        /// The day's weather for the physics scenarios; nil for the scripted ones.
        var weather: SimWeather? {
            switch self {
            case .calmNight: SimDays.calm
            case .seaBreeze: SimDays.seaBreeze
            case .frontPasses: SimDays.front
            case .windAgainstTide: SimDays.windAgainstTide
            case .gale: SimDays.gale
            default: nil
            }
        }
    }

    /// Where the simulated boat lies. Nereus is moored at Roche Harbor; Sidney, BC is a few miles over the border.
    enum Place: String, CaseIterable, Identifiable {
        case rocheHarbor = "Roche Harbor, WA"
        case sidney = "Sidney, BC"
        var id: String { rawValue }

        var coordinate: CLLocationCoordinate2D {
            switch self {
            case .rocheHarbor: return CLLocationCoordinate2D(latitude: 48.6118, longitude: -123.1575)
            case .sidney: return CLLocationCoordinate2D(latitude: 48.6500, longitude: -123.3900)
            }
        }
    }

    var onFix: ((Fix) -> Void)?
    var scenario: Scenario = .swinging
    /// Simulated seconds per real second. Above 1× the simulator also sends more fixes per second
    /// (up to 10), so a sped-up track is as dense as a real one.
    var speed: Double = 1 { didSet { if timer != nil { start() } } }
    private var stepsPerSecond: Int { Int(min(10, max(1, speed.rounded()))) }

    /// Defaults to Roche Harbor, San Juan Island, WA.
    var origin = Place.rocheHarbor.coordinate
    var rode = 25.0
    /// The boat and rode for the physics scenarios, from the app's settings. Changing it keeps the boat where it is.
    var physicsBoat: AnchorPhysics.Boat? {
        didSet { if let physicsBoat { physics?.boat = physicsBoat } }
    }
    private var physics: AnchorPhysics?
    /// When the current physics scenario started, on the real clock: the simulated clock runs on from here.
    private var startedAt = Date()

    /// Simulated time of day and how long the physics scenario has run (simulated seconds); nil when not running one.
    var clock: (time: Date, elapsed: Double)? {
        physics.map { (startedAt.addingTimeInterval($0.time), $0.time) }
    }

    /// One line on what a physics scenario is doing: simulated time, wind, current and tide.
    var status: String? {
        guard let physics else { return nil }
        let t = physics.time
        let w = physics.windNow()
        let c = physics.weather.current(t)
        let tide = physics.weather.tide(t)
        let slipped = Geo.distance(origin, AnchorEstimate.coordinate(physics.anchor, from: origin))
        return String(format: "%dh %02dm · wind %.0f kt from %@ · current %.1f kt to %@ · tide %+.1f m",
                      Int(t / 3600), Int(t / 60) % 60, w.speed, Compass.name(w.from), c.speed, Compass.name(c.toward), tide)
            + (slipped > 1 ? String(format: " · anchor dragged %.0f m", slipped) : "")
    }

    /// The simulated tide as highs and lows on the real clock (squeezed by the speed), so the app's tide displays,
    /// depth and outlook follow the model. Heights are metres above a datum 1 m below the starting low.
    func tideSnapshot(now: Date) -> TideSnapshot? {
        guard let physics else { return nil }
        let half = SimWeather.tidePeriod / 2
        let t = physics.time
        let first = Int((t / half).rounded(.down)) - 2
        let events = (first...first + 10).map { k -> TideEvent in
            let at = Double(k) * half
            let high = k % 2 != 0
            return TideEvent(time: now.addingTimeInterval((at - t) / max(speed, 1)),
                             height: 1 + (high ? physics.weather.tideRange : 0), isHigh: high)
        }
        return TideSnapshot(station: TideStation(id: "simulated", name: "Simulated tide", lat: origin.latitude, lng: origin.longitude),
                            events: events, fetched: now)
    }

    /// The simulated wind right now, in a physics scenario, so the app sees the same wind as the boat.
    var windNow: WindSample? {
        guard let physics else { return nil }
        let w = physics.windNow()
        let mean = physics.weather.wind(physics.time)
        return WindSample(time: Date(), speed: mean.speed, direction: w.from, gust: mean.speed * (1 + physics.weather.gustiness))
    }

    private var timer: Timer?
    private var simTime = 0.0
    private var last: CLLocationCoordinate2D?
    private var lastTime = Date()

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / Double(stepsPerSecond), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        simTime = 0
        last = nil
        physics = scenario.weather.flatMap { weather in physicsBoat.map { AnchorPhysics(boat: $0, weather: weather) } }
        startedAt = Date()
        start()
    }

    private func tick() {
        if var physics {
            // Integrate a simulated second at a time, however fast the simulation is running.
            let span = speed / Double(stepsPerSecond)
            let steps = max(1, Int(span.rounded()))
            for _ in 0..<steps { physics.step(span / Double(steps)) }
            self.physics = physics
            simTime = physics.time
            send(AnchorEstimate.coordinate(physics.phone, from: origin))
            return
        }
        simTime += speed / Double(stepsPerSecond)
        let t = simTime

        // Wind direction the boat lies toward, with a slow sheer.
        var base = 200.0
        if scenario == .windShift, t > 60 {
            base += 90 * min(1, (t - 60) / 120)
        }
        var heading = base + 35 * sin(2 * .pi * t / 90)
        var reach = rode
        if scenario == .wideSwing || scenario == .slowDrag {
            // Wind clocks ±75° over 20 minutes; the boat sheers ±15° on top, and sags in toward the anchor in lulls.
            heading = base + 75 * sin(2 * .pi * t / 1200) + 15 * sin(2 * .pi * t / 90)
            reach = rode * (0.88 + 0.12 * max(0, sin(2 * .pi * t / 240)))
        }

        var pivot = origin
        if scenario == .dragging, t > 45 {
            pivot = Geo.destination(from: origin, bearing: base, meters: 0.25 * (t - 45))
        }
        if scenario == .slowDrag, t > 1500 {
            pivot = Geo.destination(from: origin, bearing: base, meters: 0.01 * (t - 1500))   // 0.6 m/min
        }

        if scenario == .gpsDropout, (60..<120).contains(t) { return }

        send(Geo.destination(from: pivot, bearing: heading, meters: reach))
    }

    /// Passes on a position with GPS noise, as a fix.
    private func send(_ truth: CLLocationCoordinate2D) {
        let noisy = Geo.destination(from: truth, bearing: .random(in: 0..<360), meters: noise())

        let now = Date()
        var course: Double?
        var speedMS: Double?
        if let last {
            let moved = Geo.distance(last, noisy)
            let dt = max(0.1, now.timeIntervalSince(lastTime)) * max(1, speed)
            course = moved > 0.5 ? Geo.bearing(from: last, to: noisy) : nil
            speedMS = moved / dt
        }
        last = noisy
        lastTime = now
        onFix?(Fix(coordinate: noisy, accuracy: 4 + noise(), course: course, speed: speedMS, timestamp: now))
    }

    /// Roughly Gaussian, 0...~3 m.
    private func noise() -> Double {
        abs((0..<4).map { _ in Double.random(in: -1...1) }.reduce(0, +)) * 0.75
    }
}
