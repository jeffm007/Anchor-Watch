import Combine
import CryptoKit
import Foundation
import JavaScriptCore

/// Experimental chart data kept in the app's private Documents directory.
/// Source exchange-set archives are retained byte-for-byte; the decoded model is a rebuildable local cache.
struct OfflineENCChart: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(sha256):\(metadata.cellID)" }
    let sourceName: String
    let originalFilename: String
    let sha256: String
    let importedAt: Date
    let metadata: OfflineENCMetadata
    let features: [OfflineENCFeature]

    func heightUnits(for feature: OfflineENCFeature) -> String {
        // Spatial overrides cannot be replaced by the dataset default. Until resolved,
        // conservatively mark affected datasets unknown rather than assume metres.
        if features.contains(where: { $0.objectClass == 311 && $0.attributes["ATTL_96"] != nil }) {
            return "units unresolved (local M_UNIT override)"
        }
        switch metadata.heightUnitCode {
        case 1: return "m"; case 2: return "ft"
        default: return "units unknown"
        }
    }
    func heightDatum(for feature: OfflineENCFeature) -> String {
        if let value = feature.attributes["ATTL_185"] {
            return OfflineENCReference.datum(Int(value)) + " · feature VERDAT"
        }
        if features.contains(where: { $0.objectClass == 312 }) {
            return "Datum unresolved (local M_VDAT override)"
        }
        return OfflineENCReference.datum(metadata.verticalDatumCode) + " · dataset VDAT"
    }
    func heightValue(_ raw: String, for feature: OfflineENCFeature) -> String {
        guard let value = Double(raw), value.isFinite else { return "Invalid source value: " + raw }
        return raw + " " + heightUnits(for: feature)
    }

    /// Geographic chart objects that the current experimental renderer does not draw.
    var unportrayedFeatureCount: Int { features.filter { !$0.isMetaObject && !$0.isPortrayed }.count }
    /// Dataset metadata (coverage, quality, and similar objects) is tracked separately
    /// so it is not presented to the user as missing geographic features.
    var unportrayedMetadataCount: Int { features.filter { $0.isMetaObject && !$0.isPortrayed }.count }
    /// S-57 metadata objects such as M_COVR describe dataset coverage, which can
    /// be much larger than the area containing charted features. They must not
    /// drive zoom-to-fit or the useful chart can be compressed into a strip.
    var bounds: OfflineENCBounds? { OfflineENCBounds(features: features.filter { !$0.isMetaObject }) }

    static func mosaicCharts(in charts: [OfflineENCChart], exchangeSetHash: String,
                             selectedCellIDs: Set<String>?, includingCellID: String) -> [OfflineENCChart] {
        let matching = charts.filter { $0.sha256 == exchangeSetHash }
        let visible = selectedCellIDs.map { selected in
            matching.filter { $0.id == includingCellID || selected.contains($0.id) }
        } ?? matching
        // Draw broad-scale cells first so detailed cells paint over them.
        return visible.sorted { $0.metadata.compilationScale > $1.metadata.compilationScale }
    }

    static func mosaicBounds(in charts: [OfflineENCChart], exchangeSetHash: String) -> OfflineENCBounds? {
        // Coverage metadata can include large CATCOV=2 regions where the cell
        // explicitly has no chart data. Fit a mosaic to geographic objects,
        // just as we do for an individual cell, or the useful chart is shrunk.
        let bounds = charts.filter { $0.sha256 == exchangeSetHash }.compactMap(\.bounds)
        guard let first = bounds.first else { return nil }
        return OfflineENCBounds(west: bounds.map(\.west).min() ?? first.west,
                                south: bounds.map(\.south).min() ?? first.south,
                                east: bounds.map(\.east).max() ?? first.east,
                                north: bounds.map(\.north).max() ?? first.north)
    }

    /// Fit a nearby selected group, but do not zoom out to disconnected parts of
    /// a large exchange set. The active cell is the fallback focus; other enabled
    /// cells still render at their geographic positions and can be reached by pan.
    static func viewportBounds(in charts: [OfflineENCChart], focusedCellID: String) -> OfflineENCBounds? {
        guard let focused = charts.first(where: { $0.id == focusedCellID }),
              let focusBounds = focused.bounds else { return nil }
        guard let groupBounds = mosaicBounds(in: charts, exchangeSetHash: focused.sha256) else { return focusBounds }

        func mercatorY(_ latitude: Double) -> Double {
            log(tan(.pi / 4 + min(85.0511, max(-85.0511, latitude)) * .pi / 360))
        }
        let focusWidth = max(focusBounds.east - focusBounds.west, 1e-9)
        let focusHeight = max(mercatorY(focusBounds.north) - mercatorY(focusBounds.south), 1e-9)
        let groupWidth = max(groupBounds.east - groupBounds.west, 1e-9)
        let groupHeight = max(mercatorY(groupBounds.north) - mercatorY(groupBounds.south), 1e-9)
        let expansion = max(groupWidth / focusWidth, groupHeight / focusHeight)

        // A few neighboring cells remain legible together. A set spanning a
        // broad region stays focused on the active cell instead of shrinking
        // into disconnected specks.
        return expansion <= 2.5 ? groupBounds : focusBounds
    }
}

struct OfflineENCMetadata: Codable, Equatable, Sendable {
    let cellID: String
    let edition: String
    let update: String
    let updateDate: String
    let issueDate: String
    let exchangeStandard: String
    let compilationScale: Int
    let depthUnitCode: Int
    let verticalDatumCode: Int
    let horizontalDatumCode: Int
    let catalogPresent: Bool
    let updateFilesApplied: [String]
    var soundingDatumCode: Int? = nil
    var heightUnitCode: Int? = nil

    var depthUnitName: String {
        switch depthUnitCode {
        case 1: return "metres"
        case 2: return "feet"
        case 3: return "fathoms"
        default: return "unknown (S-57 code \(depthUnitCode))"
        }
    }

    var soundingDatumDescription: String {
        guard let code = soundingDatumCode, code > 0 else { return "unknown (cache/source lacks SDAT)" }
        if code == 27 { return "Lower low water large tide (27)" }
        return "S-57 code \(code)"
    }

    var depthReferenceDescription: String {
        "Charted depths · \(depthUnitName) · dataset sounding datum: \(soundingDatumDescription)"
    }
}

enum OfflineENCReference {
    static let datums: [Int: String] = [
        1: "Mean low water springs",
        2: "Mean lower low water springs",
        3: "Mean sea level",
        4: "Lowest low water",
        5: "Mean low water",
        6: "Lowest low water springs",
        7: "Approximate mean low water springs",
        8: "Indian spring low water",
        9: "Low water springs",
        10: "Approximate lowest astronomical tide",
        11: "Nearly lowest low water",
        12: "Mean lower low water",
        13: "Low water",
        14: "Approximate mean low water",
        15: "Approximate mean lower low water",
        16: "Mean high water",
        17: "Mean high water springs",
        18: "High water",
        19: "Approximate mean sea level",
        20: "High water springs",
        21: "Mean higher high water",
        22: "Equinoctial spring low water",
        23: "Lowest astronomical tide",
        24: "Local datum",
        25: "International Great Lakes Datum 1985",
        26: "Mean water level",
        27: "Lower low water large tide",
        28: "Higher high water large tide",
        29: "Nearly highest high water"]
    static let restrictions: [Int: String] = [
        1: "anchoring prohibited",
        2: "anchoring restricted",
        3: "fishing prohibited",
        4: "fishing restricted",
        5: "trawling prohibited",
        6: "trawling restricted",
        7: "entry prohibited",
        8: "entry restricted",
        9: "dredging prohibited",
        10: "dredging restricted",
        11: "diving prohibited",
        12: "diving restricted",
        13: "no wake",
        14: "area to be avoided",
        15: "construction prohibited"]
    static let statuses: [Int: String] = [
        1: "permanent",
        2: "occasional",
        3: "recommended",
        4: "disused",
        5: "periodically/intermittent",
        6: "reserved",
        7: "temporary",
        8: "private",
        9: "mandatory",
        11: "extinguished",
        12: "illuminated",
        13: "historic",
        14: "public",
        15: "synchronized",
        16: "watched",
        17: "un-watched",
        18: "existence doubtful"]
    static func datum(_ code: Int?) -> String {
        guard let code, code > 0 else { return "Unknown datum" }
        return (datums[code] ?? "Unknown datum") + " (S-57 \(code))"
    }
    static func labels(_ raw: String?, dictionary: [Int: String]) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return raw.split(separator: ",", omittingEmptySubsequences: false).map {
            let token = $0.trimmingCharacters(in: .whitespaces)
            guard let code = Int(token), let meaning = dictionary[code] else { return "Unknown code: " + token }
            return meaning + " (" + token + ")"
        }
    }
}

enum OfflineENCDepthBand: String, CaseIterable {
    case drying, intertidal, under2, under5, under10, under20, deep, unknown
}

struct OfflineENCFeature: Codable, Equatable, Identifiable, Sendable {
    let geometryType: String?
    let coordinates: OfflineJSONValue?
    let attributes: [String: String]
    let soundingDepths: [Double]

