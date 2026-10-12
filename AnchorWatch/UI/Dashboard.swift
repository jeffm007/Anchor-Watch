import SwiftUI

/// The main screen's top half: boat name and status, then six tiles answering "am I OK?" at a glance.
struct DashboardHeader: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(engine.boat.name.uppercased()) — ANCHOR WATCH")
                    .font(.headline.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.7)
                subtitle
            }
            Spacer(minLength: 8)
            // The status doubles as the anchor switch: drop when not anchored, raise (or silence) when anchored.
            // Always confirmed, since raising also ends the alarm watch.
            Button { confirming = true } label: { statusPill }
                .buttonStyle(.plain)
                .accessibilityHint(engine.anchor == nil ? "Drop the anchor" : "Raise the anchor")
                .confirmationDialog(engine.anchor == nil ? "Drop the anchor here?" : "Anchor watch",
                                    isPresented: $confirming, titleVisibility: .visible) {
                    if engine.anchor == nil {
                        if engine.fix != nil && !engine.gpsIsUnusable {
                            Button(engine.gpsIsPoor ? "Drop Anchor Anyway" : "Drop Anchor Here") { engine.dropAnchor() }
                        }
                    } else {
                        if engine.alarm != nil {
                            Button("Silence Alarm") { engine.silence() }
                        }
                        Button("Raise Anchor", role: .destructive) { engine.raiseAnchor() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(dialogMessage)
                }
        }
    }

    private var dialogMessage: String {
        let units = engine.units
        if engine.anchor != nil {
            return "Raising ends the watch: the circle, track and alarm all stop."
        }
        guard let fix = engine.fix else { return "Waiting for a GPS position before the anchor can be dropped." }
        if engine.gpsIsUnusable { return "GPS accuracy is only ±\(units.format(fix.accuracy)), too poor to set an anchor. Wait, or move the phone near a window." }
        if engine.gpsIsPoor { return "GPS accuracy is only ±\(units.format(fix.accuracy)), so the anchor point may be off. Waiting a minute usually helps." }
        return "GPS ±\(units.format(fix.accuracy)). Pay out \(units.format(engine.rodeToPayOut)) of rode for your scope."
    }

    @ViewBuilder private var subtitle: some View {
        if engine.sourceKind == .simulator {
            Text("Simulated GPS · not your real position").font(.caption.bold()).foregroundStyle(.yellow)
        } else if let fix = engine.fix {
            let color: Color = engine.gpsIsUnusable ? .red : engine.gpsIsPoor ? .orange : .green
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(fix.external ? "External GPS" : "iPhone GPS") ±\(engine.units.format(fix.accuracy))")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Waiting for GPS…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusPill: some View {
        let (text, icon, color): (String, String, Color) = switch engine.watchState {
        case .notAnchored: ("Not anchored", "circle.dashed", .gray)
        case .alarm: ("Alarm", "exclamationmark.octagon.fill", .red)
        case .outside: ("Outside circle", "exclamationmark.octagon.fill", .red)
        case .dragging: ("Dragging", "exclamationmark.triangle.fill", .red)
        case .movingAway: ("Moving away", "exclamationmark.triangle.fill", .orange)
        case .holding:
            engine.holdingWarning != nil || engine.watchProblems.contains(where: { $0.state == .critical })
                ? ("Check", "exclamationmark.triangle", .orange) : ("Holding", "checkmark.circle", .green)
        }
        return HStack(spacing: 4) {
            Label(text, systemImage: icon)
            Image(systemName: "chevron.down").font(.caption2.bold()).opacity(0.7)
        }
            .font(.subheadline.bold())
            .foregroundStyle(color == .gray ? Color.secondary : Color.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(color == .gray ? 0.2 : 0.35), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.8), lineWidth: 1))
    }
}

