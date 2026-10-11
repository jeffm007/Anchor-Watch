import CoreLocation

/// One position report, from the iPhone GPS or the simulator.
struct Fix: Equatable {
    var coordinate: CLLocationCoordinate2D
    /// Horizontal accuracy in metres (smaller is better).
    var accuracy: Double
    /// Degrees true, or nil when unknown.
    var course: Double?
    /// Metres per second, or nil when unknown.
    var speed: Double?
    var timestamp: Date
    /// From an external receiver paired with the phone, such as a Garmin GLO 2, rather than the iPhone's own GPS.
    var external = false
    /// Altitude accuracy in metres, when the source gives one.
    var altitudeAccuracy: Double?
}

/// Anything that can feed positions to the engine. The real GPS and the
/// simulator both conform, so the app never knows which one it is using.
@MainActor
protocol LocationSource: AnyObject {
    var onFix: ((Fix) -> Void)? { get set }
    func start()
    func stop()
}