    var id: String { "\(attributes["OBJL"] ?? "?")-\(attributes["RCID"] ?? "0")" }
    var objectClass: Int { Int(attributes["OBJL"] ?? "") ?? -1 }
    static let aidClasses: Set<Int> = [5, 6, 7, 8, 9, 14, 15, 16, 17, 18, 19, 39, 75, 144]
    static let structureClasses: Set<Int> = [84, 90, 95, 122]
    var colourCodes: [Int] { (attributes["ATTL_75"] ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    func depthBand(unitCode: Int) -> OfflineENCDepthBand {
        guard objectClass == 42, let low = Double(attributes["ATTL_87"] ?? ""),
              let high = Double(attributes["ATTL_88"] ?? ""), low.isFinite, high.isFinite, low <= high else { return .unknown }
        let factor: Double
        switch unitCode { case 1: factor = 1; case 2: factor = 0.3048; case 3: factor = 1.8288; default: return .unknown }
        let minimum = low * factor, maximum = high * factor
        if maximum <= 0 { return .drying }
        if minimum < 0 { return .intertidal }
        if minimum < 2 { return .under2 }
        if minimum < 5 { return .under5 }
        if minimum < 10 { return .under10 }
        if minimum < 20 { return .under20 }
        return .deep
    }
    /// Charted orientation, never a live-current prediction. Reject invalid/missing bearings.
    var chartedOrientation: Double? {
        guard let value = Double(attributes["ATTL_117"] ?? ""), value.isFinite, (0...360).contains(value) else { return nil }
        return value == 360 ? 0 : value
    }
    var ferryDescription: String {
        switch attributes["ATTL_25"] { case "1": return "Ferry route"; case "2": return "Cable ferry"; case "3": return "Ice ferry"; default: return "Ferry (type unspecified)" }
    }
    static let landContextClasses: Set<Int> = [13, 64, 69, 72, 73, 74, 80, 82, 98, 114, 116, 119, 125, 126, 128]
    var turbulenceDescription: String {
        switch attributes["ATTL_69"] {
        case "1": return "Breakers"
        case "2": return "Eddies"
        case "3": return "Overfalls"
        case "4": return "Tide rips"
        case "5": return "Bombora"
        default: return "Water turbulence (type unspecified)"
        }
    }
    var contextSymbolLabel: String {
        switch objectClass {
        case 13: return "Town"; case 64: return "Harbour"; case 72: return "Elev"
        case 73: return "Land"; case 74: return "Landmark"; case 80: return "Logs"
        case 82: return "Farm"; case 98: return "Pylon"; case 119: return "Water"
        case 125: return "Tank"; case 128: return "Facility"; default: return className
        }
    }
    static let informationClasses: Set<Int> = [1, 3, 4, 21, 27, 58, 104, 138]
    var restrictionLabels: [String] { OfflineENCReference.labels(attributes["ATTL_131"], dictionary: OfflineENCReference.restrictions) }
    var statusLabels: [String] { OfflineENCReference.labels(attributes["ATTL_149"], dictionary: OfflineENCReference.statuses) }
    var informationSymbol: String {
        switch objectClass {
        case 1: return "Admin"; case 3: return "Berth"; case 4: return "Anch"
        case 21: return "OH cable"; case 27: return "!"; case 58: return "Fog"
        case 104: return "Radio"; case 138: return "Tide info"; default: return "Info"
        }
    }
    var isMetaObject: Bool { (300...399).contains(objectClass) }
    var isPortrayed: Bool {
        let area = ["Polygon", "MultiPolygon"].contains(geometryType ?? "")
        let line = ["LineString", "MultiLineString"].contains(geometryType ?? "")
        let point = geometryType == "Point"
        switch objectClass {
        case 1: return area
        case 21: return line
        case 58: return point
        case 104: return point || line
        case 3, 4, 27, 138: return point || area
        case 156, 74, 82, 116: return point || line || area
        case 72: return point || line
        case 126: return line
        case 69: return area
        case 114: return line || area
        case 13, 64, 73, 80, 98, 119, 125, 128: return point || area
        default: break
        }
        if objectClass == 158 { return ["Point", "Polygon", "MultiPolygon"].contains(geometryType ?? "") }
        if objectClass == 160 { return geometryType == "Point" }
        if objectClass == 53 { return ["LineString", "MultiLineString"].contains(geometryType ?? "") }
        if Self.aidClasses.contains(objectClass) || objectClass == 90 { return geometryType == "Point" }
        if objectClass == 159 { return ["Point", "Polygon", "MultiPolygon"].contains(geometryType ?? "") }
        if Self.structureClasses.contains(objectClass) { return ["Point", "LineString", "MultiLineString", "Polygon", "MultiPolygon"].contains(geometryType ?? "") }
        if objectClass == 112 { return geometryType == "Polygon" }
        if objectClass == 153 { return geometryType == "Point" }
        if objectClass == 20 || objectClass == 121 { return geometryType == "Polygon" || (objectClass == 121 && geometryType == "Point") }
        if objectClass == 22 { return geometryType == "LineString" }
        return OfflineENCFeature.portrayedClasses.contains(objectClass) && ["Point", "MultiPoint", "LineString", "Polygon"].contains(geometryType ?? "")
    }
    var className: String { OfflineENCFeature.classNames[objectClass] ?? "Object class \(objectClass)" }

    static let portrayedClasses: Set<Int> = [5, 7, 14, 17, 18, 19, 20, 22, 30, 42, 43, 71, 75, 112, 121, 129, 153, 6, 8, 9, 15, 16, 39, 84, 90, 95, 122, 144, 159, 158, 160, 53, 13, 64, 69, 72, 73, 74, 80, 82, 98, 114, 116, 119, 125, 126, 128, 156, 1, 3, 4, 21, 27, 58, 104, 138]
    static let classNames: [Int: String] = [
        3: "Anchor berth", 4: "Anchorage area", 21: "Overhead cable", 27: "Caution area",
        58: "Fog signal", 138: "Tidal stream information panel",
        64: "Harbour facility", 74: "Landmark", 82: "Marine farm", 98: "Pylon/bridge support",
        125: "Silo/tank", 126: "Slope topline", 128: "Small craft facility", 156: "Water turbulence",
        6: "Isolated danger beacon", 8: "Safe water beacon", 15: "Installation buoy", 16: "Isolated danger buoy",
        39: "Daymark", 84: "Mooring facility", 144: "Topmark", 159: "Wreck",
        1: "Administration area", 9: "Special purpose beacon", 13: "Built-up area",
        20: "Cable area", 22: "Cable", 53: "Ferry route", 69: "Lake",
        72: "Land elevation", 73: "Land region", 80: "Log pond", 90: "Pile",
        5: "Cardinal beacon", 7: "Lateral beacon", 14: "Cardinal buoy", 17: "Lateral buoy",
        18: "Safe water buoy", 19: "Special purpose buoy", 30: "Coastline", 42: "Depth area",
        43: "Depth contour", 71: "Land area", 75: "Light", 95: "Pontoon",
        104: "Radio calling-in point", 112: "Restricted area", 114: "River",
        116: "Road", 119: "Sea area", 121: "Seabed area", 122: "Shoreline construction",
        129: "Sounding", 153: "Underwater/awash rock", 158: "Weed/kelp",
        160: "Tidal stream", 302: "Coverage metadata", 306: "Navigational system metadata",
        308: "Data quality metadata"
    ]

    func chartCoordinates() -> [ChartCoordinate] {
        var result: [ChartCoordinate] = []
        coordinates?.collectCoordinates(into: &result)
        return result
    }
}

struct ChartCoordinate: Codable, Equatable, Sendable {
    let longitude: Double
    let latitude: Double
}

enum OfflineJSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null, array([OfflineJSONValue]), object([String: OfflineJSONValue])
    // Inline tuples avoid a heap allocation and boxed values for every chart vertex.
    // Their JSON representation remains unchanged, including the optional Z value.
    case position(Double, Double), position3D(Double, Double, Double)

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let values = try? box.decode([Double].self), values.count == 2 {
            self = .position(values[0], values[1])
        } else if let values = try? box.decode([Double].self), values.count == 3 {
            self = .position3D(values[0], values[1], values[2])
        }
        else if let value = try? box.decode([OfflineJSONValue].self) { self = .array(value) }
        else { self = .object(try box.decode([String: OfflineJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .position(let x, let y): try box.encode([x, y])
        case .position3D(let x, let y, let z): try box.encode([x, y, z])
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .null: try box.encodeNil()
        case .array(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        }
    }

    func collectCoordinates(into result: inout [ChartCoordinate]) {
        switch self {
        case .position(let lon, let lat), .position3D(let lon, let lat, _):
            if lon.isFinite, lat.isFinite, (-180...180).contains(lon), (-90...90).contains(lat) {
                result.append(ChartCoordinate(longitude: lon, latitude: lat))
            }
        case .array(let values):
            if values.count >= 2, case .number(let lon) = values[0], case .number(let lat) = values[1],
               lon.isFinite, lat.isFinite, (-180...180).contains(lon), (-90...90).contains(lat) {
                result.append(ChartCoordinate(longitude: lon, latitude: lat))
            } else {
                values.forEach { $0.collectCoordinates(into: &result) }
            }
        case .object(let values): values.values.forEach { $0.collectCoordinates(into: &result) }
        case .string, .number, .bool, .null: break
        }
    }
}

struct OfflineENCBounds: Codable, Equatable, Hashable, Sendable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double

    init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }

    init?(features: [OfflineENCFeature]) {
        let points = features.flatMap { $0.chartCoordinates() }
        guard let west = points.map(\.longitude).min(), let east = points.map(\.longitude).max(),
              let south = points.map(\.latitude).min(), let north = points.map(\.latitude).max(),
              west < east, south < north else { return nil }
        self.west = west; self.south = south; self.east = east; self.north = north
    }

    func contains(_ point: ChartCoordinate) -> Bool {
        (west...east).contains(point.longitude) && (south...north).contains(point.latitude)
    }
}

enum OfflineENCImportSource: String, CaseIterable, Identifiable, Sendable {
    case noaa = "NOAA ENC"
    case chs = "CHS ENC"
    case other = "Other ENC"
    var id: String { rawValue }
}

struct OfflineENCCollection: Codable, Identifiable, Equatable, Sendable {
    var id: String { sha256 }
    let sourceName: String
    let originalFilename: String
    let sha256: String
    let importedAt: Date
    let cells: [OfflineENCZip.CellCandidate]

    /// Cache refresh/import order must not switch the overview to a sample cell.
    static func defaultCoverage(in collections: [Self], preferredID: String) -> Self? {
        if let preferred = collections.first(where: { $0.id == preferredID }) { return preferred }
        return collections.sorted { left, right in
            let overviewIDs = ["CA271100", "CA271101"]
            let leftOverview = left.cells.contains { overviewIDs.contains($0.cellID.uppercased()) }
            let rightOverview = right.cells.contains { overviewIDs.contains($0.cellID.uppercased()) }
            if leftOverview != rightOverview { return leftOverview }
            if left.cells.count != right.cells.count { return left.cells.count > right.cells.count }
            return left.id < right.id
        }.first
    }
}

enum OfflineENCImportError: LocalizedError, Equatable, Sendable {
    case tooLarge, malformedArchive(String), encryptedArchive, unsafeArchiveEntry(String), unsupportedCompression,
         unsupportedChart(String), missingCatalog, noBaseCell, multipleBaseCells, missingUpdate(String), invalidUpdate(String),
         duplicateArchive, decoderUnavailable, decoder(String), cache(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "This exchange set exceeds the experimental import limit (256 MB compressed or 600 MB expanded)."
        case .malformedArchive(let reason): return "The ZIP exchange set is damaged or incomplete: \(reason)"
        case .encryptedArchive: return "Encrypted ZIP files are not supported. No decryption was attempted."
        case .unsafeArchiveEntry(let name): return "The archive contains an unsafe or unsupported file path: \(name)"
        case .unsupportedCompression: return "The archive uses a ZIP compression method this prototype cannot read."
        case .missingCatalog: return "This is not a supported S-57 exchange set: CATALOG.031 is missing."
        case .noBaseCell: return "No S-57 base cell (.000) was found in this exchange set."
        case .multipleBaseCells: return "Choose one active chart cell from this exchange set to preview. The full chart collection is retained unchanged."
        case .missingUpdate(let name): return "The update sequence is incomplete; missing \(name). Import was cancelled."
        case .invalidUpdate(let reason): return "The chart update could not be verified: \(reason)"
        case .unsupportedChart(let reason): return "Encrypted or unsupported chart format: \(reason)"
        case .duplicateArchive: return "This exact exchange set is already in the offline chart library."
        case .decoderUnavailable: return "The experimental S-57 decoder is missing from this app build."
        case .decoder(let reason): return "The S-57 cell could not be decoded: \(reason)"
        case .cache(let reason): return "The chart could not be saved to the offline library: \(reason)"
        }
    }
}

/// Minimal, bounded ZIP reader for unencrypted, single-disk .zip exchange sets.
/// It rejects traversal paths, links, ZIP64, duplicate names, unsupported methods, and oversized payloads.
enum OfflineENCZip {
    struct Entry: Sendable {
        let name: String
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localOffset: UInt32
        let isDirectory: Bool
    }

