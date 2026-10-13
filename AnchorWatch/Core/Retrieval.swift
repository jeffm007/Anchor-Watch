import CoreLocation
import Foundation

/// Steering back up to the anchor while raising it: how far the bow is from it, which way to turn,
/// and when the bow is over it.
struct RetrievalGuide: Equatable {
    /// Bow to anchor along the surface, metres.
    var distance: Double
    /// Degrees true from the bow to the anchor.
    var bearing: Double
    /// The anchor relative to the boat's course, -180...180 (negative: to port). Nil when the boat is
    /// barely moving, since GPS course means nothing then.
    var relative: Double?
    /// The bow is over the anchor: the rode is up and down.
    var overAnchor: Bool

    /// Slower than this (about half a knot) and the GPS course is just noise.
    static let minimumSpeed = 0.25
    /// Within this many degrees of the course counts as dead ahead.
    static let aheadWithin = 10.0

    static func make(phone: Fix, anchor: CLLocationCoordinate2D, bowOffset: Double, depth: Double) -> RetrievalGuide {
        let course = (phone.speed ?? 0) >= minimumSpeed ? phone.course : nil
        // The bow is ahead of the GPS: along the course when moving; when not, a boat on its rode lies toward the anchor.
        let ahead = course ?? Geo.bearing(from: phone.coordinate, to: anchor)
        let bow = Geo.destination(from: phone.coordinate, bearing: ahead, meters: bowOffset)
        let distance = Geo.distance(bow, anchor)
        let bearing = Geo.bearing(from: bow, to: anchor)
        let relative = course.map { (bearing - $0 + 540).truncatingRemainder(dividingBy: 360) - 180 }
        // Up and down once the rode hangs within about 60° of straight down, or closer than GPS can tell apart.
        let overAnchor = distance <= max(depth * 0.5, 4)
        return RetrievalGuide(distance: distance, bearing: bearing, relative: relative, overAnchor: overAnchor)
    }

    /// What to tell the helm.
    var steer: String {
        if overAnchor { return "Over the anchor: rode up and down" }
        guard let relative else { return "Anchor lies \(Compass.name(bearing)) (\(Int(bearing.rounded()))°)" }
        let off = abs(relative)
        if off <= Self.aheadWithin { return "Dead ahead" }
        if off >= 150 { return "Behind you: turn round" }
        return "Steer \(Int((off / 5).rounded()) * 5)° to \(relative < 0 ? "port" : "starboard")"
    }
}
