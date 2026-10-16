import CoreLocation
import Foundation

/// A latest reading from a NOAA buoy or coastal station (NDBC "latest observations").
/// Wind in knots, waves in metres, pressure in hPa, temperatures in °C.
struct StationObservation: Identifiable, Equatable {
    let id: String
    var name: String
    let coordinate: CLLocationCoordinate2D
    let time: Date
    let windDirection: Double?
    let windSpeed: Double?
    let gust: Double?
    let waveHeight: Double?
    let wavePeriod: Double?
    let pressure: Double?
    /// Change over the last 3 hours, hPa.
    let pressureTrend: Double?
    let airTemp: Double?
    let waterTemp: Double?
    let visibility: Double?
    var distanceKm = 0.0
    var bearing = 0.0

    /// Pressure tendency as an arrow, with a dead band for a steady barometer.
    var trendArrow: String? {
        guard let trend = pressureTrend else { return nil }
        return trend > 0.6 ? "↑" : trend < -0.6 ? "↓" : "→"
    }
}

extension StationObservation {
    /// One line for a map callout: "ESE 5 kt, gusts 6 · 12 min ago".
    func summary(now: Date = Date()) -> String {
        var parts: [String] = []
        if let speed = windSpeed {
            parts.append((windDirection.map { "\(Compass.name($0)) " } ?? "") + "\(Int(speed.rounded())) kt"
                + (gust.map { ", gusts \(Int($0.rounded()))" } ?? ""))
        } else {
            parts.append("no wind reported")
        }
        let minutes = max(0, Int(now.timeIntervalSince(time) / 60))
        parts.append(minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h \(minutes % 60) min ago")
        return parts.joined(separator: " · ")
    }
}

enum ObservationMath {
    /// The stations worth showing for a position: the nearest few reporting wind, plus the nearest
    /// reporting waves. Stale stations (silent for hours) are ignored.
    static func nearby(_ all: [StationObservation], to point: CLLocationCoordinate2D, now: Date = Date(),
                       maxAge: TimeInterval = 3 * 3600, maxKm: Double = 200, windStations: Int = 3) -> [StationObservation] {
        let fresh: [StationObservation] = all.compactMap { obs in
            guard now.timeIntervalSince(obs.time) <= maxAge else { return nil }
            var o = obs
            o.distanceKm = Geo.distance(o.coordinate, point) / 1000
            o.bearing = Geo.bearing(from: point, to: o.coordinate)
            return o.distanceKm <= maxKm ? o : nil
        }.sorted { $0.distanceKm < $1.distanceKm }

        var chosen = Array(fresh.filter { $0.windSpeed != nil }.prefix(windStations))
        if let waves = fresh.first(where: { $0.waveHeight != nil }), !chosen.contains(where: { $0.id == waves.id }) {
            chosen.append(waves)
        }
        return chosen.sorted { $0.distanceKm < $1.distanceKm }
    }

    /// A heads-up when a nearby station is reporting gusts at or above the limit.
    static func gustAlert(_ stations: [StationObservation], limit: Double) -> (station: StationObservation, gust: Double)? {
        stations.compactMap { s in s.gust.map { (s, $0) } }
            .filter { $0.1 >= limit }
            .max { $0.1 < $1.1 }
    }
}

/// NDBC latest observations (free, no key): one ~100 KB text file covering every reporting station.
enum ObservationService {
    private static let knotsPerMetrePerSecond = 1.943844

