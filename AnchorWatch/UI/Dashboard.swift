import CoreLocation
import SwiftUI

/// The main screen's top half: boat name and status, then six tiles answering "am I OK?" at a glance.
struct DashboardHeader: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @State private var confirming = false
    // `-showDrop` opens the drop sheet at launch, for screenshots.
    @State private var dropping = ProcessInfo.processInfo.arguments.contains("-showDrop")

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
            Button { if engine.anchor == nil { dropping = true } else { confirming = true } } label: { statusPill }
                .buttonStyle(.plain)
                .accessibilityHint(engine.anchor == nil ? "Drop the anchor" : "Raise the anchor")
                .confirmationDialog("Anchor watch", isPresented: $confirming, titleVisibility: .visible) {
                    if engine.alarm != nil {
                        Button("Silence Alarm") { engine.silence() }
                    }
                    Button("Retrieve Anchor") { engine.startRetrieval() }
                    Button("Raise Anchor", role: .destructive) { engine.raiseAnchor() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Raising ends the watch: the circle, track and alarm all stop. Retrieve ends it too, and then shows the way from the bow to the anchor.")
                }
                .sheet(isPresented: $dropping) { DropAnchorSheet() }
        }
    }

    @ViewBuilder private var subtitle: some View {
        if engine.sourceKind == .simulator {
            Text("Simulated GPS · not your real position").font(.caption.bold()).foregroundStyle(.yellow)
        } else if let fix = engine.rawFix {
            let color: Color = engine.gpsIsUnusable ? .red : engine.gpsIsPoor ? .orange : .green
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(fix.external ? "External GPS" : "iPhone GPS") ±\(engine.units.format(fix.accuracy)) · \(engine.gpsFreshnessText)")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Waiting for GPS…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusPill: some View {
        let (text, icon, color): (String, String, Color) = switch engine.watchState {
        case .notAnchored: ("Not anchored", "circle.dashed", .gray)
        case .acquiringGPS: ("Acquiring GPS", "location", .orange)
        case .gpsInterrupted: ("Monitoring interrupted", "location.slash", .red)
        case .retrieving: ("Retrieving", "arrow.up", .purple)
        case .awaitingFix: ("Finding anchor", "scope", .purple)
        case .alarm: ("Alarm", "exclamationmark.octagon.fill", .red)
        case .outside: ("Outside circle", "exclamationmark.octagon.fill", .red)
        case .dragging: ("Dragging", "exclamationmark.triangle.fill", .red)
        case .movingAway: ("Moving away", "exclamationmark.triangle.fill", .orange)
        case .holding:
            engine.holdingWarning != nil || engine.pressureLevel == .fallingFast
                || engine.watchProblems.contains(where: { $0.state == .critical })
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
                    // With hazards marked, the Tide tile gives way to Clearance (the tide is in Depth at High Tide).
                    if engine.anchor != nil && !engine.hazards.isEmpty { clearance } else { tap(tide(now: context.date), openDepth) }
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
        let high = engine.depthAtNextHigh
        let when = high.time.map { " · High \($0.formatted(date: .omitted, time: .shortened))" } ?? " + tide rise"
        return DashboardTile(title: "Depth at High Tide", value: units.formatTenths(high.depth),
                             detail: "Now \(units.formatTenths(engine.liveDepth))" + when)
    }

    private var scope: some View {
        DashboardTile(title: "Scope", value: engine.liveScopeRatio.map { String(format: "%.1f:1", $0) } ?? "--",
                      detail: "\(units.format(engine.rodeOut)) \(engine.rodeOutSet == nil ? "suggested" : "out")")
    }

    private var anchor: some View {
        switch engine.watchState {
        case .acquiringGPS, .gpsInterrupted:
            return DashboardTile(title: "GPS", value: "Unavailable", detail: engine.gpsFreshnessText, color: .orange)
        case .retrieving:
            return DashboardTile(title: "Anchor", value: "Retrieving", detail: "Circle watch ended")
        case .notAnchored:
            return DashboardTile(title: "Anchor", value: "Not set", detail: "Drop it below")
        case .awaitingFix:
            let progress: String = if case .collecting(let m) = engine.estimatePending {
                " \(Int(m))/\(Int(AnchorEstimate.minMinutes)) min"
            } else { "" }
            return DashboardTile(title: "Anchor", value: "Not armed", detail: "Waiting for the swing fit" + progress, color: .purple)
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

    /// Gap from the stern at full swing to the nearest marked hazard.
    private var clearance: some View {
        guard let nearest = engine.nearestHazard, let anchor = engine.anchor else {
            return DashboardTile(title: "Clearance", value: "--", detail: "No hazards marked")
        }
        let gap = nearest.clearance
        let toward = Compass.name(Geo.bearing(from: anchor, to: nearest.hazard.coordinate))
        let color: Color = gap <= 0 ? .red : gap < Outlook.hazardMargin * 3 ? .orange : .primary
        return DashboardTile(title: "Clearance", value: gap <= 0 ? "Overlap" : units.format(gap),
                             detail: "\(nearest.hazard.label) · \(toward)", color: color)
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
        if let visit = engine.previousVisit {
            let units = engine.units
            list.append(Notice(id: "visit-\(visit.id)", icon: "clock.arrow.circlepath", color: .blue,
                               title: "Anchored here before",
                               detail: "\(visit.dropped.formatted(.dateTime.day().month(.abbreviated).year())) · \(units.format(visit.rodeOut)) out in \(visit.bottom.lowercased()) · \(visit.held.rawValue.lowercased()). › uses that rode and bottom.",
                               action: { engine.applyPreviousVisit() }))
        }
        if engine.pressureLevel > .steady, let change = engine.pressureChange {
            let fast = engine.pressureLevel == .fallingFast
            list.append(Notice(id: "pressure-\(engine.pressureLevel.rawValue)", icon: "barometer", color: fast ? .red : .orange,
                               title: fast ? "Barometer falling very fast" : "Barometer falling quickly",
                               detail: String(format: "%.1f hPa in 3 hours: ", change) + (fast ? "gale risk." : "wind likely."),
                               action: openConditions))
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
            guard let risk = engine.nextRisk else {
                return ("info.circle", engine.environmentCoverage.complete ? .green : .orange,
                        engine.outlookSummaryTitle,
                        engine.environmentCoverage.summary)
            }
            return (risk.severity == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                    risk.severity == .danger ? .red : .orange,
                    "\(countdown(to: risk.start, now: now)) · \(risk.title)", OutlookList.span(risk) + " · " + engine.environmentCoverage.summary)
        }()
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Section("Data confidence") {
                    Text(engine.environmentCoverage.summary)
                    ForEach(engine.environmentDetails, id: \.self) { Text($0).font(.caption) }
                    Text(engine.adviceAssumptions).font(.caption).foregroundStyle(.secondary)
                    Button("Retry environmental data") { engine.retryEnvironment() }
                }
                if engine.outlook.isEmpty {
                    Text("No issues found in the available inputs. Check coverage above; missing inputs are not an all clear.").foregroundStyle(.secondary)
                } else if engine.visibleOutlook.isEmpty {
                    Text("No visible warnings. Hidden warnings still apply; check data coverage above.").foregroundStyle(.secondary)
                }
                ForEach(engine.visibleOutlook) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: Self.icon(item.kind)).foregroundStyle(Self.color(item.severity)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(Self.span(item)).font(.caption.bold()).foregroundStyle(.secondary)
                                if engine.isLocked(item) {
                                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                        .accessibilityLabel("Locked")
                                }
                            }
                            Text(item.title).font(.subheadline.bold())
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if engine.isLocked(item) {
                            Button { engine.unlockOutlook(item) } label: { Label("Unlock", systemImage: "lock.open") }
                                .tint(.gray)
                        } else {
                            Button(role: .destructive) { withAnimation { engine.hideOutlook(item) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { engine.lockOutlook(item) } label: { Label("Lock", systemImage: "lock") }
                                .tint(.blue)
                        }
                    }
                }
                if engine.hiddenOutlookCount > 0 {
                    Button("Show \(engine.hiddenOutlookCount) hidden") { withAnimation { engine.showHiddenOutlook() } }
                }
                Section {
                    Text("Swipe left to delete a warning (it comes back only if it gets worse) or lock it so it can't be deleted. Worked out from the tide predictions, the wind forecast and your boat, rode (\(engine.units.format(engine.rodeOut)) assumed out) and bottom. The safe gust limit is recalculated for each hour's depth. Forecasts can be wrong; keep a lookout.")
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
        case .hazard: "exclamationmark.triangle"
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

/// The first swing fit moved the anchor mark: say so, with Undo.
struct AnchorCorrectionBanner: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    var body: some View {
        if let c = engine.anchorCorrection {
            HStack(spacing: 10) {
                Image(systemName: "scope").font(.title3).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Anchor mark corrected from the swing").font(.subheadline.bold())
                    Text("Moved \(engine.units.format(c.meters)) \(Compass.name(c.bearing)) to where the boat swings around.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Undo") { engine.undoAnchorCorrection() }.font(.caption.bold())
                Button { engine.dismissAnchorCorrection() } label: { Image(systemName: "xmark").font(.caption.bold()) }
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.5), lineWidth: 1))
        }
    }
}

/// Dropping the anchor: when it went down decides where it's marked. White on dark grey so it reads easily
/// on deck and at night, where the system action sheet's small grey text doesn't.
struct DropAnchorSheet: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss

    private var units: Units { engine.units }
    private var calm: Bool { (engine.windNow?.speed ?? 0) < AnchorPlacement.minWindKnots }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Drop the anchor").font(.title2.bold())
            if let problem = gpsProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.body).foregroundStyle(engine.gpsIsUnusable || engine.fix == nil ? .red : .orange)
            }
            if engine.fix != nil && !engine.gpsIsUnusable {
                choice("Anchor going down now", detail: "Marked just ahead of the bow, \(units.format(ScopeCalculator.gpsFromBow(engine.scope))) from the phone.",
                       icon: "arrow.down.to.line", moment: .goingDown)
                choice("Boat has settled on the rode",
                       detail: "Marked \(units.format(engine.settledOffset)) upwind: a full scope distance with \(units.format(engine.rodeOut)) out.",
                       icon: "arrow.uturn.backward", moment: .settled)
                if calm {
                    Label("Too little wind to tell which way is upwind. If you choose settled, the circle alarm waits for the swing fit (about 20 minutes) before arming.",
                          systemImage: "wind")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Button { dismiss() } label: {
                Text("Cancel").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(white: 0.17))
        .preferredColorScheme(.dark)
        // Full GPS accuracy while choosing, so the drop gets a precise position.
        .onAppear { engine.preparingDrop = true }
        .onDisappear { engine.preparingDrop = false }
    }

    private var gpsProblem: String? {
        guard let fix = engine.rawFix else { return "Waiting for a GPS position before the anchor can be dropped." }
        if !engine.hasFreshPosition { return engine.gpsFreshnessText + ". Wait for a fresh position before dropping." }
        if engine.gpsIsUnusable { return "GPS accuracy is only ±\(units.format(fix.accuracy)), too poor to set an anchor. Wait, or move the phone near a window." }
        if engine.gpsIsPoor { return "GPS accuracy is only ±\(units.format(fix.accuracy)), so the anchor point may be off. Waiting a minute usually helps." }
        return nil
    }

    private func choice(_ title: String, detail: String, icon: String, moment: AnchorWatchEngine.DropMoment) -> some View {
        Button {
            engine.dropAnchor(moment)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).opacity(0.9).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(Color.blue.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}


/// Marking a hazard where the chart was long-pressed: what it is, how far to keep off, and a name.
struct HazardSheet: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss
    let coordinate: CLLocationCoordinate2D
    /// The hazard being edited; nil when marking a new one.
    let existing: Hazard?
    @State private var kind: Hazard.Kind
    @State private var radius: Double
    @State private var name: String

    init(coordinate: CLLocationCoordinate2D, existing: Hazard? = nil) {
        self.coordinate = coordinate
        self.existing = existing
        _kind = State(initialValue: existing?.kind ?? .rock)
        _radius = State(initialValue: existing?.radius ?? Hazard.Kind.rock.defaultRadius)
        _name = State(initialValue: existing?.name ?? "")
    }

    private var units: Units { engine.units }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Mark a hazard" : "Edit hazard").font(.title2.bold())
            Picker("Kind", selection: $kind) {
                ForEach(Hazard.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: kind) { _, k in radius = k.defaultRadius }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Keep off by", value: units.format(radius))
                Slider(value: $radius, in: 2...80, step: 1)
                Text(kind == .boat ? "Another boat swings on its own rode: allow for its swing." : "How far around the mark to stay clear.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
            if let anchor = engine.anchor {
                let gap = Clearance.clearance(anchor: anchor, sternReach: engine.sternReach,
                                              hazard: Hazard(kind: kind, at: coordinate, radius: radius))
                Label(gap <= 0 ? "Your swing reaches it." : "Your stern's swing clears it by \(units.format(gap)).",
                      systemImage: gap <= 0 ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .foregroundStyle(gap <= 0 ? .red : gap < Outlook.hazardMargin * 3 ? .orange : .green)
            }
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Text("Cancel").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                Button {
                    if var hazard = existing {
                        hazard.kind = kind
                        hazard.radius = radius
                        hazard.name = name
                        engine.updateHazard(hazard)
                    } else {
                        engine.addHazard(Hazard(kind: kind, at: coordinate, radius: radius, name: name))
                    }
                    dismiss()
                } label: {
                    Text(existing == nil ? "Mark it" : "Save").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .background(Color.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            if let existing {
                Button(role: .destructive) {
                    engine.removeHazard(existing.id)
                    dismiss()
                } label: {
                    Text("Remove this hazard").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .foregroundStyle(.white)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(white: 0.17))
        .preferredColorScheme(.dark)
    }
}

/// Night watch: black and dim red, just what matters from the berth, so it doesn't spoil night vision.
struct NightModeView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showExit = false
    @State private var savedBrightness: CGFloat?

    private let red = Color(red: 0.85, green: 0.1, blue: 0.08)
    private var units: Units { engine.units }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(status.uppercased()).font(.title2.weight(.heavy)).tracking(2)
                    VStack(spacing: 0) {
                        Text(engine.distance.map(units.format) ?? "--")
                            .font(.system(size: 76, weight: .bold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.5).lineLimit(1)
                        Text("from the anchor · alarm at \(units.format(engine.radius))").font(.subheadline)
                    }
                    NightRadar(red: red).frame(maxWidth: 320, maxHeight: 320).aspectRatio(1, contentMode: .fit)
                    HStack(spacing: 16) {
                        if let w = engine.windNow { Text("\(Int(w.speed.rounded())) kt \(Compass.name(w.direction))") }
                        if let next = engine.nextTide { Text("\(next.isHigh ? "High" : "Low") \(next.time.formatted(date: .omitted, time: .shortened))") }
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                        if let fix = engine.fix { Text("±\(units.format(fix.accuracy))") }
                    }
                    .font(.footnote.monospacedDigit())
                    if let alarm = engine.alarm {
                        Text(alarm.message).font(.headline).multilineTextAlignment(.center)
                        Button { engine.silence() } label: {
                            Text("SILENCE").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 16)
                        }
                        .foregroundStyle(.black)
                        .background(red, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if showExit {
                        Button { dismiss() } label: {
                            Text("Exit night mode").font(.headline).padding(.horizontal, 24).padding(.vertical, 10)
                        }
                        .overlay(Capsule().stroke(red, lineWidth: 1))
                    }
                }
                .foregroundStyle(red)
                .padding(20)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation { showExit = true }
                Task { try? await Task.sleep(for: .seconds(5)); withAnimation { showExit = false } }
            }
        }
        .statusBarHidden()
        .onAppear {
            engine.nightMode = true
            // Dim the screen right down, and put it back afterwards.
            if let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen {
                savedBrightness = screen.brightness
                screen.brightness = 0.05
            }
        }
        .onDisappear {
            engine.nightMode = false
            if let savedBrightness, let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen {
                screen.brightness = savedBrightness
            }
        }
    }

    private var status: String {
        switch engine.watchState {
        case .notAnchored: "Not anchored"
        case .acquiringGPS: "Acquiring GPS"
        case .gpsInterrupted: "Monitoring interrupted"
        case .retrieving: "Retrieving"
        case .awaitingFix: "Finding anchor"
        case .alarm: "Alarm"
        case .outside: "Outside circle"
        case .dragging: "Dragging"
        case .movingAway: "Moving away"
        case .holding: "Holding"
        }
    }
}

/// North-up sketch of the anchorage in red: alarm and swing circles, the anchor, the boat and the last half hour.
struct NightRadar: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    let red: Color

    var body: some View {
        Canvas { ctx, size in
            guard let anchor = engine.anchor else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = (min(size.width, size.height) / 2 - 6) / max(engine.radius, engine.swingRadius, 1)
            func p(_ coord: CLLocationCoordinate2D) -> CGPoint {
                let o = GPSQuality.offset(coord, from: anchor)
                return CGPoint(x: c.x + o.east * scale, y: c.y - o.north * scale)
            }
            func ring(_ r: Double) -> Path { Path(ellipseIn: CGRect(x: c.x - r * scale, y: c.y - r * scale, width: 2 * r * scale, height: 2 * r * scale)) }
            ctx.stroke(ring(engine.radius), with: .color(red), lineWidth: 2)
            ctx.stroke(ring(engine.swingRadius), with: .color(red.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            let recent = engine.track.filter { Date().timeIntervalSince($0.timestamp) * max(engine.simTimeScale, 1) <= 1800 }
            if recent.count > 1 {
                var trail = Path()
                trail.addLines(recent.map { p($0.coordinate) })
                ctx.stroke(trail, with: .color(red.opacity(0.6)), lineWidth: 1.5)
            }
            ctx.draw(Text(anchorGlyph).font(.title3).foregroundStyle(red), at: c)
            if let fix = engine.fix {
                let b = p(fix.coordinate)
                ctx.fill(Path(ellipseIn: CGRect(x: b.x - 6, y: b.y - 6, width: 12, height: 12)), with: .color(red))
            }
            ctx.draw(Text("N").font(.caption.bold()).foregroundStyle(red.opacity(0.7)), at: CGPoint(x: c.x, y: 8))
        }
    }
}

/// While raising: a big arrow from the bow to the anchor, the distance, and which way to steer.
struct RetrieveView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss

    private var units: Units { engine.units }

    var body: some View {
        VStack(spacing: 18) {
            Text("RETRIEVING THE ANCHOR").font(.headline.weight(.heavy)).tracking(2).foregroundStyle(.secondary)
                .padding(.top, 24)
            Spacer()
            if let guide = engine.retrievalGuide {
                let color: Color = guide.overAnchor ? .green : .white
                Group {
                    if guide.overAnchor {
                        Image(systemName: "arrow.down.to.line")
                    } else {
                        Image(systemName: "arrow.up")
                            .rotationEffect(.degrees(guide.relative ?? guide.bearing))
                            .animation(.easeOut(duration: 0.5), value: guide.relative ?? guide.bearing)
                    }
                }
                .font(.system(size: 150, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 240, height: 240)
                .background(Circle().stroke(Color.white.opacity(0.15), lineWidth: 2))
                .overlay(alignment: .top) {
                    // North-up when the boat isn't moving fast enough to know its course.
                    if guide.relative == nil && !guide.overAnchor {
                        Text("N").font(.caption.bold()).foregroundStyle(.secondary).offset(y: -22)
                    }
                }
                Text(units.format(guide.distance))
                    .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color)
                Text("bow to anchor" + (engine.fix.map { " · GPS ±\(units.format($0.accuracy))" } ?? ""))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(guide.steer).font(.title2.bold()).foregroundStyle(color).multilineTextAlignment(.center)
                Text(guide.overAnchor ? "Break it out and bring it up."
                     : guide.relative == nil ? "North up. Get under way slowly for a steering arrow."
                     : "Arrow relative to your course over the ground.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView()
                Text("Waiting for GPS").foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                engine.endRetrieval()
                dismiss()
            } label: {
                Text("Anchor's up").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .buttonStyle(.plain)
            .background(Color.green.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
