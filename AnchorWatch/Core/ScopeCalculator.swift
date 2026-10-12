import Foundation

/// Rode and alarm-radius maths. All values in metres.
struct ScopeSettings: Codable, Equatable {
    /// Water depth at the anchor. Entered by hand now; Phase 2 sonar will feed this.
    var depth = 3.048   // 10 ft
    /// Expected rise above the depth entered, so the scope covers high water.
    var tideRise = 0.0
    /// Bow roller height above the water.
    var bowHeight = 1.219   // 4 ft
    /// Bow to stern. Nereus is 47 ft (50 ft with the swim deck lowered). The phone is assumed to sit amidships.
    var boatLength = 14.326
    /// Rode length : (depth + bow height).
    var scopeRatio = 5.0
    /// Extra room in the alarm radius beyond where the rode lets the boat go: GPS error and chain slack. 20 ft.
    var margin = 6.096

    init() {}

    /// Tolerates settings saved before a field existed, so an update never wipes them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? depth
        tideRise = try c.decodeIfPresent(Double.self, forKey: .tideRise) ?? tideRise
        bowHeight = try c.decodeIfPresent(Double.self, forKey: .bowHeight) ?? bowHeight
        boatLength = try c.decodeIfPresent(Double.self, forKey: .boatLength) ?? boatLength
        scopeRatio = try c.decodeIfPresent(Double.self, forKey: .scopeRatio) ?? scopeRatio
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? margin
        if margin == 5.0 { margin = 6.096 }     // the old 5 m default becomes 20 ft
    }

    /// Memberwise-style init for tests and previews.
    init(depth: Double, tideRise: Double = 0, bowHeight: Double, boatLength: Double, scopeRatio: Double, margin: Double) {
        self.depth = depth; self.tideRise = tideRise; self.bowHeight = bowHeight
        self.boatLength = boatLength; self.scopeRatio = scopeRatio; self.margin = margin
    }

    /// Depth the rode must cover: today's depth plus the expected tide rise.
    var designDepth: Double { depth + tideRise }
}

enum ScopeCalculator {
    /// Rode to pay out, from the bow roller.
    static func rode(_ s: ScopeSettings) -> Double {
        s.scopeRatio * (s.designDepth + s.bowHeight)
    }

    /// Horizontal reach of the rode once it is taut.
    static func horizontalReach(_ s: ScopeSettings) -> Double {
        let h = s.designDepth + s.bowHeight
        let r = rode(s)
        return r > h ? (r * r - h * h).squareRoot() : 0
    }

    /// Distance from the bow roller back to the phone, assuming it is amidships.
    static func gpsFromBow(_ s: ScopeSettings) -> Double { s.boatLength / 2 }

    /// The farthest the GPS position can be from the anchor without the boat dragging.
    static func suggestedRadius(_ s: ScopeSettings) -> Double {
        horizontalReach(s) + gpsFromBow(s) + s.margin
    }
}