    /// Parses `latest_obs.txt`. Missing values are "MM".
    static func parse(_ text: String) -> [StationObservation] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard f.count >= 21, let lat = Double(f[1]), let lon = Double(f[2]),
                  let y = Int(f[3]), let mo = Int(f[4]), let d = Int(f[5]), let h = Int(f[6]), let mi = Int(f[7]),
                  let time = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)) else { return nil }
            func value(_ i: Int) -> Double? { f[i] == "MM" ? nil : Double(f[i]) }
            return StationObservation(
                id: f[0].uppercased(), name: f[0].uppercased(),
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), time: time,
                windDirection: value(8), windSpeed: value(9).map { $0 * knotsPerMetrePerSecond },
                gust: value(10).map { $0 * knotsPerMetrePerSecond },
                waveHeight: value(11), wavePeriod: value(12),
                pressure: value(15), pressureTrend: value(16),
                airTemp: value(17), waterTemp: value(18), visibility: value(20))
        }
    }

    // MARK: Environment and Climate Change Canada (SWOB real-time)

    struct CanadianStation: Equatable {
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    static func parseCanadianStations(_ data: Data) throws -> [CanadianStation] {
        struct Reply: Decodable {
            let features: [Feature]
            struct Feature: Decodable { let geometry: Geometry; let properties: Props }
            struct Geometry: Decodable { let coordinates: [Double] }
            struct Props: Decodable { let name: String? }
        }
        return try JSONDecoder().decode(Reply.self, from: data).features.compactMap { f in
            guard let name = f.properties.name, f.geometry.coordinates.count >= 2 else { return nil }
            return CanadianStation(name: name, coordinate: CLLocationCoordinate2D(latitude: f.geometry.coordinates[1], longitude: f.geometry.coordinates[0]))
        }
    }

    /// The latest reading from one SWOB item. Wind is a 10-minute average with the 10-minute maximum as
    /// the gust, both in km/h; pressure is the station pressure in hPa.
    static func parseCanadianObservation(_ data: Data) throws -> StationObservation? {
        struct Reply: Decodable {
            let features: [Feature]
            struct Feature: Decodable { let geometry: Geometry; let properties: [String: JSONValue] }
            struct Geometry: Decodable { let coordinates: [Double] }
        }
        guard let feature = try JSONDecoder().decode(Reply.self, from: data).features.first, feature.geometry.coordinates.count >= 2 else { return nil }
        let p = feature.properties
        func number(_ key: String) -> Double? { p[key]?.number }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let timeText = p["date_tm-value"]?.string, let time = fractional.date(from: timeText) ?? ISO8601DateFormatter().date(from: timeText) else { return nil }

        let kmhPerKnot = 1.852
        let name = p["stn_nam-value"]?.string ?? "Canadian station"
        return StationObservation(
            id: "EC-" + (p["tc_id-value"]?.string ?? name), name: name,
            coordinate: CLLocationCoordinate2D(latitude: feature.geometry.coordinates[1], longitude: feature.geometry.coordinates[0]),
            time: time,
            windDirection: number("avg_wnd_dir_10m_pst10mts"),
            windSpeed: number("avg_wnd_spd_10m_pst10mts").map { $0 / kmhPerKnot },
            gust: number("max_wnd_spd_10m_pst10mts").map { $0 / kmhPerKnot },
            waveHeight: nil, wavePeriod: nil,
            pressure: number("stn_pres"), pressureTrend: nil,
            airTemp: number("air_temp"), waterTemp: nil, visibility: number("vis"))
    }

    /// Environment Canada stations near `point`: the few closest, each queried for its latest reading.
    /// Canada only (north of 41°N). Failures are quietly ignored so they never hide the NOAA readings.
    static func fetchCanadian(near point: CLLocationCoordinate2D, count: Int = 5) async -> [StationObservation] {
        guard point.latitude > 41, let stations = await canadianStations() else { return [] }
        let nearest = stations
            .map { ($0, Geo.distance($0.coordinate, point)) }
            .filter { $0.1 <= 200_000 }
            .sorted { $0.1 < $1.1 }
            .prefix(count)
            .map(\.0)

        return await withTaskGroup(of: StationObservation?.self) { group in
            for station in nearest {
                group.addTask {
                    var components = URLComponents(string: "https://api.weather.gc.ca/collections/swob-realtime/items")!
                    components.queryItems = [URLQueryItem(name: "f", value: "json"), URLQueryItem(name: "limit", value: "1"),
                                             URLQueryItem(name: "sortby", value: "-date_tm-value"),
                                             URLQueryItem(name: "stn_nam-value", value: station.name)]
                    guard let url = components.url, let data = try? await download(url: url),
                          let observation = try? parseCanadianObservation(data) else { return nil }
                    return observation
                }
            }
            var results: [StationObservation] = []
            for await observation in group { if let observation { results.append(observation) } }
            return results
        }
    }

    private static func canadianStations() async -> [CanadianStation]? {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("eccc-stations.json")
        struct Saved: Codable { let name: String; let lat: Double; let lon: Double }
        if let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 30 * 24 * 3600,
           let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Saved].self, from: data) {
            return saved.map { CanadianStation(name: $0.name, coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
        }
        guard let url = URL(string: "https://api.weather.gc.ca/collections/swob-stations/items?f=json&limit=2000"),
              let data = try? await download(url: url), let list = try? parseCanadianStations(data), !list.isEmpty else { return nil }
        try? JSONEncoder().encode(list.map { Saved(name: $0.name, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }).write(to: file)
        return list
    }

    private static func download(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("AnchorWatch/0.1 (personal boat project)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Station names from `activestations.xml`, keyed by upper-case station id.
    static func parseNames(_ xml: String) -> [String: String] {
        var names: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: #"<station id="([^"]+)"[^>]*? name="([^"]*)""#)
        for match in pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let id = Range(match.range(at: 1), in: xml), let name = Range(match.range(at: 2), in: xml) else { continue }
            names[xml[id].uppercased()] = xml[name].trimmingCharacters(in: .whitespaces)
        }
        return names
    }

    struct NearbyResult {
        var stations: [StationObservation]
        var warnings: [String]
    }

    /// Each provider completes independently: a failed NOAA request cannot discard Canadian readings.
    static func fetchNearbyResult(_ point: CLLocationCoordinate2D, now: Date = Date(),
                                  noaa: (() async throws -> [StationObservation])? = nil,
                                  canada: (() async throws -> [StationObservation])? = nil) async throws -> NearbyResult {
        func attempt(_ fetch: () async throws -> [StationObservation]) async -> Result<[StationObservation], Error> {
            do { return .success(try await fetch()) } catch { return .failure(error) }
        }
        async let us = attempt(noaa ?? {
            let text = try await download("/data/latest_obs/latest_obs.txt")
            let names = await stationNames()
            return parse(text).map { obs in var s = obs; s.name = names[s.id] ?? s.id; return s }
        })
        async let ca = attempt(canada ?? { await fetchCanadian(near: point) })
        let (usResult, caResult) = await (us, ca)
        var pooled: [StationObservation] = [], warnings: [String] = []
        var failure: Error?
        for (name, result) in [("NOAA", usResult), ("Environment Canada", caResult)] {
            switch result {
            case .success(let readings): pooled += readings
            case .failure(let error): warnings.append(name + " unavailable: " + error.localizedDescription); failure = error
            }
        }
        let nearby = ObservationMath.nearby(pooled, to: point, now: now)
        if nearby.isEmpty, let failure { throw failure }
        return NearbyResult(stations: nearby, warnings: warnings)
    }

    static func fetchNearby(_ point: CLLocationCoordinate2D, now: Date = Date()) async throws -> [StationObservation] {
        try await fetchNearbyResult(point, now: now).stations
    }

    private static func stationNames() async -> [String: String] {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ndbc-names.json")
        if let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 30 * 24 * 3600,
           let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode([String: String].self, from: data) {
            return cached
        }
        guard let xml = try? await download("/activestations.xml") else { return [:] }
        let names = parseNames(xml)
        try? JSONEncoder().encode(names).write(to: url)
        return names
    }

    private static func download(_ path: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.ndbc.noaa.gov" + path)!)
        request.setValue("AnchorWatch/0.1 (personal boat project)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return text
    }
}

/// SWOB properties are a mix of numbers, strings and nulls.
enum JSONValue: Decodable {
    case number(Double), string(String), other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let t = try? c.decode(String.self) { self = .string(t) }
        else { self = .other }
    }

    var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    var string: String? { if case .string(let t) = self { return t } else { return nil } }
}
