import CoreLocation
import Foundation

struct TideStation: Codable, Equatable {
    static let noaa = "noaa"
    static let chs = "chs"

    let id: String
    let name: String
    let lat: Double
    let lng: Double
    /// Who publishes the predictions: `noaa` (US) or `chs` (Canadian Hydrographic Service).
    let source: String

    init(id: String, name: String, lat: Double, lng: Double, source: String = TideStation.noaa) {
        self.id = id; self.name = name; self.lat = lat; self.lng = lng; self.source = source
    }

    /// Stations saved before Canadian support have no `source`; they are NOAA's.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? TideStation.noaa
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }

    var sourceName: String { source == TideStation.chs ? "Canadian Hydrographic Service" : "NOAA" }
}

/// One predicted high or low. Heights are metres above the chart datum (MLLW).
struct TideEvent: Codable, Equatable {
    let time: Date
    let height: Double
    let isHigh: Bool
}

struct TideSnapshot: Codable, Equatable {
    var station: TideStation
    var events: [TideEvent]
    var fetched: Date
}

/// Pure tide arithmetic, kept apart from networking so it can be tested.
enum TideMath {
    /// Estimated height at `time`, assuming the usual cosine curve between consecutive highs and lows.
    static func height(at time: Date, events: [TideEvent]) -> Double? {
        guard let i = events.lastIndex(where: { $0.time <= time }), i + 1 < events.count else { return nil }
        let a = events[i], b = events[i + 1]
        let span = b.time.timeIntervalSince(a.time)
        guard span > 0 else { return nil }
        let f = time.timeIntervalSince(a.time) / span
        return a.height + (b.height - a.height) * (1 - cos(.pi * f)) / 2
    }

    /// How far the water is expected to rise above its level at `now`, at any point in the next `hours`.
    static func rise(from now: Date, hours: Double, events: [TideEvent]) -> Double? {
        guard let current = height(at: now, events: events) else { return nil }
        var best = current
        var t = now
        let end = now.addingTimeInterval(hours * 3600)
        while t <= end {
            if let h = height(at: t, events: events) { best = max(best, h) }
            t = t.addingTimeInterval(300)
        }
        return best - current
    }

    /// Lowest and highest water expected in the next `hours`, and when each comes.
    static func extremes(from now: Date, hours: Double, events: [TideEvent]) -> (low: TideEvent, high: TideEvent)? {
        guard let current = height(at: now, events: events) else { return nil }
        var low = TideEvent(time: now, height: current, isHigh: false)
        var high = TideEvent(time: now, height: current, isHigh: true)
        var t = now
        let end = now.addingTimeInterval(hours * 3600)
        while t <= end {
            if let h = height(at: t, events: events) {
                if h < low.height { low = TideEvent(time: t, height: h, isHigh: false) }
                if h > high.height { high = TideEvent(time: t, height: h, isHigh: true) }
            }
            t = t.addingTimeInterval(300)
        }
        return (low, high)
    }

    /// Depth at the anchorage every `step` for the next `hours`: today's depth moved by how much the tide
    /// rises or falls from now. Stops where the predictions run out.
    static func depths(depthNow: Double, events: [TideEvent], from now: Date, hours: Double = 24,
                       step: TimeInterval = 600) -> [(time: Date, depth: Double)] {
        guard let tideNow = height(at: now, events: events) else { return [] }
        return stride(from: 0, through: hours * 3600, by: step).compactMap { offset in
            let t = now.addingTimeInterval(offset)
            return height(at: t, events: events).map { (t, max(0, depthNow + $0 - tideNow)) }
        }
    }

    /// Stretches of `points` where the depth is below `limit`, with the least depth in each.
    static func shallowWindows(_ points: [(time: Date, depth: Double)], below limit: Double) -> [(start: Date, end: Date, least: Double)] {
        var windows: [(start: Date, end: Date, least: Double)] = []
        for p in points where p.depth < limit {
            if let last = windows.last, p.time.timeIntervalSince(last.end) <= 3600 {
                windows[windows.count - 1] = (last.start, p.time, min(last.least, p.depth))
            } else {
                windows.append((p.time, p.time, p.depth))
            }
        }
        return windows
    }

