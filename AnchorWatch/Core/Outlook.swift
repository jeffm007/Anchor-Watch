import Foundation

/// One thing coming up at the anchorage in the next 24 hours.
struct OutlookItem: Equatable, Identifiable {
    enum Severity: Int, Comparable {
        case info, caution, danger
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    enum Kind: String { case shallow, scope, gusts, windShift, tideTurn }

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
}

/// The next 24 hours at this anchorage, from the tide and wind forecasts: when the water gets thin, when the scope
/// gets short, when forecast gusts beat what the setup holds, when the wind shifts and when the tide turns.
/// Predictive rather than descriptive: it says when things go wrong, not just what they are now.
enum Outlook {
    /// Scope below this at any time is flagged; below `veryShortScope` it's serious.
    static let shortScope = 4.0
    static let veryShortScope = 3.0

    /// The anchoring maths run for each forecast hour, with the depth at that hour (so high water's shorter
    /// scope lowers the limit). Current and waves are left at the Anchoring defaults.
    static func hourly(_ b: BoatProfile, scope s: ScopeSettings, bottom: AnchorConditions.Bottom, rodeOut: Double,
                       depths: [(time: Date, depth: Double)], forecast: [WindSample],
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
            let r = AnchorMath.assess(b, scope: scope, c)
            return HourlyHolding(time: sample.time, speed: sample.speed, gust: sample.gust, direction: sample.direction,
                                 depth: depth, safeGust: r.safeGust, status: r.status)
        }
    }

    static func items(_ b: BoatProfile, scope s: ScopeSettings, rodeOut: Double,
                      depths: [(time: Date, depth: Double)], hourly: [HourlyHolding], tideTurns: [TideEvent],
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

        // Wind shifts: each time the wind settles 60° or more from where it was, with enough wind to swing the boat.
        let steady = hourly.filter { $0.speed >= 8 }
        var reference = steady.first
        for h in steady.dropFirst() {
            guard let ref = reference else { break }
            if Compass.difference(h.direction, ref.direction) >= 60 {
                items.append(OutlookItem(
                    kind: .windShift, severity: .info, start: h.time, end: nil,
                    title: "Wind shifts \(Compass.name(ref.direction)) → \(Compass.name(h.direction))",
                    detail: "The boat swings to the new wind. Check the swing still clears everything."))
                reference = h
            }
        }

        // Highs and lows: the current turns and the anchor may have to reset.
        for t in tideTurns where t.time > now && t.time <= end {
            items.append(OutlookItem(
                kind: .tideTurn, severity: .info, start: t.time, end: nil,
                title: t.isHigh ? "High water" : "Low water",
                detail: "Tidal current turns; the boat may swing and the anchor reset."))
        }

        return items.sorted { $0.start < $1.start }
    }

    /// The first thing worth worrying about.
    static func nextRisk(_ items: [OutlookItem]) -> OutlookItem? {
        items.first { $0.severity >= .caution }
    }
}