struct DashboardTiles: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    let openConditions: () -> Void
    let openDepth: () -> Void
    let openAnchoring: () -> Void
    private var units: Units { engine.units }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    tap(wind, openConditions)
                    tap(depth, openDepth)
                    tap(scope, openAnchoring)
                }
                GridRow {
                    tap(anchor, openAnchoring)
                    tap(tide(now: context.date), openDepth)
                    distance
                }
            }
        }
    }

    private func tap(_ tile: some View, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { tile }.buttonStyle(.plain)
    }

    private var wind: some View {
        let now = engine.windNow
        return DashboardTile(title: "Wind", value: now.map { "\(Int($0.speed.rounded())) kt" } ?? "--",
                             detail: now.map { "From \(Compass.name($0.direction)) · gust \(Int($0.gust.rounded())) kt" } ?? "No forecast",
                             windFrom: now?.direction)
    }

    private var depth: some View {
        let trend = engine.nextTide.map { $0.isHigh ? "Rising" : "Falling" } ?? "As entered"
        return DashboardTile(title: "Depth", value: units.formatTenths(engine.liveDepth), detail: trend)
    }

    private var scope: some View {
        DashboardTile(title: "Scope", value: engine.liveScopeRatio.map { String(format: "%.1f:1", $0) } ?? "--",
                      detail: "\(units.format(engine.rodeOutEstimate)) rode")
    }

    private var anchor: some View {
        switch engine.watchState {
        case .notAnchored:
            return DashboardTile(title: "Anchor", value: "Not set", detail: "Drop it below")
        case .alarm(let reason):
            return DashboardTile(title: "Anchor", value: "ALARM", detail: reason.message, color: .red)
        case .outside(let distance):
            return DashboardTile(title: "Anchor", value: "Outside", detail: "\(units.format(distance - engine.radius)) past the circle", color: .red)
        case .dragging(let drift):
            return DashboardTile(title: "Anchor", value: "Dragging",
                                 detail: "\(units.format(drift.distance)) \(Compass.name(drift.bearing)) in \(Int(drift.minutes.rounded())) min", color: .red)
        case .movingAway(let rate):
            return DashboardTile(title: "Anchor", value: "Moving away",
                                 detail: "+\(units.format(rate)) per min", color: .orange)
        case .holding:
            return DashboardTile(title: "Anchor", value: "Secure", detail: swingDetail)
        }
    }

    /// What the swing fit says, since it's the only check on where the anchor really is.
    private var swingDetail: String {
        if let estimate = engine.anchorEstimate, let anchor = engine.anchor {
            let off = Geo.distance(anchor, estimate.center)
            return off <= estimate.semiMajor
                ? "Swing agrees with mark"
                : "Swing: \(units.format(off)) \(Compass.name(Geo.bearing(from: anchor, to: estimate.center))) of mark"
        }
        switch engine.estimatePending {
        case .collecting(let minutes): return "Finding by swing \(Int(minutes))/\(Int(AnchorEstimate.minMinutes)) min"
        case .tooUncertain: return "Need more swing to fix it"
        case nil:
            let toward = engine.fix.flatMap { fix in engine.anchor.map { Compass.name(Geo.bearing(from: fix.coordinate, to: $0)) } }
            return "No drag" + (toward.map { " · lies \($0)" } ?? "")
        }
    }

    private func tide(now: Date) -> some View {
        guard let next = engine.nextTide, let height = engine.tideNow else {
            return DashboardTile(title: "Tide", value: "--", detail: "No tide data")
        }
        let change = next.height - height
        let minutes = max(0, Int(next.time.timeIntervalSince(now) / 60))
        let when = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return DashboardTile(title: "Tide", value: "\(change >= 0 ? "+" : "−")\(units.formatTenths(abs(change)))",
                             detail: "\(next.isHigh ? "High" : "Low") in \(when)")
    }

    private var distance: some View {
        guard engine.anchor != nil else {
            return DashboardTile(title: "Distance", value: "--", detail: "Alarm \(units.format(engine.radius))")
        }
        let d = engine.distance ?? 0
        let color: Color = d > engine.radius ? .red : d > engine.radius * 0.8 ? .orange : .primary
        return DashboardTile(title: "Distance", value: engine.distance.map(units.format) ?? "--",
                             detail: "Max \(units.format(engine.maxDistance)) · alarm \(units.format(engine.radius))",
                             color: color)
    }
}

struct DashboardTile: View {
    let title: String
    let value: String
    let detail: String
    var color: Color = .primary
    /// Wind direction (degrees true, where it comes from): draws an arrow beside the value pointing the way it blows.
    var windFrom: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let windFrom {
                    Image(systemName: "location.north.fill")
                        .font(.subheadline)
                        .rotationEffect(.degrees(windFrom + 180))
                        .foregroundStyle(.secondary)
                }
                Text(value).font(.system(.title2, design: .rounded).bold()).monospacedDigit()
                    .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Everything worth knowing that isn't an alarm: forecast trouble, weather alerts, watch problems.
struct NoticesCard: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    let openAnchoring: () -> Void
    let openConditions: () -> Void
    let openAlerts: () -> Void
    let openWatchCheck: () -> Void
    /// Notices hidden with a tap, and when. Each comes back after `hideFor` if it still applies.
    @State private var hidden: [String: Date] = [:]
    private let hideFor: TimeInterval = 3600

    private struct Notice: Identifiable {
        let id: String
        let icon: String
        let color: Color
        let title: String
        let detail: String
        let action: () -> Void
    }

    private var notices: [Notice] {
        var list: [Notice] = []
        if engine.armed {
            for problem in engine.watchProblems.sorted(by: { $0.state == .critical && $1.state != .critical }) {
                list.append(Notice(id: "check-\(problem.title)", icon: "exclamationmark.octagon",
                                   color: problem.state == .critical ? .red : .orange,
                                   title: problem.title, detail: "The watch check has the details", action: openWatchCheck))
            }
        }
        for alert in engine.nwsAlerts {
            list.append(Notice(id: "nws-\(alert.id)", icon: "exclamationmark.triangle", color: alert.severity.color,
                               title: alert.event,
                               detail: alert.ends.map { "Until \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" } ?? "Weather alert",
                               action: openAlerts))
        }
        if let hit = engine.observedGustAlert {
            list.append(Notice(id: "observed-\(Int(hit.gust / 5))", icon: "wind", color: .orange,
                               title: "Observed gusts \(Int(hit.gust.rounded())) kt",
                               detail: "At \(StationName.short(hit.station.name))", action: openConditions))
        }
        return list
    }