    // The CHS V-PAC-A collection is about 162 MiB compressed and 400 MiB expanded.
    // Keep explicit caps while leaving room for that collection and comparable packages.
    static let maxArchiveBytes = 256 * 1024 * 1024
    static let maxExpandedBytes = 600 * 1024 * 1024
    static let maxEntryBytes = 25 * 1024 * 1024
    static let maxEntries = 5000

    struct CellCandidate: Codable, Identifiable, Hashable, Sendable {
        let path: String
        let cellID: String
        let title: String
        let bounds: OfflineENCBounds?
        var id: String { path }
    }

    static func cellCandidates(in data: Data) throws -> [CellCandidate] {
        let files = try entries(in: data).filter { !$0.isDirectory }
        guard files.contains(where: { URL(fileURLWithPath: $0.name).lastPathComponent.uppercased() == "CATALOG.031" }) else {
            throw OfflineENCImportError.missingCatalog
        }
        let infoByCell = try collectionInfo(in: data, files: files)
        let catalogueBounds = try catalogueBounds(in: data, files: files)
        let cells = files.filter { $0.name.lowercased().hasSuffix(".000") && isActiveCellPath($0.name) }
        guard !cells.isEmpty else { throw OfflineENCImportError.noBaseCell }
        return cells.map { entry in
            let file = URL(fileURLWithPath: entry.name).lastPathComponent
            let cellID = String(file.dropLast(4))
            let info = infoByCell[cellID]
            return CellCandidate(path: entry.name, cellID: cellID, title: info?.title ?? cellID,
                                 bounds: info?.bounds ?? catalogueBounds[cellID])
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.cellID < $1.cellID : order == .orderedAscending
        }
    }

    /// CATALOG.031 travels with the exchange set even when the optional CHS CSV
    /// was left out of a user-created ZIP. Read its ISO 8211 CATD extents.
    static func readCatalogueBounds(_ data: Data) throws -> [String: OfflineENCBounds] {
        let bytes = [UInt8](data)
        var offset = 0
        var result: [String: OfflineENCBounds] = [:]
        func number(_ start: Int, _ length: Int) -> Int? {
            guard start >= 0, length > 0, start + length <= bytes.count else { return nil }
            return Int(String(decoding: bytes[start..<start + length], as: UTF8.self))
        }
        while offset < bytes.count {
            guard offset + 24 <= bytes.count,
                  let length = number(offset, 5), length >= 25, offset + length <= bytes.count,
                  let base = number(offset + 12, 5), base >= 25, base < length,
                  let lengthSize = number(offset + 20, 1), lengthSize > 0,
                  let positionSize = number(offset + 21, 1), positionSize > 0,
                  let tagSize = number(offset + 23, 1), tagSize > 0 else {
                throw OfflineENCImportError.malformedArchive("invalid CATALOG.031 record")
            }
            // The descriptive record defines fields, rather than chart extents.
            if bytes[offset + 6] != 76 {
                let stride = tagSize + lengthSize + positionSize
                var directory = offset + 24
                while directory < offset + base - 1 {
                    guard directory + stride <= offset + base - 1,
                          let fieldLength = number(directory + tagSize, lengthSize), fieldLength > 0,
                          let position = number(directory + tagSize + lengthSize, positionSize), position >= 0,
                          base + position + fieldLength <= length else {
                        throw OfflineENCImportError.malformedArchive("invalid CATALOG.031 field bounds")
                    }
                    let tag = String(decoding: bytes[directory..<directory + tagSize], as: UTF8.self)
                    if tag == "CATD" {
                        let start = offset + base + position
                        let payload = Array(bytes[start..<start + fieldLength])
                        guard payload.count >= 13 else { throw OfflineENCImportError.malformedArchive("short CATD field") }
                        let fields = payload.dropFirst(12).split(separator: 31, omittingEmptySubsequences: false)
                            .map { String(decoding: $0, as: UTF8.self) }
                        if fields.count >= 7, fields[0].lowercased().hasSuffix(".000"), fields[3].hasPrefix("BIN"),
                           let south = Double(fields[3].dropFirst(3)), let west = Double(fields[4]),
                           let north = Double(fields[5]), let east = Double(fields[6]),
                           west < east, south < north, west >= -180, east <= 180, south >= -90, north <= 90 {
                            let filename = fields[0].replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
                            result[String(filename.dropLast(4))] = OfflineENCBounds(west: west, south: south, east: east, north: north)
                        }
                    }
                    directory += stride
                }
            }
            offset += length
        }
        return result
    }

    private static func catalogueBounds(in data: Data, files: [Entry]) throws -> [String: OfflineENCBounds] {
        guard let entry = files.first(where: { URL(fileURLWithPath: $0.name).lastPathComponent.uppercased() == "CATALOG.031" }) else { return [:] }
        return try readCatalogueBounds(contents(of: entry, in: data))
    }

