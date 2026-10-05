import CoreLocation
import Foundation

enum NWSSeverity: Int, Comparable, Equatable {
    case unknown, minor, moderate, severe, extreme

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    init(_ text: String?) {
        switch text {
        case "Extreme": self = .extreme
        case "Severe": self = .severe
        case "Moderate": self = .moderate
        case "Minor": self = .minor
        default: self = .unknown
        }
    }
}

/// An active National Weather Service watch, warning or advisory covering the boat's position.
struct NWSAlert: Identifiable, Equatable {
    let id: String
    let event: String
    let headline: String
    let severity: NWSSeverity
    let onset: Date?
    /// When it ends: the event's own end time if given, otherwise its expiry.
    let ends: Date?
    let areaDesc: String
    let description: String
    let instruction: String

    /// Alerts worth interrupting a sleeping skipper for: serious ones, plus the marine and
    /// fast-developing hazards that matter at anchor whatever their official severity.
    var isUrgentForBoaters: Bool {
        if severity >= .moderate { return true }
        let keywords = ["small craft", "gale", "storm", "marine", "tornado", "waterspout", "thunderstorm",
                        "hurricane", "tropical", "tsunami", "dense fog", "surf", "high wind", "flood"]
        return keywords.contains { event.lowercased().contains($0) }
    }

    static let sample = NWSAlert(
        id: "sample", event: "Small Craft Advisory", headline: "Small Craft Advisory in effect until 10 PM",
        severity: .minor, onset: Date(), ends: Date().addingTimeInterval(6 * 3600),
        areaDesc: "Rosario Strait; Haro Strait",
        description: "* WHAT...Southwest winds 15 to 25 kt with gusts to 30 kt.\n* WHERE...Rosario Strait and Haro Strait.\n* IMPACTS...Conditions will be hazardous to small craft.",
        instruction: "Inexperienced mariners, especially those operating smaller vessels, should avoid navigating in hazardous conditions.")
}

/// Active alerts from api.weather.gov (free, US only, no key; asks for an identifying User-Agent).
enum AlertService {
    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    /// Drops alerts that have already ended and sorts the worst first.
    static func parse(_ data: Data, now: Date = Date()) throws -> [NWSAlert] {
        struct Reply: Decodable {
            let features: [Feature]
            struct Feature: Decodable { let properties: Props }
            struct Props: Decodable {
                let id: String?
                let event: String?
                let headline: String?
                let severity: String?
                let status: String?
                let onset: String?
                let effective: String?
                let ends: String?
                let expires: String?
                let areaDesc: String?
                let description: String?
                let instruction: String?
            }
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let alerts: [NWSAlert] = reply.features.compactMap { feature in
            let p = feature.properties
            guard let event = p.event, p.status == nil || p.status == "Actual" else { return nil }
            let ends = date(p.ends) ?? date(p.expires)
            if let ends, ends < now { return nil }
            return NWSAlert(id: p.id ?? event + (p.onset ?? ""), event: event, headline: p.headline ?? event,
                            severity: NWSSeverity(p.severity), onset: date(p.onset) ?? date(p.effective), ends: ends,
                            areaDesc: p.areaDesc ?? "", description: p.description ?? "", instruction: p.instruction ?? "")
        }
        return alerts.sorted { a, b in
            a.severity != b.severity ? a.severity > b.severity : (a.onset ?? .distantFuture) < (b.onset ?? .distantFuture)
        }
    }

    static func fetch(near point: CLLocationCoordinate2D) async throws -> [NWSAlert] {
        var components = URLComponents(string: "https://api.weather.gov/alerts/active")!
        components.queryItems = [URLQueryItem(name: "point", value: String(format: "%.4f,%.4f", point.latitude, point.longitude))]
        var request = URLRequest(url: components.url!)
        request.setValue("AnchorWatch/0.1 (personal boat project)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }
}
