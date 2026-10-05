import CoreLocation
import MapKit
import XCTest
@testable import AnchorWatch

final class GeoTests: XCTestCase {
    func testDestinationDistanceRoundTrip() {
        let a = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)
        let b = Geo.destination(from: a, bearing: 45, meters: 100)
        XCTAssertEqual(Geo.distance(a, b), 100, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: a, to: b), 45, accuracy: 0.1)
    }
}

final class ScopeTests: XCTestCase {
    func testFiveToOneInThreeMetres() {
        let s = ScopeSettings(depth: 3, bowHeight: 1.2, boatLength: 12, scopeRatio: 5, margin: 3)
        XCTAssertEqual(ScopeCalculator.rode(s), 21, accuracy: 0.001)
        XCTAssertEqual(ScopeCalculator.horizontalReach(s), 20.57, accuracy: 0.01)
        XCTAssertEqual(ScopeCalculator.suggestedRadius(s), 29.57, accuracy: 0.01)  // reach + half the boat + margin
    }

    func testTideRiseIsAddedToDepth() {
        var s = ScopeSettings(depth: 3, bowHeight: 1, boatLength: 12, scopeRatio: 5, margin: 0)
        XCTAssertEqual(ScopeCalculator.rode(s), 20, accuracy: 0.001)
        s.tideRise = 2
        XCTAssertEqual(ScopeCalculator.rode(s), 30, accuracy: 0.001)   // 5 × (3 + 2 + 1)
    }

    func testOldSavedSettingsStillDecode() throws {
        let old = #"{"depth":4,"bowHeight":1,"boatLength":15,"scopeRatio":7,"margin":5}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ScopeSettings.self, from: old)
        XCTAssertEqual(s.depth, 4)
        XCTAssertEqual(s.scopeRatio, 7)
        XCTAssertEqual(s.tideRise, 0)
    }

    func testShortRodeHasNoReach() {
        let s = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 10, scopeRatio: 1, margin: 0)
        XCTAssertEqual(ScopeCalculator.horizontalReach(s), 0)
    }
}

@MainActor
final class EngineTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)

    private func makeEngine() -> AnchorWatchEngine {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
    }

    private func fix(_ meters: Double) -> Fix {
        Fix(coordinate: Geo.destination(from: origin, bearing: 90, meters: meters),
            accuracy: 3, course: nil, speed: nil, timestamp: Date())
    }

    func testDropAveragesRecentFixes() {
        let e = makeEngine()
        e.ingest(fix(0)); e.ingest(fix(10))
        e.dropAnchor()
        XCTAssertEqual(Geo.distance(e.anchor!, origin), 5, accuracy: 0.1)
    }

    func testPoorAccuracyFlagged() {
        let e = makeEngine()
        XCTAssertTrue(e.gpsIsPoor, "no fix yet")
        e.ingest(fix(0))
        XCTAssertFalse(e.gpsIsPoor)
        e.ingest(Fix(coordinate: origin, accuracy: 40, course: nil, speed: nil, timestamp: Date()))
        XCTAssertTrue(e.gpsIsPoor)
    }

    func testBowPointsAtAnchorWhenAnchored() {
        let e = makeEngine()
        e.ingest(fix(0)); e.dropAnchor()
        e.ingest(fix(20))                       // boat 20 m east of the anchor
        XCTAssertEqual(e.heading ?? -1, 270, accuracy: 0.5)   // bow points west, at the anchor
    }

    func testMovingTheSimulatedBoatRaisesTheAnchorAndRemembersThePlace() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        e.ingest(fix(0)); e.dropAnchor()
        XCTAssertNotNil(e.anchor)
        e.simPlace = .sidney
        XCTAssertNil(e.anchor, "an anchor at Roche Harbor makes no sense once the boat is at Sidney")
        XCTAssertNil(e.fix)
        let again = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertEqual(again.simPlace, .sidney)
    }

    func testSimulatedPlacesAreDistinctAndKnown() {
        let places = SimulatedLocationSource.Place.allCases
        XCTAssertEqual(places.map(\.rawValue), ["Roche Harbor, WA", "Sidney, BC"])
        XCTAssertGreaterThan(Geo.distance(places[0].coordinate, places[1].coordinate), 10_000)
    }

    func testNoAlarmInsideCircle() {
        let e = makeEngine()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        for _ in 0..<5 { e.ingest(fix(20)) }
        XCTAssertNil(e.alarm)
    }

    func testAlarmNeedsTwoConsecutiveFixesOutside() {
        let e = makeEngine()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        e.ingest(fix(40))
        XCTAssertNil(e.alarm, "single glitch should not alarm")
        e.ingest(fix(20))
        e.ingest(fix(40))
        XCTAssertNil(e.alarm, "counter resets when back inside")
        e.ingest(fix(41))
        XCTAssertNotNil(e.alarm)
    }

    func testMovingAnchorCanClearThreat() {
        let e = makeEngine()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        e.ingest(fix(40))
        e.moveAnchor(to: fix(40).coordinate)
        e.ingest(fix(40))
        XCTAssertNil(e.alarm)
        XCTAssertEqual(e.distance ?? 99, 0, accuracy: 0.5)
    }

    func testSilenceSnoozesThenRaiseClears() {
        let e = makeEngine()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        e.ingest(fix(50)); e.ingest(fix(50))
        XCTAssertNotNil(e.alarm)
        e.silence()
        e.ingest(fix(50)); e.ingest(fix(50))
        XCTAssertNil(e.alarm, "snoozed")
        e.raiseAnchor()
        XCTAssertNil(e.anchor)
    }

    func testAnchorSurvivesRelaunch() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        a.ingest(fix(0)); a.dropAnchor(); a.radius = 55
        let b = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertEqual(b.radius, 55)
        XCTAssertNotNil(b.anchor)
    }
}

