import CoreLocation
import Foundation

struct TideStation: Codable, Equatable, Identifiable {
    static let noaa = "noaa"
    static let chs = "chs"

    let id: String
    let name: String
    let lat: Double
    let lng: Double
    /// Who publishes the predictions: `noaa` (US) or `chs` (Canadian Hydrographic Service).
    let source: String
    /// CHS forecast series exposed in this station's metadata, when present.
    let forecastSeriesCode: String?

    init(id: String, name: String, lat: Double, lng: Double, source: String = TideStation.noaa,
         forecastSeriesCode: String? = nil) {
        self.id = id; self.name = name; self.lat = lat; self.lng = lng; self.source = source
        self.forecastSeriesCode = forecastSeriesCode
    }

    /// Stations saved before Canadian support have no `source`; they are NOAA's.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? TideStation.noaa
        forecastSeriesCode = try c.decodeIfPresent(String.self, forKey: .forecastSeriesCode)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }

    var sourceName: String { source == TideStation.chs ? "Canadian Hydrographic Service" : "NOAA" }
}

/// A published high or low, in metres above its provider's chart datum (NOAA: MLLW; CHS: local chart datum).
struct TideEvent: Codable, Equatable {
    let time: Date
    let height: Double
    let isHigh: Bool
}

struct TideSnapshot: Codable, Equatable {
    var station: TideStation
    var events: [TideEvent]
    var fetched: Date
    var heightModelID: String? { ValidatedBCTides.modelID(for: station) }
}

/// One sample from an operational, weather-aware water-level forecast, in metres above its datum.
struct OFSWaterLevelSample: Codable, Equatable {
    let time: Date
    let height: Double
}

/// Cached NOAA OFS or CHS IWLS water-level forecast. This model guidance is distinct from a tide prediction.
struct WaterLevelForecastSeries: Codable, Equatable {
    let stationID: String
    let datum: String
    let fetched: Date
    let samples: [OFSWaterLevelSample]
    let stationSource: String
    let seriesCode: String

    init(stationID: String, datum: String, fetched: Date, samples: [OFSWaterLevelSample],
         stationSource: String = TideStation.noaa, seriesCode: String = "ofs_water_level") {
        self.stationID = stationID; self.datum = datum; self.fetched = fetched; self.samples = samples
        self.stationSource = stationSource; self.seriesCode = seriesCode
    }

    private enum CodingKeys: String, CodingKey { case stationID, datum, fetched, samples, stationSource, seriesCode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try c.decode(String.self, forKey: .stationID)
        datum = try c.decode(String.self, forKey: .datum)
        fetched = try c.decode(Date.self, forKey: .fetched)
        samples = try c.decode([OFSWaterLevelSample].self, forKey: .samples)
        stationSource = try c.decodeIfPresent(String.self, forKey: .stationSource) ?? TideStation.noaa
        seriesCode = try c.decodeIfPresent(String.self, forKey: .seriesCode) ?? "ofs_water_level"
    }

    func height(at time: Date) -> Double? {
        guard let index = samples.lastIndex(where: { $0.time <= time }), index + 1 < samples.count else { return nil }
        let a = samples[index], b = samples[index + 1]
        let span = b.time.timeIntervalSince(a.time)
        guard span > 0 else { return nil }
        let fraction = time.timeIntervalSince(a.time) / span
        return a.height + (b.height - a.height) * fraction
    }
}

