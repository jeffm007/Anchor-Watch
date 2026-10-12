import CoreLocation
import Foundation

/// A NOAA tidal current prediction station. Most sit in channels, where the current runs harder than in a
/// sheltered anchorage nearby, so the app scales the speed (see `AnchorWatchEngine.currentFactor`).
struct CurrentStation: Codable, Equatable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
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
        struct Row: Decodable { let id: String; let name: String; let lat: Double; let lng: Double }
        var seen = Set<String>()
        return try JSONDecoder().decode(Reply.self, from: data).stations.compactMap { row in
            guard seen.insert(row.id).inserted else { return nil }
            return CurrentStation(id: row.id, name: row.name, lat: row.lat, lng: row.lng)
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

/// NOAA tidal current predictions for the station nearest the boat. US waters only; nil where there's no
/// station close enough to mean anything.
enum CurrentService {
    /// Farther than this, a station's current says little about the anchorage.
    static let maxDistance = 25_000.0

    static func snapshot(near point: CLLocationCoordinate2D, now: Date = Date()) async throws -> CurrentSnapshot? {
        guard let stations = try await stations(),
              let station = stations.min(by: { Geo.distance($0.coordinate, point) < Geo.distance($1.coordinate, point) }),
              Geo.distance(station.coordinate, point) <= maxDistance else { return nil }
        if let saved = load(CurrentSnapshot.self, "currents-\(station.id).json"),
           now.timeIntervalSince(saved.fetched) < 6 * 3600,
           (saved.events.last?.time ?? .distantPast) > now.addingTimeInterval(30 * 3600) {
            return saved
        }
        do {
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = TimeZone(identifier: "UTC")
            day.dateFormat = "yyyyMMdd"
            let url = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=currents_predictions&application=AnchorWatch"
                + "&station=\(station.id)&begin_date=\(day.string(from: now.addingTimeInterval(-24 * 3600)))&range=96"
                + "&interval=MAX_SLACK&units=english&time_zone=gmt&format=json"
            let events = try CurrentMath.parsePredictions(try await download(url))
            guard events.count >= 2 else { return nil }
            let fresh = CurrentSnapshot(station: station, events: events, fetched: now)
            save(fresh, "currents-\(station.id).json")
            return fresh
        } catch {
            return load(CurrentSnapshot.self, "currents-\(station.id).json")
        }
    }

    private static func stations() async throws -> [CurrentStation]? {
        if let cached = load([CurrentStation].self, "current-stations.json") { return cached }
        let list = try CurrentMath.parseStations(
            try await download("https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=currentpredictions"))
        save(list, "current-stations.json")
        return list
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
