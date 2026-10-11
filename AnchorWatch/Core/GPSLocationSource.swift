import CoreLocation

@MainActor
final class GPSLocationSource: NSObject, LocationSource, CLLocationManagerDelegate {
    var onFix: ((Fix) -> Void)?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Background GPS is what drains the battery, so it is on only while an anchor is being watched.
    /// With it off, iOS suspends the app when you leave it and stops the GPS.
    var keepsRunningInBackground = false {
        didSet {
            manager.allowsBackgroundLocationUpdates = keepsRunningInBackground
            manager.showsBackgroundLocationIndicator = keepsRunningInBackground
        }
    }

    func start() {
        manager.requestAlwaysAuthorization()
        manager.allowsBackgroundLocationUpdates = keepsRunningInBackground
        manager.showsBackgroundLocationIndicator = keepsRunningInBackground
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.filter { $0.horizontalAccuracy >= 0 }.map {
            Fix(coordinate: $0.coordinate,
                accuracy: $0.horizontalAccuracy,
                course: $0.course >= 0 ? $0.course : nil,
                speed: $0.speed >= 0 ? $0.speed : nil,
                timestamp: $0.timestamp,
                external: $0.sourceInformation?.isProducedByAccessory ?? false,
                altitudeAccuracy: $0.verticalAccuracy > 0 ? $0.verticalAccuracy : nil)
        }
        Task { @MainActor in fixes.forEach(self.deliver) }
    }

    /// Every position iOS sends, before one source is picked: for the Testing page.
    var onReading: ((Fix) -> Void)?
    var preference: FixSelector.Preference {
        get { selector.preference }
        set { selector.preference = newValue }
    }
    private var selector = FixSelector()

    private func deliver(_ fix: Fix) {
        onReading?(fix)
        if selector.accept(fix) { onFix?(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// iOS mixes positions from a paired receiver (Garmin GLO 2) with the iPhone's own, and the app can't choose which.
/// While both are reporting, the receiver wins if its accuracy is decent or no worse than the iPhone's;
/// otherwise the more accurate iPhone wins. Testing can force one source instead.
/// A source that has gone quiet for `timeout` never blocks the other.
struct FixSelector {
    enum Preference: String, CaseIterable, Identifiable {
        case auto = "Auto", external = "External", phone = "iPhone"
        var id: String { rawValue }
    }

    var preference = Preference.auto
    /// The receiver is trusted up to this accuracy even when the iPhone claims better (~50 ft).
    /// An iPhone under a roof can report a few feet while really being well off.
    static let trustedExternal = 15.0
    static let timeout: TimeInterval = 10

    private(set) var lastExternal: Fix?
    private(set) var lastInternal: Fix?

    /// Records the fix and says whether to pass it on.
    mutating func accept(_ fix: Fix) -> Bool {
        if fix.external { lastExternal = fix } else { lastInternal = fix }
        guard let other = fix.external ? lastInternal : lastExternal,
              fix.timestamp.timeIntervalSince(other.timestamp) < Self.timeout else { return true }
        let (external, phone) = fix.external ? (fix, other) : (other, fix)
        let externalWins = switch preference {
        case .auto: external.accuracy <= Self.trustedExternal || external.accuracy <= phone.accuracy
        case .external: true
        case .phone: false
        }
        return fix.external == externalWins
    }
}