typealias OFSWaterLevelSeries = WaterLevelForecastSeries


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

    /// CHS high/low events remain the coverage and event authority. The BC override
    /// changes the continuous harmonic height curve, never published event heights/times.
    static func height(at time: Date, snapshot: TideSnapshot) -> Double? {
        guard let first = snapshot.events.first, let last = snapshot.events.last,
              first.time <= time, time <= last.time else { return nil }
        if snapshot.heightModelID != nil {
            return ValidatedBCTides.height(at: time, station: snapshot.station)
        }
        return height(at: time, events: snapshot.events)
    }

    static func rise(from now: Date, hours: Double, snapshot: TideSnapshot) -> Double? {
        if snapshot.heightModelID == nil { return rise(from: now, hours: hours, events: snapshot.events) }
        guard hours.isFinite, hours >= 0,
              let current = height(at: now, snapshot: snapshot),
              height(at: now.addingTimeInterval(hours * 3600), snapshot: snapshot) != nil else { return nil }
        var best = current
        for offset in stride(from: 0.0, through: hours * 3600, by: 300) {
            guard let value = height(at: now.addingTimeInterval(offset), snapshot: snapshot) else { return nil }
            best = max(best, value)
        }
        for event in snapshot.events where event.time >= now && event.time <= now.addingTimeInterval(hours * 3600) {
            best = max(best, event.height)
        }
        return best - current
    }

    /// Report provider event times, including Campbell River's CHS secondary turns.
    static func extremes(from now: Date, hours: Double, snapshot: TideSnapshot) -> (low: TideEvent, high: TideEvent)? {
        if snapshot.heightModelID == nil { return extremes(from: now, hours: hours, events: snapshot.events) }
        let end = now.addingTimeInterval(hours * 3600)
        guard hours.isFinite, hours >= 0, let startHeight = height(at: now, snapshot: snapshot),
              let endHeight = height(at: end, snapshot: snapshot) else { return nil }
        let candidates = snapshot.events.filter { $0.time >= now && $0.time <= end }
            + [TideEvent(time: now, height: startHeight, isHigh: false),
               TideEvent(time: end, height: endHeight, isHigh: true)]
        guard let low = candidates.min(by: { $0.height < $1.height }),
              let high = candidates.max(by: { $0.height < $1.height }) else { return nil }
        return (low, high)
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
        var run: (start: Date, end: Date, least: Double)?
        func close() { if let run { windows.append(run) }; run = nil }
        for p in points.sorted(by: { $0.time < $1.time }) {
            guard p.depth.isFinite, p.depth < limit else { close(); continue }
            if let previous = run, p.time.timeIntervalSince(previous.end) <= 3600 {
                run = (previous.start, p.time, min(previous.least, p.depth))
            } else {
                close()
                run = (p.time, p.time, p.depth)
            }
        }
        close()
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

struct PugetTideTableData: Codable {
    struct RequestDates: Codable { var begin: String; var end: String }
    struct Boundary: Codable { var south: Double; var north: Double; var west: Double; var east: Double }
    struct Failure: Codable { var id: String; var name: String; var reason: String }
    struct Station: Codable, Sendable {
        struct Event: Codable, Sendable { var time: String; var height: String; var kind: String }
        var id: String
        var name: String
        var lat: Double
        var lng: Double
        var subordinate: Bool
        var referenceId: String?
        var events: [Event]
        var count: Int
        var first: String
        var last: String
    }

    var title: String
    var source: String
    var generatedUTC: String
    var requestDates: RequestDates
    var datum: String
    var units: String
    var timeZone: String
    var countInventory: Int
    var successCount: Int
    var failedCount: Int
    var stations: [Station]
    var failures: [Failure]
    var boundary: Boundary
    var disclaimer: String
}

/// NOAA CO-OPS tide predictions (free, US waters). Station lists and predictions are cached on
/// disk so a previously fetched anchorage still works without a connection.
enum TideService {
    enum TideError: LocalizedError {
        case noStations, noData, offline, noCoverage

        var errorDescription: String? {
            switch self {
            case .noStations: return "No tide stations found."
            case .noCoverage: return "No tide prediction station within 25 km. Tide adjustment is unavailable here."
            case .noData: return "No usable tide predictions were returned for this station."
            case .offline: return "No saved tide predictions cover the next 24 hours. Connect to download tides."
            }
        }
    }

    /// An operational coverage limit, not a guarantee of tidal similarity.
    static let maximumStationDistance = 25_000.0
    static func coveredStation(near point: CLLocationCoordinate2D, stations: [TideStation]) throws -> TideStation {
        guard CLLocationCoordinate2DIsValid(point) else { throw TideError.noCoverage }
        let valid = stations.filter { CLLocationCoordinate2DIsValid($0.coordinate) }
        guard let station = TideMath.nearest(to: point, in: valid) else { throw TideError.noStations }
        guard Geo.distance(station.coordinate, point) <= maximumStationDistance else { throw TideError.noCoverage }
        return station
    }

    /// Simulator-only launch aid: exercise real disk-cache fallback without changing host networking.
    static var offlineSimulatorTest: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("-offlineTides")
        #else
        return false
        #endif
    }

    private static let base = "https://api.tidesandcurrents.noaa.gov"
    private static let tableCacheName = "puget-sound-tide-data.json"

    /// Most recently refreshed Puget Sound table dataset, or the bundled seed on first launch/offline.
    static func loadPugetTableData() -> Data? {
        if let cached = try? Data(contentsOf: tableCacheURL()),
           (try? JSONDecoder().decode(PugetTideTableData.self, from: cached)) != nil { return cached }
        guard let bundled = Bundle.main.url(forResource: "puget-sound-tide-data", withExtension: "json"),
              let data = try? Data(contentsOf: bundled),
              (try? JSONDecoder().decode(PugetTideTableData.self, from: data)) != nil else { return nil }
        return data
    }

    /// Refresh all 99 displayed table stations from NOAA, in small batches to avoid burst traffic.
    /// If individual requests fail, their last saved predictions remain and the failures are reported.
    static func refreshPugetTableData() async throws -> Data {
        guard let cached = loadPugetTableData() else { throw TideError.noData }
        var dataset = try JSONDecoder().decode(PugetTideTableData.self, from: cached)
        let (begin, end) = tableDateRange()
        var refreshed = dataset.stations
        var failures: [PugetTideTableData.Failure] = []
        var successes = 0
        let batchSize = 5
        struct StationFetchResult: Sendable {
            let id: String
            let events: [PugetTideTableData.Station.Event]?
            let errorMessage: String?
        }

        for offset in stride(from: 0, to: dataset.stations.count, by: batchSize) {
            let batch = Array(dataset.stations[offset..<min(offset + batchSize, dataset.stations.count)])
            let results = await withTaskGroup(of: StationFetchResult.self) { group in
                for station in batch {
                    group.addTask {
                        do { return StationFetchResult(id: station.id, events: try await fetchPugetStation(station: station, begin: begin, end: end), errorMessage: nil) }
                        catch { return StationFetchResult(id: station.id, events: nil, errorMessage: error.localizedDescription) }
                    }
                }
                var collected: [StationFetchResult] = []
                for await result in group { collected.append(result) }
                return collected
            }

            for result in results {
                guard let index = refreshed.firstIndex(where: { $0.id == result.id }) else { continue }
                if let events = result.events {
                    refreshed[index].events = events
                    refreshed[index].count = events.count
                    refreshed[index].first = events.first?.time ?? ""
                    refreshed[index].last = events.last?.time ?? ""
                    successes += 1
                } else {
                    failures.append(.init(id: result.id, name: refreshed[index].name, reason: result.errorMessage ?? "No predictions returned"))
                }
            }
        }

        guard successes > 0 else { throw TideError.offline }
        dataset.generatedUTC = ISO8601DateFormatter().string(from: Date())
        dataset.requestDates = .init(begin: begin, end: end)
        dataset.stations = refreshed
        dataset.successCount = successes
        dataset.failedCount = failures.count
        dataset.failures = failures
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dataset)
        try data.write(to: tableCacheURL(), options: .atomic)
        return data
    }

    private static func tableCacheURL() -> URL {
        let manager = FileManager.default
        let directory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TideTables", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory.appendingPathComponent(tableCacheName)
    }

    private static func tableDateRange(now: Date = Date()) -> (String, String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let today = calendar.startOfDay(for: now)
        let begin = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 28, to: today) ?? today
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd"
        return (formatter.string(from: begin), formatter.string(from: end))
    }

    private static func fetchPugetStation(station: PugetTideTableData.Station, begin: String, end: String) async throws -> [PugetTideTableData.Station.Event] {
        struct Reply: Decodable {
            struct Row: Decodable { let t: String; let v: String; let type: String }
            let predictions: [Row]?
        }
        var components = URLComponents(string: base + "/api/prod/datagetter")!
        components.queryItems = [
            URLQueryItem(name: "product", value: "predictions"),
            URLQueryItem(name: "application", value: "AnchorWatch"),
            URLQueryItem(name: "begin_date", value: begin),
            URLQueryItem(name: "end_date", value: end),
            URLQueryItem(name: "datum", value: "MLLW"),
            URLQueryItem(name: "station", value: station.id),
            URLQueryItem(name: "time_zone", value: "lst_ldt"),
            URLQueryItem(name: "units", value: "english"),
            URLQueryItem(name: "interval", value: "hilo"),
            URLQueryItem(name: "format", value: "json")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("AnchorWatch/0.1 (iOS; personal boat project)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TideError.noData }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let rows = reply.predictions ?? []
        guard rows.count >= 2 else { throw TideError.noData }
        let events = rows.compactMap { row -> PugetTideTableData.Station.Event? in
            guard let height = Double(row.v), row.type == "H" || row.type == "L" else { return nil }
            return .init(time: row.t, height: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), height), kind: row.type == "H" ? "High" : "Low")
        }.sorted { $0.time < $1.time }
        guard events.count >= 2 else { throw TideError.noData }
        return events
    }

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
            .map { row in
                let forecastCode = row.timeSeries?.map(\.code).first { $0 == "wlf" || $0 == "wlf-spine" }
                return TideStation(id: row.id, name: row.officialName, lat: row.latitude, lng: row.longitude,
                                   source: TideStation.chs, forecastSeriesCode: forecastCode)
            }
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

    /// CHS forecast series (`wlf` or `wlf-spine`) use eventDate/value rows in the station's chart datum.
    static func parseCHSWaterLevelForecast(_ data: Data, station: TideStation, fetched: Date) throws -> WaterLevelForecastSeries {
        struct Row: Decodable {
            let eventDate: String
            let value: Double
            let qcFlagCode: QualityFlag?
        }
        /// CHS currently serializes `qcFlagCode` as a string (for example, "2"); accept
        /// numbers as well so cached fixtures and any API representation changes remain safe.
        struct QualityFlag: Decodable {
            let value: Int?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) { value = number; return }
                if let string = try? container.decode(String.self) { value = Int(string); return }
                value = nil
            }
        }
        let formatter = ISO8601DateFormatter()
        let rows = try JSONDecoder().decode([Row].self, from: data)
            .compactMap { row -> OFSWaterLevelSample? in
                guard row.qcFlagCode?.value != 3, row.value.isFinite,
                      let time = formatter.date(from: row.eventDate) else { return nil }
                return OFSWaterLevelSample(time: time, height: row.value)
            }
            .sorted { $0.time < $1.time }
        guard rows.count >= 2, let seriesCode = station.forecastSeriesCode else { throw TideError.noData }
        let unique = rows.reduce(into: [OFSWaterLevelSample]()) { result, sample in
            if result.last?.time != sample.time { result.append(sample) }
        }
        guard unique.count >= 2 else { throw TideError.noData }
        return WaterLevelForecastSeries(stationID: station.id, datum: "CHS chart datum", fetched: fetched,
                                        samples: unique, stationSource: TideStation.chs, seriesCode: seriesCode)
    }

    // MARK: Fetching

    /// Predictions for the station nearest `point`, from the cache when fresh, else from NOAA.
    /// Falls back to older saved predictions when offline. `fromCache` identifies disk results, including offline fallback.
    static func snapshot(near point: CLLocationCoordinate2D, now: Date = Date(), forceRefresh: Bool = false) async throws -> (snapshot: TideSnapshot, fromCache: Bool) {
        let station = try await nearestStation(to: point)

        return try await snapshot(for: station, now: now, cached: loadSnapshot(station), forceRefresh: forceRefresh, fetch: { station, now in
            try await fetchEvents(station: station, now: now)
        }, save: saveSnapshot)
    }

    /// Loads this station's saved prediction and refreshes it when stale; usable saved data survives offline.
    static func snapshot(for station: TideStation, now: Date = Date(), forceRefresh: Bool = false) async throws -> (snapshot: TideSnapshot, fromCache: Bool) {
        try await snapshot(for: station, now: now, cached: loadSnapshot(station), forceRefresh: forceRefresh, fetch: { station, now in
            try await fetchEvents(station: station, now: now)
        }, save: saveSnapshot)
    }

    static func cachedSnapshot(for station: TideStation, now: Date = Date()) -> TideSnapshot? {
        loadSnapshot(station).flatMap { usableCache($0, station: station, now: now) }
    }

    /// Injected I/O keeps offline coverage, station isolation and event provenance testable.
    static func snapshot(for station: TideStation, now: Date, cached: TideSnapshot?, forceRefresh: Bool = false,
                         fetch: (TideStation, Date) async throws -> [TideEvent],
                         save: (TideSnapshot) -> Void = { _ in }) async throws -> (snapshot: TideSnapshot, fromCache: Bool) {
        let saved = cached.flatMap { usableCache($0, station: station, now: now) }
        if !forceRefresh, let saved, !offlineSimulatorTest, now.timeIntervalSince(saved.fetched) >= 0,
           now.timeIntervalSince(saved.fetched) < 6 * 3600 { return (saved, true) }
        do {
            let events = try await fetch(station, now)
            let fresh = TideSnapshot(station: station, events: events, fetched: now)
            guard usableCache(fresh, station: station, now: now) != nil else { throw TideError.noData }
            save(fresh)
            return (fresh, false)
        } catch {
            if let saved { return (saved, true) }
            throw error is URLError ? TideError.offline : error
        }
    }

    static func usableCache(_ snapshot: TideSnapshot, station: TideStation, now: Date) -> TideSnapshot? {
        guard snapshot.station.source == station.source, snapshot.station.id == station.id,
              snapshot.events.count >= 2,
              snapshot.events.allSatisfy({ $0.height.isFinite && $0.time.timeIntervalSince1970.isFinite }),
              zip(snapshot.events, snapshot.events.dropFirst()).allSatisfy({ $0.time < $1.time }),
              snapshot.events.first!.time <= now,
              snapshot.events.last!.time >= now.addingTimeInterval(24 * 3600) else { return nil }
        return snapshot
    }

    /// Station locations for the optional chart layer. Lists are fetched once and persisted locally.
    static func stationsForOverlay() async -> [TideStation] {
        async let noaa = stations(source: TideStation.noaa)
        async let canadian = stations(source: TideStation.chs)
        let all = (await noaa ?? []) + (await canadian ?? [])
        var seen = Set<String>()
        return all.filter { seen.insert($0.source + ":" + $0.id).inserted }
            .filter { CLLocationCoordinate2DIsValid($0.coordinate) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The nearest station in either country, so a boat near the border gets the closest tides
    /// whichever side they are on. Canadian stations are only loaded when north of 41°N.
    private static func nearestStation(to point: CLLocationCoordinate2D) async throws -> TideStation {
        async let noaa = stations(source: TideStation.noaa)
        async let canadian: [TideStation]? = point.latitude > 41 ? stations(source: TideStation.chs) : []
        let all = (await noaa ?? []) + (await canadian ?? [])
        guard !all.isEmpty else { throw TideError.offline }
        return try coveredStation(near: point, stations: all)
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
            return source == TideStation.chs ? loadLegacyCHSStations() : nil
        }
    }

    private static func fetchEvents(station: TideStation, now: Date) async throws -> [TideEvent] {
        if station.source == TideStation.chs { return try await fetchCHSEvents(station: station, now: now) }
        let path = noaaPredictionPath(station: station, now: now)
        let events = try await download(path: path, parse: parsePredictions)
        guard events.count >= 2 else { throw TideError.noData }
        return events
    }

    /// Request the recent nowcast and the NOAA model's next 72 hours in chart datum.
    static func noaaOFSWaterLevelURL(station: TideStation, now: Date) -> URL? {
        guard station.source == TideStation.noaa else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd HH:mm"
        var components = URLComponents(string: base + "/api/prod/datagetter")
        components?.queryItems = [
            URLQueryItem(name: "begin_date", value: formatter.string(from: now.addingTimeInterval(-6 * 3600))),
            URLQueryItem(name: "end_date", value: formatter.string(from: now.addingTimeInterval(72 * 3600))),
            URLQueryItem(name: "station", value: station.id),
            URLQueryItem(name: "product", value: "ofs_water_level"),
            URLQueryItem(name: "datum", value: "MLLW"),
            URLQueryItem(name: "time_zone", value: "gmt"),
            URLQueryItem(name: "units", value: "metric"),
            URLQueryItem(name: "application", value: "AnchorWatch"),
            URLQueryItem(name: "format", value: "json")
        ]
        return components?.url
    }

    /// Parse NOAA's CO-OPS response for operational forecast-system water levels.
    static func parseOFSWaterLevels(_ data: Data, stationID: String, fetched: Date) throws -> OFSWaterLevelSeries {
        struct Row: Decodable { let t: String; let v: String }
        struct Reply: Decodable { let data: [Row]? }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let samples = (reply.data ?? []).compactMap { row -> OFSWaterLevelSample? in
            guard let time = formatter.date(from: row.t), let height = Double(row.v), height.isFinite else { return nil }
            return OFSWaterLevelSample(time: time, height: height)
        }.sorted { $0.time < $1.time }
        guard samples.count >= 2 else { throw TideError.noData }
        let unique = samples.reduce(into: [OFSWaterLevelSample]()) { result, sample in
            if result.last?.time != sample.time { result.append(sample) }
        }
        return OFSWaterLevelSeries(stationID: stationID, datum: "MLLW", fetched: fetched, samples: unique)
    }

    /// Cached NOAA model guidance refreshes after six hours and remains available offline for up to a day.
    static func ofsWaterLevel(for station: TideStation, now: Date = Date()) async throws -> (series: OFSWaterLevelSeries, fromCache: Bool) {
        guard let url = noaaOFSWaterLevelURL(station: station, now: now) else { throw TideError.noData }
        let cached = loadOFSWaterLevel(station)
        if let cached, usableOFSWaterLevel(cached, station: station, now: now, maximumAge: 6 * 3600) {
            return (cached, true)
        }
        do {
            let series = try await download(url: url.absoluteString) {
                try parseOFSWaterLevels($0, stationID: station.id, fetched: now)
            }
            guard usableOFSWaterLevel(series, station: station, now: now, maximumAge: .infinity) else {
                throw TideError.noData
            }
            saveOFSWaterLevel(series)
            return (series, false)
        } catch {
            if let cached, usableOFSWaterLevel(cached, station: station, now: now, maximumAge: 24 * 3600) {
                return (cached, true)
            }
            throw error
        }
    }

    static func usableOFSWaterLevel(_ series: OFSWaterLevelSeries, station: TideStation, now: Date,
                                    maximumAge: TimeInterval) -> Bool {
        usableWaterLevelForecast(series, station: station, now: now, maximumAge: maximumAge,
                                 expectedDatum: "MLLW", expectedCode: "ofs_water_level")
    }

    /// CHS station forecasts are optional; only stations advertising a supported forecast series are queried.
    static func chsWaterLevelForecastURL(station: TideStation, now: Date) -> URL? {
        guard station.source == TideStation.chs,
              let code = station.forecastSeriesCode, code == "wlf" || code == "wlf-spine" else { return nil }
        let iso = ISO8601DateFormatter()
        var components = URLComponents(string: "https://api-iwls.dfo-mpo.gc.ca/api/v1/stations/\(station.id)/data")
        components?.queryItems = [
            URLQueryItem(name: "time-series-code", value: code),
            URLQueryItem(name: "from", value: iso.string(from: now.addingTimeInterval(-6 * 3600))),
            URLQueryItem(name: "to", value: iso.string(from: now.addingTimeInterval(48 * 3600)))
        ]
        return components?.url
    }

    /// Cached CHS forecast refreshes after six hours and remains available offline for up to a day.
    static func chsWaterLevelForecast(for station: TideStation, now: Date = Date()) async throws -> (series: WaterLevelForecastSeries, fromCache: Bool) {
        guard let url = chsWaterLevelForecastURL(station: station, now: now),
              let code = station.forecastSeriesCode else { throw TideError.noData }
        let cached = loadWaterLevelForecast(station)
        if let cached, usableWaterLevelForecast(cached, station: station, now: now, maximumAge: 6 * 3600,
                                                expectedDatum: "CHS chart datum", expectedCode: code) {
            return (cached, true)
        }
        do {
            let series = try await download(url: url.absoluteString) {
                try parseCHSWaterLevelForecast($0, station: station, fetched: now)
            }
            guard usableWaterLevelForecast(series, station: station, now: now, maximumAge: .infinity,
                                           expectedDatum: "CHS chart datum", expectedCode: code) else {
                throw TideError.noData
            }
            saveWaterLevelForecast(series)
            return (series, false)
        } catch {
            if let cached, usableWaterLevelForecast(cached, station: station, now: now, maximumAge: 24 * 3600,
                                                    expectedDatum: "CHS chart datum", expectedCode: code) {
                return (cached, true)
            }
            throw error
        }
    }

    static func usableWaterLevelForecast(_ series: WaterLevelForecastSeries, station: TideStation, now: Date,
                                         maximumAge: TimeInterval, expectedDatum: String,
                                         expectedCode: String) -> Bool {
        guard series.stationSource == station.source, series.stationID == station.id,
              series.datum == expectedDatum, series.seriesCode == expectedCode,
              series.samples.count >= 2, series.fetched <= now.addingTimeInterval(300),
              now.timeIntervalSince(series.fetched) <= maximumAge,
              series.samples.allSatisfy({ $0.height.isFinite && $0.time.timeIntervalSince1970.isFinite }),
              zip(series.samples, series.samples.dropFirst()).allSatisfy({ $0.time < $1.time }),
              series.samples.first!.time <= now.addingTimeInterval(3600),
              series.samples.last!.time >= now.addingTimeInterval(12 * 3600) else { return false }
        return true
    }

    /// UTC day bounds include yesterday and the complete day 28 days ahead.
    static func noaaPredictionPath(station: TideStation, now: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyyMMdd"
        let begin = day.string(from: now.addingTimeInterval(-24 * 3600))
        let end = day.string(from: now.addingTimeInterval(28 * 24 * 3600))
        return "/api/prod/datagetter?product=predictions&application=AnchorWatch&begin_date=\(begin)&end_date=\(end)"
            + "&datum=MLLW&station=\(station.id)&time_zone=gmt&units=metric&interval=hilo&format=json"
    }

    private static func fetchCHSEvents(station: TideStation, now: Date) async throws -> [TideEvent] {
        let iso = ISO8601DateFormatter()
        let from = iso.string(from: now.addingTimeInterval(-24 * 3600))
        let to = iso.string(from: now.addingTimeInterval(28 * 24 * 3600))
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
        if offlineSimulatorTest {
            print("AnchorWatch offline tide test: blocked network request; using saved coverage if available.")
            throw URLError(.notConnectedToInternet)
        }
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("AnchorWatch/0.1 (iOS; personal boat project)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }

    // MARK: Disk cache

    private static func cacheURL(_ name: String) -> URL {
        let manager = FileManager.default
        var directory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tides", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        let url = directory.appendingPathComponent(name)
        let legacy = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        if !manager.fileExists(atPath: url.path), let data = try? Data(contentsOf: legacy) {
            try? data.write(to: url, options: .atomic)
        }
        return url
    }

    private static func loadStations(source: String) -> [TideStation]? {
        let url = cacheURL(stationListCacheName(source))
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 60 * 24 * 3600,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([TideStation].self, from: data)
    }

    private static func saveStations(_ stations: [TideStation], source: String) {
        try? JSONEncoder().encode(stations).write(to: cacheURL(stationListCacheName(source)), options: .atomic)
    }

    private static func stationListCacheName(_ source: String) -> String {
        source == TideStation.noaa ? "tide-stations.json" : "tide-stations-\(source)-forecast-v1.json"
    }

    /// Keep Canadian station selection working offline after upgrading from the older cache schema.
    private static func loadLegacyCHSStations() -> [TideStation]? {
        guard let data = try? Data(contentsOf: cacheURL("tide-stations-\(TideStation.chs).json")) else { return nil }
        return try? JSONDecoder().decode([TideStation].self, from: data)
    }

    private static func loadSnapshot(_ station: TideStation) -> TideSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL("tide-\(station.source)-\(station.id).json")) else { return nil }
        return try? JSONDecoder().decode(TideSnapshot.self, from: data)
    }

    private static func saveSnapshot(_ snapshot: TideSnapshot) {
        try? JSONEncoder().encode(snapshot).write(to: cacheURL("tide-\(snapshot.station.source)-\(snapshot.station.id).json"), options: .atomic)
    }

    private static func loadOFSWaterLevel(_ station: TideStation) -> OFSWaterLevelSeries? {
        guard let data = try? Data(contentsOf: cacheURL("ofs-water-level-\(station.id).json")) else { return nil }
        return try? JSONDecoder().decode(OFSWaterLevelSeries.self, from: data)
    }

    private static func saveOFSWaterLevel(_ series: OFSWaterLevelSeries) {
        try? JSONEncoder().encode(series).write(to: cacheURL("ofs-water-level-\(series.stationID).json"), options: .atomic)
    }

    private static func loadWaterLevelForecast(_ station: TideStation) -> WaterLevelForecastSeries? {
        guard let data = try? Data(contentsOf: cacheURL("water-level-forecast-\(station.source)-\(station.id).json")) else { return nil }
        return try? JSONDecoder().decode(WaterLevelForecastSeries.self, from: data)
    }

    private static func saveWaterLevelForecast(_ series: WaterLevelForecastSeries) {
        try? JSONEncoder().encode(series).write(to: cacheURL("water-level-forecast-\(series.stationSource)-\(series.stationID).json"), options: .atomic)
    }
}