    private static func collectionInfo(in data: Data, files: [Entry]) throws -> [String: (title: String, bounds: OfflineENCBounds?)] {
        guard let csv = files.first(where: {
            let name = URL(fileURLWithPath: $0.name).lastPathComponent.lowercased()
            return name.hasPrefix("chs_collections_encs57_") && name.hasSuffix(".csv")
        }) else { return [:] }
        guard csv.uncompressedSize <= 2 * 1024 * 1024 else { throw OfflineENCImportError.tooLarge }
        let bytes = try contents(of: csv, in: data)
        let text = String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
        let rows = parseCSV(text)
        guard let header = rows.first else { return [:] }
        // A vendor catalogue can contain duplicate/blank headings. Avoid the
        // Dictionary(uniqueKeysWithValues:) precondition, which would terminate
        // the app while scanning an otherwise valid exchange set.
        var columns: [String: Int] = [:]
        for (index, heading) in header.enumerated() {
            let key = heading.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, columns[key] == nil { columns[key] = index }
        }
        guard let collectionColumn = columns["Collection"], let nameColumn = columns["Name"],
              let titleColumn = columns["Title"], let southColumn = columns["SLAT"],
              let westColumn = columns["WLON"], let northColumn = columns["NLAT"],
              let eastColumn = columns["ELON"] else { return [:] }
        var result: [String: (title: String, bounds: OfflineENCBounds?)] = [:]
        for row in rows.dropFirst() where row.count > max(nameColumn, titleColumn) {
            guard row.count > max(collectionColumn, max(southColumn, max(westColumn, max(northColumn, eastColumn)))) else { continue }
            let collection = row[collectionColumn].trimmingCharacters(in: .whitespacesAndNewlines)
            guard collection.caseInsensitiveCompare("Cancel_Annuler") != .orderedSame else { continue }
            let cell = row[nameColumn].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = row[titleColumn].trimmingCharacters(in: .whitespacesAndNewlines)
            if !cell.isEmpty, !title.isEmpty {
                let south = Double(row[southColumn]), west = Double(row[westColumn])
                let north = Double(row[northColumn]), east = Double(row[eastColumn])
                let bounds: OfflineENCBounds?
                if let south, let west, let north, let east, west < east, south < north,
                   (-180...180).contains(west), (-180...180).contains(east),
                   (-90...90).contains(south), (-90...90).contains(north) {
                    bounds = OfflineENCBounds(west: west, south: south, east: east, north: north)
                } else {
                    bounds = nil
                }
                result[cell] = (title, bounds)
            }
        }
        return result
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        let characters = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty:
                    quoted = true
                case ",":
                    row.append(field); field = ""
                case "\r", "\n", "\r\n":
                    row.append(field); field = ""
                    if !row.allSatisfy(\.isEmpty) { rows.append(row) }
                    row = []
                    if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                default:
                    field.append(character)
                }
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !row.allSatisfy(\.isEmpty) { rows.append(row) }
        }
        return rows
    }

    fileprivate static func isActiveCellPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map { $0.lowercased() }
        return components.contains("enc_root") && !components.contains("cancel_annuler")
    }

    static func entries(in data: Data) throws -> [Entry] {
        guard data.count <= maxArchiveBytes else { throw OfflineENCImportError.tooLarge }
        guard data.count >= 22 else { throw OfflineENCImportError.malformedArchive("end record is missing") }
        let start = max(0, data.count - 65_557)
        var eocd: Int?
        for offset in stride(from: data.count - 22, through: start, by: -1) where u32(data, offset) == 0x06054b50 {
            let commentLength = Int(u16(data, offset + 20))
            if offset + 22 + commentLength == data.count { eocd = offset; break }
        }
        guard let end = eocd else { throw OfflineENCImportError.malformedArchive("end record was not found") }
        guard u16(data, end + 4) == 0, u16(data, end + 6) == 0,
              u16(data, end + 8) == u16(data, end + 10) else {
            throw OfflineENCImportError.malformedArchive("multi-volume archives are not supported")
        }
        let count = Int(u16(data, end + 10)), centralSize = Int(u32(data, end + 12)), centralOffset = Int(u32(data, end + 16))
        guard count != 0xffff, centralSize != Int(UInt32.max), centralOffset != Int(UInt32.max) else {
            throw OfflineENCImportError.malformedArchive("ZIP64 is not supported in this prototype")
        }
        guard count <= maxEntries, centralOffset >= 0, centralSize >= 0,
              centralOffset + centralSize <= end else {
            throw OfflineENCImportError.malformedArchive("central directory bounds are invalid")
        }
        var result: [Entry] = []
        var seen = Set<String>()
        var offset = centralOffset
        var expandedTotal = 0
        for _ in 0..<count {
            guard offset + 46 <= centralOffset + centralSize, u32(data, offset) == 0x02014b50 else {
                throw OfflineENCImportError.malformedArchive("central directory entry is invalid")
            }
            let flags = u16(data, offset + 8), method = u16(data, offset + 10)
            let compressed = u32(data, offset + 20), expanded = u32(data, offset + 24)
            let nameLength = Int(u16(data, offset + 28)), extraLength = Int(u16(data, offset + 30)), commentLength = Int(u16(data, offset + 32))
            let disk = u16(data, offset + 34), external = u32(data, offset + 38), local = u32(data, offset + 42)
            let endOfEntry = offset + 46 + nameLength + extraLength + commentLength
            guard endOfEntry <= centralOffset + centralSize, disk == 0 else {
                throw OfflineENCImportError.malformedArchive("central directory entry is truncated or spans disks")
            }
            guard compressed != UInt32.max, expanded != UInt32.max, local != UInt32.max else {
                throw OfflineENCImportError.malformedArchive("ZIP64 entries are not supported")
            }
            let rawName = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            guard let name = String(data: rawName, encoding: .utf8), isSafePath(name) else {
                throw OfflineENCImportError.unsafeArchiveEntry(String(decoding: rawName, as: UTF8.self))
            }
            guard seen.insert(name).inserted else { throw OfflineENCImportError.unsafeArchiveEntry("duplicate entry \(name)") }
            if flags & (0x0001 | 0x0040) != 0 { throw OfflineENCImportError.encryptedArchive }
            let unixMode = external >> 16
            if (unixMode & 0xF000) == 0xA000 { throw OfflineENCImportError.unsafeArchiveEntry("symbolic link \(name)") }
            guard method == 0 || method == 8 else { throw OfflineENCImportError.unsupportedCompression }
            guard expanded <= maxEntryBytes, compressed <= maxArchiveBytes else { throw OfflineENCImportError.tooLarge }
            expandedTotal += Int(expanded)
            guard expandedTotal <= maxExpandedBytes else { throw OfflineENCImportError.tooLarge }
            result.append(Entry(name: name, flags: flags, method: method, crc: u32(data, offset + 16),
                                compressedSize: compressed, uncompressedSize: expanded, localOffset: local,
                                isDirectory: name.hasSuffix("/")))
            offset = endOfEntry
        }
        guard offset == centralOffset + centralSize else { throw OfflineENCImportError.malformedArchive("central directory size does not match") }
        return result
    }

    static func orderedUpdateSequence(baseCellFilename: String, entryNames: [String]) throws -> [String] {
        let file = URL(fileURLWithPath: baseCellFilename).lastPathComponent
        let stem = String(file.dropLast(4)).lowercased()
        let pairs = entryNames.compactMap { name -> (Int, String)? in
            let candidate = URL(fileURLWithPath: name).lastPathComponent
            guard candidate.lowercased().hasPrefix(stem + "."), candidate.count == stem.count + 4,
                  let number = Int(candidate.suffix(3)), number > 0 else { return nil }
            return (number, name)
        }.sorted { $0.0 < $1.0 }
        for (index, item) in pairs.enumerated() where item.0 != index + 1 {
            throw OfflineENCImportError.missingUpdate(String(format: "%@.%03d", stem, index + 1))
        }
        return pairs.map(\.1)
    }

    static func contents(of entry: Entry, in data: Data) throws -> Data {
        let local = Int(entry.localOffset)
        guard local + 30 <= data.count, u32(data, local) == 0x04034b50 else {
            throw OfflineENCImportError.malformedArchive("local file header is invalid for \(entry.name)")
        }
        let nameLength = Int(u16(data, local + 26)), extraLength = Int(u16(data, local + 28))
        let payloadStart = local + 30 + nameLength + extraLength
        let payloadEnd = payloadStart + Int(entry.compressedSize)
        guard payloadStart >= local, payloadEnd <= data.count else {
            throw OfflineENCImportError.malformedArchive("payload bounds are invalid for \(entry.name)")
        }
        let compressed = data.subdata(in: payloadStart..<payloadEnd)
        let output: Data
        if entry.method == 0 {
            guard compressed.count == entry.uncompressedSize else { throw OfflineENCImportError.malformedArchive("stored size mismatch for \(entry.name)") }
            output = compressed
        } else {
            let outputSize = Int(entry.uncompressedSize)
            var decoded = Data(count: outputSize)
            let result = compressed.withUnsafeBytes { source in
                decoded.withUnsafeMutableBytes { destination in
                    aw_inflate_raw(source.bindMemory(to: UInt8.self).baseAddress, UInt32(compressed.count),
                                   destination.bindMemory(to: UInt8.self).baseAddress, UInt32(outputSize))
                }
            }
            guard result == 0 else { throw OfflineENCImportError.malformedArchive("deflate failed for \(entry.name)") }
            output = decoded
        }
        let checksum = output.withUnsafeBytes { aw_crc32($0.bindMemory(to: UInt8.self).baseAddress, UInt32(output.count)) }
        guard checksum == entry.crc else { throw OfflineENCImportError.malformedArchive("checksum mismatch for \(entry.name)") }
        return output
    }

    private static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != ".." && $0 != "." }
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

