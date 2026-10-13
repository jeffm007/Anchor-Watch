import SwiftUI
import WatchConnectivity
import WatchKit

/// Anchor Watch on the wrist: the phone's status at a glance, a haptic alarm, and Silence.
@main
struct AnchorWatchWatchApp: App {
    @StateObject private var link = PhoneLink()

    var body: some Scene {
        WindowGroup {
            StatusView().environmentObject(link)
        }
    }
}

/// What the phone last sent, and the line back to it.
@MainActor
final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var status: [String: Any] = [:]
    private var buzz: Timer?

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

    func silence() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["silence": true], replyHandler: nil)
    }

    private func receive(_ context: [String: Any]) {
        status = context
        // While the alarm is up and this app is open, tap the wrist every couple of seconds.
        if alarm != nil {
            if buzz == nil {
                WKInterfaceDevice.current().play(.notification)
                buzz = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    WKInterfaceDevice.current().play(.notification)
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

    private var color: Color {
        switch link.tone {
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
                    Text(link.state.uppercased()).font(.headline.weight(.heavy)).foregroundStyle(color)
                        .multilineTextAlignment(.center)
                    Text(link.distance).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1)
                    if !link.radius.isEmpty { Text(link.radius).font(.footnote).foregroundStyle(.secondary) }
                    if let alarm = link.alarm {
                        Text(alarm).font(.footnote.bold()).foregroundStyle(.red).multilineTextAlignment(.center)
                        Button("Silence") { link.silence() }
                            .tint(.red)
                    } else {
                        Text(link.detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if !link.wind.isEmpty { Text(link.wind).font(.footnote) }
                    if let updated = link.updated {
                        let age = Int(context.date.timeIntervalSince(updated))
                        Text(age < 60 ? "Updated just now" : "Updated \(age / 60) min ago")
                            .font(.caption2).foregroundStyle(age > 120 ? .orange : .secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .background((link.alarm != nil ? Color.red.opacity(0.25) : Color.clear).ignoresSafeArea())
        }
    }
}
