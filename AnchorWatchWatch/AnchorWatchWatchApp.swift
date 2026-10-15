import SwiftUI
import WatchConnectivity
import WatchKit

/// Anchor Watch on the wrist: the phone's status at a glance, a haptic alarm, and Silence.
@main
struct AnchorWatchWatchApp: App {
    @StateObject private var link = PhoneLink()
    /// `-chart` opens on the chart, for screenshots.
    @State private var page = ProcessInfo.processInfo.arguments.contains("-chart") ? 1 : 0

    var body: some Scene {
        WindowGroup {
            // Turn the crown or swipe up for the chart.
            TabView(selection: $page) {
                StatusView().tag(0)
                TrackView().tag(1)
            }
            .tabViewStyle(.verticalPage)
            .environmentObject(link)
        }
    }
}

/// What the phone last sent, and the line back to it.
@MainActor
final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var silenceResult: String?
    @Published private(set) var status: [String: Any] = [:]
    private var buzz: Timer?
    /// Red on black, to keep night vision. Follows the phone's night mode; the moon button sets it here.
    @Published var night = UserDefaults.standard.bool(forKey: "night") {
        didSet { UserDefaults.standard.set(night, forKey: "night") }
    }
    private var phoneNight: String?

    override init() {
        super.init()
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            status = ["state": "Holding", "tone": "green", "distance": "112 ft", "radius": "Alarm at 205 ft",
                      "detail": "Anchor lies NE", "wind": "Wind 14 kt SW, gusts 19", "updated": Date().timeIntervalSince1970]
        }
        if ProcessInfo.processInfo.arguments.contains("-demoAlarm") {
            status = ["state": "Dragging", "tone": "red", "distance": "231 ft", "radius": "Alarm at 205 ft",
                      "alarm": "Boat left the circle", "wind": "Wind 24 kt SW, gusts 31", "updated": Date().timeIntervalSince1970]
        }
        if !status.isEmpty {
            // A swing to the NE of the anchor, ending at the boat.
            let track = (0...60).map { i -> String in
                let a = (20 + Double(i) * 1.6) * .pi / 180, r = 34 + 2 * sin(Double(i) / 3)
                return "\(Int(r * sin(a))),\(Int(r * cos(a)))"
            }
            status["radiusM"] = "62"
            status["track"] = track.joined(separator: " ")
            status["boat"] = track.last
        }
        if ProcessInfo.processInfo.arguments.contains("-night") { night = true }
        if ProcessInfo.processInfo.arguments.contains("-day") { night = false }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var state: String { status["state"] as? String ?? "Waiting for iPhone" }
    var tone: String { status["tone"] as? String ?? "gray" }
    var distance: String { status["distance"] as? String ?? "--" }
    var radius: String { status["radius"] as? String ?? "" }
    var detail: String { status["detail"] as? String ?? "Open Anchor Watch on the iPhone." }
    var wind: String { status["wind"] as? String ?? "" }
    var alarm: String? { status["alarm"] as? String }
    var updated: Date? { (status["updated"] as? Double).map(Date.init(timeIntervalSince1970:)) }
    /// The chart, in metres east and north of the anchor.
    var radiusMetres: Double? { (status["radiusM"] as? String).flatMap(Double.init) }
    var boat: CGPoint? { (status["boat"] as? String).flatMap(Self.point) }
    var track: [CGPoint] { ((status["track"] as? String) ?? "").split(separator: " ").compactMap { Self.point(String($0)) } }

    private static func point(_ text: String) -> CGPoint? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }

    func silence() {
        guard WCSession.default.isReachable else { silenceResult = "iPhone unreachable — alarm not silenced"; return }
        silenceResult = "Waiting for iPhone…"
        WCSession.default.sendMessage(["silence": true], replyHandler: { reply in
            Task { @MainActor in self.silenceResult = reply["silenced"] as? Bool == true ? "iPhone acknowledged Silence" : "Silence not confirmed" }
        }, errorHandler: { _ in
            Task { @MainActor in self.silenceResult = "Could not reach iPhone — Silence not confirmed" }
        })
    }

    func isStale(at date: Date) -> Bool { updated.map { date.timeIntervalSince($0) > 120 } ?? true }

    private func receive(_ context: [String: Any]) {
        status = context
        // Follow the phone when it goes into or out of night mode, but don't undo the watch's own choice
        // on the first update after launch.
        if let n = context["night"] as? String, n != phoneNight {
            if phoneNight != nil || n == "1" { night = n == "1" }
            phoneNight = n
        }
        // While the alarm is up and this app is open, tap the wrist every couple of seconds.
        if alarm != nil && !isStale(at: Date()) {
            if buzz == nil {
                WKInterfaceDevice.current().play(.notification)
                buzz = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                    Task { @MainActor in
                        guard let self else { timer.invalidate(); return }
                        guard !self.isStale(at: Date()) else { timer.invalidate(); self.buzz = nil; return }
                        WKInterfaceDevice.current().play(.notification)
                    }
                }
            }
        } else {
            buzz?.invalidate()
            buzz = nil
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in if !context.isEmpty { self.receive(context) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.receive(context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.receive(message) }
    }
}

struct StatusView: View {
    @EnvironmentObject var link: PhoneLink

    private let red = Color(red: 0.85, green: 0.1, blue: 0.08)
    private var night: Bool { link.night }
    /// At night everything is red: bright for what matters, dim for the rest.
    private var primary: Color { night ? red : .primary }
    private var secondary: Color { night ? red.opacity(0.6) : .secondary }

