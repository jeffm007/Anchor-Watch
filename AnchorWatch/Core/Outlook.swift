import Foundation

/// One thing coming up at the anchorage in the next 24 hours.
struct OutlookItem: Equatable, Identifiable {
    enum Severity: Int, Comparable {
        case info, caution, danger
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    enum Kind: String { case shallow, scope, gusts, swing, windShift, tideTurn, slack }

    let kind: Kind
    let severity: Severity
    let start: Date
    /// When the stretch ends; nil for a single moment (a wind shift, a high or low).
    let end: Date?
    let title: String
    let detail: String
    var id: String { "\(kind.rawValue)-\(Int(start.timeIntervalSince1970))" }
}

/// One forecast hour with the safe gust limit worked out at that hour's depth.
struct HourlyHolding: Equatable {
    let time: Date
    let speed: Double
    let gust: Double
    let direction: Double
    let depth: Double
    let safeGust: Double?
    let status: AnchorAssessment.Status
    /// Current at the anchorage, if predicted: knots, where it goes, and whether it's the flood.
    var current: CurrentAt? = nil
    /// Which way the boat lies from the anchor (degrees true): along the combined push of wind and current.
    var lie: Double = 0
    /// Size of that push and its two parts, newtons.
    var push: Double = 0
    var windPush: Double = 0
    var currentPush: Double = 0
}

/// Current at a moment: speed (knots), where the water goes (degrees true), and whether it's flooding.
struct CurrentAt: Equatable {
    let speed: Double
    let toward: Double
    let flooding: Bool
}

/// The next 24 hours at this anchorage, from the tide and wind forecasts: when the water gets thin, when the scope
/// gets short, when forecast gusts beat what the setup holds, when the wind shifts and when the tide turns.
/// Predictive rather than descriptive: it says when things go wrong, not just what they are now.
enum Outlook {
    /// Scope below this at any time is flagged; below `veryShortScope` it's serious.
    static let shortScope = 4.0
    static let veryShortScope = 3.0

    /// A swing at least this big makes the anchor turn and reset.
    static let swingDegrees = 90.0
    /// Below this push (the wind's on the front windage at 5 kt) the boat isn't held to any heading.
    static func minPush(_ b: BoatProfile) -> Double { BoatMath.windLoad(b, knots: 5) ?? 50 }

    /// The anchoring maths run for each forecast hour, with the depth at that hour (so high water's shorter
    /// scope lowers the limit) and the predicted current if there is one; otherwise the Anchoring defaults.
    /// Also works out which way the boat lies from the wind and current together.
    static func hourly(_ b: BoatProfile, scope s: ScopeSettings, bottom: AnchorConditions.Bottom, rodeOut: Double,
                       depths: [(time: Date, depth: Double)], forecast: [WindSample],
                       current: ((Date) -> CurrentAt?)? = nil,
                       now: Date = Date(), hours: Double = 24) -> [HourlyHolding] {
        let window = forecast.filter { $0.time >= now.addingTimeInterval(-1800) && $0.time <= now.addingTimeInterval(hours * 3600) }
        return window.map { sample in
            let depth = depths.min { abs($0.time.timeIntervalSince(sample.time)) < abs($1.time.timeIntervalSince(sample.time)) }?.depth ?? s.depth
            var scope = s
            scope.depth = depth
            scope.tideRise = 0
            var c = AnchorConditions()
            c.wind = min(sample.speed, sample.gust)
            c.gust = sample.gust
            c.bottom = bottom
            c.rodeOut = rodeOut
            let windToward = (sample.direction + 180).truncatingRemainder(dividingBy: 360)
            let flow = current?(sample.time)
            if let flow {
                c.current = flow.speed
                let angle = Compass.difference(windToward, flow.toward)
                c.currentDirection = angle <= 45 ? .with : angle >= 135 ? .against : .across
            }
            let r = AnchorMath.assess(b, scope: scope, c)

            // The boat lies where wind and current together push it.
            let windPush = BoatMath.windLoad(b, knots: sample.speed) ?? 0
            let currentPush = flow.map { AnchorMath.currentLoad(b, knots: $0.speed) } ?? 0
            let east = windPush * sin(windToward.radians) + currentPush * sin((flow?.toward ?? 0).radians)
            let north = windPush * cos(windToward.radians) + currentPush * cos((flow?.toward ?? 0).radians)
            return HourlyHolding(time: sample.time, speed: sample.speed, gust: sample.gust, direction: sample.direction,
                                 depth: depth, safeGust: r.safeGust, status: r.status, current: flow,
                                 lie: (atan2(east, north).degrees + 360).truncatingRemainder(dividingBy: 360),
                                 push: (east * east + north * north).squareRoot(), windPush: windPush, currentPush: currentPush)
        }
    }

