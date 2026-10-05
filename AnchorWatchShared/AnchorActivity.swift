import ActivityKit
import Foundation

/// Shared by the app and the Live Activity extension: what the lock screen and Dynamic Island show.
struct AnchorWatchAttributes: ActivityAttributes {
    enum Status: String, Codable, Hashable {
        case holding, caution, alarm
    }

    struct ContentState: Codable, Hashable {
        /// Already formatted in the user's units, e.g. "36 ft".
        var distanceText: String
        var radiusText: String
        /// Distance as a fraction of the alarm radius; 1.0 is the edge of the circle.
        var fraction: Double
        var status: Status
        var headline: String
        var updated: Date
    }

    var boatName: String
}
