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

// GPS navigation is independent of the anchor-watch engine and its alarm state.
import Combine

struct NavigationWaypoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && latitude.isFinite && longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate) }
}

struct NavigationMetrics {
    let distance: Double
    let bearing: Double
    let speed: Double?
    let course: Double?
    let seconds: Double?
    static func usable(_ fix: Fix?, now: Date) -> Bool {
        guard let fix else { return false }
        let age = now.timeIntervalSince(fix.timestamp)
        return age >= -2 && age <= 15 && fix.accuracy.isFinite && fix.accuracy >= 0 && fix.accuracy <= 100 && CLLocationCoordinate2DIsValid(fix.coordinate)
    }
    static func calculate(fix: Fix?, destination: NavigationWaypoint, speed: Double?, now: Date) -> Self? {
        guard usable(fix, now: now), let fix, destination.isValid else { return nil }
        let distance = Geo.distance(fix.coordinate, destination.coordinate)
        let validSpeed = speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let moving = (validSpeed ?? 0) >= 0.5
        let course = moving ? fix.course.flatMap { $0.isFinite && $0 >= 0 && $0 < 360 ? $0 : nil } : nil
        return Self(distance: distance, bearing: Geo.bearing(from: fix.coordinate, to: destination.coordinate), speed: validSpeed, course: course,
                    seconds: moving ? distance / validSpeed! : nil)
    }
}

@MainActor final class NavigationStore: ObservableObject {
    @Published private(set) var waypoints: [NavigationWaypoint] = []
    @Published var activeID: UUID?
    @Published var placing = false
    @Published var draft: NavigationWaypoint?
    @Published var error: String?
    @Published private(set) var speed: Double?
    private var samples: [(Date, Double)] = []
    private var lastTimestamp: Date?
    private let defaults: UserDefaults
    private let key = "navigation.waypoints.v1"
    private var loadFailed = false
    var active: NavigationWaypoint? { waypoints.first { $0.id == activeID } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do {
                let saved = try JSONDecoder().decode([NavigationWaypoint].self, from: data)
                guard saved.allSatisfy(\.isValid), Set(saved.map(\.id)).count == saved.count else { throw CocoaError(.fileReadCorruptFile) }
                waypoints = saved
            } catch { loadFailed = true; self.error = "Saved waypoints could not be read. The stored data has not been replaced." }
        }
    }
    @discardableResult func save(_ waypoint: NavigationWaypoint) -> Bool {
        guard waypoint.isValid else { error = "Enter a name and valid latitude (−90…90) and longitude (−180…180)."; return false }
        guard !loadFailed else { return false }
        var updated = waypoints
        if let index = updated.firstIndex(where: { $0.id == waypoint.id }) { updated[index] = waypoint } else { updated.append(waypoint) }
        return persist(updated)
    }
    func delete(_ waypoint: NavigationWaypoint) {
        if persist(waypoints.filter { $0.id != waypoint.id }), activeID == waypoint.id { activeID = nil }
    }
    private func persist(_ updated: [NavigationWaypoint]) -> Bool {
        do { defaults.set(try JSONEncoder().encode(updated), forKey: key); waypoints = updated; error = nil; return true }
        catch { self.error = "Unable to save waypoints."; return false }
    }
    func pick(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        placing = false
        draft = .init(name: "Waypoint \(waypoints.count + 1)", latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
    func ingest(_ fix: Fix?, now: Date = Date()) {
        guard NavigationMetrics.usable(fix, now: now), let fix else { samples = []; speed = nil; return }
        guard lastTimestamp == nil || fix.timestamp > lastTimestamp! else { return }
        lastTimestamp = fix.timestamp
        samples.removeAll { fix.timestamp.timeIntervalSince($0.0) > 10 }
        guard let value = fix.speed, value.isFinite, value >= 0 else { samples = []; speed = nil; return }
        samples.append((fix.timestamp, value))
        if samples.count > 30 { samples.removeFirst(samples.count - 30) }
        speed = samples.map(\.1).reduce(0, +) / Double(samples.count)
    }
}
