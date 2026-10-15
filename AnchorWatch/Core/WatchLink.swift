import CoreLocation
import Foundation
import WatchConnectivity

/// Keeps the Apple Watch app up to date with the anchor watch, and takes Silence from it.
/// Sends when the status changes or every 30 seconds, and at once when an alarm starts.
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    var onSilence: (() -> Void)?
    private var lastSent: [String: String] = [:]
    private var lastSentAt = Date.distantPast
    private var alarmWasUp = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// `status` is the text the watch shows; nothing is sent unless a watch app is installed.
    func publish(_ status: [String: String]) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let alarmUp = status["alarm"] != nil
        // The chart changes with every fix: send it at most every 10 seconds unless something else changed.
        let chartKeys: Set<String> = ["track", "boat"]
        let changed = status.filter { !chartKeys.contains($0.key) } != lastSent.filter { !chartKeys.contains($0.key) }
        let chartChanged = status != lastSent
        let age = Date().timeIntervalSince(lastSentAt)
        guard changed || age >= 30 || (chartChanged && age >= 10) || alarmUp != alarmWasUp else { return }
        var context: [String: Any] = status
        context["updated"] = Date().timeIntervalSince1970
        try? session.updateApplicationContext(context)
        // An alarm that's just started goes straight through if the watch app is open.
        if alarmUp && !alarmWasUp && session.isReachable { session.sendMessage(context, replyHandler: nil) }
        lastSent = status
        lastSentAt = Date()
        alarmWasUp = alarmUp
    }

    /// The chart for the watch, in whole metres east and north of the anchor: the alarm radius, the boat,
    /// and the track thinned to `points` ("x,y x,y …").
    static func chart(anchor: CLLocationCoordinate2D, radius: Double, boat: CLLocationCoordinate2D?,
                      track: [CLLocationCoordinate2D], points: Int = 80) -> [String: String] {
        func xy(_ c: CLLocationCoordinate2D) -> String {
            let d = Geo.distance(anchor, c), b = Geo.bearing(from: anchor, to: c) * .pi / 180
            return "\(Int((d * sin(b)).rounded())),\(Int((d * cos(b)).rounded()))"
        }
        let step = max(1, track.count / points)
        let thinned = stride(from: 0, to: track.count, by: step).map { track[$0] } + (track.last.map { [$0] } ?? [])
        var chart = ["radiusM": "\(Int(radius.rounded()))", "track": thinned.map(xy).joined(separator: " ")]
        if let boat { chart["boat"] = xy(boat) }
        return chart
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["silence"] as? Bool == true else { replyHandler(["silenced": false]); return }
        Task { @MainActor in
            let handled = self.onSilence != nil
            self.onSilence?()
            replyHandler(["silenced": handled])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["silence"] as? Bool == true else { return }
        Task { @MainActor in self.onSilence?() }
    }
}
