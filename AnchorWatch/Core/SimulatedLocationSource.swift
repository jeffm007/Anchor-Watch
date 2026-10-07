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
        var id: String { rawValue }
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
        start()
    }

    private func tick() {
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

        let truth = Geo.destination(from: pivot, bearing: heading, meters: reach)
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
