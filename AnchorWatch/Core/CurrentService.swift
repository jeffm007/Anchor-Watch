import CoreLocation
import Foundation

enum CurrentProvider: String, Codable {
    case noaa
    case chs

    var displayName: String { self == .chs ? "Canadian Hydrographic Service" : "NOAA" }
}

/// A NOAA or Canadian Hydrographic Service tidal-current prediction station.
/// Most sit in channels, where the current runs harder than in a sheltered anchorage nearby.
struct CurrentStation: Codable, Equatable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    var provider: CurrentProvider
    var stationCode: String?

    init(id: String, name: String, lat: Double, lng: Double,
         provider: CurrentProvider = .noaa, stationCode: String? = nil) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lng = lng
        self.provider = provider
        self.stationCode = stationCode
    }

    private enum CodingKeys: String, CodingKey { case id, name, lat, lng, provider, stationCode }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)
        provider = try c.decodeIfPresent(CurrentProvider.self, forKey: .provider) ?? .noaa
        stationCode = try c.decodeIfPresent(String.self, forKey: .stationCode)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
    var providerName: String { provider.displayName }
}

/// One predicted slack, strongest flood or strongest ebb. Velocity in knots, positive flooding and negative
/// ebbing; the directions are where the water goes, degrees true.
struct CurrentEvent: Codable, Equatable {
    let time: Date
    let velocity: Double
    let floodToward: Double
    let ebbToward: Double
    var isSlack: Bool { abs(velocity) < 0.1 }
}

struct CurrentSnapshot: Codable, Equatable {
    var station: CurrentStation
    var events: [CurrentEvent]
    var fetched: Date
    var fromCache: Bool? = nil
}

/// Pure current arithmetic and parsing, apart from the networking so it can be tested.
enum CurrentMath {
    /// Speed (knots, at the station) and the direction the water goes at `time`, following the usual cosine
    /// curve between consecutive slacks and maximums. Nil outside the predictions.
    static func at(_ time: Date, events: [CurrentEvent]) -> (speed: Double, toward: Double)? {
        guard let i = events.lastIndex(where: { $0.time <= time }), i + 1 < events.count else { return nil }
        let a = events[i], b = events[i + 1]
        let span = b.time.timeIntervalSince(a.time)
        guard span > 0 else { return nil }
        let f = time.timeIntervalSince(a.time) / span
        let v = a.velocity + (b.velocity - a.velocity) * (1 - cos(.pi * f)) / 2
        return (abs(v), v >= 0 ? a.floodToward : a.ebbToward)
    }

    /// The station list, one entry per station (it repeats each station for every depth it measures).
    static func parseStations(_ data: Data) throws -> [CurrentStation] {
        struct Reply: Decodable { let stations: [Row] }
        struct Row: Decodable {
            let id: String; let name: String; let lat: Double; let lng: Double
            let type: String?
        }
        var seen = Set<String>()
        return try JSONDecoder().decode(Reply.self, from: data).stations.compactMap { row in
            // NOAA labels weak-and-variable stations "W"; those have no usable predictions.
            if row.type == "W" { return nil }
            guard seen.insert(row.id).inserted else { return nil }
            return CurrentStation(id: row.id, name: row.name, lat: row.lat, lng: row.lng)
        }
    }

    static func parseCHSStations(_ data: Data) throws -> [CurrentStation] {
        struct Row: Decodable {
            let id: String; let code: String; let officialName: String
            let latitude: Double; let longitude: Double
            let timeSeries: [Series]?
            struct Series: Decodable { let code: String }
        }
        return try JSONDecoder().decode([Row].self, from: data)
            .filter { $0.timeSeries?.contains { $0.code == "wcp1-events" } == true }
            .map { CurrentStation(id: $0.id, name: $0.officialName, lat: $0.latitude, lng: $0.longitude,
                                  provider: .chs, stationCode: $0.code) }
    }