@MainActor
final class OfflineENCStore: ObservableObject {
    @Published private(set) var charts: [OfflineENCChart] = []
    @Published private(set) var collections: [OfflineENCCollection] = []
    @Published private(set) var selectedChartID: String?
    private let fileManager = FileManager.default
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ExperimentalENC", isDirectory: true)
        load()
        Task { [weak self] in
            await self?.indexPreviouslyImportedCollections()
            await self?.refreshSoundingDatums()
        }
    }

    var selectedChart: OfflineENCChart? { charts.first { $0.id == selectedChartID } }

    /// Read local supporting text only; no URL fetching or external path resolution.
    func supportingText(named name: String, chart: OfflineENCChart) async -> String {
        let root = self.root
        return await Task.detached(priority: .utility) {
            do {
                guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name.lowercased().hasSuffix(".txt") else {
                    return "Unsupported supporting-file reference: " + name
                }
                let data = try Data(contentsOf: root.appendingPathComponent(chart.sha256).appendingPathComponent("original.zip"))
                let entries = try OfflineENCZip.entries(in: data).filter { !$0.isDirectory && URL(fileURLWithPath: $0.name).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
                let cellEntries = entries.filter { URL(fileURLWithPath: $0.name).deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare(chart.metadata.cellID) == .orderedSame }
                let candidates = cellEntries.isEmpty ? entries : cellEntries
                guard candidates.count == 1, let entry = candidates.first else { return "Supporting text is missing or ambiguous in this exchange set: " + name }
                guard entry.uncompressedSize <= 256 * 1024 else { return "Supporting text exceeds the display limit: " + name }
                let bytes = try OfflineENCZip.contents(of: entry, in: data)
                return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? "Supporting text could not be decoded."
            } catch { return "Supporting text unavailable: " + error.localizedDescription }
        }.value
    }

    func select(_ chart: OfflineENCChart) { selectedChartID = chart.id }

    func registerCollection(_ data: Data, filename: String, source: OfflineENCImportSource,
                            candidates: [OfflineENCZip.CellCandidate]) async throws -> OfflineENCCollection {
        let root = self.root
        let collection = try await Task.detached(priority: .userInitiated) {
            try OfflineENCImportWorker.registerCollection(data, filename: filename, source: source,
                                                          candidates: candidates, root: root)
        }.value
        if let index = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[index] = collection
        } else {
            collections.append(collection)
        }
        return collection
    }

    func importCell(_ candidate: OfflineENCZip.CellCandidate, from collection: OfflineENCCollection,
                    data: Data) async throws -> OfflineENCChart {
        let root = self.root
        let chart = try await Task.detached(priority: .userInitiated) {
            try OfflineENCImportWorker.importCell(data, collection: collection, candidate: candidate, root: root)
        }.value
        cache(chart)
        return chart
    }

    func importCell(_ candidate: OfflineENCZip.CellCandidate, from collection: OfflineENCCollection, select: Bool = true) async throws -> OfflineENCChart {
        let root = self.root
        let chart = try await Task.detached(priority: .userInitiated) {
            try OfflineENCImportWorker.importCell(from: collection, candidate: candidate, root: root)
        }.value
        cache(chart, select: select)
        return chart
    }

    func packageCell(_ candidate: OfflineENCZip.CellCandidate, from collection: OfflineENCCollection,
                     viewport: OfflineENCBounds? = nil, overview: Bool = false) async throws -> (chart: OfflineENCChart, bounds: [String: OfflineENCBounds], estimatedBytes: Int) {
        let root = self.root
        let worker = Task.detached(priority: .utility) {
            try await OfflineENCViewportReader.shared.read(candidate, collection: collection, root: root,
                                                         viewport: viewport, overview: overview)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private func cache(_ chart: OfflineENCChart, select: Bool = true) {
        if let index = charts.firstIndex(where: { $0.id == chart.id }) { charts[index] = chart }
        else { charts.append(chart) }
        if select { selectedChartID = chart.id }
    }

    func load() {
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { charts = []; collections = []; return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        collections = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("collection.json")),
                  let collection = try? decoder.decode(OfflineENCCollection.self, from: data) else { return nil }
            return collection
        }.sorted { $0.importedAt > $1.importedAt }
        charts = folders.flatMap { folder -> [OfflineENCChart] in
            let cellsFolder = folder.appendingPathComponent("cells", isDirectory: true)
            guard let cellFolders = try? fileManager.contentsOfDirectory(at: cellsFolder, includingPropertiesForKeys: nil) else {
                // Read the previous single-chart cache format for existing imports.
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("chart.json")),
                      let chart = try? decoder.decode(OfflineENCChart.self, from: data) else { return [] }
                return [chart]
            }
            return cellFolders.compactMap { cellFolder in
                guard let data = try? Data(contentsOf: cellFolder.appendingPathComponent("chart.json")),
                      let chart = try? decoder.decode(OfflineENCChart.self, from: data) else { return nil }
                return chart
            }
        }.sorted { $0.importedAt > $1.importedAt }
        if selectedChartID == nil || !charts.contains(where: { $0.id == selectedChartID }) { selectedChartID = charts.first?.id }
    }

    /// Rebuild old decoded caches from their retained source, preserving selection.
    private func refreshSoundingDatums() async {
        for chart in charts where chart.metadata.soundingDatumCode == nil || chart.metadata.heightUnitCode == nil {
            guard let collection = collections.first(where: { $0.sha256 == chart.sha256 }),
                  let cell = collection.cells.first(where: { $0.cellID == chart.metadata.cellID }) else { continue }
            _ = try? await importCell(cell, from: collection, select: false)
        }
    }

    /// Upgrades archives retained by the earlier single-cell importer so they
    /// appear in the collection browser without asking the user to pick them again.
    private func indexPreviouslyImportedCollections() async {
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // Existing indexes may have been created without the optional CSV. Repair
        // their extents from the retained archive, without reimporting chart data.
        for collection in collections where collection.cells.contains(where: { $0.bounds == nil }) {
            let root = self.root
            do {
                let repaired = try await Task.detached(priority: .utility) {
                    let folder = root.appendingPathComponent(collection.sha256)
                    let data = try Data(contentsOf: folder.appendingPathComponent("original.zip"), options: .mappedIfSafe)
                    let candidates = try OfflineENCZip.cellCandidates(in: data)
                    let updated = OfflineENCCollection(sourceName: collection.sourceName, originalFilename: collection.originalFilename,
                        sha256: collection.sha256, importedAt: collection.importedAt, cells: candidates)
                    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(updated).write(to: folder.appendingPathComponent("collection.json"), options: .atomic)
                    return updated
                }.value
                if let index = collections.firstIndex(where: { $0.id == repaired.id }) { collections[index] = repaired }
            } catch {
                // Preserve the usable chart library if its original archive is unavailable.
            }
        }
        for folder in folders where !fileManager.fileExists(atPath: folder.appendingPathComponent("collection.json").path) {
            let archiveURL = folder.appendingPathComponent("original.zip")
            guard fileManager.fileExists(atPath: archiveURL.path),
                  let existingChartData = try? Data(contentsOf: folder.appendingPathComponent("chart.json")),
                  let existingChart = try? decoder.decode(OfflineENCChart.self, from: existingChartData) else { continue }
            do {
                let (data, candidates) = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
                    return (data, try OfflineENCZip.cellCandidates(in: data))
                }.value
                let source: OfflineENCImportSource = existingChart.sourceName.localizedCaseInsensitiveContains("NOAA") ? .noaa :
                    (existingChart.sourceName.localizedCaseInsensitiveContains("CHS") ? .chs : .other)
                _ = try await registerCollection(data, filename: existingChart.originalFilename,
                                                 source: source, candidates: candidates)
            } catch {
                // Keep the legacy cell available even if its original archive
                // cannot be indexed; the existing chart cache remains usable.
            }
        }
    }
}

/// Runs ZIP validation, S-57 decode, and cache writes away from the main actor so large
/// exchange sets do not block navigation or make the app appear hung.
private enum OfflineENCImportWorker {
    static func registerCollection(_ data: Data, filename: String, source: OfflineENCImportSource,
                                   candidates: [OfflineENCZip.CellCandidate], root: URL) throws -> OfflineENCCollection {
        guard data.count <= OfflineENCZip.maxArchiveBytes else { throw OfflineENCImportError.tooLarge }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let folder = root.appendingPathComponent(digest, isDirectory: true)
        let indexURL = folder.appendingPathComponent("collection.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let saved = try? Data(contentsOf: indexURL), let collection = try? decoder.decode(OfflineENCCollection.self, from: saved) {
            return collection
        }
        var sourceName = source.rawValue
        if source == .chs && candidates.contains(where: { $0.cellID.uppercased().contains("9995") }) {
            sourceName = "CHS Chart 9995 · fictitious sample · NOT FOR NAVIGATION"
        }
        let collection = OfflineENCCollection(sourceName: sourceName, originalFilename: filename, sha256: digest,
                                              importedAt: Date(), cells: candidates)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let archiveURL = folder.appendingPathComponent("original.zip")
            if !FileManager.default.fileExists(atPath: archiveURL.path) { try data.write(to: archiveURL, options: .atomic) }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(collection).write(to: indexURL, options: .atomic)
            return collection
        } catch {
            throw OfflineENCImportError.cache(error.localizedDescription)
        }
    }

    static func importCell(from collection: OfflineENCCollection, candidate: OfflineENCZip.CellCandidate,
                           root: URL, cacheFolderName: String = "cells") throws -> OfflineENCChart {
        let archiveURL = root.appendingPathComponent(collection.sha256, isDirectory: true).appendingPathComponent("original.zip")
        let data: Data
        do { data = try Data(contentsOf: archiveURL, options: .mappedIfSafe) }
        catch { throw OfflineENCImportError.cache("The retained exchange set could not be read: \(error.localizedDescription)") }
        return try importCell(data, collection: collection, candidate: candidate, root: root, cacheFolderName: cacheFolderName)
    }

    static func importCell(_ data: Data, collection: OfflineENCCollection,
                           candidate: OfflineENCZip.CellCandidate, root: URL, cacheFolderName: String = "cells") throws -> OfflineENCChart {
        guard data.count <= OfflineENCZip.maxArchiveBytes else { throw OfflineENCImportError.tooLarge }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == collection.sha256,
              collection.cells.contains(where: { $0.path == candidate.path && $0.cellID == candidate.cellID }) else {
            throw OfflineENCImportError.invalidUpdate("the selected cell does not belong to this retained exchange set")
        }
        let packageFolder = root.appendingPathComponent(digest, isDirectory: true)
        let cellCacheName = SHA256.hash(data: Data(candidate.cellID.utf8)).map { String(format: "%02x", $0) }.joined()
        let cellFolder = packageFolder.appendingPathComponent(cacheFolderName, isDirectory: true).appendingPathComponent(cellCacheName, isDirectory: true)
        let cachedChartURL = cellFolder.appendingPathComponent("chart.json")
        let cachedDecoder = JSONDecoder(); cachedDecoder.dateDecodingStrategy = .iso8601
        if let cachedData = try? Data(contentsOf: cachedChartURL),
           let cachedChart = try? cachedDecoder.decode(OfflineENCChart.self, from: cachedData),
           cachedChart.metadata.soundingDatumCode != nil, cachedChart.metadata.heightUnitCode != nil {
            return cachedChart
        }
        let entries = try OfflineENCZip.entries(in: data).filter { !$0.isDirectory }
        guard entries.contains(where: { URL(fileURLWithPath: $0.name).lastPathComponent.uppercased() == "CATALOG.031" }) else {
            throw OfflineENCImportError.missingCatalog
        }
        let cells = entries.filter { $0.name.lowercased().hasSuffix(".000") && OfflineENCZip.isActiveCellPath($0.name) }
        guard !cells.isEmpty else { throw OfflineENCImportError.noBaseCell }
        guard let baseEntry = cells.first(where: { $0.name == candidate.path }) else {
            throw OfflineENCImportError.invalidUpdate("the selected chart cell is not an active base cell in this exchange set")
        }
        let baseName = URL(fileURLWithPath: baseEntry.name).lastPathComponent
        let updateNames = try OfflineENCZip.orderedUpdateSequence(baseCellFilename: baseName, entryNames: entries.map(\.name))
        let updateEntries = try updateNames.map { name -> OfflineENCZip.Entry in
            guard let entry = entries.first(where: { $0.name == name }) else { throw OfflineENCImportError.invalidUpdate("update entry disappeared") }
            return entry
        }
        let base = try OfflineENCZip.contents(of: baseEntry, in: data)
        let updates = try updateEntries.map { try OfflineENCZip.contents(of: $0, in: data) }
        let parsed = try OfflineS57Decoder().decode(base: base, updates: updates)
        let cellID = URL(fileURLWithPath: parsed.metadata.name).deletingPathExtension().lastPathComponent
        let chart = OfflineENCChart(sourceName: collection.sourceName, originalFilename: collection.originalFilename, sha256: digest, importedAt: Date(),
                                    metadata: OfflineENCMetadata(cellID: cellID, edition: parsed.metadata.edition,
                                        update: parsed.metadata.update, updateDate: parsed.metadata.updateDate,
                                        issueDate: parsed.metadata.issueDate, exchangeStandard: String(format: "%.1f", parsed.metadata.exchangeStandard),
                                        compilationScale: parsed.metadata.scale, depthUnitCode: parsed.metadata.depthUnitCode,
                                        verticalDatumCode: parsed.metadata.verticalDatumCode, horizontalDatumCode: parsed.metadata.horizontalDatumCode,
                                        catalogPresent: true, updateFilesApplied: updateEntries.map { URL(fileURLWithPath: $0.name).lastPathComponent },
                                        soundingDatumCode: parsed.metadata.soundingDatumCode, heightUnitCode: parsed.metadata.heightUnitCode),
                                    features: parsed.features)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cellFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(chart).write(to: cachedChartURL, options: .atomic)
            return chart
        } catch {
            throw OfflineENCImportError.cache(error.localizedDescription)
        }
    }
}

