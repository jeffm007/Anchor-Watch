import CoreLocation
import Foundation

/// One night (or afternoon) at anchor, saved when the anchor is raised.
struct AnchorageEntry: Codable, Equatable, Identifiable {
    enum Held: String, Codable, CaseIterable, Identifiable {
        case unknown = "Not noted", well = "Held well", dragged = "Dragged"
        var id: String { rawValue }
    }

    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var dropped: Date
    var raised: Date
    /// Metres: depth when set, rode out, alarm radius, and the furthest the boat went from the anchor.
    var depth: Double
    var rodeOut: Double
    var radius: Double
    var maxDistance: Double
    var bottom: String
    var held = Held.unknown
    var notes = ""
    /// The track, thinned: [latitude, longitude] pairs.
    var track: [[Double]] = []
    /// Locked entries can't be deleted. Optional so logs saved before locking existed still load.
    var locked: Bool?

    var isLocked: Bool {
        get { locked == true }
        set { locked = newValue }
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var trackCoordinates: [CLLocationCoordinate2D] { track.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) } }
}

/// Saving the log, and finding earlier visits.
enum AnchorageLog {
    /// Anchored this close to a logged anchor counts as the same anchorage.
    static let sameSpot = 150.0
    /// Stays shorter than this aren't logged (a lunch stop still counts; a quick test drop doesn't).
    static let minimumStay: TimeInterval = 10 * 60

    /// The latest earlier visit within `sameSpot` of `point`, leaving out `excluding`.
    static func previousVisit(near point: CLLocationCoordinate2D, in entries: [AnchorageEntry], before date: Date) -> AnchorageEntry? {
        entries.filter { $0.dropped < date && Geo.distance($0.coordinate, point) <= sameSpot }.max { $0.dropped < $1.dropped }
    }

    /// Every n-th point, so a long night keeps its shape in a few hundred points.
    static func thin(_ points: [CLLocationCoordinate2D], to limit: Int = 400) -> [[Double]] {
        guard points.count > limit else { return points.map { [$0.latitude, $0.longitude] } }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { i in let p = points[Int((Double(i) * step).rounded())]; return [p.latitude, p.longitude] }
    }

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("anchorages.json")
    }

    static func load(from url: URL? = nil) -> [AnchorageEntry] {
        (try? Data(contentsOf: url ?? file)).flatMap { try? JSONDecoder().decode([AnchorageEntry].self, from: $0) } ?? []
    }

    static func save(_ entries: [AnchorageEntry], to url: URL? = nil) {
        try? JSONEncoder().encode(entries).write(to: url ?? file, options: .atomic)
    }
}