    /// CHS current predictions are supplied as signed flood/ebb events and a separate direction series.
    /// CHS current-direction values are bearings of flow toward true north, in degrees.
    static func parseCHSPredictions(events eventData: Data, directions directionData: Data) throws -> [CurrentEvent] {
        struct EventRow: Decodable {
            let eventDate: String
            let qualifier: String
            let value: Double
            let qcFlagCode: String?
        }
        struct DirectionRow: Decodable {
            let eventDate: String
            let value: Double
            let qcFlagCode: String?
        }
        let iso = ISO8601DateFormatter()
        let rawEvents = try JSONDecoder().decode([EventRow].self, from: eventData)
            .compactMap { row -> (time: Date, qualifier: String, speed: Double)? in
                guard row.qcFlagCode != "3", let time = iso.date(from: row.eventDate) else { return nil }
                return (time, row.qualifier, row.value)
            }
            .sorted { $0.time < $1.time }
        let directions = try JSONDecoder().decode([DirectionRow].self, from: directionData)
            .compactMap { row -> (time: Date, bearing: Double)? in
                guard row.qcFlagCode != "3", let time = iso.date(from: row.eventDate), row.value.isFinite,
                      row.value >= 0, row.value <= 360 else { return nil }
                return (time, row.value.truncatingRemainder(dividingBy: 360))
            }
            .sorted { $0.time < $1.time }
        guard rawEvents.count >= 2, !directions.isEmpty else { return [] }

        func direction(at time: Date) -> Double? {
            directions.min(by: { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) })
                .flatMap { abs($0.time.timeIntervalSince(time)) <= 45 * 60 ? $0.bearing : nil }
        }
        func circularMean(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let radians = values.map { $0 * .pi / 180 }
            let x = radians.map(cos).reduce(0, +)
            let y = radians.map(sin).reduce(0, +)
            return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }

        let floodDirections = rawEvents.compactMap { $0.qualifier == "EXTREMA_FLOOD" ? direction(at: $0.time) : nil }
        let ebbDirections = rawEvents.compactMap { $0.qualifier == "EXTREMA_EBB" ? direction(at: $0.time) : nil }
        guard let floodToward = circularMean(floodDirections), let ebbToward = circularMean(ebbDirections) else { return [] }
        return rawEvents.compactMap { row in
            let velocity: Double
            switch row.qualifier {
            case "EXTREMA_FLOOD": velocity = abs(row.speed)
            case "EXTREMA_EBB": velocity = -abs(row.speed)
            case "SLACK": velocity = 0
            default: return nil
            }
            return CurrentEvent(time: row.time, velocity: velocity, floodToward: floodToward, ebbToward: ebbToward)
        }
    }

    /// `currents_predictions` at `interval=MAX_SLACK`: slacks and maximums, times in GMT.
    static func parsePredictions(_ data: Data) throws -> [CurrentEvent] {
        struct Reply: Decodable { let current_predictions: Body? }
        struct Body: Decodable { let cp: [Row] }
        struct Row: Decodable {
            let Time: String
            let Velocity_Major: Double
            let meanFloodDir: Double
            let meanEbbDir: Double
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = try JSONDecoder().decode(Reply.self, from: data).current_predictions?.cp ?? []
        return rows.compactMap { row in
            formatter.date(from: row.Time).map {
                CurrentEvent(time: $0, velocity: row.Velocity_Major, floodToward: row.meanFloodDir, ebbToward: row.meanEbbDir)
            }
        }
        .sorted { $0.time < $1.time }
    }
}

/// NOAA and CHS tidal-current prediction snapshots for a nearby station. Saved predictions survive offline.
enum CurrentService {
    /// Farther than this, a station's current says little about the anchorage.
    static let maxDistance = 25_000.0