private struct DecodedOfflineENC: Decodable {
    struct Metadata: Decodable {
        let name: String; let edition: String; let update: String; let updateDate: String; let issueDate: String
        let exchangeStandard: Double; let scale: Int; let depthUnitCode: Int; let heightUnitCode: Int; let soundingDatumCode: Int; let verticalDatumCode: Int; let horizontalDatumCode: Int
    }
    struct Feature: Decodable {
        struct Geometry: Decodable { let type: String; let coordinates: OfflineJSONValue }
        let geometry: Geometry?
        let attributes: [String: String]
        let soundingDepths: [Double]?
    }
    let ok: Bool; let error: String?; let metadata: Metadata?; let features: [Feature]?
}

private final class OfflineS57Decoder {
    func decode(base: Data, updates: [Data]) throws -> (metadata: DecodedOfflineENC.Metadata, features: [OfflineENCFeature]) {
        guard let bundleURL = Bundle.main.url(forResource: "anchorwatch-s57-bridge", withExtension: "js"),
              let script = try? String(contentsOf: bundleURL, encoding: .utf8),
              let context = JSContext() else { throw OfflineENCImportError.decoderUnavailable }
        context.exceptionHandler = { _, exception in _ = exception?.toString() }
        context.evaluateScript(script)
        guard let function = context.objectForKeyedSubscript("anchorWatchDecode"), !function.isUndefined else {
            throw OfflineENCImportError.decoderUnavailable
        }
        let updatePayload = try JSONSerialization.data(withJSONObject: updates.map { $0.base64EncodedString() })
        guard let updateJSON = String(data: updatePayload, encoding: .utf8),
              let response = function.call(withArguments: [base.base64EncodedString(), updateJSON])?.toString(),
              let data = response.data(using: .utf8), let decoded = try? JSONDecoder().decode(DecodedOfflineENC.self, from: data) else {
            throw OfflineENCImportError.decoder("decoder returned an unreadable result")
        }
        guard decoded.ok, let metadata = decoded.metadata, let features = decoded.features else {
            throw OfflineENCImportError.unsupportedChart(decoded.error ?? "cell is not a supported unencrypted S-57 ENC")
        }
        guard metadata.scale > 0, (1...3).contains(metadata.depthUnitCode) else {
            throw OfflineENCImportError.decoder("chart scale or depth units are missing or invalid")
        }
        let chartFeatures = features.map { item in
            OfflineENCFeature(geometryType: item.geometry?.type, coordinates: item.geometry?.coordinates,
                             attributes: item.attributes, soundingDepths: item.soundingDepths ?? [])
        }
        if chartFeatures.isEmpty { throw OfflineENCImportError.decoder("cell contains no features") }
        return (metadata, chartFeatures)
    }
}

/// A viewport working set; original exchange sets and prepared cells stay on disk.
/// Keeping this separate from the manually selected library prevents a package
/// browse from changing the active cell or loading every decoded cell into RAM.
@MainActor
final class OfflineENCPackageSession: ObservableObject {
    @Published private(set) var cells: [OfflineENCChart] = []
    @Published private(set) var featureBounds: [String: [String: OfflineENCBounds]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var status = ""
    @Published private(set) var failures: [String] = []
    @Published private(set) var memorySummary = ""
    @Published private(set) var revision = UUID()
    private(set) var rasterIdentity = ""
    private var generation = UUID()

    func reset() {
        generation = UUID(); revision = UUID(); rasterIdentity = ""
        cells = []; featureBounds = [:]; failures = []; status = ""; isLoading = false; memorySummary = ""
    }

    func load(_ candidates: [OfflineENCZip.CellCandidate], collection: OfflineENCCollection,
              store: OfflineENCStore, viewport: OfflineENCBounds? = nil, overview: Bool = false,
              overviewCellIDs: Set<String> = []) async {
        guard !Task.isCancelled else { return }
        let token = UUID(); generation = token
        isLoading = true
        defer { if generation == token { isLoading = false } }
        // Cached images cover the transition; release the old vector window first.
        cells = []; featureBounds = [:]; failures = []; rasterIdentity = ""
        var estimatedBytes = 0
        for (index, candidate) in candidates.enumerated() {
            guard !Task.isCancelled, generation == token else { return }
            status = "Preparing visible chart data \(index + 1)/\(candidates.count) · \(candidate.cellID)"
            do {
                let prepared = try await store.packageCell(candidate, from: collection, viewport: viewport,
                                                           overview: overview || overviewCellIDs.contains(candidate.cellID))
                guard !Task.isCancelled, generation == token else { return }
                featureBounds[prepared.chart.id] = prepared.bounds
                cells.append(prepared.chart)
                estimatedBytes += prepared.estimatedBytes
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                failures.append("\(candidate.cellID): \(error.localizedDescription)")
            }
        }
        guard !Task.isCancelled, generation == token else { return }
        cells.sort {
            $0.metadata.compilationScale == $1.metadata.compilationScale
                ? $0.metadata.cellID < $1.metadata.cellID
                : $0.metadata.compilationScale > $1.metadata.compilationScale
        }
        rasterIdentity = OfflineENCRasterIdentity.make(viewport: viewport, overview: overview,
            overviewCellIDs: overviewCellIDs,
            cellVersions: cells.map { "\($0.id):\($0.metadata.edition):\($0.metadata.update)" })
        revision = UUID()
        status = "\(cells.count) visible cells ready" + (failures.isEmpty ? " · local/offline" : " · \(failures.count) failed")
        memorySummary = "Visible chart data estimate: \(estimatedBytes / 1_048_576) MB"
        if estimatedBytes > 64 * 1024 * 1024 { memorySummary += " · Dense view—zoom in to reduce memory" }
        let missing = cells.reduce(0) { $0 + $1.unportrayedFeatureCount }
        if missing > 0 { status += " · \(missing) visible features not portrayed" }
    }
}

/// Identity of the actual decoded window, not a load attempt. Exact bounds are intentional:
/// viewport readers clip geometry, so adjacent windows must never share a scene accidentally.
enum OfflineENCRasterIdentity {
    static func make(viewport: OfflineENCBounds?, overview: Bool,
                     overviewCellIDs: Set<String>, cellVersions: [String]) -> String {
        "window-v1:\(String(describing: viewport)):\(overview):" +
            overviewCellIDs.sorted().joined(separator: ";") + ":" + cellVersions.sorted().joined(separator: ";")
    }
}

extension OfflineENCFeature {
    var portrayalOrder: Int {
        switch objectClass {
        case 42: return 0
        case 71: return 1
        case 13, 69, 72, 73, 114, 116, 119, 126, 43: return 2
        case 30: return 3
        case 20, 121: return 4
        case 1, 3, 4, 27, 138, 112: return 5
        case 21, 22, 53, 104: return 6
        case 129: return 7
        default: return 8
        }
    }
}

/// Progressive detail thresholds in approximate ground metres across the viewport.
/// S-57 filename usage bands keep harbour cells out of regional-scale views.
enum OfflineENCPackagePolicy {
    static let workingSetLimit = 16
    static func validOverviewDistance(_ metres: Double) -> Double {
        [3_000.0, 6_000, 12_000, 24_000].contains(metres) ? metres : 6_000
    }
    static func maximumUsageBand(metresAcross: Double, overviewDistance: Double = 6_000) -> Int {
        let metresAcross = metresAcross * 6_000 / validOverviewDistance(overviewDistance)
        if metresAcross > 60_000 { return 2 }
        if metresAcross > 20_000 { return 3 }
        if metresAcross > 6_000 { return 4 }
        if metresAcross > 1_000 { return 5 }
        return 6
    }
    /// Overview is deliberately a context map, not a full navigation portrayal.
    static func isOverview(metresAcross: Double, overviewDistance: Double = 6_000) -> Bool {
        metresAcross > validOverviewDistance(overviewDistance)
    }
    static func showsInOverview(objectClass: Int) -> Bool {
        // Coastline, depth areas/contours and land only. Avoid dense point marks.
        [30, 42, 43, 71].contains(objectClass)
    }
    static func usageBand(cellID: String) -> Int? {
        guard cellID.count >= 3, let band = Int(String(cellID.dropFirst(2).prefix(1))), (1...6).contains(band) else { return nil }
        return band
    }
}

/// Screen-independent addresses at half-octave zoom levels. The tile edge is
/// divisible by all portrayal decluttering grids (8, 12, 18) to avoid grid seams.
struct OfflineENCTileAddress: Hashable, Sendable {
    static let side: CGFloat = 216
    let level: Int
    let x: Int
    let y: Int
    var zoom: CGFloat { pow(2, CGFloat(level) / 2) }
    static func visible(size: CGSize, zoom: CGFloat, pan: CGSize) -> [Self] {
        guard size.width > 0, size.height > 0, zoom.isFinite, zoom > 0,
              pan.width.isFinite, pan.height.isFinite else { return [] }
        let level = Int(floor(log2(zoom) * 2))
        let ratio = zoom / pow(2, CGFloat(level) / 2)
        let span = side * ratio
        let minX = Int(floor((-size.width / 2 - pan.width) / span))
        let maxX = Int(floor((size.width / 2 - pan.width) / span))
        let minY = Int(floor((-size.height / 2 - pan.height) / span))
        let maxY = Int(floor((size.height / 2 - pan.height) / span))
        guard maxX - minX < 16, maxY - minY < 16 else { return [] }
        let centreX = -pan.width / span, centreY = -pan.height / span
        return (minX...maxX).flatMap { x in (minY...maxY).map { Self(level: level, x: x, y: $0) } }
            .sorted {
                let a = hypot(CGFloat($0.x) + 0.5 - centreX, CGFloat($0.y) + 0.5 - centreY)
                let b = hypot(CGFloat($1.x) + 0.5 - centreX, CGFloat($1.y) + 0.5 - centreY)
                return a == b ? ($0.y == $1.y ? $0.x < $1.x : $0.y < $1.y) : a < b
            }
    }
    func screenRect(size: CGSize, liveZoom: CGFloat, pan: CGSize) -> CGRect {
        let span = Self.side * liveZoom / zoom
        return CGRect(x: size.width / 2 + pan.width + CGFloat(x) * span,
                      y: size.height / 2 + pan.height + CGFloat(y) * span, width: span, height: span)
    }
}

/// Conservative admission estimate for retained decoded geometry plus its bounds index.
/// This does not cap decoder temporaries, UI/GPU allocations or total process RSS.
struct OfflineENCWorkingSetBudget {
    let limit: Int
    private var costs: [String: Int] = [:]
    init(limit: Int = 64 * 1024 * 1024) { self.limit = max(0, limit) }
    var usedBytes: Int { costs.values.reduce(0, +) }
    func canFit(_ bytes: Int) -> Bool { bytes >= 0 && bytes <= limit - usedBytes }
    mutating func admit(_ id: String, bytes: Int) -> Bool {
        guard bytes >= 0, bytes <= limit - usedBytes + (costs[id] ?? 0) else { return false }
        costs[id] = bytes; return true
    }
    mutating func retain(_ ids: Set<String>) { costs = costs.filter { ids.contains($0.key) } }
    mutating func removeAll() { costs.removeAll() }
    static func estimate(_ chart: OfflineENCChart) -> Int {
        // Factor two allows for allocator capacity/slack; per-feature allowance includes bounds/index keys.
        2 * (1024 + chart.features.reduce(0) { total, feature in
            total + 512 + feature.soundingDepths.count * 8 + (feature.coordinates?.estimatedStorageBytes ?? 0)
                + feature.attributes.reduce(0) { $0 + 128 + $1.key.utf8.count + $1.value.utf8.count }
        })
    }
}

extension OfflineJSONValue {
    var estimatedStorageBytes: Int {
        let own = MemoryLayout<OfflineJSONValue>.stride
        switch self {
        case .array(let items): return own + 64 + items.reduce(0) { $0 + $1.estimatedStorageBytes }
        case .object(let items): return own + 128 + items.reduce(0) { $0 + 128 + $1.key.utf8.count + $1.value.estimatedStorageBytes }
        case .string(let text): return own + 32 + text.utf8.count
        default: return own
        }
    }
}

/// Immutable feature records permit viewport reads without decoding the entire cell.
/// Large base geometry is streamed through a bounded clipping pipeline.
struct OfflineENCFeatureIndex: Codable {
    struct Record: Codable {
        let offset: UInt64
        let length: Int
        let objectClass: Int
        let bounds: OfflineENCBounds?
        var geometry: [[[Chunk]]]? = nil // polygons → rings → disk chunks
    }
    struct Chunk: Codable {
        let offset: UInt64
        let length: Int
        let count: Int
    }
    let chart: OfflineENCChart // metadata/provenance only, no feature geometry
    let records: [Record]
    let byteCount: UInt64