    private var color: Color {
        if night { return red }
        return switch link.tone {
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        default: .gray
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            ScrollView {
                VStack(spacing: 6) {
                    Text((link.isStale(at: context.date) ? "Monitoring status stale" : link.state).uppercased()).font(.headline.weight(.heavy)).foregroundStyle(link.isStale(at: context.date) ? (night ? primary : .orange) : color)
                        .multilineTextAlignment(.center)
                    Text(link.isStale(at: context.date) ? "--" : link.distance).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1).foregroundStyle(primary)
                    if !link.radius.isEmpty { Text(link.radius).font(.footnote).foregroundStyle(secondary) }
                    if let alarm = link.alarm, !link.isStale(at: context.date) {
                        Text(alarm).font(.footnote.bold()).foregroundStyle(night ? primary : .red).multilineTextAlignment(.center)
                        Button("Silence") { link.silence() }
                            .tint(.red)
                    } else {
                        Text(link.isStale(at: context.date) ? "Open Anchor Watch on iPhone to check current monitoring." : link.detail).font(.footnote).foregroundStyle(secondary).multilineTextAlignment(.center)
                    }
                    if let result = link.silenceResult { Text(result).font(.footnote).multilineTextAlignment(.center) }
                    if !link.wind.isEmpty { Text(link.wind).font(.footnote).foregroundStyle(primary) }
                    if let updated = link.updated {
                        let age = Int(context.date.timeIntervalSince(updated))
                        Text(age < 60 ? "Updated just now" : "Updated \(age / 60) min ago")
                            .font(.caption2).foregroundStyle(age > 120 && !night ? .orange : secondary)
                    }
                    Button { link.night.toggle() } label: {
                        Image(systemName: night ? "sun.max.fill" : "moon.fill").foregroundStyle(secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityLabel(night ? "Day colours" : "Night mode")
                }
                .padding(.horizontal, 4)
            }
            .background((link.alarm != nil ? Color.red.opacity(night ? 0.18 : 0.25) : night ? Color.black : Color.clear).ignoresSafeArea())
        }
    }
}

/// The anchor in the middle, the alarm circle, the recent track and the boat, north up.
struct TrackView: View {
    @EnvironmentObject var link: PhoneLink

    private let red = Color(red: 0.85, green: 0.1, blue: 0.08)

    var body: some View {
        let night = link.night
        TimelineView(.periodic(from: .now, by: 5)) { context in
        VStack(spacing: 2) {
            if link.isStale(at: context.date) { Text("STALE — open iPhone app").font(.caption.bold()).foregroundStyle(night ? red : .orange) }
            if let radius = link.radiusMetres {
                Canvas { context, size in
                    let track = link.track
                    // Fit the circle, or the track if it has gone outside it.
                    let extent = max(radius, track.map { max(abs($0.x), abs($0.y)) }.max() ?? 0) * 1.08
                    let scale = (min(size.width, size.height) / 2 - 10) / extent
                    let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                    func at(_ p: CGPoint) -> CGPoint { CGPoint(x: mid.x + p.x * scale, y: mid.y - p.y * scale) }

                    let r = radius * scale
                    let circle = Path(ellipseIn: CGRect(x: mid.x - r, y: mid.y - r, width: 2 * r, height: 2 * r))
                    let alarm = link.alarm != nil
                    context.stroke(circle, with: .color(night ? red.opacity(0.7) : alarm ? .red : .green), lineWidth: 2)

                    if track.count > 1 {
                        var line = Path()
                        line.addLines(track.map(at))
                        context.stroke(line, with: .color(night ? red.opacity(0.5) : .purple),
                                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }

                    // The anchor: a ring with a cross.
                    var anchor = Path(ellipseIn: CGRect(x: mid.x - 5, y: mid.y - 5, width: 10, height: 10))
                    anchor.move(to: CGPoint(x: mid.x, y: mid.y - 9)); anchor.addLine(to: CGPoint(x: mid.x, y: mid.y + 9))
                    context.stroke(anchor, with: .color(night ? red : .white), lineWidth: 2)

                    if let boat = link.boat {
                        let b = at(boat)
                        let dot = Path(ellipseIn: CGRect(x: b.x - 6, y: b.y - 6, width: 12, height: 12))
                        context.fill(dot, with: .color(night ? red : alarm ? .red : .cyan))
                        context.stroke(dot, with: .color(night ? .black : .white), lineWidth: 1.5)
                    }

                    context.draw(Text("N").font(.caption2.bold()).foregroundStyle(night ? red.opacity(0.7) : .secondary),
                                 at: CGPoint(x: mid.x, y: mid.y - r - 7))
                }
                HStack {
                    Spacer().frame(width: 28)
                    Spacer()
                    Text(link.distance).font(.headline.monospacedDigit()).foregroundStyle(night ? red : .primary)
                    Spacer()
                    Button { link.night.toggle() } label: {
                        Image(systemName: night ? "sun.max.fill" : "moon.fill")
                            .foregroundStyle(night ? red.opacity(0.6) : .secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(night ? "Day colours" : "Night mode")
                }
                .padding(.horizontal, 10)
            } else {
                Text("No anchor set").foregroundStyle(night ? red.opacity(0.7) : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        }
        .padding(.top, 8)
        .background((link.alarm != nil ? Color.red.opacity(night ? 0.18 : 0.25) : night ? Color.black : Color.clear).ignoresSafeArea())
    }
}
