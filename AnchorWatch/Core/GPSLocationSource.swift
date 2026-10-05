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
                timestamp: $0.timestamp)
        }
        Task { @MainActor in fixes.forEach { self.onFix?($0) } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