    static func nearest(to point: CLLocationCoordinate2D, in stations: [TideStation]) -> TideStation? {
        stations.min { Geo.distance($0.coordinate, point) < Geo.distance($1.coordinate, point) }
    }

    /// Upcoming highs and lows, soonest first.
    static func upcoming(_ events: [TideEvent], after now: Date, limit: Int) -> [TideEvent] {
        Array(events.filter { $0.time > now }.prefix(limit))
    }
}

/// NOAA CO-OPS tide predictions (free, US waters). Station lists and predictions are cached on
/// disk so a previously fetched anchorage still works without a connection.
enum TideService {
    enum TideError: LocalizedError {
        case noStations, noData, offline

        var errorDescription: String? {
            switch self {
            case .noStations: return "No tide stations found."
            case .noData: return "NOAA returned no tide predictions for this station."
            case .offline: return "Can't reach NOAA and nothing is saved yet. Connect once to download the tides."
            }
        }
    }

    private static let base = "https://api.tidesandcurrents.noaa.gov"

    // MARK: Parsing (static so tests can feed sample JSON)

    static func parseStations(_ data: Data) throws -> [TideStation] {
        struct Reply: Decodable { let stations: [Row] }
        struct Row: Decodable { let id: String; let name: String; let lat: Double; let lng: Double }
        return try JSONDecoder().decode(Reply.self, from: data).stations.map { TideStation(id: $0.id, name: $0.name, lat: $0.lat, lng: $0.lng) }
    }

    /// Predictions requested with `time_zone=gmt` and `units=metric`.
    static func parsePredictions(_ data: Data) throws -> [TideEvent] {
        struct Reply: Decodable { let predictions: [Row]? }
        struct Row: Decodable { let t: String; let v: String; let type: String }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = try JSONDecoder().decode(Reply.self, from: data).predictions ?? []
        return rows.compactMap { row in
            guard let time = formatter.date(from: row.t), let height = Double(row.v) else { return nil }
            return TideEvent(time: time, height: height, isHigh: row.type == "H")
        }
    }

    /// Canadian Hydrographic Service stations that publish high/low predictions.
    static func parseCHSStations(_ data: Data) throws -> [TideStation] {
        struct Row: Decodable {
            let id: String
            let officialName: String
            let latitude: Double
            let longitude: Double
            let timeSeries: [Series]?
            struct Series: Decodable { let code: String }
        }
        return try JSONDecoder().decode([Row].self, from: data)
            .filter { $0.timeSeries?.contains { $0.code == "wlp-hilo" } == true }
            .map { TideStation(id: $0.id, name: $0.officialName, lat: $0.latitude, lng: $0.longitude, source: TideStation.chs) }
    }

    /// CHS "wlp-hilo" predictions give each extreme's time and height but not whether it is a high
    /// or a low. Highs and lows alternate, so the parity whose heights average higher are the highs.
    static func parseCHSEvents(_ data: Data) throws -> [TideEvent] {
        struct Row: Decodable { let eventDate: String; let value: Double }
        let formatter = ISO8601DateFormatter()
        let rows = try JSONDecoder().decode([Row].self, from: data)
            .compactMap { row in formatter.date(from: row.eventDate).map { (time: $0, height: row.value) } }
            .sorted { $0.time < $1.time }
        guard rows.count >= 2 else { return [] }

        func mean(_ parity: Int) -> Double {
            let values = rows.enumerated().filter { $0.offset % 2 == parity }.map(\.element.height)
            return values.reduce(0, +) / Double(values.count)
        }
        let highParity = mean(0) >= mean(1) ? 0 : 1
        return rows.enumerated().map { TideEvent(time: $0.element.time, height: $0.element.height, isHigh: $0.offset % 2 == highParity) }
    }

    // MARK: Fetching

    /// Predictions for the station nearest `point`, from the cache when fresh, else from NOAA.
    /// Falls back to older saved predictions when offline. `fromCache` is true when the network failed.
    static func snapshot(near point: CLLocationCoordinate2D, now: Date = Date()) async throws -> (snapshot: TideSnapshot, fromCache: Bool) {
        let station = try await nearestStation(to: point)

        if let saved = loadSnapshot(station),
           now.timeIntervalSince(saved.fetched) < 6 * 3600,
           (saved.events.last?.time ?? .distantPast) > now.addingTimeInterval(36 * 3600) {
            return (saved, false)
        }
        do {
            let events = try await fetchEvents(station: station, now: now)
            let fresh = TideSnapshot(station: station, events: events, fetched: now)
            saveSnapshot(fresh)
            return (fresh, false)
        } catch {
            if let saved = loadSnapshot(station) { return (saved, true) }
            throw error is URLError ? TideError.offline : error
        }
    }