    var body: some View {
        let all = notices
        let now = Date()
        let shown = all.filter { n in hidden[n.id].map { now.timeIntervalSince($0) >= hideFor } ?? true }
        let hiddenCount = all.count - shown.count
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(shown.prefix(2)) { n in
                    HStack(alignment: .top, spacing: 10) {
                        // Tapping the notice hides it; the chevron opens the screen it's about.
                        Button { withAnimation { hidden[n.id] = Date() } } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: n.icon).foregroundStyle(n.color).font(.title3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.title).font(.subheadline.bold()).foregroundStyle(.primary)
                                    Text(n.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Hides this notice for an hour")
                        Button(action: n.action) {
                            Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open details")
                    }
                }
                HStack {
                    if shown.count > 2 {
                        Text("+\(shown.count - 2) more").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hiddenCount > 0 {
                        Button("Show \(hiddenCount) hidden") { withAnimation { hidden = [:] } }
                            .font(.caption2.bold())
                    }
                }
                .padding(.leading, 32)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// The most important line on the dashboard after the status: what's the next thing to go wrong in the next 24 hours,
/// and how long until it does. Tap for the whole outlook.
struct OutlookBanner: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    // `-showOutlook` opens the full list at launch, for screenshots.
    @State private var showAll = ProcessInfo.processInfo.arguments.contains("-showOutlook")

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Button { showAll = true } label: { content(now: context.date) }
                .buttonStyle(.plain)
        }
        .sheet(isPresented: $showAll) { OutlookList() }
    }

    private func content(now: Date) -> some View {
        let (icon, color, title, detail): (String, Color, String, String) = {
            if engine.outlook.isEmpty && engine.tide == nil && engine.windHere == nil {
                return ("clock", .secondary, "Next 24 hours", "Waiting for the tide and wind forecasts…")
            }
            guard let risk = engine.nextRisk else {
                let next = engine.outlook.first { $0.start > now }
                return ("checkmark.circle.fill", .green, "Clear for the next 24 hours",
                        next.map { "Next: \($0.title.lowercased()) at \($0.start.formatted(date: .omitted, time: .shortened))" }
                            ?? "Nothing in the tide or wind forecast to worry about.")
            }
            return (risk.severity == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                    risk.severity == .danger ? .red : .orange,
                    "\(countdown(to: risk.start, now: now)) · \(risk.title)", OutlookList.span(risk))
        }()
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(color.opacity(color == .secondary ? 0.07 : 0.15), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(color == .secondary ? 0 : 0.5), lineWidth: 1))
    }

    /// "Now", "In 45m", "In 3h 20m".
    private func countdown(to date: Date, now: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "Now" }
        return minutes >= 60 ? "In \(minutes / 60)h \(minutes % 60)m" : "In \(minutes)m"
    }
}

/// Everything coming up in the next 24 hours, in time order.
struct OutlookList: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if engine.outlook.isEmpty {
                    Text("Nothing yet: the outlook needs the tide or wind forecast.").foregroundStyle(.secondary)
                }
                ForEach(engine.outlook) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: Self.icon(item.kind)).foregroundStyle(Self.color(item.severity)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.span(item)).font(.caption.bold()).foregroundStyle(.secondary)
                            Text(item.title).font(.subheadline.bold())
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text("Worked out from the tide predictions, the wind forecast and your boat, rode (\(engine.units.format(engine.rodeOutEstimate)) assumed out) and bottom. The safe gust limit is recalculated for each hour's depth. Forecasts can be wrong; keep a lookout.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Next 24 hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }

    /// "2:10 AM – 4:30 AM", or one time.
    static func span(_ item: OutlookItem) -> String {
        let start = time(item.start)
        guard let end = item.end, end > item.start else { return start }
        return "\(start) – \(time(end))"
    }

    private static func time(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened)
                                          : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func icon(_ kind: OutlookItem.Kind) -> String {
        switch kind {
        case .shallow: "arrow.down.to.line"
        case .scope: "ruler"
        case .gusts: "wind"
        case .swing: "arrow.triangle.2.circlepath"
        case .windShift: "arrow.triangle.turn.up.right.circle"
        case .tideTurn: "water.waves"
        case .slack: "arrow.left.arrow.right"
        }
    }

    static func color(_ severity: OutlookItem.Severity) -> Color {
        switch severity {
        case .info: .blue
        case .caution: .orange
        case .danger: .red
        }
    }
}

