import CoreMotion
import Foundation

/// One barometer reading, hectopascals (millibars).
struct PressureReading: Codable, Equatable {
    let time: Date
    let hPa: Double
}

/// What the pressure is doing. A falling barometer warns of wind before it arrives.
enum PressureTrend {
    /// Falls over three hours, by the usual marine rules of thumb: 3 hPa is quick (wind likely), 6 is very fast
    /// (gale risk).
    static let quickFall = 3.0
    static let rapidFall = 6.0

    enum Level: Int, Comparable {
        case steady, fallingQuickly, fallingFast
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Change over the last `hours` (latest minus the reading nearest that long ago), if the history reaches back
    /// most of the way.
    static func change(_ readings: [PressureReading], over hours: Double = 3, now: Date = Date()) -> Double? {
        guard let latest = readings.last else { return nil }
        let target = now.addingTimeInterval(-hours * 3600)
        guard let then = readings.min(by: { abs($0.time.timeIntervalSince(target)) < abs($1.time.timeIntervalSince(target)) }),
              latest.time.timeIntervalSince(then.time) >= hours * 3600 * 0.8 else { return nil }
        return latest.hPa - then.hPa
    }

    static func level(_ change: Double?) -> Level {
        guard let change else { return .steady }
        return -change >= rapidFall ? .fallingFast : -change >= quickFall ? .fallingQuickly : .steady
    }
}

/// The iPhone's own barometer. Nothing on phones without one, or in the simulator.
@MainActor
final class Barometer {
    var onReading: ((Double) -> Void)?
    private let altimeter = CMAltimeter()
    private(set) var running = false

    static var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    func start() {
        guard Self.isAvailable, !running else { return }
        running = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            self?.onReading?(data.pressure.doubleValue * 10)      // kPa to hPa
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        running = false
    }
}