    static func stationsForOverlay() async -> [CurrentStation] {
        let all = await allStations()
        var seen = Set<String>()
        return all.filter { seen.insert($0.provider.rawValue + ":" + $0.id).inserted }
            .filter { CLLocationCoordinate2DIsValid($0.coordinate) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func snapshot(near point: CLLocationCoordinate2D, now: Date = Date()) async throws -> CurrentSnapshot? {
        guard let station = await allStations().min(by: {
            Geo.distance($0.coordinate, point) < Geo.distance($1.coordinate, point)
        }),
              Geo.distance(station.coordinate, point) <= maxDistance else { return nil }
        return try await snapshot(for: station, now: now)
    }

    static func cachedSnapshot(for station: CurrentStation) -> CurrentSnapshot? {
        load(CurrentSnapshot.self, cacheName(for: station))
    }

    static func snapshot(for station: CurrentStation, now: Date = Date()) async throws -> CurrentSnapshot {
        let cacheName = cacheName(for: station)
        if let saved = load(CurrentSnapshot.self, cacheName),
           now.timeIntervalSince(saved.fetched) < 6 * 3600,
           (saved.events.last?.time ?? .distantPast) > now.addingTimeInterval(30 * 3600) {
            var cached = saved
            cached.fromCache = true
            return cached
        }
        do {
            let events: [CurrentEvent]
            switch station.provider {
            case .noaa: events = try await fetchNOAA(station: station, now: now)
            case .chs: events = try await fetchCHS(station: station, now: now)
            }
            guard events.count >= 2 else { throw URLError(.cannotParseResponse) }
            let fresh = CurrentSnapshot(station: station, events: events, fetched: now)
            save(fresh, cacheName)
            return fresh
        } catch {
            if var saved = load(CurrentSnapshot.self, cacheName) {
                saved.fromCache = true
                return saved
            }
            throw error
        }
    }

    private static func cacheName(for station: CurrentStation) -> String {
        station.provider == .chs ? "currents-chs-\(station.id).json" : "currents-\(station.id).json"
    }

    private static func allStations() async -> [CurrentStation] {
        async let noaa: [CurrentStation] = stations(provider: .noaa)
        async let chs: [CurrentStation] = stations(provider: .chs)
        return await noaa + chs
    }

    private static func stations(provider: CurrentProvider) async -> [CurrentStation] {
        let filename = "current-stations-\(provider.rawValue).json"
        if let cached = load([CurrentStation].self, filename) { return cached }
        do {
            let list: [CurrentStation]
            switch provider {
            case .noaa:
                list = try CurrentMath.parseStations(try await download(
                    "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=currentpredictions"))
            case .chs:
                list = try CurrentMath.parseCHSStations(try await download(
                    "https://api-iwls.dfo-mpo.gc.ca/api/v1/stations?chs-region-code=PAC&time-series-code=wcp1-events"))
            }
            save(list, filename)
            return list
        } catch {
            return []
        }
    }

    private static func fetchNOAA(station: CurrentStation, now: Date) async throws -> [CurrentEvent] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyyMMdd"
        let url = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=currents_predictions&application=AnchorWatch"
            + "&station=\(station.id)&begin_date=\(day.string(from: now.addingTimeInterval(-24 * 3600)))&range=96"
            + "&interval=MAX_SLACK&units=english&time_zone=gmt&format=json"
        return try CurrentMath.parsePredictions(try await download(url))
    }

    private static func fetchCHS(station: CurrentStation, now: Date) async throws -> [CurrentEvent] {
        let iso = ISO8601DateFormatter()
        let from = iso.string(from: now.addingTimeInterval(-24 * 3600))
        let to = iso.string(from: now.addingTimeInterval(28 * 24 * 3600))
        let root = "https://api-iwls.dfo-mpo.gc.ca/api/v1/stations/\(station.id)/data"
        async let events = download("\(root)?time-series-code=wcp1-events&from=\(from)&to=\(to)")
        async let directions = download("\(root)?time-series-code=wcdp1&from=\(from)&to=\(to)&resolution=FIFTEEN_MINUTES")
        return try CurrentMath.parseCHSPredictions(events: await events, directions: await directions)
    }

    private static func download(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("AnchorWatch/0.1 (iOS; personal boat project)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func url(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        (try? Data(contentsOf: url(name))).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, _ name: String) {
        try? JSONEncoder().encode(value).write(to: url(name))
    }
}