    static func intersects(_ a: OfflineENCBounds, _ b: OfflineENCBounds) -> Bool {
        a.west <= b.east && a.east >= b.west && a.south <= b.north && a.north >= b.south
    }
    static func featureBounds(_ feature: OfflineENCFeature) -> OfflineENCBounds? {
        let points = feature.chartCoordinates()
        guard let first = points.first else { return nil }
        var west = first.longitude, east = west, south = first.latitude, north = south
        for point in points.dropFirst() {
            west = min(west, point.longitude); east = max(east, point.longitude)
            south = min(south, point.latitude); north = max(north, point.latitude)
        }
        return .init(west: west, south: south, east: east, north: north)
    }
    static func build(chart: OfflineENCChart, directory: URL) throws {
        let manager = FileManager.default
        let temporary = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("features.bin")
        manager.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var records: [Record] = [], offset: UInt64 = 0
        for feature in chart.features {
            try Task.checkCancellation()
            try autoreleasepool {
                let groups = OfflineENCGeometryStream.groups(feature)
                let stored = groups == nil ? feature : OfflineENCFeature(geometryType: feature.geometryType,
                    coordinates: nil, attributes: feature.attributes, soundingDepths: feature.soundingDepths)
                let data = try encoder.encode(stored)
                try handle.write(contentsOf: data)
                var record = Record(offset: offset, length: data.count, objectClass: feature.objectClass,
                                    bounds: featureBounds(feature))
                offset += UInt64(data.count)
                if let groups {
                    record.geometry = try groups.map { rings in
                        try rings.map { points in
                            try stride(from: 0, to: points.count, by: 256).map { start in
                                try Task.checkCancellation()
                                return try autoreleasepool {
                                    let end = min(start + 256, points.count)
                                    let bytes = try encoder.encode(Array(points[start..<end]))
                                    let chunk = Chunk(offset: offset, length: bytes.count, count: end - start)
                                    try handle.write(contentsOf: bytes)
                                    offset += UInt64(bytes.count)
                                    return chunk
                                }
                            }
                        }
                    }
                }
                records.append(record)
            }
        }
        try handle.synchronize()
        let header = OfflineENCChart(sourceName: chart.sourceName, originalFilename: chart.originalFilename,
            sha256: chart.sha256, importedAt: chart.importedAt, metadata: chart.metadata, features: [])
        let index = Self(chart: header, records: records, byteCount: offset)
        try encoder.encode(index).write(to: temporary.appendingPathComponent("index.json"), options: .atomic)
        try Task.checkCancellation()
        try manager.moveItem(at: temporary, to: directory)
    }

    static func read(directory: URL, viewport: OfflineENCBounds?, overview: Bool) throws -> (chart: OfflineENCChart, bounds: [String: OfflineENCBounds], estimatedBytes: Int) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("index.json")))
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent("features.bin"))
        defer { try? handle.close() }
        guard try handle.seekToEnd() == index.byteCount else { throw OfflineENCImportError.cache("Incomplete feature index") }
        var features: [OfflineENCFeature] = [], boxes: [String: OfflineENCBounds] = [:]
        var expectedOffset: UInt64 = 0
        for record in index.records {
            try Task.checkCancellation()
            guard record.length > 0, record.offset == expectedOffset, record.offset <= index.byteCount,
                  UInt64(record.length) <= index.byteCount - record.offset else { throw OfflineENCImportError.cache("Invalid feature record") }
            expectedOffset += UInt64(record.length)
            for group in record.geometry ?? [] {
                for ring in group {
                    for chunk in ring {
                        guard (1...256).contains(chunk.count), chunk.length > 0,
                              chunk.offset == expectedOffset, chunk.offset <= index.byteCount,
                              UInt64(chunk.length) <= index.byteCount - chunk.offset else {
                            throw OfflineENCImportError.cache("Invalid geometry chunk")
                        }
                        expectedOffset += UInt64(chunk.length)
                    }
                }
            }
            let metadata = record.objectClass >= 300
            if !metadata {
                if overview && !OfflineENCPackagePolicy.showsInOverview(objectClass: record.objectClass) { continue }
                if let viewport, let bounds = record.bounds, !intersects(viewport, bounds) { continue }
            }
            try autoreleasepool {
                try handle.seek(toOffset: record.offset)
                guard let data = try handle.read(upToCount: record.length), data.count == record.length else {
                    throw OfflineENCImportError.cache("Truncated feature record")
                }
                var feature = try decoder.decode(OfflineENCFeature.self, from: data)
                if let geometry = record.geometry {
                    feature = try OfflineENCGeometryStream.read(feature, groups: geometry, viewport: viewport,
                                                                handle: handle, decoder: decoder)
                    if feature.coordinates == nil { return }
                }
                features.append(feature)
                if let box = record.bounds { boxes[feature.id] = box }
            }
        }
        guard expectedOffset == index.byteCount else { throw OfflineENCImportError.cache("Missing feature records") }
        features.sort { $0.portrayalOrder < $1.portrayalOrder }
        let source = index.chart
        let chart = OfflineENCChart(sourceName: source.sourceName, originalFilename: source.originalFilename,
            sha256: source.sha256, importedAt: source.importedAt, metadata: source.metadata, features: features)
        return (chart, boxes, OfflineENCWorkingSetBudget.estimate(chart))
    }
}

/// Serializes first-time index construction so cancelled gestures cannot start
/// several full-cell decodes concurrently. Subsequent reads only decode selected records.
actor OfflineENCViewportReader {
    static let shared = OfflineENCViewportReader()
    func read(_ candidate: OfflineENCZip.CellCandidate, collection: OfflineENCCollection, root: URL,
              viewport: OfflineENCBounds?, overview: Bool) throws -> (chart: OfflineENCChart, bounds: [String: OfflineENCBounds], estimatedBytes: Int) {
        try Task.checkCancellation()
        return try autoreleasepool {
            let name = SHA256.hash(data: Data(candidate.cellID.utf8)).map { String(format: "%02x", $0) }.joined()
            let directory = root.appendingPathComponent(collection.sha256).appendingPathComponent("viewport-index-v2").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { return try OfflineENCFeatureIndex.read(directory: directory, viewport: viewport, overview: overview) }
                catch is CancellationError { throw CancellationError() }
                catch { try FileManager.default.removeItem(at: directory) } // derived cache only
            }
            try autoreleasepool {
                let source = try OfflineENCImportWorker.importCell(from: collection, candidate: candidate, root: root, cacheFolderName: "package-cells")
                try Task.checkCancellation()
                try OfflineENCFeatureIndex.build(chart: source, directory: directory)
            }
            return try OfflineENCFeatureIndex.read(directory: directory, viewport: viewport, overview: overview)
        }
    }
}

