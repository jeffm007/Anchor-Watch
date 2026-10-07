import CoreLocation
import Foundation

/// Finds the anchor from the boat's swing. At anchor the phone moves on (or inside) a circle centred on
/// the anchor, whose radius is the rode's reach plus the bow-to-phone distance. The outer edge of the
/// track traces that circle, so fitting a circle to the edge finds the anchor.
enum AnchorEstimate {
    enum Method: Equatable {
        /// Enough swing to fit both the centre and the radius.
        case free
        /// Little swing: the radius is fixed from the scope calculator and only the centre is fitted.
        case fixedRadius
    }

    struct Result: Equatable {
        let center: CLLocationCoordinate2D
        /// Error ellipse around the centre, metres: the anchor is inside it about two times in three.
        let semiMajor: Double
        let semiMinor: Double
        /// Bearing of the long axis, degrees true (0..<180).
        let majorBearing: Double
        let method: Method
        /// Radius of the fitted circle, and the one the scope calculator expects.
        let radius: Double
        let modelRadius: Double
        /// Degrees of swing the edge points cover.
        let arc: Double
        let pointsUsed: Int
        let minutes: Double
        /// True if the wind cross-check lands inside the tolerance, false if not, nil with no wind.
        let windAgrees: Bool?
    }

    /// Why there's no estimate yet, for the status line.
    enum Pending: Equatable {
        case collecting(minutes: Double)
        case tooUncertain(semiMajor: Double)
    }

    // Tuning, quoted by the user guide.
    /// Ignore the first minutes after the drop, while the anchor sets and the boat backs down.
    static let settleMinutes = 2.0
    static let minMinutes = 20.0
    static let minPoints = 30
    static let sliceDegrees = 10.0
    /// Share of each slice's points, farthest first, taken as the stretched-out edge.
    static let edgeFraction = 0.2
    static let freeFitArc = 90.0
    /// Huber weighting: residuals beyond this many robust sigmas count for less.
    static let huberK = 1.5
    /// 1-sigma ellipse × this covers about 68% in two dimensions, matching the GPS ± circle.
    static let confidenceScale = 1.51
    /// GPS error drifts slowly, so no amount of averaging gets below this.
    static let floorMeters = 2.0
    /// Estimates vaguer than this aren't shown.
    static let maxSemiMajor = 25.0
    static let windMinKnots = 5.0
    static let windTolerance = 15.0
    /// The wind check uses where the boat has been over this last stretch.
    static let windWindowSeconds = 60.0
    /// A fixed-radius fit is only as good as the radius: the rode let out may differ from the scope
    /// calculator's. This share of the radius is added as uncertainty along the swing direction.
    static let modelRadiusError = 0.15

    // MARK: Local flat coordinates (metres east and north of a reference point)

    struct Point { var x: Double, y: Double }

    static func local(_ c: CLLocationCoordinate2D, from ref: CLLocationCoordinate2D) -> Point {
        Point(x: (c.longitude - ref.longitude).radians * Geo.earthRadius * cos(ref.latitude.radians),
              y: (c.latitude - ref.latitude).radians * Geo.earthRadius)
    }

