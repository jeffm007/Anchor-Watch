import Charts
import SwiftUI

/// Tide, depth, keel clearance and scope over the next 24 hours, then the depth, tide and scope settings.
/// Predictive: it says when the water gets thin and how the scope changes, not just what it is now.
struct WaterView: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    private var units: Units { engine.units }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let points = engine.waterForecast
                Form {
                    DepthEntrySection()
                    if points.isEmpty {
                        Section("Next 24 hours") {
                            Text(engine.tide == nil ? (engine.tideStatus.isEmpty ? "Waiting for tide predictions…" : engine.tideStatus) : engine.depthReferenceDetail)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        timeline(points, now: context.date)
                        outlook(points)
                    }
                    currentSection(now: context.date)
                    DepthSections()
                }
            }
            .task { await engine.refreshTide() }
            .navigationTitle("Water")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Timeline

    private func timeline(_ points: [(time: Date, depth: Double)], now: Date) -> some View {
        let draft = engine.boat.draft
        let clearanceLine = draft + AnchorMath.keelClearance
        let events = engine.tide.map { TideMath.upcoming($0.events, after: now, limit: 6) }?
            .filter { $0.time <= points.last!.time } ?? []
        let top = (points.map(\.depth).max() ?? 0) * units.perMeter * 1.15

        return Section {
            Chart {
                ForEach(points, id: \.time) { p in
                    AreaMark(x: .value("Time", p.time), y: .value("Depth", p.depth * units.perMeter))
                        .foregroundStyle(.linearGradient(colors: [.blue.opacity(0.45), .blue.opacity(0.08)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.time), y: .value("Depth", p.depth * units.perMeter))
                        .foregroundStyle(.blue)
                }
                if draft > 0 {
                    RuleMark(y: .value("Keel", draft * units.perMeter))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Keel \(units.formatTenths(draft))").font(.caption2).foregroundStyle(.red)
                        }
                    RuleMark(y: .value("Clearance", clearanceLine * units.perMeter))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                ForEach(events, id: \.time) { e in
                    let depth = engine.depth(at: e.time)
                    PointMark(x: .value("Time", e.time), y: .value("Depth", depth * units.perMeter))
                        .foregroundStyle(e.isHigh ? .cyan : .orange)
                        .annotation(position: e.isHigh ? .top : .bottom) {
                            VStack(spacing: 0) {
                                Text(e.isHigh ? "High" : "Low").font(.caption2.bold())
                                Text(e.time.formatted(date: .omitted, time: .shortened)).font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: 0...max(top, 1))
            .chartYAxisLabel("depth (\(units.symbol))")
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .frame(height: 220)
            .padding(.vertical, 6)
        } header: { Text("Depth at the anchorage, next 24 hours") } footer: {
            Text(engine.depthReferenceDetail + " From the depth you set and the \(engine.tide?.station.name ?? "nearest station") predictions. Red is your keel, orange dashed is \(units.format(AnchorMath.keelClearance)) under it.")
        }
    }

    // MARK: Outlook

    private func outlook(_ points: [(time: Date, depth: Double)]) -> some View {
        let draft = engine.boat.draft
        // The predicted highs and lows themselves, so the times match the chart rather than the nearest sample.
        let turns = (engine.tide.map { TideMath.upcoming($0.events, after: Date(), limit: 6) } ?? [])
            .filter { $0.time <= points.last!.time }
            .map { (time: $0.time, depth: engine.depth(at: $0.time)) }
        let candidates = points + turns
        let lowest = candidates.min { $0.depth < $1.depth }!
        let highest = candidates.max { $0.depth < $1.depth }!
        let rode = engine.rodeOut
        let bow = engine.scope.bowHeight
        let scopeAtHigh = rode / (highest.depth + bow)
        let scopeAtLow = rode / (lowest.depth + bow)
        let shallow = draft > 0 ? TideMath.shallowWindows(points, below: draft + AnchorMath.keelClearance) : []

        return Section {
            LabeledContent("Depth now", value: units.formatTenths(engine.liveDepth))
            LabeledContent("Lowest, \(time(lowest.time))") {
                Text("\(units.formatTenths(lowest.depth))" + (draft > 0 ? " · \(units.formatTenths(lowest.depth - draft)) under keel" : ""))
                    .foregroundStyle(color(underKeel: lowest.depth - draft))
            }
            LabeledContent("Highest, \(time(highest.time))", value: units.formatTenths(highest.depth))
            LabeledContent("Scope with \(units.format(rode)) out") {
                Text(String(format: "%.1f:1 at high · %.1f:1 at low", scopeAtHigh, scopeAtLow))
                    .foregroundStyle(scopeAtHigh < 3 ? .red : scopeAtHigh < 4 ? .orange : .secondary)
            }
            ForEach(Array(shallow.enumerated()), id: \.offset) { _, w in
                Label(w.least <= draft
                      ? "Aground from \(time(w.start)) to \(time(w.end)): as little as \(units.formatTenths(w.least)) of water for a \(units.formatTenths(draft)) draft."
                      : "Under \(units.format(AnchorMath.keelClearance)) below the keel from \(time(w.start)) to \(time(w.end)), least \(units.formatTenths(w.least - draft)).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(w.least <= draft ? .red : .orange)
            }
            if scopeAtHigh < 4 {
                Label(String(format: "Scope drops to %.1f:1 at high water around %@. Let out more rode before then.", scopeAtHigh, time(highest.time)),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(scopeAtHigh < 3 ? .red : .orange)
            }
            if shallow.isEmpty && scopeAtHigh >= 4 {
                Label("Enough water and scope through the next 24 hours.", systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(.green)
            }
        } header: { Text("Outlook") } footer: {
            Text("Swings and slack water are in Next 24 hours on the Watch tab.")
        }
    }

    // MARK: Current

    @ViewBuilder private func currentSection(now: Date) -> some View {
        Section {
            if let snapshot = engine.currents {
                let km = engine.fix.map { Geo.distance(snapshot.station.coordinate, $0.coordinate) / 1000 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.station.name).font(.subheadline.bold())
                    Text((km.map { String(format: "%.0f km away · ", $0) } ?? "") + "NOAA current predictions").font(.caption).foregroundStyle(.secondary)
                }
                if let flow = engine.currentHere(at: now) {
                    LabeledContent("Here now (estimated)",
                                   value: flow.speed < 0.1 ? "Slack" : String(format: "%.1f kt toward the %@ (%@)", flow.speed, Compass.name(flow.toward), flow.flooding ? "flood" : "ebb"))
                }
                ForEach((engine.scaledCurrentEvents ?? []).filter { $0.time > now }.prefix(4), id: \.time) { e in
                    LabeledContent(e.isSlack ? "Slack" : e.velocity >= 0 ? "Strongest flood" : "Strongest ebb") {
                        Text(time(e.time) + (e.isSlack ? "" : String(format: " · %.1f kt %@", abs(e.velocity),
                                                                      Compass.name(e.velocity >= 0 ? e.floodToward : e.ebbToward))))
                    }
                }
                Picker("Current here vs the station", selection: $engine.currentFactor) {
                    Text("100%").tag(1.0); Text("50%").tag(0.5); Text("25%").tag(0.25)
                }
            } else {
                Text("No NOAA current station within \(Int(CurrentService.maxDistance / 1000)) km. The outlook uses the highs and lows for when the current turns.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Current") } footer: {
            if engine.currents != nil {
                Text("Stations are mostly in channels, where the current runs harder than in a sheltered anchorage, so the speeds here are scaled. Use 100% if you're anchored in the channel itself.")
            }
        }
    }

    private func time(_ date: Date) -> String {
        let sameDay = Calendar.current.isDateInToday(date)
        return sameDay ? date.formatted(date: .omitted, time: .shortened)
                       : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func color(underKeel: Double) -> Color {
        guard engine.boat.draft > 0 else { return .secondary }
        return underKeel <= 0 ? .red : underKeel < AnchorMath.keelClearance ? .orange : .secondary
    }
}

/// Top of the Weather tab: wind and gusts for the next 24 hours against the gust this setup can hold at each
/// hour's depth, with the direction, then what the outlook says about the wind.
struct WindOutlookSections: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    var body: some View {
        let hours = engine.hourlyHolding
        if !hours.isEmpty {
            Section {
                Chart {
                    ForEach(hours, id: \.time) { h in
                        AreaMark(x: .value("Time", h.time), yStart: .value("Wind", h.speed), yEnd: .value("Gust", h.gust))
                            .foregroundStyle(.orange.opacity(0.25))
                        LineMark(x: .value("Time", h.time), y: .value("Knots", h.gust), series: .value("Series", "Gusts"))
                            .foregroundStyle(.orange)
                        LineMark(x: .value("Time", h.time), y: .value("Knots", h.speed), series: .value("Series", "Wind"))
                            .foregroundStyle(.blue)
                        if let safe = h.safeGust {
                            LineMark(x: .value("Time", h.time), y: .value("Knots", safe), series: .value("Series", "Limit"))
                                .foregroundStyle(.red)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        }
                    }
                    // Direction every three hours, pointing the way the wind blows.
                    ForEach(Array(hours.enumerated()).filter { $0.offset % 3 == 0 }.map(\.element), id: \.time) { h in
                        PointMark(x: .value("Time", h.time), y: .value("Knots", 0))
                            .opacity(0)
                            .annotation(position: .top) {
                                Image(systemName: "location.north.fill").font(.caption2)
                                    .rotationEffect(.degrees(h.direction + 180)).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartYAxisLabel("knots")
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 200)
                .padding(.vertical, 6)
            } header: { Text("Wind, next 24 hours") } footer: {
                Text("Blue is the wind, orange the gusts, red dashed the gust your setup holds at each hour's depth (\(engine.units.format(engine.rodeOut)) of rode in \(engine.anchorBottom.rawValue.lowercased())). Arrows show which way it blows.")
            }
        }
        let wind = engine.visibleOutlook.filter { $0.kind == .gusts || $0.kind == .windShift || $0.kind == .swing }
        Section("Wind outlook") {
            if wind.isEmpty {
                Label(hours.isEmpty ? "Waiting for the wind forecast…" : "No gusts beyond your setup and no big swings in the next 24 hours.",
                      systemImage: hours.isEmpty ? "clock" : "checkmark.circle")
                    .font(.subheadline).foregroundStyle(hours.isEmpty ? Color.secondary : Color.green)
            }
            ForEach(wind) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: OutlookList.icon(item.kind)).foregroundStyle(OutlookList.color(item.severity)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(OutlookList.span(item)).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(item.title).font(.subheadline.bold())
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The phone's barometer on the Weather tab: now, the last three hours' change, and six hours of history.
struct BarometerSection: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    var body: some View {
        let history = engine.pressureHistory.filter { Date().timeIntervalSince($0.time) <= 6 * 3600 }
        Section {
            if let latest = history.last {
                LabeledContent("Now", value: String(format: "%.1f hPa", latest.hPa))
                if let change = engine.pressureChange {
                    LabeledContent("Last 3 hours") {
                        Text(String(format: "%+.1f hPa", change))
                            .foregroundStyle(engine.pressureLevel == .fallingFast ? .red : engine.pressureLevel == .fallingQuickly ? .orange : .secondary)
                    }
                } else {
                    LabeledContent("Last 3 hours", value: "Building up history…")
                }
                if history.count > 2 {
                    let low = history.map(\.hPa).min()!, high = history.map(\.hPa).max()!
                    Chart(history, id: \.time) { r in
                        LineMark(x: .value("Time", r.time), y: .value("hPa", r.hPa)).foregroundStyle(.teal)
                    }
                    .chartYScale(domain: (low - 1)...(high + 1))
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 1)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                    .frame(height: 120)
                }
            } else {
                Text(Barometer.isAvailable ? "Waiting for the first reading…" : "This device has no barometer.")
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Barometer") } footer: {
            Text("The phone's own pressure sensor. A fall of \(Int(PressureTrend.quickFall)) hPa in 3 hours usually means wind is coming; \(Int(PressureTrend.rapidFall)) or more, a gale. You'll get a notification when it crosses either.")
        }
    }
}