final class TideTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Low 0 m at t0, high 2 m six hours later, low 0 m six hours after that.
    private var events: [TideEvent] {
        [TideEvent(time: t0, height: 0, isHigh: false),
         TideEvent(time: t0.addingTimeInterval(6 * 3600), height: 2, isHigh: true),
         TideEvent(time: t0.addingTimeInterval(12 * 3600), height: 0, isHigh: false),
         TideEvent(time: t0.addingTimeInterval(18 * 3600), height: 2, isHigh: true)]
    }

    func testHeightInterpolatesBetweenLowAndHigh() {
        XCTAssertEqual(TideMath.height(at: t0.addingTimeInterval(3 * 3600), events: events)!, 1, accuracy: 0.001)   // midway
        XCTAssertEqual(TideMath.height(at: t0.addingTimeInterval(6 * 3600), events: events)!, 2, accuracy: 0.001)   // at the high
        XCTAssertNil(TideMath.height(at: t0.addingTimeInterval(-3600), events: events), "before the data")
    }

    func testRiseCoversTheNextHigh() {
        // From the low, the next 12 h include the 2 m high.
        XCTAssertEqual(TideMath.rise(from: t0, hours: 12, events: events)!, 2, accuracy: 0.01)
        // From midway up the flood, only 1 m of rise remains.
        XCTAssertEqual(TideMath.rise(from: t0.addingTimeInterval(3 * 3600), hours: 12, events: events)!, 1, accuracy: 0.01)
    }

    func testRiseIsZeroWhenTideIsFalling() {
        // From the high, the next 3 h are all lower.
        XCTAssertEqual(TideMath.rise(from: t0.addingTimeInterval(6 * 3600), hours: 3, events: events)!, 0, accuracy: 0.001)
    }

    func testNearestStation() {
        let near = TideStation(id: "1", name: "Near", lat: 48.61, lng: -123.15)
        let far = TideStation(id: "2", name: "Far", lat: 48.52, lng: -123.01)
        let point = CLLocationCoordinate2D(latitude: 48.6118, longitude: -123.1575)
        XCTAssertEqual(TideMath.nearest(to: point, in: [far, near])?.id, "1")
    }

    func testParsesNOAAReplies() throws {
        let stations = #"{"stations":[{"id":"9449834","name":"Roche Harbor, San Juan Island","state":"WA","lat":48.6117,"lng":-123.1583,"type":"R"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try TideService.parseStations(stations).first?.id, "9449834")

        let predictions = #"{"predictions":[{"t":"2026-10-05 06:35","v":"-0.232","type":"L"},{"t":"2026-10-05 14:53","v":"7.584","type":"H"}]}"#.data(using: .utf8)!
        let events = try TideService.parsePredictions(predictions)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].height, -0.232, accuracy: 0.0001)
        XCTAssertFalse(events[0].isHigh)
        XCTAssertTrue(events[1].isHigh)
        XCTAssertEqual(events[1].time.timeIntervalSince(events[0].time), (8 * 60 + 18) * 60, accuracy: 1)
    }
}