    static func coordinate(_ p: Point, from ref: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: ref.latitude + (p.y / Geo.earthRadius).degrees,
                               longitude: ref.longitude + (p.x / (Geo.earthRadius * cos(ref.latitude.radians))).degrees)
    }

    // MARK: The estimate

    /// - Parameters:
    ///   - track: fixes since the anchor was dropped (older ones are ignored).
    ///   - mark: where the anchor is marked now; the first guess at the centre.
    ///   - modelRadius: rode reach plus bow-to-phone distance, from the scope calculator.
    ///   - timeScale: simulated seconds per real second, so a sped-up simulator reaches the waits sooner.
    static func estimate(track: [Fix], dropped: Date, mark: CLLocationCoordinate2D, modelRadius: Double,
                         windFrom: Double?, windKnots: Double?, timeScale: Double = 1) -> Result? {
        if case .success(let r) = evaluate(track: track, dropped: dropped, mark: mark, modelRadius: modelRadius,
                                           windFrom: windFrom, windKnots: windKnots, timeScale: timeScale) { return r }
        return nil
    }

    static func evaluate(track: [Fix], dropped: Date, mark: CLLocationCoordinate2D, modelRadius: Double,
                         windFrom: Double?, windKnots: Double?, timeScale: Double = 1) -> Swift.Result<Result, PendingError> {
        let scale = max(timeScale, 1)
        let start = dropped.addingTimeInterval(settleMinutes * 60 / scale)
        let fixes = track.filter { $0.timestamp >= start }
        let minutes = (fixes.last?.timestamp.timeIntervalSince(start) ?? 0) * scale / 60
        guard minutes >= minMinutes, fixes.count >= minPoints, modelRadius > 0 else {
            return .failure(PendingError(.collecting(minutes: max(0, minutes))))
        }
        return fit(fixes, mark: mark, modelRadius: modelRadius, minutes: minutes,
                   windFrom: windFrom, windKnots: windKnots, timeScale: scale)
    }

    /// Steps 3–6 on a given stretch of track, with no waiting rules. The drift check uses it on a rolling window.
    static func fit(_ fixes: [Fix], mark: CLLocationCoordinate2D, modelRadius: Double, minutes: Double,
                    windFrom: Double?, windKnots: Double?, timeScale scale: Double = 1) -> Swift.Result<Result, PendingError> {
        guard fixes.count >= minPoints, modelRadius > 0 else {
            return .failure(PendingError(.collecting(minutes: minutes)))
        }
        let points = fixes.map { local($0.coordinate, from: mark) }
        var center = Point(x: 0, y: 0)
        var fit: Fit?
        var edge: [Point] = []
        var arc = 0.0
        // Pick the edge around the current guess, fit, and repeat around the new centre.
        for _ in 0..<3 {
            (edge, arc) = outerEdge(points, around: center)
            guard edge.count >= 3 else { break }
            let free = arc >= freeFitArc
            guard let f = fitCircle(edge, start: center, radius: modelRadius, fitRadius: free) else { break }
            fit = f
            center = f.center
        }
        guard let fit else { return .failure(PendingError(.collecting(minutes: minutes))) }

        // Each slice is treated as one independent measurement: points within a slice share GPS error.
        let slices = Double(Set(edge.map { slice(of: $0, around: fit.center) }).count)
        let inflate = Double(edge.count) / max(slices, 1)
        var covariance = fit.covariance
        covariance.xx *= inflate; covariance.xy *= inflate; covariance.yy *= inflate
        if !fit.fittedRadius {
            // Radius doubt moves the centre toward or away from the boat: along the mean direction to the edge.
            let mx = edge.map(\.x).reduce(0, +) / Double(edge.count) - fit.center.x
            let my = edge.map(\.y).reduce(0, +) / Double(edge.count) - fit.center.y
            let len = max(hypot(mx, my), 1e-6)
            let ux = mx / len, uy = my / len
            let v = pow(modelRadiusError * modelRadius, 2)
            covariance.xx += v * ux * ux; covariance.xy += v * ux * uy; covariance.yy += v * uy * uy
        }
        let (major, minor, bearing) = ellipse(covariance, scale: confidenceScale)
        let semiMajor = max(major, floorMeters), semiMinor = max(minor, floorMeters)
        guard semiMajor <= maxSemiMajor else {
            return .failure(PendingError(.tooUncertain(semiMajor: semiMajor)))
        }

        // Wind cross-check: the anchor lies upwind of the boat, a radius away.
        var windAgrees: Bool?
        if let windFrom, let windKnots, windKnots >= windMinKnots, let latest = fixes.last {
            let recent = fixes.filter { latest.timestamp.timeIntervalSince($0.timestamp) <= windWindowSeconds / scale }.map { local($0.coordinate, from: mark) }
            let boat = Point(x: recent.map(\.x).reduce(0, +) / Double(recent.count), y: recent.map(\.y).reduce(0, +) / Double(recent.count))
            let byWind = Point(x: boat.x + fit.radius * sin(windFrom.radians), y: boat.y + fit.radius * cos(windFrom.radians))
            windAgrees = hypot(byWind.x - fit.center.x, byWind.y - fit.center.y) <= max(windTolerance, 2 * semiMajor)
        }

        return .success(Result(center: coordinate(fit.center, from: mark), semiMajor: semiMajor, semiMinor: semiMinor,
                               majorBearing: bearing, method: fit.fittedRadius ? .free : .fixedRadius,
                               radius: fit.radius, modelRadius: modelRadius, arc: arc, pointsUsed: edge.count,
                               minutes: minutes, windAgrees: windAgrees))
    }

    struct PendingError: Error, Equatable {
        let pending: Pending
        init(_ pending: Pending) { self.pending = pending }
    }

    // MARK: Steps

    static func slice(of p: Point, around c: Point) -> Int {
        let bearing = (atan2(p.x - c.x, p.y - c.y).degrees + 360).truncatingRemainder(dividingBy: 360)
        return Int(bearing / sliceDegrees)
    }

    /// The farthest share of points in each slice round `center`, and how many degrees of swing they cover.
    static func outerEdge(_ points: [Point], around center: Point) -> (edge: [Point], arc: Double) {
        var slices: [Int: [Point]] = [:]
        for p in points { slices[slice(of: p, around: center), default: []].append(p) }
        var edge: [Point] = []
        for (_, ps) in slices {
            let sorted = ps.sorted { hypot($0.x - center.x, $0.y - center.y) > hypot($1.x - center.x, $1.y - center.y) }
            edge += sorted.prefix(max(1, Int((Double(sorted.count) * edgeFraction).rounded(.up))))
        }
        // Arc covered = 360° less the biggest empty gap between occupied slices.
        let occupied = slices.keys.sorted()
        let count = Int(360 / sliceDegrees)
        var biggestGap = 0
        for (i, s) in occupied.enumerated() {
            let next = i + 1 < occupied.count ? occupied[i + 1] : occupied[0] + count
            biggestGap = max(biggestGap, next - s - 1)
        }
        let arc = occupied.isEmpty ? 0 : Double(count - biggestGap) * sliceDegrees
        return (edge, arc)
    }

    struct Fit {
        var center: Point
        var radius: Double
        var fittedRadius: Bool
        /// 2×2 covariance of the centre, m².
        var covariance: (xx: Double, xy: Double, yy: Double)
    }

    /// Geometric circle fit by Gauss–Newton with Huber weights. With `fitRadius` false, the radius stays at `radius`.
    static func fitCircle(_ pts: [Point], start: Point, radius: Double, fitRadius: Bool) -> Fit? {
        var cx = start.x, cy = start.y, r = radius
        let n = fitRadius ? 3 : 2
        guard pts.count > n else { return nil }
        var normal = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var sigma2 = 1.0

        for _ in 0..<30 {
            let d = pts.map { max(hypot($0.x - cx, $0.y - cy), 1e-6) }
            let e = zip(d, pts).map { $0.0 - r }
            // Robust scale from the median absolute residual.
            let mad = e.map(abs).sorted()[e.count / 2] * 1.4826
            let k = huberK * max(mad, 0.5)
            let w = e.map { abs($0) <= k ? 1 : k / abs($0) }

            normal = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var rhs = [Double](repeating: 0, count: n)
            for i in pts.indices {
                var j = [-(pts[i].x - cx) / d[i], -(pts[i].y - cy) / d[i]]
                if fitRadius { j.append(-1) }
                for a in 0..<n {
                    rhs[a] -= w[i] * j[a] * e[i]
                    for b in 0..<n { normal[a][b] += w[i] * j[a] * j[b] }
                }
            }
            guard let step = solve(normal, rhs) else { return nil }
            cx += step[0]; cy += step[1]
            if fitRadius { r += step[2] }
            sigma2 = zip(w, e).map { $0 * $1 * $1 }.reduce(0, +) / Double(max(pts.count - n, 1))
            if hypot(step[0], step[1]) < 0.001 { break }
        }
        guard let inverse = invert(normal) else { return nil }
        return Fit(center: Point(x: cx, y: cy), radius: r, fittedRadius: fitRadius,
                   covariance: (sigma2 * inverse[0][0], sigma2 * inverse[0][1], sigma2 * inverse[1][1]))
    }

    /// Semi-axes and long-axis bearing of the ellipse for a 2×2 covariance, scaled.
    static func ellipse(_ c: (xx: Double, xy: Double, yy: Double), scale: Double) -> (Double, Double, Double) {
        let mean = (c.xx + c.yy) / 2
        let spread = (pow((c.xx - c.yy) / 2, 2) + c.xy * c.xy).squareRoot()
        let major = max(mean + spread, 0).squareRoot() * scale
        let minor = max(mean - spread, 0).squareRoot() * scale
        // Angle of the long axis from east, anticlockwise; turned into a compass bearing.
        let angle = 0.5 * atan2(2 * c.xy, c.xx - c.yy)
        let bearing = ((90 - angle.degrees) + 360).truncatingRemainder(dividingBy: 180)
        return (major, minor, bearing)
    }

    // MARK: Small linear algebra

    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        guard let inv = invert(a) else { return nil }
        return inv.map { row in zip(row, b).map(*).reduce(0, +) }
    }

    /// Gauss–Jordan inverse of a small matrix.
    static func invert(_ a: [[Double]]) -> [[Double]]? {
        let n = a.count
        var m = a.enumerated().map { i, row in row + (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            let p = m[col][col]
            m[col] = m[col].map { $0 / p }
            for row in 0..<n where row != col {
                let f = m[row][col]
                m[row] = zip(m[row], m[col]).map { $0 - f * $1 }
            }
        }
        return m.map { Array($0[n...]) }
    }
}