    /// `currentEvents` are the predicted slacks and maximums when there's a current station nearby, already
    /// scaled to the anchorage; without them the highs and lows stand in for when the current turns.
    static func items(_ b: BoatProfile, scope s: ScopeSettings, rodeOut: Double,
                      depths: [(time: Date, depth: Double)], hourly: [HourlyHolding], tideTurns: [TideEvent],
                      currentEvents: [CurrentEvent]? = nil,
                      units: Units, now: Date = Date(), hours: Double = 24) -> [OutlookItem] {
        var items: [OutlookItem] = []
        let end = now.addingTimeInterval(hours * 3600)
        func when(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

        // Thin water under the keel.
        if b.draft > 0 {
            for w in TideMath.shallowWindows(depths, below: b.draft + AnchorMath.keelClearance) {
                let aground = w.least <= b.draft
                items.append(OutlookItem(
                    kind: .shallow, severity: aground ? .danger : .caution, start: w.start, end: w.end,
                    title: aground ? "Aground at low water" : "Under \(units.format(AnchorMath.keelClearance)) below the keel",
                    detail: aground ? "As little as \(units.formatTenths(w.least)) of water for a \(units.formatTenths(b.draft)) draft."
                                    : "Least \(units.formatTenths(w.least - b.draft)) under the keel."))
            }
        }

        // Short scope at high water.
        let scopes = depths.map { (time: $0.time, depth: rodeOut / max($0.depth + s.bowHeight, 0.1)) }
        for w in TideMath.shallowWindows(scopes, below: shortScope) {
            items.append(OutlookItem(
                kind: .scope, severity: w.least < veryShortScope ? .danger : .caution, start: w.start, end: w.end,
                title: String(format: "Scope down to %.1f:1", w.least),
                detail: "High water shortens the scope with \(units.format(rodeOut)) out. Let out more rode before then."))
        }

        // Forecast gusts the setup can't comfortably hold, hour by hour.
        var run: [HourlyHolding] = []
        func closeRun() {
            guard let first = run.first, let last = run.last else { return }
            let peak = run.max { $0.gust < $1.gust }!
            let limit = run.compactMap(\.safeGust).min()
            let worst = run.map(\.status).max()!
            let beyond = limit.map { peak.gust > $0 } ?? false
            items.append(OutlookItem(
                kind: .gusts, severity: worst == .danger ? .danger : .caution, start: first.time,
                end: run.count > 1 ? last.time : nil,
                title: beyond ? "Gusts \(Int(peak.gust.rounded())) kt, beyond the \(Int(limit!)) kt you can hold"
                              : "Gusts \(Int(peak.gust.rounded())) kt, close to your limit",
                detail: "Peak around \(when(peak.time)) from the \(Compass.name(peak.direction)). Let out more rode, or move somewhere better."))
            run = []
        }
        for h in hourly {
            if h.status != .good { run.append(h) } else { closeRun() }
        }
        closeRun()

        // Swings: the boat lies along the combined push of wind and current. A big change in that direction
        // turns the boat round the anchor, which then has to turn and reset in the bottom.
        let held = hourly.filter { $0.push >= minPush(b) }
        var swingTimes: [Date] = []
        if var reference = held.first {
            for h in held.dropFirst() {
                let turn = Compass.difference(h.lie, reference.lie)
                guard turn >= swingDegrees else { continue }
                let currentLeads = h.currentPush > h.windPush
                let cause: String
                if currentLeads, let flow = h.current {
                    cause = "The \(flow.flooding ? "flood" : "ebb") takes over (\(String(format: "%.1f", flow.speed)) kt toward the \(Compass.name(flow.toward)))"
                } else {
                    cause = "The wind goes round to the \(Compass.name(h.direction)) at \(Int(h.speed.rounded())) kt"
                }
                items.append(OutlookItem(
                    kind: .swing, severity: .caution, start: h.time, end: nil,
                    title: "Boat swings about \(Int((turn / 10).rounded()) * 10)°",
                    detail: "\(cause). The anchor has to turn and reset; check it holds and the new swing clears everything."))
                swingTimes.append(h.time)
                reference = h
            }
        }

        // Smaller wind shifts (60° or more with enough wind to swing the boat), unless a swing already covers them.
        let steady = hourly.filter { $0.speed >= 8 }
        var reference = steady.first
        for h in steady.dropFirst() {
            guard let ref = reference else { break }
            if Compass.difference(h.direction, ref.direction) >= 60 {
                if !swingTimes.contains(where: { abs($0.timeIntervalSince(h.time)) <= 5400 }) {
                    items.append(OutlookItem(
                        kind: .windShift, severity: .info, start: h.time, end: nil,
                        title: "Wind shifts \(Compass.name(ref.direction)) → \(Compass.name(h.direction))",
                        detail: "The boat swings to the new wind. Check the swing still clears everything."))
                }
                reference = h
            }
        }

        if let currentEvents {
            // Slack water, from the current predictions.
            for (i, e) in currentEvents.enumerated() where e.isSlack && e.time > now && e.time <= end {
                let next = currentEvents.dropFirst(i + 1).first { !$0.isSlack }
                let then = next.map { ", then the \($0.velocity >= 0 ? "flood" : "ebb"), up to \(String(format: "%.1f", abs($0.velocity))) kt toward the \(Compass.name($0.velocity >= 0 ? $0.floodToward : $0.ebbToward))" } ?? ""
                items.append(OutlookItem(kind: .slack, severity: .info, start: e.time, end: nil,
                                         title: "Slack water", detail: "The current turns\(then)."))
            }
        } else {
            // No current predictions: the highs and lows stand in for the turn. With little wind to hold it,
            // the boat will lie to the current and swing round when it turns.
            for t in tideTurns where t.time > now && t.time <= end {
                let wind = hourly.min { abs($0.time.timeIntervalSince(t.time)) < abs($1.time.timeIntervalSince(t.time)) }?.speed
                let light = wind.map { $0 < 6 } ?? false
                items.append(OutlookItem(
                    kind: .tideTurn, severity: light ? .caution : .info, start: t.time, end: nil,
                    title: t.isHigh ? "High water" : "Low water",
                    detail: light ? "Light wind at the turn of the tide: the boat will likely swing with the current and the anchor reset."
                                  : "Tidal current turns; the boat may swing and the anchor reset."))
            }
        }

        return items.sorted { $0.start < $1.start }
    }

    /// The smallest arc holding every bearing: where it starts and how wide it runs clockwise, in degrees.
    /// Nil when there are none; width 360 when they spread all the way round.
    static func arc(_ bearings: [Double]) -> (from: Double, width: Double)? {
        let sorted = bearings.map { ($0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }.sorted()
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return (first, 0) }
        // The arc is everything except the biggest empty gap between neighbouring bearings.
        var gap = 360 - sorted.last! + first, start = first
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > gap {
            gap = b - a
            start = b
        }
        return gap < 30 ? (0, 360) : (start, 360 - gap)
    }

    /// Farthest the stern can be from the anchor: the rode taut at the shallowest water, plus the boat's length.
    static func swingRadius(rodeOut: Double, shallowest depth: Double, bowHeight: Double, boatLength: Double) -> Double {
        let h = depth + bowHeight
        return (rodeOut > h ? (rodeOut * rodeOut - h * h).squareRoot() : 0) + boatLength
    }

    /// The first thing worth worrying about.
    static func nextRisk(_ items: [OutlookItem]) -> OutlookItem? {
        items.first { $0.severity >= .caution }
    }
}

