import Foundation

/// The boat and its ground tackle: what the rode, holding and load calculations need.
/// Lengths in metres, areas in square metres, weights in kilograms, volumes in litres, rope and chain sizes in millimetres.
/// Always a powerboat. Zero means "not entered yet". The defaults are Nereus (ex-Kinship), a 2005 Selene 47, from the Edwards Marine Survey of 30 Sep 2024;
/// the survey doesn't give freeboard, heights, anchor weights or rode lengths, so those are marked GUESS until measured. Length overall and bow roller height live in `ScopeSettings`,
/// which the scope maths already uses, so they are not repeated here.
struct BoatProfile: Codable, Equatable {
    enum AnchorType: String, Codable, CaseIterable, Identifiable {
        case newGeneration = "New generation", plow = "Plow", claw = "Claw", fluke = "Fluke"
        var id: String { rawValue }
        var examples: String {
            switch self {
            case .newGeneration: return "Rocna, Mantus, Spade, Vulcan, Ultra"
            case .plow: return "CQR, Delta, Lewmar plow"
            case .claw: return "Bruce and its copies"
            case .fluke: return "Danforth, Fortress"
            }
        }
    }

    enum RodeType: String, Codable, CaseIterable, Identifiable {
        case allChain = "All chain", chainAndRope = "Chain + rope", rope = "Rope"
        var id: String { rawValue }
        var hasChain: Bool { self != .rope }
        var hasRope: Bool { self != .allChain }
    }

    var name = "Nereus"

    // Hull
    var waterlineLength = 14.046   // 46' 1"
    var beam = 4.775                // 15' 8"
    var draft = 1.549               // 5' 1"
    /// Dry weight: no fuel, water or waste aboard.
    var displacement = 28_122.73    // 62,000 lb

    // Tanks
    var fuelCapacity = 4_164.0      // 1,100 US gal diesel
    var waterCapacity = 1_135.6     // 300 US gal
    var holdingCapacity = 242.3     // 64 US gal blackwater
    /// Height of the deck above the water at the bow.
    var freeboard = 1.676           // GUESS 5' 6"
    /// Cabin top, doghouse or flybridge above the deck.
    var cabinHeight = 2.743         // GUESS 9 ft: pilothouse and flybridge
    /// Measured frontal windage area. Nil uses the estimate from beam and heights.
    var windageArea: Double?
    /// Measured side windage area. Nil uses the estimate from length and heights.
    var sideWindageArea: Double?

    // Ground tackle
    var anchorType = AnchorType.claw
    var anchorWeight = 49.9         // GUESS 110 lb
    var rodeType = RodeType.allChain
    var chainLength = 91.44         // GUESS 300 ft
    var chainSize = 9.525           // GUESS 3/8"
    var ropeLength = 0.0
    var ropeSize = 0.0
    var hasSnubber = true
    var snubberLength = 6.096       // GUESS 20 ft
    /// Length of snubber in use: zero when there's none.
    var snubber: Double { hasSnubber ? snubberLength : 0 }

    init() {}

    /// Tolerates profiles saved before a field existed, so an update never wipes them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        name = value(.name, name)
        waterlineLength = value(.waterlineLength, waterlineLength)
        beam = value(.beam, beam)
        draft = value(.draft, draft)
        displacement = value(.displacement, displacement)
        fuelCapacity = value(.fuelCapacity, fuelCapacity)
        waterCapacity = value(.waterCapacity, waterCapacity)
        holdingCapacity = value(.holdingCapacity, holdingCapacity)
        freeboard = value(.freeboard, freeboard)
        cabinHeight = value(.cabinHeight, cabinHeight)
        windageArea = try? c.decodeIfPresent(Double.self, forKey: .windageArea)
        sideWindageArea = try? c.decodeIfPresent(Double.self, forKey: .sideWindageArea)
        anchorType = value(.anchorType, anchorType)
        anchorWeight = value(.anchorWeight, anchorWeight)
        rodeType = value(.rodeType, rodeType)
        chainLength = value(.chainLength, chainLength)
        chainSize = value(.chainSize, chainSize)
        ropeLength = value(.ropeLength, ropeLength)
        ropeSize = value(.ropeSize, ropeSize)
        snubberLength = value(.snubberLength, snubberLength)
        hasSnubber = value(.hasSnubber, snubberLength > 0)
    }
}

/// Rode, windage and wind-load maths from the boat profile. SI units throughout.
enum BoatMath {
    static let airDensity = 1.225          // kg/m³, sea level
    /// Drag coefficient for a boat lying head to wind.
    static let dragCoefficient = 1.0
    /// Hull and cabin are not full rectangles seen from ahead.
    static let hullFill = 0.8
    /// Yawing, gusts and surge in waves can roughly double the steady load.
    static let peakFactor = 2.0

    static let dieselDensity = 0.85        // kg/L
    static let waterDensity = 1.0          // kg/L, near enough for fresh and black water

