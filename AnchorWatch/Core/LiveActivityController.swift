import ActivityKit
import Foundation

/// What the lock screen shows, with no ActivityKit types so the engine and its tests stay simple.
struct WatchSnapshot: Equatable {
    var distanceText: String
    var radiusText: String
    var fraction: Double
    var status: AnchorWatchAttributes.Status
    var headline: String
}

enum LiveActivityState: Equatable {
    /// No anchor set, so nothing to show.
    case idle
    case running
    /// Turned off for this app in iOS Settings (or system-wide).
    case disabled
    case failed(String)
}

@MainActor
protocol LiveActivityControlling: AnyObject {
    /// Nil when no anchor is set: the activity ends.
    func update(_ snapshot: WatchSnapshot?)
    var state: LiveActivityState { get }
}

/// Keeps a Live Activity on the lock screen and in the Dynamic Island while the anchor is set.
@MainActor
final class LiveActivityController: LiveActivityControlling {
    private var activity: Activity<AnchorWatchAttributes>?
    private(set) var state = LiveActivityState.idle
    private var last: WatchSnapshot?
    private var lastUpdate = Date.distantPast

    /// If the app stops updating (killed, crashed), iOS marks the activity stale after this long and the
    /// lock screen says so. A silent failure is the thing to avoid at anchor.
    private let staleAfter: TimeInterval = 120

    func update(_ snapshot: WatchSnapshot?) {
        guard let snapshot else { end(); return }

        // The user can swipe the activity away on the lock screen, or iOS can end it; then it must be started afresh.
        if let current = activity, current.activityState == .dismissed || current.activityState == .ended {
            activity = nil
            last = nil
        }
        if activity == nil {
            activity = Activity<AnchorWatchAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }   // resume after a relaunch
        }
        guard activity != nil else { start(snapshot); return }
        state = .running

        // Update on a change of status at once, otherwise at most every 5 seconds.
        guard Self.shouldSend(snapshot, after: last, elapsed: Date().timeIntervalSince(lastUpdate)) else { return }
        send(snapshot)
    }

    static func shouldSend(_ snapshot: WatchSnapshot, after last: WatchSnapshot?, elapsed: TimeInterval) -> Bool {
        elapsed >= 30 || (snapshot != last && (snapshot.status != last?.status || snapshot.headline != last?.headline || elapsed >= 5))
    }

    private func content(_ s: WatchSnapshot) -> ActivityContent<AnchorWatchAttributes.ContentState> {
        ActivityContent(state: .init(distanceText: s.distanceText, radiusText: s.radiusText, fraction: s.fraction,
                                     status: s.status, headline: s.headline, updated: Date()),
                        staleDate: Date().addingTimeInterval(staleAfter))
    }

    private func start(_ snapshot: WatchSnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { state = .disabled; return }
        do {
            activity = try Activity.request(attributes: AnchorWatchAttributes(boatName: "Nereus"), content: content(snapshot), pushType: nil)
            last = snapshot
            lastUpdate = Date()
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
            NSLog("Live Activity could not start: %@", error.localizedDescription)
        }
    }

    private func send(_ snapshot: WatchSnapshot) {
        last = snapshot
        lastUpdate = Date()
        let content = content(snapshot)
        let current = activity
        Task { await current?.update(content) }
    }

    private func end() {
        state = .idle
        guard let current = activity ?? Activity<AnchorWatchAttributes>.activities.first else { return }
        activity = nil
        last = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }
}

/// Used by tests, so no real activity is ever requested.
@MainActor
final class NoLiveActivity: LiveActivityControlling {
    var state = LiveActivityState.idle
    private(set) var snapshots: [WatchSnapshot?] = []
    func update(_ snapshot: WatchSnapshot?) { snapshots.append(snapshot) }
}
