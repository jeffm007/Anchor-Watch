import CoreLocation

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (a: Self, b: Self) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude
    }
}

/// Spherical-earth geometry. Accurate to well under a metre at anchoring distances.
enum Geo {
    static let earthRadius = 6_371_008.8

    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude.radians, φ2 = b.latitude.radians
        let dφ = φ2 - φ1
        let dλ = (b.longitude - a.longitude).radians
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from a to b, degrees true, 0..<360.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude.radians, φ2 = b.latitude.radians
        let dλ = (b.longitude - a.longitude).radians
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return (atan2(y, x).degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point reached travelling `meters` from `start` on `bearing` degrees true.
    static func destination(from start: CLLocationCoordinate2D, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let δ = meters / earthRadius
        let θ = bearing.radians
        let φ1 = start.latitude.radians, λ1 = start.longitude.radians
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return CLLocationCoordinate2D(latitude: φ2.degrees, longitude: (λ2.degrees + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}

extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
