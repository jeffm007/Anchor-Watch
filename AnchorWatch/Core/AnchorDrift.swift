import CoreLocation
import Foundation

/// Is the anchor dragging? A rolling swing fit (the last few minutes of track) is run once a minute, and
/// the centres it finds are kept. A holding anchor's centre wanders a little and comes back; a dragging
/// one moves steadily one way. A straight line through recent centres tells the two apart.
enum AnchorDrift {
    /// One rolling fit: where the anchor seemed to be, and how sure.
    struct Sample: Equatable {
        /// Minutes since the drop, in simulated time when the simulator is sped up.
        let minute: Double
        let center: CLLocationCoordinate2D
        let semiMajor: Double
    }

    struct Result: Equatable {
        /// How far the anchor has moved over the window, metres, and which way (degrees true).
        let distance: Double
        let bearing: Double
        let metersPerMinute: Double
        let minutes: Double
        /// Where the line through the centres starts and ends, for the arrow on the chart.
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
    }

    // Tuning, quoted by the user guide.
    /// Each rolling fit uses this much track.
    static let rollingMinutes = 15.0
    /// The line is fitted through the centres from this long.
    static let windowMinutes = 20.0
    static let minSamples = 5
    /// Smaller moves than this are never called drift, whatever the statistics say.
    static let minMeters = 5.0
    /// The move must also be this many times the centres' typical error.
    static let significance = 1.5
    /// Share of the centres' spread along the drift direction that the line must explain (R²).
    static let minSteadiness = 0.6
    /// Drift must be found this many fits in a row before it's reported.
    static let confirmations = 3

    /// The rolling fit at the end of `track`: the last `rollingMinutes`, from settle time on.
    static func rollingSample(track: [Fix], dropped: Date, mark: CLLocationCoordinate2D, modelRadius: Double,
                              timeScale: Double = 1) -> Sample? {
        let scale = max(timeScale, 1)
        guard let latest = track.last?.timestamp else { return nil }
        let settled = dropped.addingTimeInterval(AnchorEstimate.settleMinutes * 60 / scale)
        let from = latest.addingTimeInterval(-rollingMinutes * 60 / scale)
        guard from >= settled else { return nil }          // wait for a full window
        let window = track.filter { $0.timestamp >= from }
        guard case .success(let r) = AnchorEstimate.fit(window, mark: mark, modelRadius: modelRadius, minutes: rollingMinutes,
                                                        windFrom: nil, windKnots: nil, timeScale: scale) else { return nil }
        return Sample(minute: latest.timeIntervalSince(dropped) * scale / 60, center: r.center, semiMajor: r.semiMajor)
    }

    /// Steady movement of the centres over the last `windowMinutes`, or nil if they're holding still.
    static func assess(_ samples: [Sample]) -> Result? {
        guard let last = samples.last else { return nil }
        let recent = samples.filter { last.minute - $0.minute <= windowMinutes }
        guard recent.count >= minSamples, let first = recent.first else { return nil }
        let ref = first.center
        let pts = recent.map { AnchorEstimate.local($0.center, from: ref) }
        let t = recent.map(\.minute)

        // Least-squares line through east and north against time: the slope is the velocity.
        let tMean = t.reduce(0, +) / Double(t.count)
        let sTT = t.map { ($0 - tMean) * ($0 - tMean) }.reduce(0, +)
        guard sTT > 0 else { return nil }
        let xMean = pts.map(\.x).reduce(0, +) / Double(pts.count)
        let yMean = pts.map(\.y).reduce(0, +) / Double(pts.count)
        let vx = zip(t, pts).map { ($0 - tMean) * ($1.x - xMean) }.reduce(0, +) / sTT
        let vy = zip(t, pts).map { ($0 - tMean) * ($1.y - yMean) }.reduce(0, +) / sTT
        let speed = hypot(vx, vy)
        let span = (t.last ?? 0) - (t.first ?? 0)
        let distance = speed * span

        // Big enough to matter, and bigger than the fits' own error.
        let typicalError = recent.map(\.semiMajor).reduce(0, +) / Double(recent.count)
        guard distance >= max(minMeters, significance * typicalError) else { return nil }

        // Steady, not wander: how much of the spread along the drift direction the straight line explains.
        let ux = vx / speed, uy = vy / speed
        let along = pts.map { ($0.x - xMean) * ux + ($0.y - yMean) * uy }
        let total = along.map { $0 * $0 }.reduce(0, +)
        let residual = zip(t, along).map { pow($1 - speed * ($0 - tMean), 2) }.reduce(0, +)
        let steadiness = total > 0 ? 1 - residual / total : 0
        guard steadiness >= minSteadiness else { return nil }

        let start = AnchorEstimate.Point(x: xMean + vx * ((t.first ?? 0) - tMean), y: yMean + vy * ((t.first ?? 0) - tMean))
        let end = AnchorEstimate.Point(x: xMean + vx * ((t.last ?? 0) - tMean), y: yMean + vy * ((t.last ?? 0) - tMean))
        return Result(distance: distance, bearing: (atan2(vx, vy).degrees + 360).truncatingRemainder(dividingBy: 360),
                      metersPerMinute: speed, minutes: span,
                      from: AnchorEstimate.coordinate(start, from: ref), to: AnchorEstimate.coordinate(end, from: ref))
    }
}