    /// The nearest station in either country, so a boat near the border gets the closest tides
    /// whichever side they are on. Canadian stations are only loaded when north of 41°N.
    private static func nearestStation(to point: CLLocationCoordinate2D) async throws -> TideStation {
        async let noaa = stations(source: TideStation.noaa)
        async let canadian: [TideStation]? = point.latitude > 41 ? stations(source: TideStation.chs) : []
        let all = (await noaa ?? []) + (await canadian ?? [])
        guard !all.isEmpty else { throw TideError.offline }
        guard let station = TideMath.nearest(to: point, in: all) else { throw TideError.noStations }
        return station
    }

    /// One country's station list: from the disk cache, else downloaded and cached. Nil if unavailable.
    private static func stations(source: String) async -> [TideStation]? {
        if let cached = loadStations(source: source) { return cached }
        do {
            let list: [TideStation]
            if source == TideStation.chs {
                list = try await download(url: "https://api-iwls.dfo-mpo.gc.ca/api/v1/stations", parse: parseCHSStations)
            } else {
                list = try await download(path: "/mdapi/prod/webapi/stations.json?type=tidepredictions", parse: parseStations)
            }
            saveStations(list, source: source)
            return list
        } catch {
            return nil
        }
    }

    private static func fetchEvents(station: TideStation, now: Date) async throws -> [TideEvent] {
        if station.source == TideStation.chs { return try await fetchCHSEvents(station: station, now: now) }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyyMMdd"
        let begin = day.string(from: now.addingTimeInterval(-24 * 3600))
        let end = day.string(from: now.addingTimeInterval(4 * 24 * 3600))
        let path = "/api/prod/datagetter?product=predictions&application=AnchorWatch&begin_date=\(begin)&end_date=\(end)"
            + "&datum=MLLW&station=\(station.id)&time_zone=gmt&units=metric&interval=hilo&format=json"
        let events = try await download(path: path, parse: parsePredictions)
        guard events.count >= 2 else { throw TideError.noData }
        return events
    }

    private static func fetchCHSEvents(station: TideStation, now: Date) async throws -> [TideEvent] {
        let iso = ISO8601DateFormatter()
        let from = iso.string(from: now.addingTimeInterval(-24 * 3600))
        let to = iso.string(from: now.addingTimeInterval(4 * 24 * 3600))
        let events = try await download(
            url: "https://api-iwls.dfo-mpo.gc.ca/api/v1/stations/\(station.id)/data?time-series-code=wlp-hilo&from=\(from)&to=\(to)",
            parse: parseCHSEvents)
        guard events.count >= 2 else { throw TideError.noData }
        return events
    }

    private static func download<T>(path: String, parse: (Data) throws -> T) async throws -> T {
        try await download(url: base + path, parse: parse)
    }

    private static func download<T>(url: String, parse: (Data) throws -> T) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("AnchorWatch/0.1 (iOS; personal boat project)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }

    // MARK: Disk cache

    private static func cacheURL(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    private static func loadStations(source: String) -> [TideStation]? {
        let url = cacheURL(source == TideStation.noaa ? "tide-stations.json" : "tide-stations-\(source).json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 60 * 24 * 3600,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([TideStation].self, from: data)
    }

    private static func saveStations(_ stations: [TideStation], source: String) {
        let name = source == TideStation.noaa ? "tide-stations.json" : "tide-stations-\(source).json"
        try? JSONEncoder().encode(stations).write(to: cacheURL(name))
    }

    private static func loadSnapshot(_ station: TideStation) -> TideSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL("tide-\(station.source)-\(station.id).json")) else { return nil }
        return try? JSONDecoder().decode(TideSnapshot.self, from: data)
    }

    private static func saveSnapshot(_ snapshot: TideSnapshot) {
        try? JSONEncoder().encode(snapshot).write(to: cacheURL("tide-\(snapshot.station.source)-\(snapshot.station.id).json"))
    }
}
