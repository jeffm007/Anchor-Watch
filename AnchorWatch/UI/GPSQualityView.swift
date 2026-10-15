import Charts
import CoreLocation
import SwiftUI

/// How steady the GPS is: recent positions scattered around their average, the ± figure over time, and the
/// live numbers. iOS gives apps no satellite data, so this is the closest an app can get to signal quality.
struct GPSQualityView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @State private var minutes = 15.0

    private var units: Units { engine.units }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let samples = engine.gpsLog.filter { context.date.timeIntervalSince($0.time) <= minutes * 60 }
            Form {
                live(samples, now: context.date)
                scatter(samples)
                history(samples, now: context.date)
                Section {
                    Button("Start over", role: .destructive) { engine.clearGPSLog() }
                } footer: {
                    Text("Start over after moving the receiver, to compare one spot with another.")
                }
            }
        }
        .navigationTitle("GPS Quality")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Live

    private func live(_ samples: [(time: Date, fix: Fix)], now: Date) -> some View {
        let points = samples.map(\.fix.coordinate)
        return Section("Now") {
            if let fix = engine.rawFix {
                LabeledContent("Source", value: engine.sourceKind == .simulator ? "Simulator" : fix.external ? "External (GLO)" : "iPhone")
                LabeledContent("Accuracy", value: "±\(units.format(fix.accuracy))")
                LabeledContent("Altitude accuracy", value: fix.altitudeAccuracy.map { "±\(units.format($0))" } ?? "--")
                LabeledContent("Fixes per second", value: String(format: "%.1f", engine.updateRate))
                LabeledContent("Last position", value: "\(max(0, Int(now.timeIntervalSince(fix.timestamp))))s ago")
                if let center = GPSQuality.center(points) {
                    LabeledContent("From the average", value: units.format(Geo.distance(fix.coordinate, center)))
                }
            } else {
                Text("Waiting for a GPS position…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Scatter

    private func scatter(_ samples: [(time: Date, fix: Fix)]) -> some View {
        let points = samples.map(\.fix.coordinate)
        let center = GPSQuality.center(points)
        let half = GPSQuality.spread(points, share: 0.5)
        let most = GPSQuality.spread(points, share: 0.95)
        let dots: [(id: Int, east: Double, north: Double, external: Bool, latest: Bool)] = center.map { c in
            samples.enumerated().map { i, s in
                let o = GPSQuality.offset(s.fix.coordinate, from: c)
                return (i, o.east * units.perMeter, o.north * units.perMeter, s.fix.external, i == samples.count - 1)
            }
        } ?? []
        // Square plot, centred on the average, wide enough for every dot and at least ±10 m.
        let reach = max(10 * units.perMeter, (dots.map { max(abs($0.east), abs($0.north)) }.max() ?? 0) * 1.15)

        return Section {
            Picker("Show", selection: $minutes) {
                Text("1 min").tag(1.0); Text("5 min").tag(5.0); Text("15 min").tag(15.0)
            }.pickerStyle(.segmented)
            if dots.isEmpty {
                Text("No positions yet.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(rings(half: half, most: most), id: \.name) { ring in
                        ForEach(ring.points, id: \.angle) { p in
                            LineMark(x: .value("East", p.x), y: .value("North", p.y), series: .value("Ring", ring.name))
                                .foregroundStyle(.secondary.opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                    }
                    ForEach(dots, id: \.id) { d in
                        PointMark(x: .value("East", d.east), y: .value("North", d.north))
                            .foregroundStyle(d.latest ? Color.red : d.external ? Color.blue : Color.green)
                            .symbolSize(d.latest ? 60 : 14)
                            .opacity(d.latest ? 1 : 0.6)
                    }
                }
                .chartXScale(domain: -reach...reach)
                .chartYScale(domain: -reach...reach)
                .chartXAxisLabel("\(units.symbol) east")
                .chartYAxisLabel("\(units.symbol) north")
                .aspectRatio(1, contentMode: .fit)
                .padding(.vertical, 4)
                LabeledContent("Positions", value: "\(dots.count)")
                if let half { LabeledContent("Half within", value: units.format(half)) }
                if let most { LabeledContent("95% within", value: units.format(most)) }
            }
        } header: { Text("Where the positions fall") } footer: {
            Text("Each dot is one position around their average: blue from the external receiver, green from the iPhone, red the latest. Dashed rings hold half and 95% of them. A receiver that isn't moving should make a tight cluster; a spread or a drifting trail means a poor signal.")
        }
    }

    private func rings(half: Double?, most: Double?) -> [(name: String, points: [(angle: Int, x: Double, y: Double)])] {
        [("Half", half), ("95%", most)].compactMap { name, radius in
            radius.map { r in
                let scaled = r * units.perMeter
                return (name, stride(from: 0, through: 360, by: 10).map { a in
                    (a, scaled * sin(Double(a).radians), scaled * cos(Double(a).radians))
                })
            }
        }
    }

    // MARK: Accuracy history

    private func history(_ samples: [(time: Date, fix: Fix)], now: Date) -> some View {
        Section {
            if samples.isEmpty {
                Text("No positions yet.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                        PointMark(x: .value("Minutes ago", -now.timeIntervalSince(s.time) / 60),
                                  y: .value("Accuracy", s.fix.accuracy * units.perMeter))
                            .foregroundStyle(s.fix.external ? Color.blue : Color.green)
                            .symbolSize(10)
                    }
                    RuleMark(y: .value("Good", engine.goodAccuracy * units.perMeter))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartXScale(domain: -minutes...0)
                .chartXAxisLabel("minutes ago")
                .chartYAxisLabel("± \(units.symbol)")
                .frame(height: 160)
                .padding(.vertical, 4)
            }
        } header: { Text("Accuracy over time") } footer: {
            Text("The ± figure iOS reports with each position. Below the orange line (±\(units.format(engine.goodAccuracy))) is good enough to set an anchor.")
        }
    }
}