final class WindTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func series(_ rows: [(h: Double, speed: Double, dir: Double, gust: Double)]) -> WindSeries {
        WindSeries(coordinate: CLLocationCoordinate2D(latitude: 48.6, longitude: -123.1),
                   samples: rows.map { WindSample(time: t0.addingTimeInterval($0.h * 3600), speed: $0.speed, direction: $0.dir, gust: $0.gust) },
                   fetched: t0)
    }

    func testCompassNamesAndAngleDifference() {
        XCTAssertEqual(Compass.name(0), "N")
        XCTAssertEqual(Compass.name(315), "NW")
        XCTAssertEqual(Compass.name(359), "N")
        XCTAssertEqual(Compass.difference(350, 10), 20, accuracy: 0.001)   // wraps through north
        XCTAssertEqual(Compass.difference(90, 270), 180, accuracy: 0.001)
    }

    func testGustWarning() {
        let s = series([(0, 10, 270, 14), (3, 16, 270, 27), (6, 12, 270, 18)])
        let alerts = WindAdvice.alerts(s, now: t0, gustLimit: 25)
        XCTAssertEqual(alerts.map(\.title), ["Gusts to 27 kt"])
        XCTAssertEqual(alerts.first?.time, t0.addingTimeInterval(3 * 3600))
        XCTAssertTrue(WindAdvice.alerts(s, now: t0, gustLimit: 30).isEmpty)
    }

    func testWindShiftWarning() {
        let s = series([(0, 12, 315, 16), (2, 12, 330, 16), (4, 12, 350, 16), (6, 12, 180, 20)])
        let alerts = WindAdvice.alerts(s, now: t0, gustLimit: 40)
        XCTAssertEqual(alerts.map(\.title), ["Wind shifts NW → S"])   // 315° to 180° is a 135° turn
        XCTAssertEqual(alerts.first?.time, t0.addingTimeInterval(6 * 3600))
    }

    func testLightWindDirectionIsIgnored() {
        // Below 8 kt the boat isn't lying to the wind, so a swing in direction isn't worth a warning.
        let s = series([(0, 3, 0, 4), (3, 2, 180, 3)])
        XCTAssertTrue(WindAdvice.alerts(s, now: t0, gustLimit: 25).isEmpty)
    }

    func testLatticeStaysBoundedAndInsideTheView() {
        let near = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.61, longitude: -123.16),
                                      span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))
        let pts = WindGrid.lattice(for: near)
        XCTAssertFalse(pts.isEmpty)
        XCTAssertTrue(pts.allSatisfy { abs($0.latitude - 48.61) <= 0.15 && abs($0.longitude + 123.16) <= 0.15 })

        let wide = MKCoordinateRegion(center: near.center, span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40))
        XCTAssertLessThanOrEqual(WindGrid.lattice(for: wide).count, 64 + 16, "zooming out must not request hundreds of points")
    }

    func testZoomedInViewStillGetsArrows() {
        let tight = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.6118, longitude: -123.1575),
                                       span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003))
        let pts = WindGrid.lattice(for: tight)
        XCTAssertEqual(pts.count, 9)
        XCTAssertTrue(pts.allSatisfy { abs($0.latitude - 48.6118) <= 0.002 && abs($0.longitude + 123.1575) <= 0.002 })
    }

    func testParsesOpenMeteoSingleAndMultiple() throws {
        let one = #"{"hourly":{"time":[1800000000,1800003600],"wind_speed_10m":[10.5,null],"wind_direction_10m":[270,280],"wind_gusts_10m":[15,16]}}"#.data(using: .utf8)!
        let p = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.1)
        let single = try WindService.parse(one, points: [p])
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].samples.count, 1, "the hour with a null speed is dropped")
        XCTAssertEqual(single[0].samples[0].speed, 10.5)

        let many = "[\(String(data: one, encoding: .utf8)!),\(String(data: one, encoding: .utf8)!)]".data(using: .utf8)!
        XCTAssertEqual(try WindService.parse(many, points: [p, p]).count, 2)
    }

    func testSeriesPicksNearestHour() {
        let s = series([(0, 10, 270, 14), (1, 20, 270, 24), (2, 30, 270, 34)])
        XCTAssertEqual(s.sample(atHour: 1.2, from: t0)?.speed, 20)
        XCTAssertNil(s.sample(atHour: 10, from: t0), "no forecast that far ahead")
    }
}

