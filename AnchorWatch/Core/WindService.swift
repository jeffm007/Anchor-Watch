import CoreLocation
import Foundation
import MapKit

/// One hour of forecast wind. Speeds in knots; `direction` is where the wind comes FROM, degrees true.
struct WindSample: Codable, Equatable {
    let time: Date
    let speed: Double
    let direction: Double
    let gust: Double
}

/// Hourly forecast at one point.
struct WindSeries: Codable, Equatable {
    let coordinate: CLLocationCoordinate2D
    let samples: [WindSample]
    let fetched: Date

    /// The forecast hour nearest to `now + hours`.
    func sample(atHour hours: Double, from now: Date = Date()) -> WindSample? {
        guard now.timeIntervalSince(fetched) >= -60, now.timeIntervalSince(fetched) <= 3600 else { return nil }
        let target = now.addingTimeInterval(hours * 3600)
        return samples.min { abs($0.time.timeIntervalSince(target)) < abs($1.time.timeIntervalSince(target)) }
            .flatMap { abs($0.time.timeIntervalSince(target)) <= 3600 ? $0 : nil }
    }
}

enum Compass {
    private static let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    static func name(_ degrees: Double) -> String {
        names[Int(((degrees.truncatingRemainder(dividingBy: 360) + 360) / 22.5).rounded()) % 16]
    }

    /// Smallest angle between two bearings, 0...180.
    static func difference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}

/// Picks the map points to forecast. Points sit on a fixed lattice so cached forecasts get reused as
/// the map pans, and the count stays bounded however far you zoom out.
enum WindGrid {
    static let baseStep = 0.1          // degrees, about 6 nautical miles of latitude
    static let maxPerSide = 7

    static func lattice(for region: MKCoordinateRegion) -> [CLLocationCoordinate2D] {
        let span = max(region.span.latitudeDelta, region.span.longitudeDelta)
        var step = baseStep
        while span / step > Double(maxPerSide) { step *= 2 }

        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        var points: [CLLocationCoordinate2D] = []
        var lat = (minLat / step).rounded(.up) * step
        while lat <= maxLat {
            var lon = (minLon / step).rounded(.up) * step
            while lon <= maxLon {
                points.append(CLLocationCoordinate2D(latitude: (lat * 1000).rounded() / 1000, longitude: (lon * 1000).rounded() / 1000))
                lon += step
            }
            lat += step
        }
        // Zoomed in far enough that the lattice puts (almost) nothing on screen: show a 3×3 grid across
        // the view instead. They'll all read nearly the same, since the forecast model is coarse.
        if points.count < 4 {
            return (0..<3).flatMap { row in
                (0..<3).map { col in
                    CLLocationCoordinate2D(
                        latitude: ((minLat + region.span.latitudeDelta * (Double(row) + 0.5) / 3) * 1000).rounded() / 1000,
                        longitude: ((minLon + region.span.longitudeDelta * (Double(col) + 0.5) / 3) * 1000).rounded() / 1000)
                }
            }
        }
        return points
    }
}

/// Free wind forecasts from Open-Meteo (no API key, non-commercial use).
enum WindService {
    static func parse(_ data: Data, points: [CLLocationCoordinate2D], fetched: Date = Date()) throws -> [WindSeries] {
        struct Reply: Decodable {
            let hourly: Hourly
            struct Hourly: Decodable {
                let time: [Double]
                let wind_speed_10m: [Double?]
                let wind_direction_10m: [Double?]
                let wind_gusts_10m: [Double?]
            }
        }
        // One location returns an object; several return an array.
        let decoder = JSONDecoder()
        let replies: [Reply]
        if let many = try? decoder.decode([Reply].self, from: data) {
            replies = many
        } else {
            replies = [try decoder.decode(Reply.self, from: data)]
        }

        return zip(points, replies).map { point, reply in
            let h = reply.hourly
            let samples = h.time.indices.compactMap { i -> WindSample? in
                guard i < h.wind_speed_10m.count, i < h.wind_direction_10m.count, i < h.wind_gusts_10m.count,
                      let speed = h.wind_speed_10m[i], let dir = h.wind_direction_10m[i], let gust = h.wind_gusts_10m[i] else { return nil }
                return WindSample(time: Date(timeIntervalSince1970: h.time[i]), speed: speed, direction: dir, gust: gust)
            }
            return WindSeries(coordinate: point, samples: samples, fetched: fetched)
        }
    }

    /// Three days of hourly forecasts for each point, in a single request.
    static func fetch(_ points: [CLLocationCoordinate2D]) async throws -> [WindSeries] {
        guard !points.isEmpty else { return [] }
        let lats = points.map { String($0.latitude) }.joined(separator: ",")
        let lons = points.map { String($0.longitude) }.joined(separator: ",")
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lats)&longitude=\(lons)"
            + "&hourly=wind_speed_10m,wind_direction_10m,wind_gusts_10m&wind_speed_unit=kn"
            + "&forecast_days=3&timeformat=unixtime&timezone=GMT")!
        var request = URLRequest(url: url)
        request.setValue("AnchorWatch/0.1 (iOS; personal boat project)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data, points: points)
    }
}

/// Heads-up notices drawn from the forecast at the anchorage. These are advice, not the drag alarm.
struct WindAlert: Equatable {
    let title: String
    let time: Date
}

enum WindAdvice {
    /// Strong gusts or a big change in direction within the next `hours`.
    static func alerts(_ series: WindSeries, now: Date = Date(), hours: Double = 12,
                       gustLimit: Double, shiftDegrees: Double = 60, minSpeed: Double = 8) -> [WindAlert] {
        let end = now.addingTimeInterval(hours * 3600)
        let window = series.samples.filter { $0.time >= now.addingTimeInterval(-1800) && $0.time <= end }
        var result: [WindAlert] = []

        if let worst = window.max(by: { $0.gust < $1.gust }), worst.gust >= gustLimit {
            result.append(WindAlert(title: String(format: "Gusts to %.0f kt", worst.gust), time: worst.time))
        }

        // Only compare directions when there is enough wind for the boat to lie to it.
        let steady = window.filter { $0.speed >= minSpeed }
        if let first = steady.first, let turned = steady.first(where: { Compass.difference($0.direction, first.direction) >= shiftDegrees }) {
            result.append(WindAlert(title: "Wind shifts \(Compass.name(first.direction)) → \(Compass.name(turned.direction))", time: turned.time))
        }
        return result
    }
}

extension WindSeries {
    private enum CodingKeys: String, CodingKey { case latitude, longitude, samples, fetched }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coordinate = CLLocationCoordinate2D(latitude: try c.decode(Double.self, forKey: .latitude),
                                            longitude: try c.decode(Double.self, forKey: .longitude))
        samples = try c.decode([WindSample].self, forKey: .samples)
        fetched = try c.decode(Date.self, forKey: .fetched)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
        try c.encode(samples, forKey: .samples)
        try c.encode(fetched, forKey: .fetched)
    }
}
