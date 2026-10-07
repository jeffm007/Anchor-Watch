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

/// Where the anchor went in, given where the phone was. The anchor goes over the bow roller, which is
/// `bowOffset` metres ahead of the phone (assumed amidships), so the drop point is moved forward along
/// the best guess at which way the bow pointed. The uncertainty grows to cover how good that guess is.
enum AnchorPlacement {
    enum BowSource: Equatable {
        /// The direction the boat came in on: you approach the spot bow first.
        case approach
        /// No useful approach; a stopped boat lies head to wind.
        case wind
        /// Lying to an existing anchor, the bow points at it.
        case anchor
        /// No idea which way the bow pointed, so no offset.
        case unknown
    }

    struct Result: Equatable {
        let coordinate: CLLocationCoordinate2D
        /// Radius (metres) the true drop point is likely within: GPS error plus the bow-direction guess.
        let uncertainty: Double
        let source: BowSource
        /// Degrees true the bow was taken to point, when known.
        let bowBearing: Double?
    }

    /// The boat must have covered this much ground in the approach window to trust its direction.
    static let minApproach = 15.0
    /// Wind lighter than this doesn't hold a stopped boat's head.
    static let minWindKnots = 5.0
    /// How far off each bow-direction guess may be, degrees.
    static let approachError = 15.0, windError = 30.0, anchorError = 15.0

    static func place(phone: CLLocationCoordinate2D, gpsAccuracy: Double, bowOffset: Double,
                      approachFrom: CLLocationCoordinate2D?, lyingTo anchor: CLLocationCoordinate2D? = nil,
                      windFrom: Double?, windKnots: Double?) -> Result {
        let guess: (bearing: Double, error: Double, source: BowSource)?
        if let anchor, Geo.distance(phone, anchor) > 1 {
            guess = (Geo.bearing(from: phone, to: anchor), anchorError, .anchor)
        } else if let approachFrom, Geo.distance(approachFrom, phone) >= minApproach {
            guess = (Geo.bearing(from: approachFrom, to: phone), approachError, .approach)
        } else if let windFrom, let windKnots, windKnots >= minWindKnots {
            guess = (windFrom, windError, .wind)
        } else {
            guess = nil
        }

        guard let guess, bowOffset > 0 else {
            // The anchor is somewhere up to a half boat length from the phone, in an unknown direction.
            return Result(coordinate: phone, uncertainty: gpsAccuracy + bowOffset, source: .unknown, bowBearing: nil)
        }
        let sideways = bowOffset * sin(guess.error.radians)
        return Result(coordinate: Geo.destination(from: phone, bearing: guess.bearing, meters: bowOffset),
                      uncertainty: (gpsAccuracy * gpsAccuracy + sideways * sideways).squareRoot(),
                      source: guess.source, bowBearing: guess.bearing)
    }
}