    /// Dry weight plus full fuel, water and holding tanks. Nil until the dry weight is entered.
    static func loadedWeight(_ b: BoatProfile) -> Double? {
        guard b.displacement > 0 else { return nil }
        return b.displacement + b.fuelCapacity * dieselDensity + (b.waterCapacity + b.holdingCapacity) * waterDensity
    }

    /// Usable rode on board. Zero when nothing has been entered.
    static func rodeCarried(_ b: BoatProfile) -> Double {
        (b.rodeType.hasChain ? b.chainLength : 0) + (b.rodeType.hasRope ? b.ropeLength : 0)
    }

    /// Frontal area from beam, freeboard and cabin. Nil until beam and freeboard are entered.
    /// The radar mast is small next to the flybridge and is left out.
    static func estimatedWindage(_ b: BoatProfile) -> Double? {
        guard b.beam > 0, b.freeboard > 0 else { return nil }
        return b.beam * (b.freeboard + b.cabinHeight) * hullFill
    }

    /// The measured area if entered, otherwise the estimate.
    /// Side area from length overall, freeboard and cabin. Nil until length and freeboard are entered.
    static func estimatedSideWindage(_ b: BoatProfile, length: Double) -> Double? {
        guard length > 0, b.freeboard > 0 else { return nil }
        return length * (b.freeboard + b.cabinHeight) * hullFill
    }

    static func windage(_ b: BoatProfile) -> Double? {
        if let area = b.windageArea, area > 0 { return area }
        return estimatedWindage(b)
    }

    /// The measured side area if entered, otherwise the estimate from length overall.
    static func sideWindage(_ b: BoatProfile, length: Double) -> Double? {
        if let area = b.sideWindageArea, area > 0 { return area }
        return estimatedSideWindage(b, length: length)
    }

    /// Steady pull of the wind on the boat, in newtons, for a wind speed in knots.
    static func windLoad(_ b: BoatProfile, knots: Double) -> Double? {
        windage(b).map { windForce(area: $0, knots: knots) }
    }

    /// Pull of the wind on `area` square metres, in newtons.
    static func windForce(area: Double, knots: Double) -> Double {
        let v = knots * 0.514444
        return 0.5 * airDensity * dragCoefficient * area * v * v
    }

    /// Deepest water (at high tide) the rode on board can anchor in at this scope ratio.
    static func deepestWater(_ b: BoatProfile, scopeRatio: Double, bowHeight: Double) -> Double? {
        let rode = rodeCarried(b)
        guard rode > 0, scopeRatio > 0 else { return nil }
        return max(0, rode / scopeRatio - bowHeight)
    }
}

extension Units {
    /// Pounds alongside feet, kilograms alongside metres.
    var perKilogram: Double { self == .feet ? 1 / 0.45359237 : 1 }
    var weightSymbol: String { self == .feet ? "lb" : "kg" }

    /// US gallons alongside feet, litres alongside metres.
    var perLiter: Double { self == .feet ? 0.264172 : 1 }
    var volumeSymbol: String { self == .feet ? "gal" : "L" }

    func formatWeight(_ kilograms: Double) -> String {
        "\((kilograms * perKilogram).formatted(.number.precision(.fractionLength(0)))) \(weightSymbol)"
    }

    var perSquareMeter: Double { self == .feet ? 10.7639 : 1 }
    var areaSymbol: String { self == .feet ? "ft²" : "m²" }

    func formatArea(_ squareMeters: Double) -> String {
        String(format: "%.0f %@", squareMeters * perSquareMeter, areaSymbol)
    }

    /// A force in newtons, as pounds-force or kilograms-force.
    func formatForce(_ newtons: Double) -> String {
        self == .feet ? String(format: "%.0f lb", newtons / 4.44822) : String(format: "%.0f kg", newtons / 9.80665)
    }

    /// Chain and rope sizes: fractions of an inch alongside feet, millimetres alongside metres.
    func formatSize(_ mm: Double) -> String {
        guard self == .feet else { return String(format: "%.0f mm", mm) }
        let sixteenths = Int((mm / 25.4 * 16).rounded())
        let approx = abs(Double(sixteenths) / 16 * 25.4 - mm) > 0.1 ? "≈ " : ""
        let whole = sixteenths / 16, rest = sixteenths % 16
        guard rest > 0 else { return "\(approx)\(whole) in" }
        var num = rest, den = 16
        while num % 2 == 0 { num /= 2; den /= 2 }
        return "\(approx)\(whole > 0 ? "\(whole) " : "")\(num)/\(den) in"
    }

    /// Common chain sizes, in millimetres.
    var chainSizes: [Double] {
        self == .feet ? [4, 5, 6, 7, 8, 10, 12].map { $0 * 25.4 / 16 } : [6, 7, 8, 10, 12, 13, 14, 16]
    }

    /// Common nylon rode sizes, in millimetres.
    var ropeSizes: [Double] {
        self == .feet ? [6, 7, 8, 9, 10, 12, 14, 16].map { $0 * 25.4 / 16 } : [10, 12, 14, 16, 18, 20, 22, 24]
    }
}