final class AlertTests: XCTestCase {
    private let json = #"""
    {"features":[
      {"properties":{"id":"a1","event":"Small Craft Advisory","headline":"Small Craft Advisory until 10 PM","severity":"Minor","status":"Actual",
        "onset":"2026-10-05T12:00:00-07:00","ends":"2026-10-05T22:00:00-07:00","expires":"2026-10-05T14:00:00-07:00",
        "areaDesc":"Rosario Strait","description":"Winds 15 to 25 kt.","instruction":"Avoid navigating."}},
      {"properties":{"id":"a2","event":"Gale Warning","headline":"Gale Warning","severity":"Moderate","status":"Actual",
        "onset":"2026-10-05T18:00:00-07:00","ends":"2026-10-06T04:00:00-07:00","areaDesc":"Haro Strait"}},
      {"properties":{"id":"a3","event":"Dense Fog Advisory","severity":"Minor","status":"Actual",
        "onset":"2026-10-04T01:00:00-07:00","ends":"2026-10-04T12:00:00-07:00"}},
      {"properties":{"id":"a4","event":"Test Message","severity":"Minor","status":"Test","ends":"2026-10-06T12:00:00-07:00"}}
    ]}
    """#.data(using: .utf8)!

    /// 1 PM Pacific on 5 Oct 2026.
    private let now = ISO8601DateFormatter().date(from: "2026-10-05T13:00:00-07:00")!

    func testParseDropsEndedAndTestAlertsAndSortsWorstFirst() throws {
        let alerts = try AlertService.parse(json, now: now)
        XCTAssertEqual(alerts.map(\.id), ["a2", "a1"], "gale (moderate) before small craft (minor); fog ended; test dropped")
    }

    func testEndsPrefersEventEndOverExpiry() throws {
        let sca = try AlertService.parse(json, now: now).first { $0.id == "a1" }!
        XCTAssertEqual(sca.ends, ISO8601DateFormatter().date(from: "2026-10-05T22:00:00-07:00"))
    }

    func testMissingFieldsAreTolerated() throws {
        let gale = try AlertService.parse(json, now: now).first { $0.id == "a2" }!
        XCTAssertEqual(gale.description, "")
        XCTAssertEqual(gale.areaDesc, "Haro Strait")
    }

    func testNoAlertsIsAnEmptyList() throws {
        XCTAssertTrue(try AlertService.parse(#"{"features":[]}"#.data(using: .utf8)!, now: now).isEmpty)
    }

    func testBoatingUrgency() throws {
        let alerts = try AlertService.parse(json, now: now)
        XCTAssertTrue(alerts.allSatisfy(\.isUrgentForBoaters), "small craft and gale both matter at anchor")
        let heat = NWSAlert(id: "h", event: "Heat Advisory", headline: "", severity: .minor, onset: nil, ends: nil, areaDesc: "", description: "", instruction: "")
        XCTAssertFalse(heat.isUrgentForBoaters)
        let severeAny = NWSAlert(id: "s", event: "Something Odd", headline: "", severity: .severe, onset: nil, ends: nil, areaDesc: "", description: "", instruction: "")
        XCTAssertTrue(severeAny.isUrgentForBoaters)
    }
}

final class ObservationTests: XCTestCase {
    private let sample = """
    #STN       LAT      LON  YYYY MM DD hh mm WDIR WSPD   GST WVHT  DPD APD MWD   PRES  PTDY  ATMP  WTMP  DEWP  VIS   TIDE
    #text      deg      deg   yr mo day hr mn degT  m/s   m/s   m   sec sec degT   hPa   hPa  degC  degC  degC  nmi     ft
    FRDW1    48.55 -123.01  2026 10 05 17 36 120   2.6   3.1   MM   MM  MM  MM 1021.0  -0.4  10.6    MM    MM   MM     MM
    46088    48.33 -123.18  2026 10 05 17 50 200   5.0   6.0  0.5    5  4.0 190 1020.3   1.2  11.1  11.1  9.0   MM     MM
    CHYW1    48.80 -123.10  2026 10 05 17 30  MM    MM    MM   MM   MM  MM  MM 1020.2  -0.1    MM    MM    MM   MM     MM
    OLDW1    48.60 -123.20  2026 10 05 09 00 100   4.0   5.0   MM   MM  MM  MM 1019.0   0.0  11.0    MM    MM   MM     MM
    FARTT    28.60  -96.60  2026 10 05 17 30  40   5.1   6.2   MM   MM  MM  MM 1015.6   0.5  26.2  25.9    MM   MM     MM
    """

    /// 6 PM UTC on 5 Oct 2026.
    private var now: Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18, minute: 0))!
    }

    func testParsesValuesAndConvertsWindToKnots() {
        let all = ObservationService.parse(sample)
        XCTAssertEqual(all.count, 5)
        let f = all.first { $0.id == "FRDW1" }!
        XCTAssertEqual(f.windSpeed!, 2.6 * 1.943844, accuracy: 0.001)
        XCTAssertEqual(f.windDirection, 120)
        XCTAssertNil(f.waveHeight, "MM means missing")
        XCTAssertEqual(f.pressure, 1021.0)
        let b = all.first { $0.id == "46088" }!
        XCTAssertEqual(b.waveHeight, 0.5)
        XCTAssertEqual(b.wavePeriod, 5)
        XCTAssertEqual(b.pressureTrend, 1.2)
    }

    func testNearbyIgnoresStaleFarAndWindlessStations() {
        let point = CLLocationCoordinate2D(latitude: 48.6118, longitude: -123.1575)
        let near = ObservationMath.nearby(ObservationService.parse(sample), to: point, now: now)
        let ids = near.map(\.id)
        XCTAssertFalse(ids.contains("OLDW1"), "last reported 9 hours ago")
        XCTAssertFalse(ids.contains("FARTT"), "Texas is thousands of km away")
        XCTAssertFalse(ids.contains("CHYW1"), "no wind data")
        XCTAssertEqual(ids.first, "FRDW1", "nearest first")
        XCTAssertTrue(ids.contains("46088"))
        XCTAssertGreaterThan(near[0].distanceKm, 0)
    }

    func testSummaryLineForTheMapCallout() {
        let all = ObservationService.parse(sample)
        let f = all.first { $0.id == "FRDW1" }!
        // 17:36 UTC reading, viewed at 17:48 → 12 minutes old; 2.6 m/s ≈ 5 kt, gust 3.1 m/s ≈ 6 kt.
        XCTAssertEqual(f.summary(now: f.time.addingTimeInterval(12 * 60)), "ESE 5 kt, gusts 6 · 12 min ago")
        XCTAssertEqual(f.summary(now: f.time.addingTimeInterval(95 * 60)), "ESE 5 kt, gusts 6 · 1 h 35 min ago")
        let windless = all.first { $0.id == "CHYW1" }!
        XCTAssertTrue(windless.summary(now: windless.time).hasPrefix("no wind reported"))
    }

    func testPressureTrendArrow() {
        let all = ObservationService.parse(sample)
        XCTAssertEqual(all.first { $0.id == "46088" }?.trendArrow, "↑")
        XCTAssertEqual(all.first { $0.id == "FRDW1" }?.trendArrow, "→", "-0.4 is within the steady band")
    }

    func testGustAlertPicksTheStrongestAtOrAboveTheLimit() {
        let point = CLLocationCoordinate2D(latitude: 48.6118, longitude: -123.1575)
        let all = ObservationMath.nearby(ObservationService.parse(sample), to: point, now: now)
        XCTAssertNil(ObservationMath.gustAlert(all, limit: 25))
        let hit = ObservationMath.gustAlert(all, limit: 10)   // 6 m/s ≈ 11.7 kt at 46088
        XCTAssertEqual(hit?.station.id, "46088")
    }

    func testParsesStationNamesCaseInsensitively() {
        let xml = """
        <station id="frdw1" lat="48.545" lon="-123.012" elev="6.1" name="9449880 - Friday Harbor, WA" owner="NOS" type="fixed"/>
        <station id="46088" lat="48.332" lon="-123.179" elev="0" name="NEW DUNGENESS - 17 NM NE of Port Angeles, WA" owner="NDBC"/>
        """
        let names = ObservationService.parseNames(xml)
        XCTAssertEqual(names["FRDW1"], "9449880 - Friday Harbor, WA")
        XCTAssertEqual(StationName.short("9449880 - Friday Harbor, WA"), "Friday Harbor, WA")
        XCTAssertEqual(StationName.short("NEW DUNGENESS - 17 NM NE of Port Angeles, WA"), "NEW DUNGENESS")
        XCTAssertEqual(StationName.short("Smith Island, WA"), "Smith Island, WA")
    }
}

final class CanadianDataTests: XCTestCase {
    func testCHSStationsKeepOnlyThoseWithPredictions() throws {
        let json = #"""
        [{"id":"abc","officialName":"Sidney","latitude":48.649,"longitude":-123.393,"timeSeries":[{"code":"wlo"},{"code":"wlp-hilo"}]},
         {"id":"def","officialName":"Gauge Only","latitude":49.0,"longitude":-123.0,"timeSeries":[{"code":"wlo"}]},
         {"id":"ghi","officialName":"No Series","latitude":49.0,"longitude":-123.0}]
        """#.data(using: .utf8)!
        let stations = try TideService.parseCHSStations(json)
        XCTAssertEqual(stations.map(\.name), ["Sidney"])
        XCTAssertEqual(stations[0].source, TideStation.chs)
    }

    /// Real Sidney, BC data: a mixed tide, with a near-flat pair of heights at the start.
    func testCHSHighLowLabelling() throws {
        let rows = [("2026-10-05T03:57:00Z", 2.583), ("2026-10-05T04:59:00Z", 2.587), ("2026-10-05T13:33:00Z", 0.643),
                    ("2026-10-05T22:05:00Z", 3.095), ("2026-10-06T04:21:00Z", 2.348), ("2026-10-06T07:15:00Z", 2.463),
                    ("2026-10-06T14:39:00Z", 0.789), ("2026-10-06T22:41:00Z", 3.059)]
        let json = "[" + rows.map { #"{"eventDate":"\#($0.0)","value":\#($0.1)}"# }.joined(separator: ",") + "]"
        let events = try TideService.parseCHSEvents(json.data(using: .utf8)!)
        XCTAssertEqual(events.map(\.isHigh), [false, true, false, true, false, true, false, true])
        XCTAssertEqual(events[3].height, 3.095, accuracy: 0.0001)
    }

    func testBorderPicksTheNearestStationOfEitherCountry() {
        let friday = TideStation(id: "9449880", name: "Friday Harbor, WA", lat: 48.545, lng: -123.012)
        let sidney = TideStation(id: "abc", name: "Sidney", lat: 48.649, lng: -123.393, source: TideStation.chs)
        let nearSidney = CLLocationCoordinate2D(latitude: 48.66, longitude: -123.35)
        XCTAssertEqual(TideMath.nearest(to: nearSidney, in: [friday, sidney])?.id, "abc")
        let roche = CLLocationCoordinate2D(latitude: 48.6118, longitude: -123.1575)
        XCTAssertEqual(TideMath.nearest(to: roche, in: [friday, sidney])?.id, "9449880")
    }

    func testOldSavedStationsDefaultToNOAA() throws {
        let old = #"{"id":"9449834","name":"Roche Harbor","lat":48.61,"lng":-123.15}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(TideStation.self, from: old).source, TideStation.noaa)
    }

    func testParsesCanadianObservationAndConvertsKmhToKnots() throws {
        let json = #"""
        {"features":[{"geometry":{"coordinates":[-123.531394,48.297992,32.9]},
         "properties":{"stn_nam-value":"RACE ROCKS","tc_id-value":"WQK","date_tm-value":"2026-10-05T20:17:00.000Z",
           "avg_wnd_spd_10m_pst10mts":44.7,"avg_wnd_dir_10m_pst10mts":285,"max_wnd_spd_10m_pst10mts":51.9,
           "stn_pres":1016.5,"air_temp":15.6,"vis":null}}]}
        """#.data(using: .utf8)!
        let obs = try XCTUnwrap(try ObservationService.parseCanadianObservation(json))
        XCTAssertEqual(obs.name, "RACE ROCKS")
        XCTAssertEqual(obs.id, "EC-WQK")
        XCTAssertEqual(obs.windSpeed!, 44.7 / 1.852, accuracy: 0.001)    // 24.1 kt
        XCTAssertEqual(obs.gust!, 51.9 / 1.852, accuracy: 0.001)         // 28.0 kt
        XCTAssertEqual(obs.windDirection, 285)
        XCTAssertEqual(obs.pressure, 1016.5)
        XCTAssertNil(obs.visibility)
        XCTAssertEqual(obs.coordinate.latitude, 48.297992, accuracy: 0.0001)
    }

    func testEmptyCanadianReplyIsNotAnError() throws {
        XCTAssertNil(try ObservationService.parseCanadianObservation(#"{"features":[]}"#.data(using: .utf8)!))
    }

    func testParsesCanadianStationList() throws {
        let json = #"{"features":[{"geometry":{"coordinates":[-123.53,48.29,32]},"properties":{"name":"RACE ROCKS"}},{"geometry":{"coordinates":[0]},"properties":{"name":"BAD"}}]}"#.data(using: .utf8)!
        let list = try ObservationService.parseCanadianStations(json)
        XCTAssertEqual(list.map(\.name), ["RACE ROCKS"], "entries without a position are skipped")
    }
}

@MainActor
final class SafetyTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)

    private func make(player: SilentAlarm? = nil) -> AnchorWatchEngine {
        AnchorWatchEngine(player: player ?? SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
    }

    private func fix(_ meters: Double, accuracy: Double = 3) -> Fix {
        Fix(coordinate: Geo.destination(from: origin, bearing: 90, meters: meters), accuracy: accuracy, course: nil, speed: nil, timestamp: Date())
    }

    // MARK: GPS quality

    func testVeryPoorFixesAreIgnoredForDistanceAndAlarm() {
        let e = make()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        for _ in 0..<5 { e.ingest(fix(200, accuracy: 120)) }     // far away, but reported ±120 m
        XCTAssertNil(e.alarm)
        XCTAssertEqual(e.distance ?? 99, 0, accuracy: 1, "distance stays at the last good reading")
        XCTAssertEqual(e.fix?.accuracy, 120, "but the screen still reports the poor accuracy")
        XCTAssertTrue(e.gpsIsUnusable)
    }

    func testAlarmNeedsToBeBeyondTheRadiusPlusTheFixError() {
        let e = make()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        // 33 m with ±6 m error could still be inside the circle: no alarm.
        for _ in 0..<4 { e.ingest(fix(33, accuracy: 6)) }
        XCTAssertNil(e.alarm)
        // 38 m with ±6 m error is confidently outside.
        e.ingest(fix(38, accuracy: 6)); e.ingest(fix(38, accuracy: 6))
        XCTAssertNotNil(e.alarm)
    }

    func testAccuracyDiscountIsCapped() {
        let e = make()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        // ±40 m would swallow a 41 m reading entirely, but the credit is capped at 30% of the radius (9 m).
        e.ingest(fix(41, accuracy: 40)); e.ingest(fix(41, accuracy: 40))
        XCTAssertNotNil(e.alarm)
    }

    func testGoingBackInsideResetsTheCount() {
        let e = make()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        e.ingest(fix(45)); e.ingest(fix(20)); e.ingest(fix(45))
        XCTAssertNil(e.alarm, "the count restarted when the boat came back inside")
    }

    // MARK: Battery

    func testLowBatteryAlarmWhenNotCharging() {
        let player = SilentAlarm()
        let e = make(player: player)
        e.ingest(fix(0)); e.dropAnchor()
        e.setBattery(level: 0.08, charging: false)
        e.safetyChecks()
        XCTAssertEqual(e.alarm?.kind, "battery")
        XCTAssertEqual(e.alarm?.message, "Phone battery 8% and not charging")
        XCTAssertTrue(player.sirenSounding)
    }

    func testNoBatteryAlarmWhileChargingOrUnanchored() {
        let e = make()
        e.setBattery(level: 0.05, charging: false)
        e.safetyChecks()
        XCTAssertNil(e.alarm, "no anchor, nothing to watch")
        e.ingest(fix(0)); e.dropAnchor()
        e.setBattery(level: 0.05, charging: true)
        e.safetyChecks()
        XCTAssertNil(e.alarm, "charging")
    }

    func testDragAlarmTakesOverFromABatteryAlarm() {
        let e = make()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        e.setBattery(level: 0.05, charging: false)
        e.safetyChecks()
        XCTAssertEqual(e.alarm.map { $0.kind }, "battery")
        e.ingest(fix(60)); e.ingest(fix(60))
        XCTAssertEqual(e.alarm.map { $0.kind }, "outside", "a drifting boat outranks a flat battery")
    }

    func testSilencingOneAlarmDoesNotSilenceTheOthers() {
        let e = make()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        e.setBattery(level: 0.05, charging: false)
        e.safetyChecks()
        e.silence()                           // snoozes the battery alarm for 10 minutes
        e.safetyChecks()
        XCTAssertNil(e.alarm, "still snoozed")
        e.ingest(fix(60)); e.ingest(fix(60))
        XCTAssertEqual(e.alarm.map { $0.kind }, "outside", "the drag alarm is not snoozed")
    }

    // MARK: Audio arming

    func testAudioIsArmedOnlyWhileAnchored() {
        let player = SilentAlarm()
        let e = make(player: player)
        e.ingest(fix(0))
        XCTAssertFalse(player.armed)
        e.dropAnchor()
        XCTAssertTrue(player.armed, "the audio engine must already be running when an alarm fires in the background")
        e.raiseAnchor()
        XCTAssertFalse(player.armed)
    }

    // MARK: Checklist

    private func input(volume: Float? = 0.8, battery: Float? = 0.9, charging: Bool = true, accuracy: Double? = 4, radius: Double = 30) -> ReadinessInput {
        ReadinessInput(volume: volume, audioRoute: nil, batteryLevel: battery, charging: charging,
                       notificationsAllowed: true, locationAlways: true, accuracy: accuracy, radius: radius)
    }

    func testChecklistAllGood() {
        XCTAssertTrue(Readiness.problems(input(), format: { String(format: "%.0f m", $0) }).isEmpty)
    }

    func testChecklistFlagsVolumeBatteryAndRoute() {
        var i = input(volume: 0.15, battery: 0.12, charging: false)
        i.audioRoute = "AirPods"
        let problems = Readiness.problems(i, format: { String(format: "%.0f m", $0) })
        XCTAssertEqual(Set(problems.map(\.id)), ["volume", "battery", "route"])
        XCTAssertEqual(problems.first { $0.id == "volume" }?.state, .critical)
        XCTAssertEqual(problems.first { $0.id == "battery" }?.state, .critical)
        XCTAssertEqual(problems.first { $0.id == "route" }?.state, .warning)
    }

    func testChecklistWarnsWhenCircleIsSmallForTheGPS() {
        // ±7 m is good GPS, but a 15 m circle is barely twice that: expect false alarms.
        let problems = Readiness.problems(input(accuracy: 7, radius: 15), format: { String(format: "%.0f m", $0) })
        XCTAssertEqual(problems.map(\.id), ["radius"])
        // ±10 m is only fair GPS, so that is flagged as well.
        let fair = Readiness.problems(input(accuracy: 10, radius: 40), format: { String(format: "%.0f m", $0) })
        XCTAssertEqual(fair.map(\.id), ["gps"])
    }

    func testChecklistHandlesUnknownValues() {
        let checks = Readiness.checks(ReadinessInput(radius: 30), format: { "\($0)" })
        XCTAssertTrue(checks.contains { $0.id == "volume" && $0.state == .unknown })
        XCTAssertTrue(checks.contains { $0.id == "battery" && $0.state == .unknown })
        XCTAssertTrue(Readiness.problems(ReadinessInput(radius: 30), format: { "\($0)" }).isEmpty, "unknown is not a problem")
    }
}

@MainActor
final class LiveActivityTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)

    private func fix(_ meters: Double) -> Fix {
        Fix(coordinate: Geo.destination(from: origin, bearing: 90, meters: meters), accuracy: 3, course: nil, speed: nil, timestamp: Date())
    }

    func testSnapshotFollowsTheWatch() {
        let live = NoLiveActivity()
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: live, defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        XCTAssertNil(e.snapshot, "no anchor, no Live Activity")

        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        e.ingest(fix(10))
        var snap = try! XCTUnwrap(e.snapshot)
        XCTAssertEqual(snap.status, .holding)
        XCTAssertEqual(snap.fraction, 10.0 / 30.0, accuracy: 0.05)
        XCTAssertEqual(snap.distanceText, "33 ft")

        e.ingest(fix(60)); e.ingest(fix(60))
        snap = try! XCTUnwrap(e.snapshot)
        XCTAssertEqual(snap.status, .alarm)
        XCTAssertEqual(snap.headline, "Boat has left the alarm circle")
        XCTAssertGreaterThan(snap.fraction, 1)

        e.safetyChecks()
        XCTAssertEqual(live.snapshots.last??.status, .alarm, "the controller is fed on every safety tick")
        e.raiseAnchor()
        e.safetyChecks()
        XCTAssertNil(live.snapshots.last ?? nil, "raising the anchor ends the activity")
    }

    func testSirenTestShowsAsAnAlarmOnTheLockScreen() {
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.ingest(fix(0)); e.dropAnchor()
        XCTAssertEqual(e.snapshot?.status, .holding)
        e.testingSiren = true
        XCTAssertEqual(e.snapshot?.status, .alarm)
        XCTAssertEqual(e.snapshot?.headline, "Siren test, not a real alarm")
        e.testingSiren = false
        XCTAssertEqual(e.snapshot?.status, .holding)
    }

    func testChecklistReportsWhyTheLiveActivityIsMissing() {
        func check(_ state: LiveActivityState?) -> WatchCheck? {
            var i = ReadinessInput(radius: 30)
            i.liveActivity = state
            return Readiness.checks(i, format: { "\($0)" }).first { $0.id == "liveActivity" }
        }
        XCTAssertEqual(check(.running)?.state, .ok)
        XCTAssertEqual(check(.disabled)?.state, .warning)
        XCTAssertTrue(check(.disabled)?.detail.contains("Live Activities") == true)
        XCTAssertEqual(check(.failed("unsupported"))?.detail, "unsupported")
        XCTAssertNil(check(.idle), "nothing to report with no anchor set")
        XCTAssertNil(check(nil))
    }

    func testCriticalProblemShowsAsCaution() {
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.ingest(fix(0)); e.dropAnchor()
        e.setBattery(level: 0.12, charging: false)        // critical, but not yet the 10% alarm
        XCTAssertEqual(e.snapshot?.status, .caution)
        XCTAssertEqual(e.snapshot?.headline, "Battery 12% and not charging")
    }
}

@MainActor
final class UserGuideTests: XCTestCase {
    func testEveryTopicHasContentAndIdsAreUnique() {
        let topics = UserGuideContent.topics
        XCTAssertGreaterThanOrEqual(topics.count, 14)
        XCTAssertEqual(Set(topics.map(\.id)).count, topics.count, "topic ids must be unique")
        for topic in topics {
            XCTAssertFalse(topic.title.isEmpty)
            XCTAssertFalse(topic.blocks.isEmpty, "\(topic.title) is empty")
        }
        XCTAssertEqual(UserGuideContent.sections.map(\.title), ["Getting started", "Keeping watch", "Charts and weather", "Reference"])
    }

    /// The guide quotes these numbers; they must match what the app actually does.
    func testGuideNumbersMatchTheApp() {
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        XCTAssertEqual(GuideFacts.confirmFixes, e.confirmFixes)
        XCTAssertEqual(GuideFacts.gpsLostSeconds, Int(e.gpsLostAfter))
        XCTAssertEqual(GuideFacts.gpsPoorSeconds, Int(e.gpsPoorAfter))
        XCTAssertEqual(GuideFacts.controlsFadeSeconds, Int(e.controlsFadeDelay))
        XCTAssertEqual(GuideFacts.goodAccuracyMeters, e.goodAccuracy)
        XCTAssertEqual(GuideFacts.unusableAccuracyMeters, e.usableAccuracy)
        XCTAssertEqual(GuideFacts.discountCapPercent, Int((e.accuracyDiscountCap * 100).rounded()))
        XCTAssertEqual(GuideFacts.averagingSeconds, Int(e.averagingWindow))
        XCTAssertEqual(GuideFacts.gustDefaultKnots, Int(e.gustLimit))
        XCTAssertEqual(GuideFacts.batteryNoticePercent, Int((BatteryAdvice.noticeLevel * 100).rounded()))
        XCTAssertEqual(GuideFacts.batteryAlarmPercent, Int((BatteryAdvice.alarmLevel * 100).rounded()))
        XCTAssertEqual(GuideFacts.batteryWarnPercent, Int((BatteryAdvice.warningLevel * 100).rounded()))
        XCTAssertEqual(GuideFacts.snoozeSeconds, Int(AlarmReason.gpsLost.snooze))
        XCTAssertEqual(GuideFacts.batterySnoozeMinutes, Int(AlarmReason.lowBattery(level: 0.05).snooze / 60))
    }

    func testGuideMentionsWhatItClaimsAboutDefaults() {
        // The guide says the siren, gust and fade numbers; make sure the quoted text actually contains them.
        let all = UserGuideContent.topics.flatMap(\.blocks).map { block -> String in
            switch block {
            case .heading(let t), .text(let t), .tip(let t), .warning(let t): return t
            case .bullets(let items): return items.joined(separator: " ")
            }
        }.joined(separator: " ")
        for phrase in ["30 seconds", "60 seconds", "10 minutes", "6 seconds", "25 knots", "60°", "Test siren in 15 seconds", "Drop Anchor Here", "Depth & Scope"] {
            XCTAssertTrue(all.contains(phrase), "the guide should mention \"\(phrase)\"")
        }
    }
}
