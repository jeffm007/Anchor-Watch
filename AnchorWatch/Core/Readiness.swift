import Foundation

/// One line of the "is this phone ready to keep watch?" checklist.
struct WatchCheck: Identifiable, Equatable {
    enum State: Equatable { case ok, warning, critical, unknown }
    let id: String
    let title: String
    let detail: String
    let state: State

    var isProblem: Bool { state == .warning || state == .critical }
}

/// What the checklist needs to know. Optional values mean "can't tell" (e.g. battery on the simulator).
struct ReadinessInput {
    /// Phone volume, 0...1.
    var volume: Float?
    /// Name of the output when the siren would NOT come from the phone's own speaker (AirPods, a Bluetooth speaker, ...).
    var audioRoute: String?
    var batteryLevel: Float?
    var charging = false
    var notificationsAllowed: Bool?
    var locationAlways: Bool?
    /// Horizontal GPS accuracy in metres.
    var accuracy: Double?
    var radius: Double
    /// Nil when unknown or irrelevant (no anchor set yet).
    var liveActivity: LiveActivityState?
    var goodAccuracy = 8.0
    var usableAccuracy = 50.0
}

/// Battery thresholds shared by the checklist, the notifications and the low-battery alarm.
enum BatteryAdvice {
    static let warningLevel: Float = 0.30
    static let noticeLevel: Float = 0.20
    static let alarmLevel: Float = 0.10
}

enum Readiness {
    /// The full checklist, in the order shown on screen.
    static func checks(_ i: ReadinessInput, format: (Double) -> String) -> [WatchCheck] {
        var list: [WatchCheck] = []

        // Volume
        if let volume = i.volume {
            let percent = Int((volume * 100).rounded())
            if volume < 0.2 {
                list.append(WatchCheck(id: "volume", title: "Phone volume is only \(percent)%",
                                       detail: "Turn it up with the side buttons, or you may not hear the siren.", state: .critical))
            } else if volume < 0.5 {
                list.append(WatchCheck(id: "volume", title: "Phone volume is \(percent)%",
                                       detail: "Turn it up with the side buttons so the siren will wake you.", state: .warning))
            } else {
                list.append(WatchCheck(id: "volume", title: "Phone volume is \(percent)%", detail: "Use Test siren to hear how loud it is.", state: .ok))
            }
        } else {
            list.append(WatchCheck(id: "volume", title: "Volume unknown", detail: "", state: .unknown))
        }

        // Where the sound comes out
        if let route = i.audioRoute {
            list.append(WatchCheck(id: "route", title: "Sound will play through \(route)",
                                   detail: "Disconnect it so the siren comes from the phone's own speaker.", state: .warning))
        } else {
            list.append(WatchCheck(id: "route", title: "Siren plays from the phone's speaker", detail: "", state: .ok))
        }

        // Battery
        if let level = i.batteryLevel {
            let percent = Int((level * 100).rounded())
            if i.charging {
                list.append(WatchCheck(id: "battery", title: "Charging (\(percent)%)", detail: "", state: .ok))
            } else if level <= BatteryAdvice.alarmLevel + 0.05 {
                list.append(WatchCheck(id: "battery", title: "Battery \(percent)% and not charging",
                                       detail: "Plug the phone in now. A dead phone cannot watch the anchor.", state: .critical))
            } else if level < BatteryAdvice.warningLevel {
                list.append(WatchCheck(id: "battery", title: "Battery \(percent)% and not charging",
                                       detail: "Plug the phone in before you sleep.", state: .warning))
            } else {
                list.append(WatchCheck(id: "battery", title: "Battery \(percent)%", detail: "Plug it in overnight to be safe.", state: .ok))
            }
        } else {
            list.append(WatchCheck(id: "battery", title: "Battery level unavailable", detail: "", state: .unknown))
        }

        // Permissions
        if let allowed = i.notificationsAllowed {
            list.append(WatchCheck(id: "notifications", title: allowed ? "Notifications are on" : "Notifications are off",
                                   detail: allowed ? "" : "Allow them in Settings so alarms and weather alerts reach you in the background.",
                                   state: allowed ? .ok : .warning))
        }
        if let always = i.locationAlways {
            list.append(WatchCheck(id: "location", title: always ? "Location is set to Always" : "Location is not set to Always",
                                   detail: always ? "" : "Settings > Privacy > Location Services > Anchor Watch > Always, so watching continues with the screen off.",
                                   state: always ? .ok : .warning))
        }

        // Lock-screen status
        switch i.liveActivity {
        case .running?:
            list.append(WatchCheck(id: "liveActivity", title: "Lock-screen status is showing", detail: "", state: .ok))
        case .disabled?:
            list.append(WatchCheck(id: "liveActivity", title: "Live Activities are turned off",
                                   detail: "Turn them on in iOS Settings > Anchor Watch > Live Activities (and Settings > Face ID & Passcode > Live Activities).",
                                   state: .warning))
        case .failed(let message)?:
            list.append(WatchCheck(id: "liveActivity", title: "Lock-screen status could not start", detail: message, state: .warning))
        case .idle?, nil:
            break
        }

        // GPS quality
        if let accuracy = i.accuracy {
            if accuracy > i.usableAccuracy {
                list.append(WatchCheck(id: "gps", title: "GPS accuracy is only ±\(format(accuracy))",
                                       detail: "Too poor to watch the anchor. Move the phone near a window or outside.", state: .critical))
            } else if accuracy > i.goodAccuracy {
                list.append(WatchCheck(id: "gps", title: "GPS accuracy is ±\(format(accuracy))",
                                       detail: "Fair. A window or open deck gives a better signal.", state: .warning))
            } else {
                list.append(WatchCheck(id: "gps", title: "GPS accuracy is ±\(format(accuracy))", detail: "", state: .ok))
            }
            if i.radius < accuracy * 2.5 {
                list.append(WatchCheck(id: "radius", title: "Alarm circle is small for this GPS",
                                       detail: "The circle is \(format(i.radius)) but GPS is only good to ±\(format(accuracy)). Enlarge the circle to avoid false alarms.",
                                       state: .warning))
            } else {
                list.append(WatchCheck(id: "radius", title: "Alarm circle is \(format(i.radius))", detail: "", state: .ok))
            }
        } else {
            list.append(WatchCheck(id: "gps", title: "Waiting for a GPS position", detail: "", state: .unknown))
        }
        return list
    }

    static func problems(_ i: ReadinessInput, format: (Double) -> String) -> [WatchCheck] {
        checks(i, format: format).filter(\.isProblem)
    }
}