/// Stream large base geometry in 256-vertex chunks. Clipping is in the renderer's
/// Mercator plane, so adjacent windows intersect the same original edges.
/// Keep metadata, soundings and symbol-bearing objects on their existing path.
enum OfflineENCGeometryStream {
    static func groups(_ feature: OfflineENCFeature) -> [[[OfflineJSONValue]]]? {
        guard [30, 42, 43, 71].contains(feature.objectClass), let coordinates = feature.coordinates else { return nil }
        func array(_ value: OfflineJSONValue) -> [OfflineJSONValue]? {
            if case .array(let values) = value { return values }; return nil
        }
        let groups: [[[OfflineJSONValue]]]
        switch feature.geometryType {
        case "LineString":
            guard let points = array(coordinates) else { return nil }; groups = [[points]]
        case "Polygon", "MultiLineString":
            guard let rings = array(coordinates) else { return nil }
            let parsed = rings.compactMap(array)
            guard parsed.count == rings.count else { return nil }; groups = [parsed]
        case "MultiPolygon":
            guard let polygons = array(coordinates) else { return nil }
            var parsed: [[[OfflineJSONValue]]] = []
            for polygon in polygons {
                guard let rings = array(polygon) else { return nil }
                let points = rings.compactMap(array)
                guard points.count == rings.count else { return nil }; parsed.append(points)
            }
            groups = parsed
        default: return nil
        }
        guard groups.reduce(0, { $0 + $1.reduce(0, { $0 + $1.count }) }) > 1024 else { return nil }
        // Never discard/interpolate Z values or interpret unfamiliar geometry.
        for group in groups { for ring in group { for value in ring {
            guard case .position(let x, let y) = value, x.isFinite, y.isFinite,
                  (-180...180).contains(x), (-85...85).contains(y) else { return nil }
        } } }
        return groups
    }

    struct Vertex: Equatable {
        let x: Double
        let y: Double
        static func mercator(_ latitude: Double) -> Double { log(tan(.pi / 4 + latitude * .pi / 360)) }
        init(_ value: OfflineJSONValue) throws {
            guard case .position(let x, let latitude) = value, x.isFinite, latitude.isFinite,
                  (-180...180).contains(x), (-85...85).contains(latitude) else {
                throw OfflineENCImportError.cache("Invalid streamed chart coordinate")
            }
            self.x = x; self.y = Self.mercator(latitude)
        }
        init(x: Double, y: Double) { self.x = x; self.y = y }
        var coordinate: OfflineJSONValue { .position(x, (2 * atan(exp(y)) - .pi / 2) * 180 / .pi) }
    }
    struct Edge {
        let axisX: Bool
        let minimum: Bool
        let limit: Double
        func ordinate(_ point: Vertex) -> Double { axisX ? point.x : point.y }
        func inside(_ point: Vertex) -> Bool { minimum ? ordinate(point) >= limit : ordinate(point) <= limit }
        func intersection(_ a: Vertex, _ b: Vertex) -> Vertex {
            let t = (limit - ordinate(a)) / (ordinate(b) - ordinate(a))
            return axisX ? Vertex(x: limit, y: a.y + t * (b.y - a.y))
                         : Vertex(x: a.x + t * (b.x - a.x), y: limit)
        }
        static func bounds(_ box: OfflineENCBounds) -> [Edge] {
            [.init(axisX: true, minimum: true, limit: box.west), .init(axisX: true, minimum: false, limit: box.east),
             .init(axisX: false, minimum: true, limit: Vertex.mercator(box.south)),
             .init(axisX: false, minimum: false, limit: Vertex.mercator(box.north))]
        }
    }
    /// One Sutherland–Hodgman stage holds only first/last vertices. Cascading four
    /// stages avoids intermediate whole-ring arrays. Even-odd filling preserves
    /// holes and disconnected concave pieces, including boundary bridge segments.
    final class RingClipper {
        let edge: Edge
        let emit: (Vertex) -> Void
        var first: Vertex?
        var last: Vertex?
        init(edge: Edge, emit: @escaping (Vertex) -> Void) { self.edge = edge; self.emit = emit }
        func feed(_ point: Vertex) {
            if let last { segment(last, point) } else { first = point }
            last = point
        }
        func segment(_ a: Vertex, _ b: Vertex) {
            if edge.inside(a) != edge.inside(b) { emit(edge.intersection(a, b)) }
            if edge.inside(b) { emit(b) }
        }
        func finish() { if let last, let first { segment(last, first) } }
    }
    static func read(_ source: OfflineENCFeature, groups: [[[OfflineENCFeatureIndex.Chunk]]],
                     viewport: OfflineENCBounds?, handle: FileHandle, decoder: JSONDecoder) throws -> OfflineENCFeature {
        let polygon = source.geometryType == "Polygon" || source.geometryType == "MultiPolygon"
        let edges = viewport.map(Edge.bounds) ?? []
        func stream(_ chunks: [OfflineENCFeatureIndex.Chunk], emit: (OfflineJSONValue) throws -> Void) throws {
            for chunk in chunks {
                try Task.checkCancellation()
                try autoreleasepool {
                    try handle.seek(toOffset: chunk.offset)
                    guard let bytes = try handle.read(upToCount: chunk.length), bytes.count == chunk.length else {
                        throw OfflineENCImportError.cache("Truncated geometry chunk")
                    }
                    let values = try decoder.decode([OfflineJSONValue].self, from: bytes)
                    guard values.count == chunk.count else { throw OfflineENCImportError.cache("Invalid geometry chunk count") }
                    for value in values { try emit(value) }
                }
            }
        }
        var result: [OfflineJSONValue] = []
        for group in groups {
            var rings: [OfflineJSONValue] = []
            for chunks in group {
                var points: [OfflineJSONValue] = []
                if edges.isEmpty {
                    try stream(chunks) { points.append($0) }
                } else if polygon {
                    var stages: [RingClipper] = []
                    var sink: (Vertex) -> Void = { points.append($0.coordinate) }
                    for edge in edges.reversed() {
                        let stage = RingClipper(edge: edge, emit: sink)
                        stages.insert(stage, at: 0); sink = { stage.feed($0) }
                    }
                    try stream(chunks) { sink(try Vertex($0)) }
                    for stage in stages { stage.finish() }
                    if let first = points.first, points.last != first { points.append(first) }
                } else {
                    var previous: Vertex?
                    var lastEnd: Vertex?
                    func flush() {
                        if points.count >= 2 { rings.append(.array(points)) }
                        points.removeAll(keepingCapacity: false); lastEnd = nil
                    }
                    try stream(chunks) { value in
                        let point = try Vertex(value)
                        defer { previous = point }
                        guard let previous else { return }
                        var a = previous, b = point
                        for edge in edges {
                            let ai = edge.inside(a), bi = edge.inside(b)
                            if !ai && !bi { flush(); return }
                            if ai != bi {
                                let cut = edge.intersection(a, b)
                                if ai { b = cut } else { a = cut }
                            }
                        }
                        if lastEnd != a { flush(); points.append(a.coordinate) }
                        points.append(b.coordinate); lastEnd = b
                    }
                    flush()
                }
                if !points.isEmpty && (!polygon || points.count >= 4) { rings.append(.array(points)) }
            }
            if polygon {
                if !rings.isEmpty { result.append(.array(rings)) }
            } else { result.append(contentsOf: rings) }
        }
        let type: String
        let coordinates: OfflineJSONValue?
        if result.isEmpty { type = source.geometryType ?? ""; coordinates = nil }
        else if polygon {
            type = source.geometryType ?? "Polygon"
            coordinates = type == "Polygon" ? result[0] : .array(result)
        } else if viewport == nil && source.geometryType == "LineString" {
            type = "LineString"; coordinates = result[0]
        } else { type = "MultiLineString"; coordinates = .array(result) }
        return OfflineENCFeature(geometryType: type, coordinates: coordinates,
            attributes: source.attributes, soundingDepths: source.soundingDepths)
    }
}

/// User-selected cruising areas; identifiers refer to cells in the imported package.
struct OfflineENCCruisingArea: Identifiable, Equatable {
    let name: String
    let cellID: String
    var id: String { cellID }
    static let presets: [Self] = [
        .init(name: "S.VanC", cellID: "CA471223"),
        .init(name: "Pender", cellID: "CA471221"),
        .init(name: "W. VanC", cellID: "CA471216"),
        .init(name: "Georgia", cellID: "CA471212")]
    static func detailCells(in cells: [OfflineENCZip.CellCandidate], areaID: String) -> [OfflineENCZip.CellCandidate] {
        guard let area = cells.first(where: { $0.cellID == areaID }), let bounds = area.bounds,
              let band = OfflineENCPackagePolicy.usageBand(cellID: areaID) else { return [] }
        return cells.filter {
            guard let box = $0.bounds, let candidateBand = OfflineENCPackagePolicy.usageBand(cellID: $0.cellID), candidateBand > band else { return false }
            return box.west < bounds.east && box.east > bounds.west && box.south < bounds.north && box.north > bounds.south
        }
    }
    static func renderCells(in cells: [OfflineENCZip.CellCandidate], areaID: String, selected: Set<String>,
                            overview: Bool = false) -> [OfflineENCZip.CellCandidate] {
        // Keep selections intact, but load only the regional background at overview scale.
        if overview { return cells.filter { $0.cellID == areaID } }
        let eligible = Set(detailCells(in: cells, areaID: areaID).map(\.cellID))
        return cells.filter { $0.cellID == areaID || (eligible.contains($0.cellID) && selected.contains($0.cellID)) }
    }
}
