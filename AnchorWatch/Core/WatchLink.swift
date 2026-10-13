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
        let changed = status != lastSent
        guard changed || Date().timeIntervalSince(lastSentAt) >= 30 || alarmUp != alarmWasUp else { return }
        var context: [String: Any] = status
        context["updated"] = Date().timeIntervalSince1970
        try? session.updateApplicationContext(context)
        // An alarm that's just started goes straight through if the watch app is open.
        if alarmUp && !alarmWasUp && session.isReachable { session.sendMessage(context, replyHandler: nil) }
        lastSent = status
        lastSentAt = Date()
        alarmWasUp = alarmUp
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["silence"] as? Bool == true else { return }
        Task { @MainActor in self.onSilence?() }
    }
}
