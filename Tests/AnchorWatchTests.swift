import struct SwiftUI.Path
import CoreLocation
import CryptoKit
import MapKit
import JavaScriptCore
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
    func testSharedAndroidScopeFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let csv = try String(contentsOf: root.appendingPathComponent("fixtures/scope.csv"), encoding: .utf8)
        let rows = csv.split(separator: "\n").dropFirst()
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let cells = row.split(separator: ",").map(String.init)
            let values = try cells.dropFirst().map { try XCTUnwrap(Double($0)) }
            let settings = ScopeSettings(depth: values[0], tideRise: values[1], bowHeight: values[2],
                                         boatLength: values[3], scopeRatio: values[4], margin: values[5])
            XCTAssertEqual(ScopeCalculator.rode(settings), values[6], accuracy: 1e-8, cells[0])
            XCTAssertEqual(ScopeCalculator.suggestedRadius(settings), values[7], accuracy: 1e-8, cells[0])
        }
    }

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
        XCTAssertEqual(e.environmentLocation, e.simPlace.coordinate)
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

    func testSideButtonsFadeOnlyWhenSetAndComeBackOnATap() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        e.controlsFadeDelay = 0.05
        e.pokeControls()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(e.sideButtonsVisible)          // off by default: always shown

        e.fadeSideButtons = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(e.sideButtonsVisible)         // fades even with no anchor down
        XCTAssertTrue(e.controlsVisible)             // the bottom panel still waits for an anchor

        e.pokeControls()                             // a tap on the chart
        XCTAssertTrue(e.sideButtonsVisible)

        let again = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertTrue(again.fadeSideButtons)         // remembered
    }

    func testDropRecordsGPSUncertaintyUntilMovedByHand() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        e.ingest(fix(0)); e.dropAnchor()
        // Didn't move and no wind: bow direction unknown, so the circle covers the half boat length too.
        let expected = fix(0).accuracy + ScopeCalculator.gpsFromBow(e.scope)
        XCTAssertEqual(e.anchorPlacement?.source, .unknown)
        XCTAssertEqual(e.anchorUncertainty!, expected, accuracy: 0.001)

        let again = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertEqual(again.anchorUncertainty!, expected, accuracy: 0.001)   // survives a relaunch

        e.moveAnchor(to: Geo.destination(from: e.anchor!, bearing: 90, meters: 10))
        XCTAssertNil(e.anchorUncertainty)                                      // placed by hand
        e.moveAnchorToBoat()
        XCTAssertEqual(e.anchorPlacement?.source, .anchor)                     // bow points along the rode
        XCTAssertNotNil(e.anchorUncertainty)
        e.raiseAnchor()
        XCTAssertNil(e.anchorUncertainty)
    }

    func testDropAfterAnApproachPutsTheAnchorAtTheBow() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        // Motor 40 m east over half a minute, then stop.
        for i in 0...10 {
            var f = fix(Double(i) * 4)
            f.timestamp = Date().addingTimeInterval(Double(i - 10) * 3)
            e.ingest(f, receivedAt: f.timestamp)
        }
        e.dropAnchor()
        let half = ScopeCalculator.gpsFromBow(e.scope)
        XCTAssertEqual(e.anchorPlacement?.source, .approach)
        // The drop point averages the last 8 s of fixes (32, 36 and 40 m), then moves half a boat length east.
        let averaged = fix(36).coordinate
        XCTAssertEqual(Geo.distance(e.anchor!, averaged), half, accuracy: 0.05)
        XCTAssertEqual(Geo.bearing(from: averaged, to: e.anchor!), 90, accuracy: 1)
    }

    func testTrackRecordsUnderWayOnlyWhenSet() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        e.ingest(fix(0)); e.ingest(fix(5))
        XCTAssertTrue(e.track.isEmpty)                  // off by default: no track until anchored

        e.trackWhenUnanchored = true
        e.ingest(fix(10)); e.ingest(fix(15))
        XCTAssertEqual(e.track.count, 2)

        e.dropAnchor()
        XCTAssertEqual(e.track.count, 2)                // the way in is kept
        e.raiseAnchor()
        e.ingest(fix(20))
        XCTAssertEqual(e.track.count, 1)                // and recording carries on under way

        e.trackWhenUnanchored = false
        XCTAssertTrue(e.track.isEmpty)
        XCTAssertFalse(AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false).trackWhenUnanchored)
    }

    /// 40 minutes swinging 120° on a 36 m circle round `anchor`.
    private func swing(_ e: AnchorWatchEngine, around anchor: CLLocationCoordinate2D) {
        for i in 0..<240 {
            let bearing = 160 + 120 * (0.5 - 0.5 * cos(Double(i) / 240 * 4 * .pi))
            e.ingest(Fix(coordinate: Geo.destination(from: anchor, bearing: bearing, meters: 36), accuracy: 3,
                         course: nil, speed: nil, timestamp: Date().addingTimeInterval(180 + Double(i) * 10)), receivedAt: Date().addingTimeInterval(180 + Double(i) * 10))
        }
    }

    func testFirstSwingFitCorrectsTheMarkOnceAndUndoPutsItBack() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.ingest(fix(0)); e.dropAnchor()
        let mark = e.anchor!
        let anchor = Geo.destination(from: mark, bearing: 45, meters: 12)
        swing(e, around: anchor)
        e.updateAnchorEstimate()
        XCTAssertLessThan(Geo.distance(e.anchor!, anchor), 2, "moved to the swing's centre without being asked")
        XCTAssertTrue(e.anchorAgreesWithSwing, "so the chart shows just the anchor")
        XCTAssertEqual(e.anchorCorrection?.meters ?? 0, 12, accuracy: 2)

        e.undoAnchorCorrection()
        XCTAssertLessThan(Geo.distance(e.anchor!, mark), 0.01)
        XCTAssertNil(e.anchorCorrection)
        e.updateAnchorEstimate()
        XCTAssertLessThan(Geo.distance(e.anchor!, mark), 0.01, "only once: after that a moving estimate is for the drag warning")
    }

    func testHandPlacedMarkIsNotCorrected() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.ingest(fix(0)); e.dropAnchor()
        let placed = Geo.destination(from: e.anchor!, bearing: 200, meters: 8)
        e.moveAnchor(to: placed)
        swing(e, around: Geo.destination(from: placed, bearing: 45, meters: 12))
        e.updateAnchorEstimate()
        XCTAssertNotNil(e.anchorEstimate)
        XCTAssertLessThan(Geo.distance(e.anchor!, placed), 0.01)
        XCTAssertNil(e.anchorCorrection)
    }

    func testSettledDropAllowsForAFullScopeAhead() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.rodeOutSet = 30
        e.ingest(fix(0)); e.dropAnchor(.goingDown)
        XCTAssertEqual(e.dropOffset, 7, accuracy: 0.001, "half the boat")
        e.raiseAnchor()
        e.rodeOutSet = 30
        e.ingest(fix(0)); e.dropAnchor(.settled)
        // √(30² − 6²) ≈ 29.39 m of rode across the bottom, plus 7 m back to the phone. With no wind to say which way,
        // the mark stays at the phone and the dotted circle covers the whole distance.
        XCTAssertEqual(e.dropOffset, 29.39 + 7, accuracy: 0.05)
        XCTAssertGreaterThan(e.anchorUncertainty!, 36)
    }

    func testSettledCalmDropHoldsTheCircleAlarmUntilTheSwingFit() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.ingest(fix(0)); e.dropAnchor(.settled)                    // no wind forecast: direction unknown
        XCTAssertTrue(e.awaitingSwingFix)
        XCTAssertEqual(e.watchState, .awaitingFix)
        e.radius = 30
        for _ in 0..<4 { e.ingest(fix(120)) }
        XCTAssertNil(e.alarm, "the circle alarm waits")

        let anchor = Geo.destination(from: e.anchor!, bearing: 45, meters: 12)
        swing(e, around: anchor)
        e.updateAnchorEstimate()
        XCTAssertFalse(e.awaitingSwingFix, "armed once the swing says where the anchor is")
    }

    func testGoingDownAndHandPlacedMarksAreArmed() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.ingest(fix(0)); e.dropAnchor(.goingDown)
        XCTAssertFalse(e.awaitingSwingFix)
        e.raiseAnchor()
        e.ingest(fix(0)); e.dropAnchor(.settled)
        XCTAssertTrue(e.awaitingSwingFix)
        e.moveAnchor(to: Geo.destination(from: e.anchor!, bearing: 0, meters: 20))
        XCTAssertFalse(e.awaitingSwingFix, "placing it by hand arms the alarm")
    }

    func testOriginalDropIsKeptThroughMovesUntilClearedOrRaised() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.ingest(fix(0)); e.dropAnchor()
        let original = e.anchor!
        e.moveAnchor(to: Geo.destination(from: original, bearing: 90, meters: 20))
        XCTAssertEqual(e.originalAnchor, original)
        e.clearOriginalAnchor()
        XCTAssertEqual(e.originalAnchor, e.anchor, "the moved anchor becomes the official spot")
        let official = e.anchor!
        e.moveAnchor(to: Geo.destination(from: official, bearing: 0, meters: 15))
        XCTAssertEqual(e.originalAnchor, official, "and the next move measures from it")
        e.ingest(fix(0)); e.raiseAnchor(); e.dropAnchor()
        XCTAssertNotNil(e.originalAnchor)
        e.raiseAnchor()
        XCTAssertNil(e.originalAnchor)
    }

    func testDragWithoutAnOriginalMeasuresFromWhereTheAnchorIs() {
        // An anchor saved before the original spot was kept: it loads with none.
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(#"{"latitude":48.6,"longitude":-123.15,"radius":30}"#.data(using: .utf8), forKey: "anchorwatch.saved")
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertNotNil(e.anchor)
        XCTAssertNil(e.originalAnchor)
        e.beginAnchorDrag()
        XCTAssertEqual(e.originalAnchor, e.anchor, "a drag always has a spot to measure the move from")
    }

    func testNudgeMovesTheAnchorOneStepAndKeepsTheOriginal() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.units = .feet
        e.ingest(fix(0)); e.dropAnchor()
        let start = e.anchor!
        e.nudgeAnchor(toward: 0)
        XCTAssertEqual(Geo.distance(start, e.anchor!), 1.524, accuracy: 0.001, "5 ft")
        XCTAssertEqual(Geo.bearing(from: start, to: e.anchor!), 0, accuracy: 0.5)
        XCTAssertEqual(e.originalAnchor, start)
        e.units = .meters
        e.nudgeAnchor(toward: 90)
        XCTAssertEqual(Geo.distance(start, e.anchor!), (1.524 * 1.524 + 1).squareRoot(), accuracy: 0.01, "1 m in metric")
    }

    func testMoveToSwingEstimateThenItAgrees() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.ingest(fix(0)); e.dropAnchor()
        let mark = e.anchor!
        let anchor = Geo.destination(from: mark, bearing: 45, meters: 12)
        for i in 0..<240 {                              // 40 minutes swinging 120° on a 36 m circle
            let bearing = 160 + 120 * (0.5 - 0.5 * cos(Double(i) / 240 * 4 * .pi))
            e.ingest(Fix(coordinate: Geo.destination(from: anchor, bearing: bearing, meters: 36), accuracy: 3,
                         course: nil, speed: nil, timestamp: Date().addingTimeInterval(180 + Double(i) * 10)), receivedAt: Date().addingTimeInterval(180 + Double(i) * 10))
        }
        e.updateAnchorEstimate()
        let estimate = try! XCTUnwrap(e.anchorEstimate)
        XCTAssertLessThan(Geo.distance(estimate.center, anchor), 2)

        e.moveAnchorToEstimate()
        XCTAssertLessThan(Geo.distance(e.anchor!, anchor), 2)
        XCTAssertEqual(e.anchorUncertainty!, estimate.semiMajor, accuracy: 0.001)
        XCTAssertLessThan(Geo.distance(e.anchor!, e.anchorEstimate!.center), e.anchorEstimate!.semiMajor)   // now agrees
    }

    func testAnchorThatStartsDraggingRaisesTheWarningOnlyAfterItMoves() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.radius = 200                                  // keep the ordinary drag alarm out of the way
        e.ingest(fix(0)); e.dropAnchor()
        let pivot0 = e.anchor!
        var warnedBeforeDrag = false
        for i in 0..<(55 * 6) {                         // 55 minutes, a fix every 10 s
            let minute = Double(i) / 6
            let dragged = max(0, minute - 25) * 1.0     // 1 m/min east from minute 25
            let pivot = Geo.destination(from: pivot0, bearing: 90, meters: dragged)
            let bearing = 270 + 60 * sin(minute / 10 * 2 * .pi)   // swinging ±60° downwind (west of the anchor)
            e.ingest(Fix(coordinate: Geo.destination(from: pivot, bearing: bearing, meters: 36), accuracy: 3,
                         course: nil, speed: nil, timestamp: Date().addingTimeInterval(Double(i) * 10)), receivedAt: Date().addingTimeInterval(Double(i) * 10))
            if i % 6 == 5 {
                e.updateAnchorEstimate()
                if minute < 25 && e.anchorDrift != nil { warnedBeforeDrag = true }
            }
        }
        XCTAssertFalse(warnedBeforeDrag)
        let drift = try! XCTUnwrap(e.anchorDrift)
        XCTAssertEqual(drift.bearing, 90, accuracy: 20)
        XCTAssertGreaterThan(drift.distance, AnchorDrift.minMeters)
        e.raiseAnchor()
        XCTAssertNil(e.anchorDrift)
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

@MainActor
final class BoatProfileTests: XCTestCase {
    func testRodeCarriedFollowsRodeType() {
        var b = BoatProfile()
        b.rodeType = .chainAndRope; b.chainLength = 30; b.ropeLength = 60
        XCTAssertEqual(BoatMath.rodeCarried(b), 90)
        b.rodeType = .allChain
        XCTAssertEqual(BoatMath.rodeCarried(b), 30)
        b.rodeType = .rope
        XCTAssertEqual(BoatMath.rodeCarried(b), 60)
    }

    func testDeepestWater() {
        var b = BoatProfile()
        b.rodeType = .allChain; b.chainLength = 60
        XCTAssertEqual(BoatMath.deepestWater(b, scopeRatio: 5, bowHeight: 1)!, 11, accuracy: 0.001)   // 60 / 5 − 1
        b.chainLength = 0
        XCTAssertNil(BoatMath.deepestWater(b, scopeRatio: 5, bowHeight: 1))
    }

    func testWindageEstimateAndOverride() {
        var b = BoatProfile()
        b.freeboard = 0
        XCTAssertNil(BoatMath.windage(b))
        b.beam = 4; b.freeboard = 1.5; b.cabinHeight = 0.5
        // 4 × 2 × 0.8 hull and cabin; the radar mast is left out
        XCTAssertEqual(BoatMath.windage(b)!, 6.4, accuracy: 0.001)
        b.windageArea = 12
        XCTAssertEqual(BoatMath.windage(b)!, 12)
        // 15 × 2 × 0.8 along the side
        XCTAssertEqual(BoatMath.estimatedSideWindage(b, length: 15)!, 24, accuracy: 0.001)
        XCTAssertNil(BoatMath.estimatedSideWindage(b, length: 0))
    }

    func testSnubberOffCountsAsNone() {
        var b = BoatProfile()
        b.snubberLength = 6
        XCTAssertEqual(b.snubber, 6)
        b.hasSnubber = false
        XCTAssertEqual(b.snubber, 0)
        let old = #"{"snubberLength":0}"#.data(using: .utf8)!
        XCTAssertFalse(try JSONDecoder().decode(BoatProfile.self, from: old).hasSnubber)   // saved before the toggle existed
    }

    func testWindLoadGrowsWithTheSquareOfSpeed() {
        var b = BoatProfile()
        b.windageArea = 10
        let at20 = BoatMath.windLoad(b, knots: 20)!
        XCTAssertEqual(at20, 0.5 * 1.225 * 10 * pow(20 * 0.514444, 2), accuracy: 0.01)
        XCTAssertEqual(BoatMath.windLoad(b, knots: 40)!, at20 * 4, accuracy: 0.01)
    }

    func testOldSavedProfileStillDecodes() throws {
        let old = #"{"name":"Nereus","beam":4.6,"anchorType":"Something new"}"#.data(using: .utf8)!
        let b = try JSONDecoder().decode(BoatProfile.self, from: old)
        XCTAssertEqual(b.name, "Nereus")
        XCTAssertEqual(b.beam, 4.6)
        XCTAssertEqual(b.anchorType, BoatProfile().anchorType)   // unknown value falls back to the default
        XCTAssertNil(b.windageArea)
    }

    func testDefaultsMatchNereussSurvey() {
        let b = BoatProfile()
        let u = Units.feet
        XCTAssertEqual(b.beam * u.perMeter, 15 + 8.0 / 12, accuracy: 0.01)
        XCTAssertEqual(b.displacement * u.perKilogram, 62_000, accuracy: 1)
        XCTAssertEqual(b.fuelCapacity * u.perLiter, 1_100, accuracy: 0.5)
        XCTAssertEqual(b.waterCapacity * u.perLiter, 300, accuracy: 0.5)
        XCTAssertEqual(b.holdingCapacity * u.perLiter, 64, accuracy: 0.5)
    }

    func testLoadedWeightAddsFullTanks() {
        var b = BoatProfile()
        b.displacement = 10_000; b.fuelCapacity = 1_000; b.waterCapacity = 500; b.holdingCapacity = 100
        XCTAssertEqual(BoatMath.loadedWeight(b)!, 10_000 + 850 + 600, accuracy: 0.001)
        b.displacement = 0
        XCTAssertNil(BoatMath.loadedWeight(b))
    }

    func testChainSizesInInches() {
        XCTAssertEqual(Units.feet.formatSize(9.525), "3/8 in")
        XCTAssertEqual(Units.feet.formatSize(25.4), "1 in")
        XCTAssertEqual(Units.feet.formatSize(10), "≈ 3/8 in")
        XCTAssertEqual(Units.meters.formatSize(10), "10 mm")
    }

    func testProfileSurvivesRelaunchAndFlagsShortRode() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        a.scope = ScopeSettings(depth: 10, bowHeight: 1, boatLength: 12, scopeRatio: 5, margin: 0)   // needs 55 m
        XCTAssertNil(a.rodeShortfall)   // nothing entered yet
        a.boat.name = "Nereus"; a.boat.rodeType = .allChain; a.boat.chainLength = 50
        let b = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertEqual(b.boat.name, "Nereus")
        XCTAssertEqual(b.rodeShortfall!, 5, accuracy: 0.001)
    }
}

final class AnchorPlacementTests: XCTestCase {
    private let phone = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)

    func testApproachBeatsWindAndMovesTheDropForward() {
        let from = Geo.destination(from: phone, bearing: 270, meters: 40)     // came in heading east
        let r = AnchorPlacement.place(phone: phone, gpsAccuracy: 4, bowOffset: 7, approachFrom: from, windFrom: 180, windKnots: 15)
        XCTAssertEqual(r.source, .approach)
        XCTAssertEqual(r.bowBearing!, 90, accuracy: 0.1)
        XCTAssertEqual(Geo.distance(phone, r.coordinate), 7, accuracy: 0.01)
        XCTAssertEqual(r.uncertainty, (16 + pow(7 * sin(15.0 * .pi / 180), 2)).squareRoot(), accuracy: 0.001)
    }

    func testShortApproachFallsBackToTheWind() {
        let from = Geo.destination(from: phone, bearing: 270, meters: 5)
        let r = AnchorPlacement.place(phone: phone, gpsAccuracy: 4, bowOffset: 7, approachFrom: from, windFrom: 200, windKnots: 12)
        XCTAssertEqual(r.source, .wind)
        XCTAssertEqual(Geo.bearing(from: phone, to: r.coordinate), 200, accuracy: 0.1)   // bow into the wind
    }

    func testNoClueLeavesItAtThePhoneWithAWiderCircle() {
        let r = AnchorPlacement.place(phone: phone, gpsAccuracy: 4, bowOffset: 7, approachFrom: nil, windFrom: 200, windKnots: 3)
        XCTAssertEqual(r.source, .unknown)
        XCTAssertEqual(r.coordinate, phone)
        XCTAssertEqual(r.uncertainty, 11, accuracy: 0.001)
    }

    func testLyingToAnAnchorUsesTheRode() {
        let old = Geo.destination(from: phone, bearing: 30, meters: 40)
        let r = AnchorPlacement.place(phone: phone, gpsAccuracy: 4, bowOffset: 7, approachFrom: nil, lyingTo: old, windFrom: nil, windKnots: nil)
        XCTAssertEqual(r.source, .anchor)
        XCTAssertEqual(r.bowBearing!, 30, accuracy: 0.1)
    }
}

final class AnchorEstimateTests: XCTestCase {
    private let mark = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)
    private let dropped = Date(timeIntervalSince1970: 1_800_000_000)

    /// A boat swinging on a circle of `radius` round the true anchor (12 m NE of the mark), from bearing
    /// `from` through `through` degrees and back, with GPS noise and some lulls where it sits inside the circle.
    private func swing(radius: Double, from: Double, through: Double, minutes: Double, noise: Double = 2) -> (track: [Fix], anchor: CLLocationCoordinate2D) {
        let anchor = Geo.destination(from: mark, bearing: 45, meters: 12)
        var seed: UInt64 = 42
        func random() -> Double {                       // repeatable pseudo-random, -1...1
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53) * 2 - 1
        }
        let count = Int(minutes * 6)                    // a fix every 10 s
        let track = (0..<count).map { i -> Fix in
            let t = Double(i) / Double(count)
            let bearing = from + (through - from) * (0.5 - 0.5 * cos(t * 4 * .pi))   // back and forth twice
            let lull = i % 7 == 0 ? 0.85 : 1.0          // chain sagging in a lull
            let onCircle = Geo.destination(from: anchor, bearing: bearing, meters: radius * lull)
            let noisy = Geo.destination(from: onCircle, bearing: (random() + 1) * 180, meters: abs(random()) * noise)
            return Fix(coordinate: noisy, accuracy: 4, course: nil, speed: nil,
                       timestamp: dropped.addingTimeInterval(180 + Double(i) * 10))
        }
        return (track, anchor)
    }

    func testWideSwingFindsTheAnchorAndTheRadius() {
        let (track, anchor) = swing(radius: 40, from: 150, through: 300, minutes: 40)
        let r = AnchorEstimate.estimate(track: track, dropped: dropped, mark: mark, modelRadius: 30, windFrom: nil, windKnots: nil)!
        XCTAssertEqual(r.method, .free)
        XCTAssertGreaterThanOrEqual(r.arc, 90)
        XCTAssertLessThan(Geo.distance(r.center, anchor), 3)
        XCTAssertEqual(r.radius, 40, accuracy: 3)       // found the real radius, not the model's 30
        XCTAssertLessThan(r.semiMajor, 10)
    }

    func testNarrowSwingFixesTheRadiusAndIsUncertainAcrossTheSwing() {
        let (track, anchor) = swing(radius: 40, from: 200, through: 240, minutes: 40)
        let r = AnchorEstimate.estimate(track: track, dropped: dropped, mark: mark, modelRadius: 40, windFrom: nil, windKnots: nil)
        guard let r else { return }                     // too uncertain to show is also a fair answer
        XCTAssertEqual(r.method, .fixedRadius)
        XCTAssertLessThan(Geo.distance(r.center, anchor), r.semiMajor + 3)
        XCTAssertGreaterThan(r.semiMajor, r.semiMinor)
    }

    func testTooSoonIsStillCollecting() {
        let (track, _) = swing(radius: 40, from: 150, through: 300, minutes: 10)
        let result = AnchorEstimate.evaluate(track: track, dropped: dropped, mark: mark, modelRadius: 40, windFrom: nil, windKnots: nil)
        guard case .failure(let p) = result, case .collecting(let minutes) = p.pending else { return XCTFail("expected collecting") }
        XCTAssertLessThan(minutes, AnchorEstimate.minMinutes)
    }

    func testWindPointingTheWrongWayDisagrees() {
        let (track, _) = swing(radius: 40, from: 150, through: 300, minutes: 40)
        // The boat ends the track at bearing ~150° from the anchor, so the wind should be from ~330°.
        let good = AnchorEstimate.estimate(track: track, dropped: dropped, mark: mark, modelRadius: 40, windFrom: 330, windKnots: 15)!
        let bad = AnchorEstimate.estimate(track: track, dropped: dropped, mark: mark, modelRadius: 40, windFrom: 150, windKnots: 15)!
        XCTAssertEqual(good.windAgrees, true)
        XCTAssertEqual(bad.windAgrees, false)
    }

    func testSpedUpSimulatorReachesTheWaitSooner() {
        // 40 simulated minutes squeezed into 4 real minutes: fixes 1 s apart instead of 10 s.
        let (slow, _) = swing(radius: 40, from: 150, through: 300, minutes: 40)
        let fast = slow.enumerated().map { i, f in
            Fix(coordinate: f.coordinate, accuracy: f.accuracy, course: nil, speed: nil,
                timestamp: dropped.addingTimeInterval(18 + Double(i)))
        }
        XCTAssertNil(AnchorEstimate.estimate(track: fast, dropped: dropped, mark: mark, modelRadius: 30, windFrom: nil, windKnots: nil))
        let r = AnchorEstimate.estimate(track: fast, dropped: dropped, mark: mark, modelRadius: 30, windFrom: nil, windKnots: nil, timeScale: 10)
        XCTAssertEqual(r?.minutes ?? 0, (257 - 12) * 10 / 60.0, accuracy: 0.01)   // last fix 257 s; settle ends at 12 s
    }

    func testEllipseAxesFromCovariance() {
        let (major, minor, bearing) = AnchorEstimate.ellipse((xx: 9, xy: 0, yy: 1), scale: 1)
        XCTAssertEqual(major, 3, accuracy: 1e-9)
        XCTAssertEqual(minor, 1, accuracy: 1e-9)
        XCTAssertEqual(bearing, 90, accuracy: 1e-9)     // long axis east-west
    }
}

final class AnchorDriftTests: XCTestCase {
    private let start = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)

    private func samples(_ count: Int, position: (Double) -> (east: Double, north: Double)) -> [AnchorDrift.Sample] {
        (0..<count).map { i in
            let minute = 20 + Double(i)
            let p = position(minute)
            return AnchorDrift.Sample(minute: minute, center: AnchorEstimate.coordinate(AnchorEstimate.Point(x: p.east, y: p.north), from: start),
                                      semiMajor: 2)
        }
    }

    func testHoldingStillIsNotDrift() {
        let jitter = [0.8, -1.1, 0.4, 1.2, -0.6, -0.9, 0.7, 0.1, -1.3, 0.9, 0.3, -0.4, 1.0, -0.8, 0.5, -0.2, 0.6, -1.0, 0.2, 0.8]
        XCTAssertNil(AnchorDrift.assess(samples(20) { m in (jitter[Int(m) % 20], jitter[(Int(m) + 7) % 20]) }))
    }

    func testSteadyDriftIsCaughtWithSizeAndDirection() {
        // 1 m/min toward the north-east, for 19 minutes.
        let r = AnchorDrift.assess(samples(20) { m in ((m - 20) * 0.7071, (m - 20) * 0.7071) })!
        XCTAssertEqual(r.distance, 19, accuracy: 0.5)
        XCTAssertEqual(r.bearing, 45, accuracy: 1)
        XCTAssertEqual(r.metersPerMinute, 1, accuracy: 0.05)
    }

    func testWanderingBackAndForthIsNotDrift() {
        // 8 m either way along an east-west line, twice over: big moves, but no steady direction.
        XCTAssertNil(AnchorDrift.assess(samples(20) { m in (8 * sin((m - 20) / 19 * 4 * .pi), 0) }))
    }

    func testSmallMovesAreNeverDrift() {
        XCTAssertNil(AnchorDrift.assess(samples(20) { m in ((m - 20) * 0.2, 0) }))   // 3.8 m in 19 min
    }
}

final class AnchoringTests: XCTestCase {
    private func arcLength(_ shape: RodeShape) -> Double {
        zip(shape.points, shape.points.dropFirst()).reduce(0) { sum, pair in
            sum + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
    }

    func testLiftOffAndChainNeededAreInverses() {
        let w = AnchorMath.chainWeight(sizeMM: 10)
        XCTAssertEqual(w, 0.022 * 100 * AnchorMath.submergedFraction * 9.81, accuracy: 0.001)
        let load = AnchorMath.liftOffLoad(length: 50, height: 8, weight: w)
        XCTAssertEqual(AnchorMath.chainNeeded(load: load, height: 8, weight: w), 50, accuracy: 0.001)
    }

    func testCatenaryWithChainOnTheBottomReachesTheBow() {
        let w = AnchorMath.chainWeight(sizeMM: 10)
        let shape = AnchorMath.shape(length: 60, height: 8, load: 1000, weight: w, samples: 400)
        XCTAssertGreaterThan(shape.lying, 0)
        XCTAssertEqual(shape.shankAngle, 0)
        XCTAssertEqual(shape.points.last!.y, 8, accuracy: 0.01)
        XCTAssertEqual(arcLength(shape), 60, accuracy: 0.05)
    }

    func testCatenaryLiftedOffPullsUpOnTheAnchor() {
        let w = AnchorMath.chainWeight(sizeMM: 10)
        let load = AnchorMath.liftOffLoad(length: 30, height: 8, weight: w) * 3
        let shape = AnchorMath.shape(length: 30, height: 8, load: load, weight: w, samples: 400)
        XCTAssertEqual(shape.lying, 0)
        XCTAssertGreaterThan(shape.shankAngle, 0)
        XCTAssertLessThan(shape.shankAngle, asin(8.0 / 30) * 180 / .pi)   // flatter than a straight, taut rode
        XCTAssertEqual(shape.points.last!.y, 8, accuracy: 0.01)
        XCTAssertEqual(arcLength(shape), 30, accuracy: 0.05)
    }

    func testGustReachingInvertsTheLoad() {
        let b = BoatProfile()
        let load = AnchorMath.load(b, wind: 30, current: 1, waveHeight: 0.5)
        XCTAssertEqual(AnchorMath.gust(reaching: load.design, b, current: 1, waveHeight: 0.5)!, 30, accuracy: 0.01)
    }

    func testShortRodeInAStrongBlowIsDangerAndSaysLetOutMore() {
        let b = BoatProfile()
        let scope = ScopeSettings(depth: 6, bowHeight: 1.5, boatLength: 14.3, scopeRatio: 5, margin: 5)
        var c = AnchorConditions()
        c.gust = 30; c.rodeOut = 25; c.bottom = .sand
        let r = AnchorMath.assess(b, scope: scope, c)
        XCTAssertEqual(r.status, .danger)
        XCTAssertGreaterThan(r.rodeNeeded!, 25)
        XCTAssertTrue(AnchorMath.suggestions(b, scope: scope, c, r, units: .meters).contains { $0.hasPrefix("Let out") })
    }

    func testGaleBeyondTheChainOnBoardSaysFindShallowerWater() {
        var b = BoatProfile()
        b.chainLength = 30
        let scope = ScopeSettings(depth: 10, bowHeight: 1.5, boatLength: 14.3, scopeRatio: 5, margin: 5)
        var c = AnchorConditions()
        c.gust = 50; c.rodeOut = 30
        let r = AnchorMath.assess(b, scope: scope, c)
        XCTAssertTrue(AnchorMath.suggestions(b, scope: scope, c, r, units: .meters).contains { $0.hasPrefix("Even all") })
    }

    func testSteadyWindChangesHowTheChainLiesButNotTheGustLimits() {
        let b = BoatProfile()
        let scope = ScopeSettings(depth: 6, bowHeight: 1.5, boatLength: 14.3, scopeRatio: 5, margin: 5)
        var light = AnchorConditions(); light.wind = 5; light.gust = 25; light.rodeOut = 60
        var fresh = light; fresh.wind = 20
        let a = AnchorMath.assess(b, scope: scope, light), z = AnchorMath.assess(b, scope: scope, fresh)
        XCTAssertLessThan(a.steadyLoad.design, z.steadyLoad.design)
        XCTAssertGreaterThan(a.steadyShape.lying, z.steadyShape.lying)     // more chain lifts in more wind
        XCTAssertEqual(a.load.design, z.load.design)                       // gust load unchanged
        XCTAssertEqual(a.safeGust, z.safeGust)
    }

    func testLongRodeInABreezeHoldsWell() {
        let b = BoatProfile()
        let scope = ScopeSettings(depth: 6, bowHeight: 1.5, boatLength: 14.3, scopeRatio: 5, margin: 5)
        var c = AnchorConditions()
        c.wind = 10; c.gust = 15; c.current = 0.5; c.waveHeight = 0; c.rodeOut = 60; c.bottom = .sand
        let r = AnchorMath.assess(b, scope: scope, c)
        XCTAssertEqual(r.status, .good)
        XCTAssertGreaterThan(r.safeGust!, 15)
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

    func testExtremesFindTheLowAndHighAhead() {
        // From midway down the ebb (1 m), the low is 3 h ahead and the next high 9 h ahead.
        let ext = TideMath.extremes(from: t0.addingTimeInterval(9 * 3600), hours: 12, events: events)!
        XCTAssertEqual(ext.low.height, 0, accuracy: 0.01)
        XCTAssertEqual(ext.low.time.timeIntervalSince(t0), 12 * 3600, accuracy: 600)   // 5-min sampling
        XCTAssertEqual(ext.high.height, 2, accuracy: 0.01)
        XCTAssertEqual(ext.high.time.timeIntervalSince(t0), 18 * 3600, accuracy: 600)   // 5-min sampling
    }

    func testDepthsFollowTheTideFromNow() {
        // From the low (0 m), 5 m of water now; the 2 m high six hours on gives 7 m.
        let points = TideMath.depths(depthNow: 5, events: events, from: t0, hours: 12, step: 3600)
        XCTAssertEqual(points.first!.depth, 5, accuracy: 0.001)
        XCTAssertEqual(points[6].depth, 7, accuracy: 0.001)
        XCTAssertEqual(points[12].depth, 5, accuracy: 0.001)
    }

    func testShallowWindowsAroundTheLow() {
        // 2 m now at the high (t0+6h), falling to 0 m at the next low: below 1 m from t0+9h to t0+15h.
        let points = TideMath.depths(depthNow: 2, events: events, from: t0.addingTimeInterval(6 * 3600), hours: 12, step: 600)
        let windows = TideMath.shallowWindows(points, below: 1)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].least, 0, accuracy: 0.01)
        XCTAssertEqual(windows[0].start.timeIntervalSince(t0) / 3600, 9, accuracy: 0.2)
        XCTAssertEqual(windows[0].end.timeIntervalSince(t0) / 3600, 15, accuracy: 0.2)
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

    func testParsesNOAAOFSLevelsAndInterpolates() throws {
        let json = #"{"data":[{"t":"2026-10-22 12:00","v":"1.25","f":"","q":"p"},{"t":"2026-10-22 12:06","v":"1.55","f":"","q":"p"}]}"#.data(using: .utf8)!
        let fetched = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
        let series = try TideService.parseOFSWaterLevels(json, stationID: "9447130", fetched: fetched)
        XCTAssertEqual(series.stationID, "9447130")
        XCTAssertEqual(series.datum, "MLLW")
        XCTAssertEqual(series.samples.count, 2)
        XCTAssertEqual(series.height(at: fetched.addingTimeInterval(180))!, 1.4, accuracy: 0.001)
        XCTAssertNil(series.height(at: fetched.addingTimeInterval(-1)))
    }

    func testOFSRequestUsesMLLWAndExpectedStationAndForecastRange() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
        let station = TideStation(id: "9447130", name: "Seattle", lat: 47.6, lng: -122.3)
        let url = try XCTUnwrap(TideService.noaaOFSWaterLevelURL(station: station, now: now))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "product" })?.value, "ofs_water_level")
        XCTAssertEqual(items.first(where: { $0.name == "datum" })?.value, "MLLW")
        XCTAssertEqual(items.first(where: { $0.name == "station" })?.value, station.id)
        XCTAssertEqual(items.first(where: { $0.name == "time_zone" })?.value, "gmt")
        XCTAssertEqual(items.first(where: { $0.name == "end_date" })?.value, "20261025 12:00")
        XCTAssertNil(TideService.noaaOFSWaterLevelURL(
            station: TideStation(id: "chs-1", name: "Canada", lat: 49, lng: -123, source: TideStation.chs), now: now))
    }

    func testOFSCacheRequiresMatchingStationDatumAndFreshForecastCoverage() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
        let station = TideStation(id: "9447130", name: "Seattle", lat: 47.6, lng: -122.3)
        let samples = (-6...72).map { hour in
            OFSWaterLevelSample(time: now.addingTimeInterval(Double(hour) * 3600), height: Double(hour) / 10)
        }
        let series = OFSWaterLevelSeries(stationID: station.id, datum: "MLLW", fetched: now, samples: samples)
        XCTAssertTrue(TideService.usableOFSWaterLevel(series, station: station, now: now, maximumAge: 6 * 3600))
        let wrongStation = OFSWaterLevelSeries(stationID: "other", datum: "MLLW", fetched: now, samples: samples)
        XCTAssertFalse(TideService.usableOFSWaterLevel(wrongStation, station: station, now: now, maximumAge: 6 * 3600))
        let old = OFSWaterLevelSeries(stationID: station.id, datum: "MLLW", fetched: now.addingTimeInterval(-25 * 3600), samples: samples)
        XCTAssertFalse(TideService.usableOFSWaterLevel(old, station: station, now: now, maximumAge: 24 * 3600))
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
        [{"id":"abc","officialName":"Sidney","latitude":48.649,"longitude":-123.393,"timeSeries":[{"code":"wlo"},{"code":"wlp-hilo"},{"code":"wlf"}]},
         {"id":"def2","officialName":"SPINE Gauge","latitude":49.0,"longitude":-123.0,"timeSeries":[{"code":"wlp-hilo"},{"code":"wlf-spine"}]},
         {"id":"def","officialName":"Gauge Only","latitude":49.0,"longitude":-123.0,"timeSeries":[{"code":"wlo"}]},
         {"id":"ghi","officialName":"No Series","latitude":49.0,"longitude":-123.0}]
        """#.data(using: .utf8)!
        let stations = try TideService.parseCHSStations(json)
        XCTAssertEqual(stations.map(\.name), ["Sidney", "SPINE Gauge"])
        XCTAssertEqual(stations[0].source, TideStation.chs)
        XCTAssertEqual(stations[0].forecastSeriesCode, "wlf")
        XCTAssertEqual(stations[1].forecastSeriesCode, "wlf-spine")
    }

    func testCHSForecastURLUsesStationAdvertisedSeriesAnd48HourWindow() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
        let station = TideStation(id: "station-id", name: "Aero Trading", lat: 54, lng: -130,
                                  source: TideStation.chs, forecastSeriesCode: "wlf")
        let url = try XCTUnwrap(TideService.chsWaterLevelForecastURL(station: station, now: now))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "time-series-code" })?.value, "wlf")
        XCTAssertEqual(items.first(where: { $0.name == "from" })?.value, "2026-10-22T06:00:00Z")
        XCTAssertEqual(items.first(where: { $0.name == "to" })?.value, "2026-10-24T12:00:00Z")
        XCTAssertNil(TideService.chsWaterLevelForecastURL(
            station: TideStation(id: "prediction-only", name: "Campbell River", lat: 50, lng: -125,
                                 source: TideStation.chs), now: now))
    }

    func testCHSForecastParserAndCacheValidation() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
        let station = TideStation(id: "station-id", name: "Aero Trading", lat: 54, lng: -130,
                                  source: TideStation.chs, forecastSeriesCode: "wlf")
        let json = #"""
        [{"eventDate":"2026-10-22T06:00:00Z","value":1.2,"qcFlagCode":"1"},
         {"eventDate":"2026-10-22T12:00:00Z","value":1.4,"qcFlagCode":"2"},
         {"eventDate":"2026-10-23T12:00:00Z","value":1.1,"qcFlagCode":1},
         {"eventDate":"2026-10-24T12:00:00Z","value":0.9,"qcFlagCode":"1"},
         {"eventDate":"2026-10-24T13:00:00Z","value":999.0,"qcFlagCode":"3"}]
        """#.data(using: .utf8)!
        let series = try TideService.parseCHSWaterLevelForecast(json, station: station, fetched: now)
        XCTAssertEqual(series.samples.count, 4, "Questionable/suspect values must not enter the forecast curve")
        XCTAssertEqual(series.stationSource, TideStation.chs)
        XCTAssertEqual(series.datum, "CHS chart datum")
        XCTAssertEqual(series.seriesCode, "wlf")
        // 3 hours along the 24-hour interval from 1.4 m to 1.1 m.
        XCTAssertEqual(series.height(at: now.addingTimeInterval(3 * 3600))!, 1.3625, accuracy: 0.001)
        XCTAssertTrue(TideService.usableWaterLevelForecast(series, station: station, now: now, maximumAge: 6 * 3600,
                                                            expectedDatum: "CHS chart datum", expectedCode: "wlf"))
        XCTAssertFalse(TideService.usableWaterLevelForecast(series, station: station, now: now, maximumAge: 6 * 3600,
                                                             expectedDatum: "MLLW", expectedCode: "wlf"))
        XCTAssertFalse(TideService.usableWaterLevelForecast(series, station: station, now: now, maximumAge: 6 * 3600,
                                                             expectedDatum: "CHS chart datum", expectedCode: "wlf-spine"))
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
        XCTAssertEqual(e.rawFix?.accuracy, 120, "but the screen still reports the poor accuracy")
        XCTAssertTrue(e.gpsIsUnusable)
    }

    func testExternalReceiverWithoutALockIsIgnored() {
        let e = make()
        e.ingest(fix(0)); e.dropAnchor(); e.radius = 30
        // A GLO 2 indoors: ±50 m, which an iPhone fix could just pass, while wandering 120 m off.
        for _ in 0..<5 {
            var wandering = fix(120, accuracy: 50)
            wandering.external = true
            e.ingest(wandering)
        }
        XCTAssertNil(e.alarm)
        XCTAssertEqual(e.distance ?? 99, 0, accuracy: 1)
        XCTAssertTrue(e.gpsIsUnusable)
    }

    func testGPSLogKeepsEveryPositionEvenUnusableOnes() {
        let e = make()
        e.ingest(fix(0)); e.ingest(fix(5, accuracy: 120))
        XCTAssertEqual(e.gpsLog.count, 2)
        e.clearGPSLog()
        XCTAssertTrue(e.gpsLog.isEmpty)
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

    func testAnchorMathGuideWorkedExampleUsesTheModel() {
        let text = UserGuideContent.anchorMath.blocks.compactMap { block -> String? in
            if case .formula(let t) = block { return t }
            return nil
        }.joined(separator: "\n")
        var c = AnchorConditions()
        c.wind = 15; c.gust = 25; c.current = 0.5; c.waveHeight = 0.3048; c.bottom = .mud; c.rodeOut = 45.72
        let scope = ScopeSettings(depth: 6.096, tideRise: 0, bowHeight: 1.219, boatLength: 14.326, scopeRatio: 5, margin: 5)
        let r = AnchorMath.assess(BoatProfile(), scope: scope, c)
        XCTAssertTrue(text.contains(String(format: "safe gust limit  = %.1f kt", r.safeGust!)))
        XCTAssertTrue(text.contains("H_max = w × (L² − h²) / (2h)"))
    }

    func testAnchorMathFormulasFitAPhone() {
        for block in UserGuideContent.anchorMath.blocks {
            guard case .formula(let t) = block else { continue }
            for line in t.split(separator: "\n") {
                XCTAssertLessThanOrEqual(line.count, 42, "too wide for a phone: \(line)")
            }
        }
    }

    func testGuideMentionsWhatItClaimsAboutDefaults() {
        // The guide says the siren, gust and fade numbers; make sure the quoted text actually contains them.
        let all = UserGuideContent.topics.flatMap(\.blocks).map { block -> String in
            switch block {
            case .heading(let t), .text(let t), .tip(let t), .warning(let t), .formula(let t): return t
            case .bullets(let items): return items.joined(separator: " ")
            }
        }.joined(separator: " ")
        for phrase in ["30 seconds", "60 seconds", "10 minutes", "6 seconds", "25 knots", "60°", "Test siren in 15 seconds", "Drop Anchor Here", "Water tab"] {
            XCTAssertTrue(all.contains(phrase), "the guide should mention \"\(phrase)\"")
        }
    }
}

final class FixSelectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fix(_ accuracy: Double, at seconds: Double, external: Bool) -> Fix {
        Fix(coordinate: CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15), accuracy: accuracy,
            course: nil, speed: nil, timestamp: t0.addingTimeInterval(seconds), external: external)
    }

    func testDecentReceiverWinsOverAConfidentIPhone() {
        var s = FixSelector()
        XCTAssertTrue(s.accept(fix(5, at: 0, external: true)))
        XCTAssertFalse(s.accept(fix(2, at: 1, external: false)), "iPhone under a roof claiming 2 m is ignored")
        XCTAssertTrue(s.accept(fix(5, at: 2, external: true)))
    }

    func testPoorReceiverGivesWayToABetterIPhone() {
        var s = FixSelector()
        XCTAssertTrue(s.accept(fix(4, at: 0, external: false)))
        XCTAssertFalse(s.accept(fix(30, at: 1, external: true)), "receiver indoors at 30 m is dropped")
        XCTAssertTrue(s.accept(fix(4, at: 2, external: false)))
    }

    func testPoorReceiverStillBeatsAWorseIPhone() {
        var s = FixSelector()
        XCTAssertTrue(s.accept(fix(40, at: 0, external: false)))
        XCTAssertTrue(s.accept(fix(30, at: 1, external: true)))
        XCTAssertFalse(s.accept(fix(40, at: 2, external: false)))
    }

    func testQuietSourceNeverBlocks() {
        var s = FixSelector()
        XCTAssertTrue(s.accept(fix(5, at: 0, external: true)))
        XCTAssertTrue(s.accept(fix(8, at: 11, external: false)), "receiver silent for over 10 s")
        var t = FixSelector()
        XCTAssertTrue(t.accept(fix(30, at: 0, external: true)), "only source: always passed on")
    }
}

final class GPSQualityTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)

    func testSpreadAroundTheAverage() {
        // Four positions 10 m out on each compass point, and one in the middle.
        let ring = [0.0, 90, 180, 270].map { Geo.destination(from: origin, bearing: $0, meters: 10) } + [origin]
        let c = GPSQuality.center(ring)!
        XCTAssertEqual(Geo.distance(c, origin), 0, accuracy: 0.01)
        XCTAssertEqual(GPSQuality.spread(ring, share: 0.95)!, 10, accuracy: 0.01)
        XCTAssertEqual(GPSQuality.spread(ring, share: 0.2)!, 0, accuracy: 0.01)   // the middle one
        XCTAssertNil(GPSQuality.spread([], share: 0.5))
    }

    func testOffsetEastAndNorth() {
        let o = GPSQuality.offset(Geo.destination(from: origin, bearing: 45, meters: 100), from: origin)
        XCTAssertEqual(o.east, 70.71, accuracy: 0.1)
        XCTAssertEqual(o.north, 70.71, accuracy: 0.1)
    }
}

final class HoldingWarningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = ScopeSettings(depth: 6, bowHeight: 1.2, boatLength: 14.3, scopeRatio: 5, margin: 5)

    private func forecast(gustAt3h gust: Double) -> [WindSample] {
        (0...12).map { h in
            WindSample(time: now.addingTimeInterval(Double(h) * 3600), speed: 10, direction: 200, gust: h == 3 ? gust : 15)
        }
    }

    func testWarnsWhenForecastGustsBeatTheSafeLimit() {
        let b = BoatProfile()
        var c = AnchorConditions(); c.gust = 15; c.wind = 10; c.bottom = .mud; c.rodeOut = 40
        let safe = AnchorMath.assess(b, scope: scope, c).safeGust!
        let w = AnchorMath.forecastWarning(b, scope: scope, bottom: .mud, rodeOut: 40, forecast: forecast(gustAt3h: safe + 10), now: now)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.time, now.addingTimeInterval(3 * 3600))
        XCTAssertNil(AnchorMath.forecastWarning(b, scope: scope, bottom: .mud, rodeOut: 40, forecast: forecast(gustAt3h: safe - 5), now: now))
    }

    func testIgnoresGustsBeyondTheWindow() {
        var samples = forecast(gustAt3h: 15)
        samples.append(WindSample(time: now.addingTimeInterval(20 * 3600), speed: 40, direction: 200, gust: 80))
        XCTAssertNil(AnchorMath.forecastWarning(BoatProfile(), scope: scope, bottom: .mud, rodeOut: 40, forecast: samples, now: now))
    }
}

final class CurrentDirectionTests: XCTestCase {
    private let scope = ScopeSettings(depth: 6, bowHeight: 1.2, boatLength: 14.3, scopeRatio: 5, margin: 5)

    func testAgainstCountsSomeSideWindageAndNeverLess() {
        let b = BoatProfile()
        var c = AnchorConditions(); c.wind = 15; c.gust = 25; c.current = 1; c.rodeOut = 60
        let with = AnchorMath.assess(b, scope: scope, c)
        c.currentDirection = .against
        let against = AnchorMath.assess(b, scope: scope, c)
        let side = BoatMath.sideWindage(b, length: scope.boatLength)!, front = BoatMath.windage(b)!
        let ratio = against.load.wind / with.load.wind
        XCTAssertGreaterThan(ratio, 1)
        XCTAssertLessThan(ratio, side / front, "a 1 kt current against 25 kt gusts doesn't hold the boat fully beam-on")
        XCTAssertGreaterThan(against.load.design, with.load.design)
        XCTAssertLessThan(against.safeGust!, with.safeGust!)
    }

    func testWeakCrossCurrentHardlyTurnsTheBoat() {
        // 0.5 kt across 13 kt gusts: the wind wins and the boat stays near head to wind.
        let b = BoatProfile()
        var c = AnchorConditions(); c.wind = 6; c.gust = 13; c.current = 0.5; c.currentDirection = .across
        let front = BoatMath.windage(b)!, side = BoatMath.sideWindage(b, length: scope.boatLength)!
        let area = AnchorMath.windArea(b, scope: scope, c)!
        XCTAssertLessThan((area - front) / (side - front), 0.25)
    }

    func testBalancedAgainstLiesBeamOn() {
        XCTAssertEqual(AnchorMath.beamOnShare(windPush: 500, currentPush: 500, .against), 1, accuracy: 0.001)
        XCTAssertEqual(AnchorMath.beamOnShare(windPush: 1000, currentPush: 100, .against), 0.01, accuracy: 0.001)
        XCTAssertEqual(AnchorMath.beamOnShare(windPush: 100, currentPush: 100, .across), 0.5, accuracy: 0.001)
        XCTAssertEqual(AnchorMath.beamOnShare(windPush: 100, currentPush: 100, .with), 0)
    }

    func testGustRoundTripWithSideArea() {
        let b = BoatProfile()
        let area = BoatMath.sideWindage(b, length: 14.3)!
        let load = AnchorMath.load(b, wind: 30, current: 1, waveHeight: 0.5, windArea: area)
        XCTAssertEqual(AnchorMath.gust(reaching: load.design, b, current: 1, waveHeight: 0.5, windArea: area)!, 30, accuracy: 0.01)
    }

    func testTipsMentionTheTurnOnlyAcrossOrAgainst() {
        let b = BoatProfile(), turn = Date(timeIntervalSince1970: 1_800_000_000)
        var c = AnchorConditions(); c.current = 1; c.rodeOut = 60
        let r = AnchorMath.assess(b, scope: scope, c)
        XCTAssertFalse(AnchorMath.suggestions(b, scope: scope, c, r, units: .feet, tideTurn: turn).contains { $0.contains("Predicted current slack") })
        c.currentDirection = .against
        XCTAssertTrue(AnchorMath.suggestions(b, scope: scope, c, r, units: .feet, tideTurn: turn).contains { $0.contains("Predicted current slack") })
    }
}

final class DistanceTrendTests: XCTestCase {
    /// One sample every 10 s for `minutes`, distance from `f`.
    private func log(_ minutes: Double, _ f: (Double) -> Double) -> [(minute: Double, distance: Double)] {
        stride(from: 2.0, through: 2 + minutes, by: 1.0 / 6).map { ($0, f($0)) }
    }

    func testSteadyDragIntoNewGroundIsMovingAway() {
        // Swinging at 40 m for 5 min, then pulling away at 2 m/min.
        let samples = log(10) { m in m < 7 ? 40 + 2 * sin(m * 3) : 42 + 2 * (m - 7) }
        XCTAssertEqual(AnchorDrift.distanceTrend(samples)!, 2, accuracy: 0.3)
    }

    func testSaggingBackToTheSameReachIsHolding() {
        // Distance rising 4 m over two minutes in a gust, but no further than earlier gusts took it.
        let samples = log(12) { m in 36 + 4 * max(0, sin(2 * .pi * m / 4)) }
        XCTAssertNil(AnchorDrift.distanceTrend(samples))
    }

    func testNeedsEarlierHistory() {
        // Straight away from the drop: no earlier reach to compare with yet.
        XCTAssertNil(AnchorDrift.distanceTrend(log(3) { m in 20 + 3 * m }))
    }

    @MainActor func testRodeOutSetOnceIsUsedEverywhereUntilRaised() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        XCTAssertEqual(e.rodeOut, e.rodeSuggested, "the suggestion until it's set")
        e.ingest(Fix(coordinate: CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15), accuracy: 3, course: nil, speed: nil, timestamp: Date()))
        e.dropAnchor()
        e.rodeOutSet = 30
        XCTAssertEqual(e.rodeOut, 30)
        XCTAssertEqual(e.liveScopeRatio!, 30 / (e.liveDepth + e.scope.bowHeight), accuracy: 0.001)
        e.raiseAnchor()
        XCTAssertNil(e.rodeOutSet, "a new anchorage starts from the suggestion")
    }

    @MainActor func testDropSetsTheRadiusFromTheRodeAndItFollowsUntilSetByHand() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 6.096)
        e.rodeOutSet = 60
        e.ingest(Fix(coordinate: CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15), accuracy: 3, course: nil, speed: nil, timestamp: Date()))
        e.dropAnchor()
        // √(60² − 6²) ≈ 59.70 m of reach, plus 7 m to the phone amidships, plus 20 ft.
        XCTAssertEqual(e.radius, 59.70 + 7 + 6.096, accuracy: 0.05)
        XCTAssertEqual(e.swingRadius, 59.70 + 7, accuracy: 0.05, "the boat's position, amidships")
        XCTAssertEqual(e.radius - e.swingRadius, 6.096, accuracy: 0.001, "the alarm is 20 ft outside the swing")
        e.rodeOutSet = 80
        XCTAssertEqual(e.radius, (80.0 * 80 - 36).squareRoot() + 7 + 6.096, accuracy: 0.05, "follows the rode")
        e.setRadiusByHand(40)
        e.rodeOutSet = 60
        XCTAssertEqual(e.radius, 40, "a hand-set radius stays put")
        e.applySuggestedRadius()
        XCTAssertTrue(e.radiusFollowsRode)
    }

    func testOldFiveMetreMarginBecomesTwentyFeet() throws {
        let old = #"{"depth":4,"bowHeight":1,"boatLength":15,"scopeRatio":5,"margin":5}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ScopeSettings.self, from: old).margin, 6.096)
    }

    @MainActor func testEngineStaysOutsideAfterSilencing() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        let origin = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)
        func at(_ m: Double) -> Fix { Fix(coordinate: Geo.destination(from: origin, bearing: 90, meters: m), accuracy: 3, course: nil, speed: nil, timestamp: Date()) }
        e.ingest(at(0)); e.dropAnchor(); e.radius = 30
        for _ in 0..<3 { e.ingest(at(50)) }
        XCTAssertNotNil(e.alarm)
        e.silence()
        XCTAssertEqual(e.watchState, .outside(distance: e.distance!))
    }
}

final class OutlookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = ScopeSettings(depth: 6, bowHeight: 1.2, boatLength: 14.3, scopeRatio: 5, margin: 5)

    private func depths(_ f: (Double) -> Double) -> [(time: Date, depth: Double)] {
        stride(from: 0.0, through: 24, by: 1.0 / 6).map { (now.addingTimeInterval($0 * 3600), f($0)) }
    }

    private func forecast(gust: (Int) -> Double, direction: (Int) -> Double = { _ in 200 }) -> [WindSample] {
        (0...24).map { WindSample(time: now.addingTimeInterval(Double($0) * 3600), speed: min(10, gust($0)), direction: direction($0), gust: gust($0)) }
    }

    private func items(depths d: [(time: Date, depth: Double)], forecast f: [WindSample], rodeOut: Double = 40) -> [OutlookItem] {
        let b = BoatProfile()
        let hourly = Outlook.hourly(b, scope: scope, bottom: .mud, rodeOut: rodeOut, depths: d, forecast: f, now: now)
        return Outlook.items(b, scope: scope, rodeOut: rodeOut, depths: d, hourly: hourly, tideTurns: [], units: .feet, now: now)
    }

    func testCalmDeepWaterIsClear() {
        let list = items(depths: depths { _ in 6 }, forecast: forecast { _ in 8 })
        XCTAssertNil(Outlook.nextRisk(list))
    }

    func testThinWaterAtLowIsFlaggedWithItsTimes() {
        // Draft is about 1.55 m; the depth dips to 1.8 m around hour 6.
        let list = items(depths: depths { h in 6 - 4.2 * max(0, 1 - abs(h - 6) / 3) }, forecast: forecast { _ in 8 })
        let shallow = list.first { $0.kind == .shallow }
        XCTAssertNotNil(shallow)
        XCTAssertEqual(shallow!.severity, .caution)
        XCTAssertEqual(shallow!.start.timeIntervalSince(now) / 3600, 6, accuracy: 1)
    }

    func testStrongGustLaterIsTheNextRisk() {
        let list = items(depths: depths { _ in 6 }, forecast: forecast { $0 == 5 ? 60 : 8 })
        let risk = Outlook.nextRisk(list)
        XCTAssertEqual(risk?.kind, .gusts)
        XCTAssertEqual(risk?.start, now.addingTimeInterval(5 * 3600))
    }

    func testShortScopeAtHighWater() {
        // 40 m out in 9 m of water plus 1.2 m bow: under 4:1.
        let list = items(depths: depths { h in h > 10 && h < 14 ? 9 : 6 }, forecast: forecast { _ in 8 })
        XCTAssertTrue(list.contains { $0.kind == .scope })
    }

    func testWindShiftIsInformation() {
        // 70°: a shift worth knowing about, short of the 90° that swings the boat round and resets the anchor.
        let list = items(depths: depths { _ in 6 }, forecast: forecast(gust: { _ in 12 }, direction: { $0 < 8 ? 200 : 270 }))
        let shift = list.first { $0.kind == .windShift }
        XCTAssertEqual(shift?.severity, .info)
        XCTAssertNil(Outlook.nextRisk(list.filter { $0.kind == .windShift }))
    }
}

final class CurrentTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Slack, 2 kt flood toward 090 three hours on, slack, 2 kt ebb toward 270.
    private var events: [CurrentEvent] {
        [0.0, 2, 0, -2, 0].enumerated().map { i, v in
            CurrentEvent(time: t0.addingTimeInterval(Double(i) * 3 * 3600), velocity: v, floodToward: 90, ebbToward: 270)
        }
    }

    func testCurrentFollowsTheCosineBetweenSlackAndMax() {
        XCTAssertEqual(CurrentMath.at(t0, events: events)!.speed, 0, accuracy: 0.001)
        XCTAssertEqual(CurrentMath.at(t0.addingTimeInterval(1.5 * 3600), events: events)!.speed, 1, accuracy: 0.001)
        let max = CurrentMath.at(t0.addingTimeInterval(3 * 3600), events: events)!
        XCTAssertEqual(max.speed, 2, accuracy: 0.001)
        XCTAssertEqual(max.toward, 90)
        XCTAssertEqual(CurrentMath.at(t0.addingTimeInterval(9 * 3600), events: events)!.toward, 270, "ebbing")
    }

    func testParsesNOAACurrentPredictions() throws {
        let json = #"{"current_predictions":{"units":"feet, knots","cp":[{"Type":"slack","meanFloodDir":82,"Bin":"7","meanEbbDir":282,"Time":"2026-10-12 00:47","Depth":"205","Velocity_Major":0.01},{"Type":"ebb","meanFloodDir":82,"Bin":"7","meanEbbDir":282,"Time":"2026-10-12 04:38","Depth":"205","Velocity_Major":-3.71}]}}"#
        let parsed = try CurrentMath.parsePredictions(Data(json.utf8))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(parsed[0].isSlack)
        XCTAssertEqual(parsed[1].velocity, -3.71)
        XCTAssertEqual(parsed[1].ebbToward, 282)
    }

    func testStationListKeepsOneEntryPerStation() throws {
        let json = #"{"stations":[{"id":"PUG1719","name":"Spieden Channel","lat":48.6,"lng":-123.1,"currbin":19,"type":"H"},{"id":"PUG1719","name":"Spieden Channel","lat":48.6,"lng":-123.1,"currbin":7,"type":"H"},{"id":"PUG1720","name":"Weak current","lat":48.6,"lng":-123.1,"currbin":1,"type":"W"}]}"#
        XCTAssertEqual(try CurrentMath.parseStations(Data(json.utf8)).count, 1)
    }

    func testParsesCHSCurrentStationsAndRequiresPredictionEvents() throws {
        let json = #"[{"id":"chs-uuid","code":"08108","officialName":"Seymour Narrows","latitude":50.133333,"longitude":-125.35,"timeSeries":[{"code":"wcp1-events"},{"code":"wcdp1"}]},{"id":"tide-only","code":"00001","officialName":"Tide Only","latitude":50.0,"longitude":-125.0,"timeSeries":[{"code":"wlp-hilo"}]}]"#
        let stations = try CurrentMath.parseCHSStations(Data(json.utf8))
        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations.first?.id, "chs-uuid")
        XCTAssertEqual(stations.first?.stationCode, "08108")
        XCTAssertEqual(stations.first?.provider, .chs)
    }

    func testParsesCHSFloodEbbSlackAndFlowDirections() throws {
        let eventJSON = #"[{"eventDate":"2026-10-22T01:13:00Z","qcFlagCode":"2","qualifier":"EXTREMA_EBB","value":8.232},{"eventDate":"2026-10-22T04:24:00Z","qcFlagCode":"2","qualifier":"SLACK","value":0.0},{"eventDate":"2026-10-22T07:14:00Z","qcFlagCode":"2","qualifier":"EXTREMA_FLOOD","value":6.714},{"eventDate":"2026-10-22T10:19:00Z","qcFlagCode":"2","qualifier":"SLACK","value":0.0},{"eventDate":"2026-10-22T13:29:00Z","qcFlagCode":"2","qualifier":"EXTREMA_EBB","value":7.202}]"#
        let directionJSON = #"[{"eventDate":"2026-10-22T01:15:00Z","qcFlagCode":"2","value":0.0},{"eventDate":"2026-10-22T07:15:00Z","qcFlagCode":"2","value":180.0},{"eventDate":"2026-10-22T13:30:00Z","qcFlagCode":"2","value":0.0}]"#
        let parsed = try CurrentMath.parseCHSPredictions(events: Data(eventJSON.utf8), directions: Data(directionJSON.utf8))
        XCTAssertEqual(parsed.count, 5)
        XCTAssertEqual(parsed[0].velocity, -8.232, accuracy: 0.001)
        XCTAssertEqual(parsed[1].velocity, 0)
        XCTAssertEqual(parsed[2].velocity, 6.714, accuracy: 0.001)
        XCTAssertEqual(parsed[2].floodToward, 180, accuracy: 0.001)
        XCTAssertEqual(parsed[2].ebbToward, 0, accuracy: 0.001)
    }

    func testOldCachedCurrentStationDefaultsToNOAA() throws {
        let json = #"{"id":"PUG1719","name":"Spieden Channel","lat":48.6,"lng":-123.1}"#
        let station = try JSONDecoder().decode(CurrentStation.self, from: Data(json.utf8))
        XCTAssertEqual(station.provider, .noaa)
    }
}

final class SwingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = ScopeSettings(depth: 6, bowHeight: 1.2, boatLength: 14.3, scopeRatio: 5, margin: 5)
    private let depths: [(time: Date, depth: Double)] = (0...144).map { (Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 600), 6.0) }

    private func forecast(speed: Double, direction: @escaping (Int) -> Double) -> [WindSample] {
        (0...24).map { WindSample(time: now.addingTimeInterval(Double($0) * 3600), speed: speed, direction: direction($0), gust: speed) }
    }

    private func outlook(_ f: [WindSample], current: ((Date) -> CurrentAt?)? = nil, events: [CurrentEvent]? = nil,
                         turns: [TideEvent] = []) -> [OutlookItem] {
        let b = BoatProfile()
        let hourly = Outlook.hourly(b, scope: scope, bottom: .mud, rodeOut: 40, depths: depths, forecast: f, current: current, now: now)
        return Outlook.items(b, scope: scope, rodeOut: 40, depths: depths, hourly: hourly, tideTurns: turns,
                             currentEvents: events, units: .feet, now: now)
    }

    func testBigWindShiftIsASwingCaution() {
        let list = outlook(forecast(speed: 15) { $0 < 6 ? 200 : 20 })
        let swing = list.first { $0.kind == .swing }
        XCTAssertEqual(swing?.severity, .caution)
        XCTAssertEqual(swing?.start, now.addingTimeInterval(6 * 3600))
        XCTAssertEqual(Outlook.nextRisk(list)?.kind, .swing)
    }

    func testCurrentTurningInLightWindSwingsTheBoat() {
        // 2 kt wind, and a 1.5 kt current that reverses at hour 6: the current holds the boat, so it swings round.
        let current: (Date) -> CurrentAt? = { t in
            t < self.now.addingTimeInterval(6 * 3600) ? CurrentAt(speed: 1.5, toward: 90, flooding: true)
                                                      : CurrentAt(speed: 1.5, toward: 270, flooding: false)
        }
        let swing = outlook(forecast(speed: 2) { _ in 0 }, current: current, events: []).first { $0.kind == .swing }
        XCTAssertNotNil(swing)
        XCTAssertTrue(swing!.detail.contains("ebb"), swing!.detail)
    }

    func testStrongWindHoldsTheBoatThroughACurrentTurn() {
        let current: (Date) -> CurrentAt? = { t in
            CurrentAt(speed: 0.3, toward: t < self.now.addingTimeInterval(6 * 3600) ? 90 : 270, flooding: true)
        }
        XCTAssertNil(outlook(forecast(speed: 20) { _ in 0 }, current: current, events: []).first { $0.kind == .swing })
    }

    func testArcWrapsThroughNorth() {
        let arc = Outlook.arc([350, 10, 30])!
        XCTAssertEqual(arc.from, 350)
        XCTAssertEqual(arc.width, 40)
        XCTAssertEqual(Outlook.arc([90, 100])!.width, 10)
        XCTAssertEqual(Outlook.arc(stride(from: 0.0, to: 360, by: 20).map { $0 })!.width, 360, "all the way round")
        XCTAssertNil(Outlook.arc([]))
    }

    func testSwingRadiusIsTheTautRodePlusBowToPhone() {
        // 50 m of rode in 3 m of water with a 1 m bow: √(2500 − 16) ≈ 49.84 m of reach, plus 7 m back to the phone.
        XCTAssertEqual(Outlook.swingRadius(rodeOut: 50, shallowest: 3, bowHeight: 1, bowToPhone: 7), 56.84, accuracy: 0.01)
    }

    func testLightWindTideTurnIsACautionWithoutCurrentData() {
        let turn = TideEvent(time: now.addingTimeInterval(4 * 3600), height: 2, isHigh: true)
        let calm = outlook(forecast(speed: 3) { _ in 0 }, turns: [turn]).first { $0.kind == .tideTurn }
        XCTAssertEqual(calm?.severity, .caution)
        let windy = outlook(forecast(speed: 15) { _ in 0 }, turns: [turn]).first { $0.kind == .tideTurn }
        XCTAssertEqual(windy?.severity, .info)
    }
}

final class AnchorPhysicsTests: XCTestCase {
    /// Roughly Nereus on 60 m (200 ft) of 3/8" chain in 11 m (36 ft) of water.
    private let boat = AnchorPhysics.Boat(rode: 60, depth: 11, bowHeight: 1.2, chainWeight: AnchorMath.chainWeight(sizeMM: 9.525),
                                          frontWindage: 17, sideWindage: 50, underwater: 4.4, mass: 31_000,
                                          bowToPhone: 7, holding: 10_000)

    private func distance(_ p: AnchorPhysics) -> Double {
        ((p.bow.x - p.anchor.x) * (p.bow.x - p.anchor.x) + (p.bow.y - p.anchor.y) * (p.bow.y - p.anchor.y)).squareRoot()
    }

    func testChainPullsNothingInTheSlackAndMoreTowardTaut() {
        var p = AnchorPhysics(boat: boat, weather: SimDays.calm)
        let slack = p.slack(depth: 11)                                     // 60 − 12.2 = 47.8 m
        XCTAssertEqual(p.pull(at: slack - 2, depth: 11), 0)
        let near = p.pull(at: slack + 5, depth: 11), far = p.pull(at: slack + 10, depth: 11)
        XCTAssertGreaterThan(near, 0)
        XCTAssertGreaterThan(far, near * 2, "the pull rises steeply as the chain lifts")
    }

    func testCalmNightWandersRoundAWideArcNotOnOneHeading() {
        // Like a real calm night: the boat lies out near the end of the slack, but in whatever direction the light
        // air and weak tide take it, wobbling in and out, and never past taut.
        var p = AnchorPhysics(boat: boat, weather: SimDays.calm)
        let taut = (60.0 * 60 - 12.2 * 12.2).squareRoot()
        var distances: [Double] = [], bearings: [Double] = []
        for i in 0..<(8 * 3600) {
            p.step()
            if i % 60 == 0 {
                distances.append(distance(p))
                bearings.append((atan2(p.bow.x - p.anchor.x, p.bow.y - p.anchor.y).degrees + 360).truncatingRemainder(dividingBy: 360))
            }
        }
        XCTAssertLessThanOrEqual(distances.max()!, taut + 0.01, "never past taut")
        XCTAssertLessThan(distances.min()!, p.slack(depth: 11), "comes well in at times")
        let mean = distances.reduce(0, +) / Double(distances.count)
        let spread = (distances.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(distances.count)).squareRoot()
        XCTAssertGreaterThan(spread, 1.5, "wobbles in and out rather than sitting on one radius")
        XCTAssertGreaterThan(Outlook.arc(bearings)!.width, 120, "lies round a wide arc, not to one heading")
    }

    func testSteadyBreezeLiesDownwindNearTheEndOfTheRode() {
        let breeze = SimWeather(wind: { _ in (15, 0) }, gustiness: 0, currentMax: 0, floodToward: 0, tideRange: 0)
        var p = AnchorPhysics(boat: boat, weather: breeze)
        for _ in 0..<3600 { p.step() }
        let bearing = (atan2(p.bow.x - p.anchor.x, p.bow.y - p.anchor.y).degrees + 360).truncatingRemainder(dividingBy: 360)
        XCTAssertEqual(bearing, 180, accuracy: 35, "a northerly blows the boat south of its anchor")
        XCTAssertGreaterThan(distance(p), p.slack(depth: 11), "out on the chain, not wandering")
    }

    @MainActor func testSimulatedTideIsSqueezedOntoTheRealClock() {
        let sim = SimulatedLocationSource()
        sim.physicsBoat = boat
        sim.scenario = .calmNight
        sim.speed = 300
        sim.restart()
        sim.stop()
        let now = Date()
        let events = try! XCTUnwrap(sim.tideSnapshot(now: now)).events
        XCTAssertEqual(zip(events, events.dropFirst()).filter { $0.isHigh == $1.isHigh }.count, 0, "highs and lows alternate")
        let next = events.first { $0.time > now }!
        // Six hours of simulated tide at 300× is about 75 real seconds.
        XCTAssertLessThan(next.time.timeIntervalSince(now), SimWeather.tidePeriod / 2 / 300 + 1)
        XCTAssertEqual(events.filter(\.isHigh).first!.height - events.filter { !$0.isHigh }.first!.height, SimDays.calm.tideRange, accuracy: 0.001)
    }

    func testGaleDragsTheAnchor() {
        var p = AnchorPhysics(boat: boat, weather: SimDays.gale)
        for _ in 0..<(12 * 3600) { p.step() }
        let moved = (p.anchor.x * p.anchor.x + p.anchor.y * p.anchor.y).squareRoot()
        XCTAssertGreaterThan(moved, 10)
    }
}

final class HazardTests: XCTestCase {
    private let anchor = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func lifecycleDefaults() -> UserDefaults {
        let suite = "HazardLifecycleTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    @MainActor private func engine(_ defaults: UserDefaults) -> AnchorWatchEngine {
        AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: defaults, useGPSHardware: false)
    }

    @MainActor private func drop(_ e: AnchorWatchEngine) {
        e.ingest(Fix(coordinate: anchor, accuracy: 3, course: nil, speed: nil, timestamp: Date()))
        e.dropAnchor()
        XCTAssertNotNil(e.anchor)
    }

    @MainActor func testRaiseHidesAllKindsAndDismissesEditorAcrossRestart() {
        let defaults = lifecycleDefaults()
        let e = engine(defaults)
        drop(e)
        let marks = Hazard.Kind.allCases.map { Hazard(kind: $0, at: anchor) }
        marks.forEach(e.addHazard)
        e.editHazard(marks[0].id)
        XCTAssertNotNil(e.nearestHazard)
        e.raiseAnchor()
        XCTAssertTrue(e.hazards.isEmpty)
        XCTAssertNil(e.pendingHazard)
        XCTAssertNil(e.nearestHazard)
        XCTAssertEqual(e.hiddenHazards.map(\.id), marks.map(\.id))
        let again = engine(defaults)
        XCTAssertTrue(again.hazards.isEmpty)
        XCTAssertEqual(again.hiddenHazards.map(\.id), marks.map(\.id))
        drop(again)
        XCTAssertTrue(again.hazards.isEmpty, "dropping never restores hidden marks")
        XCTAssertNil(again.nearestHazard)
    }

    @MainActor func testRestartWhileAnchoredKeepsActiveMarks() {
        let defaults = lifecycleDefaults()
        let e = engine(defaults)
        drop(e)
        let rock = Hazard(kind: .rock, at: anchor)
        e.addHazard(rock)
        let again = engine(defaults)
        XCTAssertNotNil(again.anchor)
        XCTAssertEqual(again.hazards, [rock])
        XCTAssertTrue(again.hiddenHazards.isEmpty)
    }

    @MainActor func testRepeatedRaisesKeepEarlierMarksAndHideNewOnes() {
        let defaults = lifecycleDefaults()
        let e = engine(defaults)
        let rock = Hazard(kind: .rock, at: anchor)
        let boat = Hazard(kind: .boat, at: anchor)
        e.addHazard(rock)
        e.raiseAnchor()
        e.raiseAnchor()
        e.addHazard(boat)
        XCTAssertEqual(e.hazards, [boat])
        e.raiseAnchor()
        XCTAssertEqual(Set(e.hiddenHazards.map(\.id)), Set([rock.id, boat.id]))
        e.restoreHazard(rock.id)
        e.restoreHazard(rock.id)
        XCTAssertEqual(e.hazards, [rock], "restoring twice cannot duplicate a mark")
        XCTAssertEqual(e.hiddenHazards.map(\.id), [boat.id])
        e.raiseAnchor()
        XCTAssertEqual(engine(defaults).hiddenHazards.count, 2)
    }

    @MainActor func testRestoreKeepsGeographicPositionAndRejoinsClearanceAndForecast() {
        let defaults = lifecycleDefaults()
        let e = engine(defaults)
        drop(e)
        let spot = e.anchor!
        let rock = Hazard(kind: .rock, at: Geo.destination(from: spot, bearing: 180, meters: 78), radius: 5, name: "Rock")
        e.addHazard(rock)
        e.raiseAnchor()
        e.ingest(Fix(coordinate: Geo.destination(from: anchor, bearing: 90, meters: 5), accuracy: 3, course: nil, speed: nil, timestamp: Date()))
        e.dropAnchor()
        XCTAssertNil(e.nearestHazard)
        let depths: [(time: Date, depth: Double)] = (0...144).map { (now.addingTimeInterval(Double($0) * 600), 6.0) }
        let forecast = (0...24).map { WindSample(time: now.addingTimeInterval(Double($0) * 3600), speed: 15, direction: 0, gust: 18) }
        let hourly = Outlook.hourly(e.boat, scope: e.scope, bottom: .mud, rodeOut: 60, depths: depths, forecast: forecast, now: now)
        func hazardWarnings() -> [OutlookItem] {
            Outlook.items(e.boat, scope: e.scope, rodeOut: 60, depths: depths, hourly: hourly, tideTurns: [],
                          anchor: spot, hazards: e.hazards, units: .feet, now: now).filter { $0.kind == .hazard }
        }
        XCTAssertTrue(hazardWarnings().isEmpty)
        e.restoreHazard(rock.id)
        XCTAssertEqual(e.hazards, [rock])
        XCTAssertEqual(e.hazards.first?.coordinate, rock.coordinate, "marks do not move with the anchor")
        XCTAssertEqual(e.nearestHazard?.hazard.id, rock.id)
        XCTAssertEqual(hazardWarnings().map(\.subject), [rock.id.uuidString])
        XCTAssertEqual(engine(defaults).hazards, [rock])
    }

    @MainActor func testPermanentDeletionPersistsWithoutDeletingOtherHiddenMarks() {
        let defaults = lifecycleDefaults()
        let e = engine(defaults)
        let rock = Hazard(kind: .rock, at: anchor)
        let dock = Hazard(kind: .dock, at: anchor)
        e.addHazard(rock); e.addHazard(dock); e.raiseAnchor()
        e.removeHazard(rock.id)
        e.restoreHazard(rock.id)
        let again = engine(defaults)
        XCTAssertTrue(again.hazards.isEmpty)
        XCTAssertEqual(again.hiddenHazards.map(\.id), [dock.id])
    }

    @MainActor func testLegacyMarksWithoutHiddenFieldRemainActive() {
        let defaults = lifecycleDefaults()
        let id = UUID()
        let legacy = "[{\"id\":\"\(id)\",\"kind\":\"Rock\",\"latitude\":48.6,\"longitude\":-123.15,\"radius\":8,\"name\":\"Old rock\"}]"
        defaults.set(Data(legacy.utf8), forKey: "anchorwatch.hazards")
        let e = engine(defaults)
        XCTAssertEqual(e.hazards.map(\.id), [id])
        XCTAssertTrue(e.hiddenHazards.isEmpty)
        e.raiseAnchor()
        XCTAssertEqual(engine(defaults).hiddenHazards.map(\.id), [id])
    }

    @MainActor func testRetrieveAndSimulatorPlaceChangeHideMarks() {
        let e = engine(lifecycleDefaults())
        drop(e)
        let rock = Hazard(kind: .rock, at: anchor)
        e.addHazard(rock)
        let spot = e.anchor
        e.startRetrieval()
        XCTAssertEqual(e.retrieveTarget, spot)
        XCTAssertTrue(e.hazards.isEmpty)
        XCTAssertEqual(e.hiddenHazards.map(\.id), [rock.id])
        e.restoreHazard(rock.id)
        e.simPlace = e.simPlace == .rocheHarbor ? .sidney : .rocheHarbor
        XCTAssertTrue(e.hazards.isEmpty)
        XCTAssertEqual(e.hiddenHazards.map(\.id), [rock.id])
    }

    @MainActor func testMovingAnchorAndSilencingKeepMarksAndRemovalClearsWarningMetadata() {
        let e = engine(lifecycleDefaults())
        drop(e)
        let rock = Hazard(kind: .rock, at: anchor)
        e.addHazard(rock)
        e.moveAnchor(to: Geo.destination(from: anchor, bearing: 90, meters: 5))
        e.silence()
        XCTAssertEqual(e.hazards, [rock])
        let warning = OutlookItem(kind: .hazard, severity: .caution, start: now, end: nil, title: "Rock", detail: "", subject: rock.id.uuidString)
        let other = OutlookItem(kind: .gusts, severity: .caution, start: now, end: nil, title: "Wind", detail: "")
        e.hideOutlook(warning); e.lockOutlook(warning)
        e.hideOutlook(other); e.lockOutlook(other)
        e.removeHazard(rock.id)
        XCTAssertFalse(e.hiddenOutlook.contains { $0.subject == rock.id.uuidString })
        XCTAssertFalse(e.isLocked(warning))
        XCTAssertTrue(e.isLocked(other), "unrelated warning preferences stay intact")
        XCTAssertEqual(e.hiddenOutlook.count, 1)
    }

    func testClearanceIsTheGapFromTheSternsFullSwingToTheEdge() {
        let rock = Hazard(kind: .rock, at: Geo.destination(from: anchor, bearing: 45, meters: 100), radius: 8)
        XCTAssertEqual(Clearance.clearance(anchor: anchor, sternReach: 70, hazard: rock), 22, accuracy: 0.01)
        XCTAssertLessThan(Clearance.clearance(anchor: anchor, sternReach: 95, hazard: rock), 0, "swing reaches it")
        let far = Hazard(kind: .dock, at: Geo.destination(from: anchor, bearing: 200, meters: 300))
        XCTAssertEqual(Clearance.nearest(anchor: anchor, sternReach: 70, hazards: [far, rock])?.hazard, rock)
    }

    func testOutlookFlagsTheHazardTheWindPushesTheBoatToward() {
        // A steady northerly: the boat lies south of the anchor, ~60 m with 60 m of rode in 6 m of water.
        let b = BoatProfile()
        let scope = ScopeSettings(depth: 6, bowHeight: 1.2, boatLength: 14.3, scopeRatio: 5, margin: 5)
        let depths: [(time: Date, depth: Double)] = (0...144).map { (now.addingTimeInterval(Double($0) * 600), 6.0) }
        let forecast = (0...24).map { WindSample(time: now.addingTimeInterval(Double($0) * 3600), speed: 15, direction: 0, gust: 18) }
        let hourly = Outlook.hourly(b, scope: scope, bottom: .mud, rodeOut: 60, depths: depths, forecast: forecast, now: now)
        let south = Hazard(kind: .rock, at: Geo.destination(from: anchor, bearing: 180, meters: 78), radius: 5)
        let north = Hazard(kind: .rock, at: Geo.destination(from: anchor, bearing: 0, meters: 78), radius: 5)
        let items = Outlook.items(b, scope: scope, rodeOut: 60, depths: depths, hourly: hourly, tideTurns: [],
                                  anchor: anchor, hazards: [south, north], units: .feet, now: now)
        let hazardItems = items.filter { $0.kind == .hazard }
        XCTAssertEqual(hazardItems.count, 1, "only the rock downwind")
        XCTAssertEqual(hazardItems.first?.severity, .danger)
    }

    @MainActor func testHazardsAreSavedAndRemoved() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        let rock = Hazard(kind: .rock, at: anchor, name: "Pole Pass rock")
        e.addHazard(rock)
        let again = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertEqual(again.hazards, [rock])
        let moved = Geo.destination(from: anchor, bearing: 90, meters: 25)
        again.moveHazard(rock.id, to: moved)
        XCTAssertEqual(again.hazards[0].coordinate, moved)
        XCTAssertEqual(again.hazards[0].name, "Pole Pass rock", "keeps everything else")
        again.removeHazard(rock.id)
        XCTAssertTrue(again.hazards.isEmpty)
    }

    @MainActor func testEditingAHazardKeepsItsPlace() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        let rock = Hazard(kind: .rock, at: anchor)
        e.addHazard(rock)
        e.editHazard(rock.id)
        XCTAssertEqual(e.pendingHazard?.hazard, rock, "the sheet opens filled in")
        var changed = rock
        changed.kind = .shoal
        changed.radius = 25
        changed.name = "Sand spit"
        e.updateHazard(changed)
        XCTAssertEqual(e.hazards, [changed])
        XCTAssertEqual(e.hazards[0].coordinate, rock.coordinate)
    }
}

final class PressureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func readings(fall: Double, hours: Double = 3) -> [PressureReading] {
        stride(from: hours * 60, through: 0, by: -10).map { m in
            PressureReading(time: now.addingTimeInterval(-m * 60), hPa: 1013 - fall * (hours * 60 - m) / (hours * 60))
        }
    }

    func testThreeHourChangeAndLevels() {
        XCTAssertEqual(PressureTrend.change(readings(fall: 4), now: now)!, -4, accuracy: 0.01)
        XCTAssertEqual(PressureTrend.level(-1.5), .steady)
        XCTAssertEqual(PressureTrend.level(-4), .fallingQuickly)
        XCTAssertEqual(PressureTrend.level(-7), .fallingFast)
        XCTAssertEqual(PressureTrend.level(+5), .steady, "a rise isn't a warning")
    }

    func testNeedsMostOfThreeHoursOfHistory() {
        XCTAssertNil(PressureTrend.change(readings(fall: 4, hours: 1), now: now))
    }

    @MainActor func testEngineKeepsAReadingAMinute() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        e.record(pressure: 1013, at: now)
        e.record(pressure: 1012.9, at: now.addingTimeInterval(20))          // too soon: dropped
        e.record(pressure: 1012.8, at: now.addingTimeInterval(61))
        XCTAssertEqual(e.pressureHistory.map(\.hPa), [1013, 1012.8])
    }
}

final class AnchorageLogTests: XCTestCase {
    private let spot = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)

    private func entry(_ at: CLLocationCoordinate2D, daysAgo: Double) -> AnchorageEntry {
        let dropped = Date().addingTimeInterval(-daysAgo * 86_400)
        return AnchorageEntry(name: "Test", latitude: at.latitude, longitude: at.longitude, dropped: dropped,
                              raised: dropped.addingTimeInterval(3600), depth: 8, rodeOut: 50, radius: 60, maxDistance: 45,
                              bottom: "Mud")
    }

    func testPreviousVisitIsTheLatestNearbyOne() {
        let old = entry(spot, daysAgo: 30), recent = entry(Geo.destination(from: spot, bearing: 90, meters: 80), daysAgo: 5)
        let elsewhere = entry(Geo.destination(from: spot, bearing: 0, meters: 2_000), daysAgo: 1)
        XCTAssertEqual(AnchorageLog.previousVisit(near: spot, in: [old, recent, elsewhere], before: Date())?.id, recent.id)
        XCTAssertNil(AnchorageLog.previousVisit(near: spot, in: [elsewhere], before: Date()))
    }

    func testLongTracksAreThinnedKeepingTheEnds() {
        let points = (0..<5_000).map { Geo.destination(from: spot, bearing: 90, meters: Double($0) * 0.1) }
        let thinned = AnchorageLog.thin(points)
        XCTAssertEqual(thinned.count, 400)
        XCTAssertEqual(thinned.last![1], points.last!.longitude, accuracy: 1e-9)
    }

    @MainActor func testRaisingAfterTenMinutesLogsTheStay() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        // An anchor dropped 20 minutes ago, as the app saves it.
        let dropped = Date().addingTimeInterval(-1_200).timeIntervalSinceReferenceDate
        defaults.set(#"{"latitude":48.6,"longitude":-123.15,"radius":40,"dropped":\#(dropped)}"#.data(using: .utf8), forKey: "anchorwatch.saved")
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        e.logURL = file
        XCTAssertNotNil(e.anchor)
        e.raiseAnchor()
        XCTAssertEqual(e.anchorages.count, 1)
        XCTAssertEqual(e.anchorages[0].radius, 40)
        XCTAssertEqual(AnchorageLog.load(from: file).count, 1, "saved to the file")
    }

    @MainActor func testALockedAnchorageCantBeDeleted() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dropped = Date().addingTimeInterval(-1_200).timeIntervalSinceReferenceDate
        defaults.set(#"{"latitude":48.6,"longitude":-123.15,"radius":40,"dropped":\#(dropped)}"#.data(using: .utf8), forKey: "anchorwatch.saved")
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        e.logURL = file
        e.raiseAnchor()
        let id = try XCTUnwrap(e.anchorages.first?.id)
        e.setAnchorageLocked(id, true)
        e.deleteAnchorage(id)
        XCTAssertEqual(e.anchorages.count, 1, "locked: kept")
        XCTAssertTrue(AnchorageLog.load(from: file)[0].isLocked, "the lock is saved")
        e.setAnchorageLocked(id, false)
        e.deleteAnchorage(id)
        XCTAssertTrue(e.anchorages.isEmpty)
    }

    func testLogsSavedBeforeLockingStillLoad() throws {
        var json = String(data: try JSONEncoder().encode([entry(spot, daysAgo: 1)]), encoding: .utf8)!
        json = json.replacingOccurrences(of: #","locked":false"#, with: "").replacingOccurrences(of: #""locked":false,"#, with: "")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try json.data(using: .utf8)!.write(to: file)
        let loaded = AnchorageLog.load(from: file)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertFalse(loaded[0].isLocked)
    }
}


final class RetrievalTests: XCTestCase {
    private let anchor = CLLocationCoordinate2D(latitude: 48.75, longitude: -123.3)

    /// GPS `meters` from the anchor on `from` bearing, heading `course` at `knots`.
    private func fix(_ meters: Double, from bearing: Double, course: Double?, knots: Double) -> Fix {
        Fix(coordinate: Geo.destination(from: anchor, bearing: bearing, meters: meters), accuracy: 3,
            course: course, speed: knots * 0.5144, timestamp: Date())
    }

    func testBowIsAheadOfTheGPSAndAnchorDeadAhead() {
        // 60 m south of the anchor, heading north: the bow (7 m ahead) is 53 m off, dead ahead.
        let g = RetrievalGuide.make(phone: fix(60, from: 180, course: 0, knots: 1), anchor: anchor, bowOffset: 7, depth: 10)
        XCTAssertEqual(g.distance, 53, accuracy: 0.5)
        XCTAssertEqual(g.relative!, 0, accuracy: 1)
        XCTAssertEqual(g.steer, "Dead ahead")
        XCTAssertFalse(g.overAnchor)
    }

    func testSteersToPortOrStarboard() {
        // South of the anchor heading 030: the anchor is to port.
        let port = RetrievalGuide.make(phone: fix(100, from: 180, course: 30, knots: 1), anchor: anchor, bowOffset: 7, depth: 10)
        XCTAssertLessThan(port.relative!, -20)
        XCTAssertTrue(port.steer.hasSuffix("to port"), port.steer)
        let starboard = RetrievalGuide.make(phone: fix(100, from: 180, course: 330, knots: 1), anchor: anchor, bowOffset: 7, depth: 10)
        XCTAssertTrue(starboard.steer.hasSuffix("to starboard"), starboard.steer)
        let behind = RetrievalGuide.make(phone: fix(100, from: 180, course: 180, knots: 1), anchor: anchor, bowOffset: 7, depth: 10)
        XCTAssertEqual(behind.steer, "Behind you: turn round")
    }

    func testBarelyMovingGivesACompassBearingNotAnArrow() {
        let g = RetrievalGuide.make(phone: fix(50, from: 225, course: 300, knots: 0.2), anchor: anchor, bowOffset: 7, depth: 10)
        XCTAssertNil(g.relative, "course is noise at 0.2 kn")
        XCTAssertEqual(g.bearing, 45, accuracy: 1)
        XCTAssertEqual(g.distance, 43, accuracy: 0.5, "bow lies toward the anchor")
        XCTAssertTrue(g.steer.hasPrefix("Anchor lies NE"), g.steer)
    }

    func testOverTheAnchorWhenTheRodeIsUpAndDown() {
        // 12 m deep: within 6 m of the anchor counts as over it.
        let g = RetrievalGuide.make(phone: fix(12, from: 180, course: 0, knots: 0.6), anchor: anchor, bowOffset: 7, depth: 12)
        XCTAssertTrue(g.overAnchor)
        XCTAssertEqual(g.steer, "Over the anchor: rode up and down")
    }

    @MainActor func testRetrievingEndsTheWatchButKeepsTheAnchorSpot() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        for _ in 0..<3 { e.ingest(Fix(coordinate: anchor, accuracy: 3, course: nil, speed: nil, timestamp: Date())) }
        e.dropAnchor()
        let spot = try! XCTUnwrap(e.anchor)
        e.startRetrieval()
        XCTAssertNil(e.anchor, "the watch has ended")
        XCTAssertEqual(e.retrieveTarget, spot)
        XCTAssertNotNil(e.retrievalGuide)
        e.endRetrieval()
        XCTAssertNil(e.retrieveTarget)
    }
}

final class HiddenOutlookTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ kind: OutlookItem.Kind, _ severity: OutlookItem.Severity, hours: Double, to end: Double? = nil,
                      subject: String = "") -> OutlookItem {
        OutlookItem(kind: kind, severity: severity, start: t0.addingTimeInterval(hours * 3600),
                    end: end.map { t0.addingTimeInterval($0 * 3600) }, title: "", detail: "", subject: subject)
    }

    func testStaysHiddenAsTheStretchShiftsButNotALaterOne() {
        let hidden = HiddenOutlook(item(.gusts, .caution, hours: 3, to: 6))
        XCTAssertTrue(hidden.covers(item(.gusts, .caution, hours: 4, to: 6)), "same stretch, redone an hour later")
        XCTAssertFalse(hidden.covers(item(.gusts, .caution, hours: 15, to: 17)), "a separate blow later")
        XCTAssertFalse(hidden.covers(item(.shallow, .caution, hours: 3, to: 6)), "a different warning")
    }

    func testComesBackWhenItGetsWorse() {
        let hidden = HiddenOutlook(item(.hazard, .caution, hours: 2, subject: "boat"))
        XCTAssertTrue(hidden.covers(item(.hazard, .caution, hours: 9, subject: "boat")), "any warning about that hazard")
        XCTAssertFalse(hidden.covers(item(.hazard, .danger, hours: 2, subject: "boat")), "the swing now reaches it")
        XCTAssertFalse(hidden.covers(item(.hazard, .caution, hours: 2, subject: "rock")), "another hazard")
    }
}

final class LockedOutlookTests: XCTestCase {
    @MainActor func testALockedWarningCantBeDeleted() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        let item = OutlookItem(kind: .hazard, severity: .caution, start: Date(), end: nil, title: "", detail: "", subject: "boat")
        e.lockOutlook(item)
        XCTAssertTrue(e.isLocked(item))
        e.hideOutlook(item)
        XCTAssertTrue(e.hiddenOutlook.isEmpty, "locked: delete does nothing")
        let worse = OutlookItem(kind: .hazard, severity: .danger, start: Date(), end: nil, title: "", detail: "", subject: "boat")
        XCTAssertTrue(e.isLocked(worse), "stays locked as it changes")
        e.unlockOutlook(item)
        e.hideOutlook(item)
        XCTAssertEqual(e.hiddenOutlook.count, 1)
    }
}

final class WatchChartTests: XCTestCase {
    @MainActor func testChartIsMetresEastAndNorthOfTheAnchorAndThinned() {
        let anchor = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)
        let track = (0..<500).map { Geo.destination(from: anchor, bearing: Double($0) * 0.5, meters: 40) }
        let chart = WatchLink.chart(anchor: anchor, radius: 61.6, boat: Geo.destination(from: anchor, bearing: 90, meters: 30),
                                    track: track)
        XCTAssertEqual(chart["radiusM"], "62")
        XCTAssertEqual(chart["boat"], "30,0", "due east")
        let points = chart["track"]!.split(separator: " ")
        XCTAssertLessThanOrEqual(points.count, 90)
        XCTAssertEqual(points.first, "0,40", "due north")
    }
}

final class BatterySavingTests: XCTestCase {
    @MainActor func testPreciseGPSAndScreenOnOnlyWhenNeeded() {
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false)
        XCTAssertFalse(e.wantsPreciseGPS, "no anchor, no track")
        XCTAssertFalse(e.keepsScreenOn)
        e.preparingDrop = true
        XCTAssertTrue(e.wantsPreciseGPS, "about to drop")
        e.preparingDrop = false
        e.trackWhenUnanchored = true
        XCTAssertTrue(e.wantsPreciseGPS, "tracking under way")
        XCTAssertFalse(e.keepsScreenOn, "tracking alone lets the screen sleep")
        e.trackWhenUnanchored = false
        let spot = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)
        for _ in 0..<3 { e.ingest(Fix(coordinate: spot, accuracy: 3, course: nil, speed: nil, timestamp: Date())) }
        e.dropAnchor()
        XCTAssertTrue(e.wantsPreciseGPS)
        XCTAssertTrue(e.keepsScreenOn, "anchored")
        e.startRetrieval()
        XCTAssertTrue(e.keepsScreenOn, "retrieving")
        e.endRetrieval()
        XCTAssertFalse(e.keepsScreenOn)
    }
}


@MainActor
final class MonitoringFreshnessTests: XCTestCase {
    private let point = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)
    private func observation(_ date: Date, meters: Double = 0, accuracy: Double = 3) -> Fix {
        Fix(coordinate: Geo.destination(from: point, bearing: 90, meters: meters), accuracy: accuracy, course: nil, speed: nil, timestamp: date)
    }
    func testRestoredAnchorWithoutCallbacksReachesDeadline() {
        var now = Date()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let original = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: defaults, useGPSHardware: false, clock: { now })
        original.ingest(observation(now)); original.dropAnchor()
        let restored = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: defaults, useGPSHardware: false, clock: { now })
        XCTAssertEqual(restored.watchState, .acquiringGPS)
        XCTAssertEqual(restored.snapshot?.status, .caution)
        now += 31
        restored.safetyChecks()
        XCTAssertEqual(restored.alarm, .gpsLost)
        restored.silence()
        XCTAssertEqual(restored.watchState, .gpsInterrupted)
    }
    func testOldFutureInvalidAndDuplicateObservationsCannotDropOrConfirmOutside() {
        var now = Date()
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { now })
        e.ingest(observation(now - 60)); e.dropAnchor(); XCTAssertNil(e.anchor)
        e.ingest(observation(now + 60)); e.dropAnchor(); XCTAssertNil(e.anchor)
        e.ingest(observation(now, accuracy: -1)); e.dropAnchor(); XCTAssertNil(e.anchor)
        e.ingest(observation(now)); e.dropAnchor(); e.radius = 30
        now += 1
        let outside = observation(now, meters: 80)
        e.ingest(outside); e.ingest(outside)
        e.ingest(observation(now - 0.5, meters: 90))
        XCTAssertNil(e.alarm)
        now += 1
        e.ingest(observation(now, meters: 81))
        XCTAssertNotNil(e.alarm)
    }
    func testExpiredFixAndSourceSwitchInterruptMonitoringAndPreventDrop() {
        var now = Date()
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { now })
        e.ingest(observation(now)); e.dropAnchor()
        now += 16
        XCTAssertEqual(e.watchState, .gpsInterrupted)
        XCTAssertTrue(e.gpsIsUnusable)
        XCTAssertEqual(e.snapshot?.distanceText, "--")
        e.sourceKind = .gps
        XCTAssertEqual(e.watchState, .acquiringGPS)
        now += 31; e.safetyChecks(); XCTAssertEqual(e.alarm, .gpsLost)
        e.raiseAnchor(); e.dropAnchor(); XCTAssertNil(e.anchor)
    }
    func testPendingPlacementSurvivesRestartAndManualPlacementResolvesAllState() {
        let now = Date(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: defaults, useGPSHardware: false, clock: { now })
        e.ingest(observation(now)); e.dropAnchor(.settled)
        XCTAssertEqual(e.watchState, .awaitingFix)
        XCTAssertEqual(e.snapshot?.headline, e.monitoring.detail)
        XCTAssertEqual(e.monitoring.title, "Circle alarm OFF")
        let restored = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: defaults, useGPSHardware: false, clock: { now })
        XCTAssertTrue(restored.awaitingSwingFix)
        restored.ingest(observation(now))
        XCTAssertEqual(restored.watchState, .awaitingFix)
        restored.moveAnchor(to: point)
        XCTAssertEqual(restored.watchState, .holding)
        XCTAssertEqual(restored.snapshot?.status, .holding)
    }
    func testUnusableCallbacksCannotKeepMonitoringHealthy() {
        var now = Date()
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { now })
        e.ingest(observation(now)); e.dropAnchor()
        now += 61
        e.ingest(observation(now, accuracy: 100)); e.safetyChecks()
        XCTAssertEqual(e.alarm, .gpsPoor)
        XCTAssertNotEqual(e.snapshot?.status, .holding)
    }
    func testIdenticalLiveSnapshotHasBoundedHeartbeat() {
        let s = WatchSnapshot(distanceText: "10 m", radiusText: "30 m", fraction: 0.3, status: .holding, headline: "Holding")
        XCTAssertFalse(LiveActivityController.shouldSend(s, after: s, elapsed: 29))
        for minute in 1...6 { XCTAssertTrue(LiveActivityController.shouldSend(s, after: s, elapsed: Double(minute * 60))) }
    }
}


@MainActor
final class DepthConsistencyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func tide(_ id: String = "A", offset: Double = 0) -> TideSnapshot {
        TideSnapshot(station: TideStation(id: id, name: id, lat: 38.97, lng: -76.47),
                     events: [TideEvent(time: start, height: offset, isHigh: false),
                              TideEvent(time: start + 6 * 3600, height: offset + 2, isHigh: true),
                              TideEvent(time: start + 12 * 3600, height: offset, isHigh: false),
                              TideEvent(time: start + 18 * 3600, height: offset + 2, isHigh: true)], fetched: start)
    }
    func testRisingAndFallingDepthAgreesAcrossPlannerAndWaterForecast() {
        var now = start
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { now })
        e.applyTideSnapshot(tide()); e.setDepthReading(3)
        now += 3 * 3600
        XCTAssertEqual(e.liveDepth, 4, accuracy: 0.001)
        XCTAssertEqual(e.plannerScope().designDepth, 4, accuracy: 0.001)
        XCTAssertEqual(e.plannerScope(at: start + 6 * 3600).designDepth, 5, accuracy: 0.001)
        XCTAssertEqual(e.plannerScope(at: start + 12 * 3600).designDepth, 3, accuracy: 0.001)
        XCTAssertEqual(e.waterForecast.first!.depth, e.liveDepth, accuracy: 0.001)
        XCTAssertEqual(e.depthAtNextHigh.depth, 5, accuracy: 0.001)
        XCTAssertEqual(e.highWaterScope.designDepth, 5, accuracy: 0.001)
        XCTAssertEqual(e.rodeToPayOut, ScopeCalculator.rode(e.highWaterScope), accuracy: 0.001)
        now = start + 9 * 3600
        var refreshed = tide(); refreshed.fetched = now
        e.applyTideSnapshot(refreshed)
        XCTAssertEqual(e.liveDepth, 4, accuracy: 0.001)
        XCTAssertEqual(e.plannerScope().designDepth, e.liveDepth)
    }
    func testReadingAndStationReferenceSurviveRestartAndManualCorrection() {
        var now = start
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false, clock: { now })
        e.applyTideSnapshot(tide()); e.setDepthReading(3)
        now += 3 * 3600
        let restored = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false, clock: { now })
        restored.applyTideSnapshot(tide())
        XCTAssertEqual(restored.liveDepth, 4, accuracy: 0.001)
        XCTAssertEqual(restored.depthReading?.stationID, "noaa:A")
        restored.setDepthReading(3) // Same number as the original reading, but a new measurement time.
        XCTAssertEqual(restored.liveDepth, 3, accuracy: 0.001)
        XCTAssertEqual(restored.depth(at: start + 6 * 3600), 4, accuracy: 0.001)
    }
    func testStationChangeUsesItsOwnDatumAtMeasurementTime() {
        let reading = DepthReading(depth: 3, measured: start, stationID: "noaa:A", tideHeight: 0)
        XCTAssertEqual(reading.depth(at: start + 3 * 3600, tide: tide("B", offset: 10))!, 4, accuracy: 0.001)
        XCTAssertNil(reading.depth(at: start + 3 * 3600, tide: nil))
        var missing = tide("B"); missing.events.removeFirst()
        XCTAssertNil(reading.depth(at: start + 9 * 3600, tide: missing), "Must not mix the old station's height into a new datum")
    }
    func testLegacyUnboundDepthRequiresConfirmationAndLateTideUsesMeasurementTime() {
        var now = start
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(99, forKey: "anchorwatch.depthTideRef")
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false, clock: { now })
        e.applyTideSnapshot(tide())
        XCTAssertNil(e.depthReading)
        XCTAssertTrue(e.waterForecast.isEmpty)
        XCTAssertTrue(e.depthReferenceDetail.contains("Reading time unknown"))
        let offline = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { now })
        offline.setDepthReading(3)
        now += 3 * 3600
        offline.applyTideSnapshot(tide())
        XCTAssertEqual(offline.liveDepth, 4, accuracy: 0.001)
    }
    func testHistorySeabedOverridesStalePlannerAfterTabReuse() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        let point = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let visit = AnchorageEntry(name: "Prior", latitude: point.latitude, longitude: point.longitude,
                                   dropped: Date() - 86400, raised: Date() - 82800, depth: 3, rodeOut: 50, radius: 60, maxDistance: 40, bottom: "Sand")
        AnchorageLog.save([visit], to: url); e.logURL = url
        var stale = AnchorConditions(); stale.bottom = .mud
        e.ingest(Fix(coordinate: point, accuracy: 3, course: nil, speed: nil, timestamp: Date())); e.dropAnchor()
        e.applyPreviousVisit()
        XCTAssertEqual(e.plannerConditions(stale).bottom, .sand)
        XCTAssertEqual(e.rodeOut, 50)
        let restored = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertEqual(restored.plannerConditions(stale).bottom, .sand)
    }
}


@MainActor
final class EnvironmentalConfidenceTests: XCTestCase {
    private let point = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func engine(_ defaults: UserDefaults? = nil, clock: (() -> Date)? = nil) -> AnchorWatchEngine {
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: clock ?? { self.now })
        position(e, point)
        e.setDepthReading(e.scope.depth)
        return e
    }
    private func position(_ e: AnchorWatchEngine, _ p: CLLocationCoordinate2D) {
        let time = (e.fix?.timestamp ?? (now - 0.001)) + 0.001
        e.ingest(Fix(coordinate: p, accuracy: 3, course: nil, speed: nil, timestamp: time))
    }
    private func wind(_ p: CLLocationCoordinate2D, hours: Int = 26, gust: Double = 15, fetched: Date? = nil) -> WindSeries {
        WindSeries(coordinate: p, samples: (0...hours).map { WindSample(time: now + Double($0) * 3600, speed: 10, direction: 90, gust: gust) }, fetched: fetched ?? now)
    }
    private func tide(_ p: CLLocationCoordinate2D, id: String = "A") -> TideSnapshot {
        TideSnapshot(station: TideStation(id: id, name: id, lat: p.latitude, lng: p.longitude), events: (-1...6).map { TideEvent(time: now + Double($0) * 6 * 3600, height: $0 % 2 == 0 ? 0 : 2, isHigh: $0 % 2 != 0) }, fetched: now)
    }
    private func current(_ p: CLLocationCoordinate2D, id: String = "A", cached: Bool = false) -> CurrentSnapshot {
        CurrentSnapshot(station: CurrentStation(id: id, name: id, lat: p.latitude, lng: p.longitude), events: (-1...6).map { CurrentEvent(time: now + Double($0) * 6 * 3600, velocity: 0.5, floodToward: 90, ebbToward: 270) }, fetched: now, fromCache: cached)
    }
    func testCoverageRequiresContinuousSamplesAndAllInputs() {
        XCTAssertNil(EnvironmentCoverage.through([], now: now, maxGap: 5400))
        let samples = [now, now + 3600, now + 3 * 3600, now + 24 * 3600]
        XCTAssertEqual(EnvironmentCoverage.through(samples, now: now, maxGap: 5400), now + 3600)
        XCTAssertFalse(EnvironmentCoverage(windThrough: now + 86400, tideThrough: nil, currentThrough: nil, now: now).complete)
        XCTAssertTrue(EnvironmentCoverage(windThrough: now + 86400, tideThrough: now + 86400, currentThrough: now + 86400, now: now).complete)
    }
    func testTideOnlyAndWindOnlyRemainPartialWhileWarningsStillWork() async {
        let e = engine()
        e.fetchTide = { _ in (self.tide(self.point), false) }
        await e.refreshTide()
        XCTAssertFalse(e.environmentCoverage.complete)
        XCTAssertTrue(e.environmentCoverage.summary.contains("wind unavailable"))
        XCTAssertNotNil(e.environmentCoverage.tideThrough)
        let w = engine()
        w.fetchWind = { _ in self.wind(self.point, gust: 70) }
        await w.refreshWind(); w.refreshOutlookIfDue()
        XCTAssertTrue(w.environmentCoverage.summary.contains("tide/depth unavailable"))
        XCTAssertFalse(w.outlook.isEmpty, "Partial data must still produce relevant warnings")
        for item in w.visibleOutlook { w.hideOutlook(item) }
        XCTAssertGreaterThan(w.hiddenOutlookCount, 0)
        XCTAssertTrue(w.outlookSummaryTitle.contains("warnings hidden"))
    }
    func testFullCoveragePartialHorizonAndExpiry() async {
        var clock = now
        let e = engine(clock: { clock })
        e.fetchWind = { _ in self.wind(self.point) }
        e.fetchTide = { _ in (self.tide(self.point), false) }
        e.fetchCurrent = { _ in self.current(self.point) }
        await e.refreshWind(); await e.refreshTide(); await e.refreshCurrent()
        XCTAssertTrue(e.environmentCoverage.complete)
        e.fetchWind = { _ in self.wind(self.point, hours: 4) }
        await e.refreshWind()
        XCTAssertFalse(e.environmentCoverage.complete)
        XCTAssertTrue(e.environmentCoverage.summary.contains("partial horizon"))
        clock += 1801
        XCTAssertNil(e.environmentCoverage.windThrough)
        XCTAssertTrue(e.environmentRecords["wind"]!.description(at: clock).contains("Expired"))
        e.refreshOutlookIfDue(); XCTAssertTrue(e.hourlyHolding.isEmpty)
    }
    func testEmptyForecastAndOfflineFailuresNeverClaimFullAssessment() async {
        let e = engine()
        e.fetchWind = { _ in WindSeries(coordinate: self.point, samples: [], fetched: self.now) }
        await e.refreshWind()
        XCTAssertNil(e.environmentCoverage.windThrough)
        e.fetchCurrent = { _ in nil }; await e.refreshCurrent()
        XCTAssertEqual(e.environmentRecords["current"]?.phase, .noCoverage)
        e.fetchCurrent = { _ in throw URLError(.notConnectedToInternet) }; await e.refreshCurrent()
        guard case .failed? = e.environmentRecords["current"]?.phase else { return XCTFail("Network failure must not say no station") }
        e.fetchWind = { _ in throw URLError(.notConnectedToInternet) }; await e.refreshWind()
        XCTAssertFalse(e.environmentCoverage.complete)
        XCTAssertTrue(e.environmentDetails.contains { $0.contains("Refresh failed") })
    }
    func testEmptyAndExpiredTideAndCurrentDoNotContributeCoverage() async {
        let e = engine()
        var tides = tide(point), currents = current(point)
        tides.events = []; currents.events = []
        e.fetchTide = { _ in (tides, false) }; e.fetchCurrent = { _ in currents }
        await e.refreshTide(); await e.refreshCurrent()
        XCTAssertNil(e.environmentCoverage.tideThrough)
        XCTAssertNil(e.environmentCoverage.currentThrough)
        tides = tide(point); currents = current(point)
        tides.fetched = now - 29 * 86400; currents.fetched = now - 7 * 3600
        await e.refreshTide(); await e.refreshCurrent()
        XCTAssertNil(e.environmentCoverage.tideThrough)
        XCTAssertNil(e.environmentCoverage.currentThrough)
        XCTAssertNil(e.currentHere(at: now))
        XCTAssertTrue(e.waterForecast.isEmpty)
    }
    func testWindCacheSurvivesOfflineRestartAndIsBoundToLocation() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = engine(defaults)
        e.fetchWind = { _ in self.wind(self.point) }; await e.refreshWind()
        let restored = engine(defaults)
        XCTAssertEqual(restored.environmentRecords["wind"]?.phase, .cached)
        XCTAssertNotNil(restored.windHere)
        restored.fetchWind = { _ in throw URLError(.notConnectedToInternet) }; await restored.refreshWind()
        XCTAssertNotNil(restored.environmentCoverage.windThrough, "Fresh cached data remains available with explicit failure status")
        XCTAssertFalse(restored.environmentCoverage.complete)
        position(restored, Geo.destination(from: point, bearing: 90, meters: 10000))
        XCTAssertNil(restored.windHere)
        XCTAssertNil(restored.environmentRecords["wind"]?.fetched)
    }
    func testNearbyReanchorReusesDataAndTravelInvalidatesIt() async {
        let e = engine()
        var requests = 0
        e.fetchWind = { p in requests += 1; return self.wind(p) }
        await e.refreshWind()
        let generation = e.environmentGeneration
        e.dropAnchor(); e.raiseAnchor()
        position(e, Geo.destination(from: point, bearing: 90, meters: 100)); e.dropAnchor()
        XCTAssertEqual(e.environmentGeneration, generation)
        XCTAssertNotNil(e.windHere)
        XCTAssertEqual(requests, 1)
        e.raiseAnchor(); position(e, Geo.destination(from: point, bearing: 90, meters: 10000)); e.dropAnchor()
        XCTAssertGreaterThan(e.environmentGeneration, generation)
        XCTAssertNil(e.windHere)
        XCTAssertNil(e.tide)
        XCTAssertTrue(e.outlook.isEmpty)
    }
    func testLateResponsesFromOldAnchorageCannotReplaceNewResults() async throws {
        let e = engine(), other = Geo.destination(from: point, bearing: 90, meters: 10000)
        var windReply: CheckedContinuation<WindSeries, Error>?
        var tideReply: CheckedContinuation<(snapshot: TideSnapshot, fromCache: Bool), Error>?
        var currentReply: CheckedContinuation<CurrentSnapshot?, Error>?
        e.fetchWind = { p in
            if Geo.distance(p, self.point) < 100 { return try await withCheckedThrowingContinuation { windReply = $0 } }
            return self.wind(p)
        }
        e.fetchTide = { p in
            if Geo.distance(p, self.point) < 100 { return try await withCheckedThrowingContinuation { tideReply = $0 } }
            return (self.tide(p, id: "B"), false)
        }
        e.fetchCurrent = { p in
            if Geo.distance(p, self.point) < 100 { return try await withCheckedThrowingContinuation { currentReply = $0 } }
            return self.current(p, id: "B")
        }
        let oldWind = Task { await e.refreshWind() }
        let oldTide = Task { await e.refreshTide() }
        let oldCurrent = Task { await e.refreshCurrent() }
        while windReply == nil || tideReply == nil || currentReply == nil { await Task.yield() }
        XCTAssertEqual(e.environmentRecords["wind"]?.phase, .loading)
        XCTAssertEqual(e.environmentRecords["tide"]?.phase, .loading)
        XCTAssertEqual(e.environmentRecords["current"]?.phase, .loading)
        position(e, other)
        await e.refreshWind(); await e.refreshTide(); await e.refreshCurrent()
        windReply!.resume(returning: wind(point)); tideReply!.resume(returning: (tide(point), false)); currentReply!.resume(returning: current(point))
        await oldWind.value; await oldTide.value; await oldCurrent.value
        XCTAssertEqual(e.tide?.station.id, "B")
        XCTAssertEqual(e.currents?.station.id, "B")
        XCTAssertLessThan(Geo.distance(try XCTUnwrap(e.windHere).coordinate, other), 1)
        XCTAssertEqual(e.environmentRecords["tide"]?.phase, .ready)
    }
    func testCurrentCacheAndChangedTideStationProvenance() async {
        let e = engine()
        e.fetchCurrent = { _ in self.current(self.point, cached: true) }; await e.refreshCurrent()
        XCTAssertEqual(e.environmentRecords["current"]?.phase, .cached)
        XCTAssertTrue(e.environmentDetails.contains { $0.contains("Cached") })
        e.fetchTide = { _ in (self.tide(self.point), false) }; await e.refreshTide()
        var changed = tide(point, id: "B")
        changed.events = changed.events.map { TideEvent(time: $0.time, height: $0.height + 10, isHigh: $0.isHigh) }
        e.fetchTide = { _ in (changed, false) }; await e.refreshTide()
        XCTAssertEqual(e.liveDepth, e.scope.depth, accuracy: 0.001, "New station must not apply a different datum to an old reference")
    }
    func testWrongLocationResponseIsRejected() async {
        let e = engine()
        e.fetchWind = { _ in self.wind(Geo.destination(from: self.point, bearing: 90, meters: 10000)) }
        await e.refreshWind()
        XCTAssertNil(e.windHere)
        guard case .failed? = e.environmentRecords["wind"]?.phase else { return XCTFail("Wrong-location result must fail") }
    }
    func testHourlyDepthDoesNotStretchPastForecastCoverage() {
        let scope = ScopeSettings(depth: 3, bowHeight: 1, boatLength: 12, scopeRatio: 5, margin: 3)
        let hourly = Outlook.hourly(BoatProfile(), scope: scope, bottom: .sand, rodeOut: 30,
                                   depths: [(now, 8)], forecast: [WindSample(time: now + 4 * 3600, speed: 10, direction: 90, gust: 15)], now: now)
        XCTAssertEqual(hourly.first?.depth, 3, "A remote depth sample cannot cover the missing horizon")
    }
}

@MainActor
final class IntegratedReviewFixTests: XCTestCase {
    private let point = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)
    private func tide(at time: Date, point: CLLocationCoordinate2D, id: String = "A") -> TideSnapshot {
        TideSnapshot(station: TideStation(id: id, name: id, lat: point.latitude, lng: point.longitude),
                     events: [TideEvent(time: time - 3600, height: 0, isHigh: false),
                              TideEvent(time: time + 3600, height: 2, isHigh: true),
                              TideEvent(time: time + 10800, height: 0, isHigh: false)], fetched: time)
    }
    func testGPSAndEnvironmentalFreshnessRemainIndependent() {
        var now = Date()
        let originalTime = now
        let e = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { now })
        e.ingest(Fix(coordinate: point, accuracy: 3, course: nil, speed: nil, timestamp: now))
        e.applyTideSnapshot(tide(at: now, point: point)); e.setDepthReading(3); e.dropAnchor()
        now += 16; e.safetyChecks()
        XCTAssertEqual(e.watchState, .gpsInterrupted)
        XCTAssertEqual(e.plannerScope().designDepth, e.liveDepth)
        XCTAssertFalse(e.waterForecast.isEmpty, "GPS interruption does not expire valid environmental predictions")
        now += 1
        e.ingest(Fix(coordinate: point, accuracy: 3, course: nil, speed: nil, timestamp: now))
        var expired = tide(at: originalTime, point: point); expired.fetched = now - 29 * 86400
        e.applyTideSnapshot(expired)
        XCTAssertEqual(e.watchState, .holding, "Forecast confidence does not suspend fresh position monitoring")
        XCTAssertTrue(e.waterForecast.isEmpty)
        XCTAssertEqual(e.plannerScope().designDepth, 3)
        XCTAssertNotNil(e.depthReading, "Offline/expired predictions do not discard the sounder reading")
    }
    func testRestartPreservesDepthButTravelRequiresNewReading() {
        var now = Date()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        func engine() -> AnchorWatchEngine {
            AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: defaults, useGPSHardware: false, clock: { now })
        }
        let e = engine()
        e.ingest(Fix(coordinate: point, accuracy: 3, course: nil, speed: nil, timestamp: now))
        e.applyTideSnapshot(tide(at: now, point: point)); e.setDepthReading(3); e.dropAnchor()
        let restored = engine()
        restored.ingest(Fix(coordinate: point, accuracy: 3, course: nil, speed: nil, timestamp: now))
        restored.applyTideSnapshot(tide(at: now, point: point))
        XCTAssertNotNil(restored.depthReading)
        XCTAssertFalse(restored.waterForecast.isEmpty)
        restored.raiseAnchor(); now += 1
        let other = Geo.destination(from: point, bearing: 90, meters: 10000)
        restored.ingest(Fix(coordinate: other, accuracy: 3, course: nil, speed: nil, timestamp: now))
        XCTAssertNil(restored.depthReading)
        restored.applyTideSnapshot(tide(at: now, point: other, id: "B"))
        XCTAssertTrue(restored.waterForecast.isEmpty)
        restored.setDepthReading(5)
        XCTAssertEqual(restored.liveDepth, 5, accuracy: 0.001)
        XCTAssertFalse(restored.waterForecast.isEmpty)
    }
}


@MainActor
final class ReviewFixRegressionTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 48, longitude: -123)

    private func engine(_ defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!,
                        player: SilentAlarm? = nil) -> AnchorWatchEngine {
        AnchorWatchEngine(player: player ?? SilentAlarm(), liveActivity: NoLiveActivity(), defaults: defaults, useGPSHardware: false)
    }

    private func fix(_ point: CLLocationCoordinate2D, at time: Date = Date()) -> Fix {
        Fix(coordinate: point, accuracy: 3, course: nil, speed: nil, timestamp: time)
    }

    private func swing(_ engine: AnchorWatchEngine, around center: CLLocationCoordinate2D,
                       radius: Double, arc: Double = 120) {
        let start = Date()
        for i in 0..<240 {
            let bearing = 160 + arc * (0.5 - 0.5 * cos(Double(i) / 240 * 4 * .pi))
            let time = start.addingTimeInterval(180 + Double(i) * 10)
            engine.ingest(fix(Geo.destination(from: center, bearing: bearing, meters: radius), at: time), receivedAt: time)
        }
        engine.updateAnchorEstimate()
    }

    func testNarrowSwingUsesActualRodeAndPresentDepthWithoutMovingACorrectMark() throws {
        let e = engine()
        e.scope = ScopeSettings(depth: 5, tideRise: 3, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.rodeOutSet = 60
        e.ingest(fix(origin)); e.dropAnchor()
        let radius = sqrt(60.0 * 60 - 6 * 6) + 7
        swing(e, around: origin, radius: radius, arc: 20)
        let estimate = try XCTUnwrap(e.anchorEstimate)
        XCTAssertEqual(estimate.modelRadius, radius, accuracy: 0.001)
        XCTAssertEqual(estimate.method, .fixedRadius)
        XCTAssertLessThan(Geo.distance(try XCTUnwrap(e.anchor), origin), 2)
        XCTAssertNil(e.anchorCorrection)
    }

    func testHandPlacedAnchorStaysPutAfterRelaunch() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = engine(defaults)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.ingest(fix(origin)); e.dropAnchor(); e.moveAnchor(to: origin)
        let again = engine(defaults)
        swing(again, around: Geo.destination(from: origin, bearing: 45, meters: 12), radius: 36)
        XCTAssertNotNil(again.anchorEstimate)
        XCTAssertLessThan(Geo.distance(try XCTUnwrap(again.anchor), origin), 0.01)
        XCTAssertNil(again.anchorCorrection)
    }

    func testAutomaticCorrectionIsNotRepeatedAfterRelaunch() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = engine(defaults)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.ingest(fix(origin)); e.dropAnchor()
        let first = Geo.destination(from: origin, bearing: 45, meters: 12)
        swing(e, around: first, radius: 36)
        XCTAssertNotNil(e.anchorCorrection)
        let saved = try XCTUnwrap(e.anchor)
        let again = engine(defaults)
        swing(again, around: Geo.destination(from: saved, bearing: 45, meters: 12), radius: 36)
        XCTAssertNotNil(again.anchorEstimate)
        XCTAssertLessThan(Geo.distance(try XCTUnwrap(again.anchor), saved), 0.01)
        XCTAssertNil(again.anchorCorrection)
    }

    func testUncorrectedDropStillGetsItsFirstCorrectionAfterRelaunch() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = engine(defaults)
        e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
        e.ingest(fix(origin)); e.dropAnchor()
        let again = engine(defaults)
        let center = Geo.destination(from: origin, bearing: 45, meters: 12)
        swing(again, around: center, radius: 36)
        XCTAssertLessThan(Geo.distance(try XCTUnwrap(again.anchor), center), 2)
        XCTAssertNotNil(again.anchorCorrection)
    }

    func testLegacySavedMarkIsPreservedUnlessStillAwaitingSwing() throws {
        for awaiting in [false, true] {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let e = engine(defaults)
            e.scope = ScopeSettings(depth: 5, bowHeight: 1, boatLength: 14, scopeRatio: 5, margin: 0)
            e.ingest(fix(origin)); e.dropAnchor(awaiting ? .settled : .goingDown)
            let data = try XCTUnwrap(defaults.data(forKey: "anchorwatch.saved"))
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            legacy.removeValue(forKey: "estimateAutoApplied")
            defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "anchorwatch.saved")
            let again = engine(defaults)
            let center = Geo.destination(from: origin, bearing: 45, meters: 12)
            swing(again, around: center, radius: 36)
            let target = awaiting ? center : origin
            XCTAssertLessThan(Geo.distance(try XCTUnwrap(again.anchor), target), 2)
        }
    }

    func testAudioFailureIsCriticalAndShownInAlarmAndLockScreenThenClears() throws {
        let player = SilentAlarm()
        let e = engine(player: player)
        e.ingest(fix(origin)); e.dropAnchor(); e.radius = 30
        player.audioFailure = "Audio output unavailable"
        e.safetyChecks()
        XCTAssertEqual(e.watchChecks.first { $0.id == "audio" }?.state, .critical)
        XCTAssertEqual(e.snapshot?.headline, "Siren unavailable")
        e.testingSiren = true
        XCTAssertEqual(e.snapshot?.headline, "Siren unavailable", "a failed test must not claim the siren is sounding")
        e.testingSiren = false
        let outside = Geo.destination(from: origin, bearing: 90, meters: 60)
        e.ingest(fix(outside)); e.ingest(fix(outside))
        XCTAssertTrue(try XCTUnwrap(e.alarmHeadline).contains("siren unavailable"))
        XCTAssertEqual(e.snapshot?.headline, e.alarmHeadline)
        XCTAssertNotNil(e.alarm, "audio failure must not discard the navigation alarm")
        player.audioFailure = nil
        e.safetyChecks()
        XCTAssertFalse(e.watchChecks.contains { $0.id == "audio" })
        XCTAssertEqual(e.snapshot?.headline, e.alarm?.message)
    }
}

final class HoldingLimitRegressionTests: XCTestCase {
    func testRopeAndMixedRodeGustLimitUsesAngleAdjustedHolding() throws {
        let scope = ScopeSettings(depth: 6, bowHeight: 1.5, boatLength: 14.3, scopeRatio: 5, margin: 5)
        for type in [BoatProfile.RodeType.rope, .chainAndRope, .allChain] {
            var boat = BoatProfile()
            boat.rodeType = type; boat.chainLength = 10
            var conditions = AnchorConditions()
            conditions.current = 0; conditions.waveHeight = 0; conditions.rodeOut = 60; conditions.bottom = .sand
            let limit = try XCTUnwrap(AnchorMath.assess(boat, scope: scope, conditions).holdingGust)
            conditions.gust = limit * 0.99
            let below = AnchorMath.assess(boat, scope: scope, conditions)
            XCTAssertLessThan(below.anchorLoad, try XCTUnwrap(below.holding) / AnchorMath.holdingSafety)
            conditions.gust = limit * 1.01
            let above = AnchorMath.assess(boat, scope: scope, conditions)
            XCTAssertGreaterThan(above.anchorLoad, try XCTUnwrap(above.holding) / AnchorMath.holdingSafety)
        }
    }

    func testDepthRecommendationInvertsLoadedChainEquation() throws {
        let weight = AnchorMath.chainWeight(sizeMM: 9.525)
        for load in [0.0, 500, 2_000, 5_000] {
            let depth = try XCTUnwrap(AnchorMath.deepestChainDepth(length: 60, load: load, weight: weight, bowHeight: 1.5))
            let needed = AnchorMath.chainNeeded(load: load, height: depth + 1.5, weight: weight) * AnchorMath.rodeMargin
            XCTAssertEqual(needed, 60, accuracy: 0.0001)
            let deeper = AnchorMath.chainNeeded(load: load, height: depth + 1.6, weight: weight) * AnchorMath.rodeMargin
            XCTAssertGreaterThan(deeper, 60)
        }
    }

    func testGaleAdviceDoesNotRecommendDeeperOrInsufficientWater() {
        var boat = BoatProfile(); boat.chainLength = 30
        let scope = ScopeSettings(depth: 10, bowHeight: 1.5, boatLength: 14.3, scopeRatio: 5, margin: 5)
        var conditions = AnchorConditions(); conditions.gust = 50; conditions.rodeOut = 30
        let result = AnchorMath.assess(boat, scope: scope, conditions)
        let tips = AnchorMath.suggestions(boat, scope: scope, conditions, result, units: .meters)
        XCTAssertTrue(tips.contains { $0.contains("adequate keel clearance") && $0.contains("seek more shelter") })
        XCTAssertFalse(tips.contains { $0.contains("Look for water under") })
        XCTAssertNil(AnchorMath.deepestChainDepth(length: 1, load: 5_000, weight: 10, bowHeight: 1.5))
    }
}

@MainActor
final class AudioStartupRegressionTests: XCTestCase {
    private struct StartupError: LocalizedError {
        let errorDescription: String? = "Simulated audio failure"
    }

    func testSessionFailurePreventsStartupAndRecoversOnWatchdogRetry() {
        var failing = true
        var starts = 0
        let player = AlarmPlayer(sessionSetup: { if failing { throw StartupError() } }, engineStartup: { starts += 1 })
        player.arm()
        XCTAssertEqual(player.audioFailure, "Simulated audio failure")
        XCTAssertEqual(starts, 0)
        failing = false
        player.ensureRunning()
        XCTAssertNil(player.audioFailure)
        XCTAssertEqual(starts, 1)
        player.disarm()
    }

    func testInterruptionRemainsVisibleUntilItEndsAndAudioRestarts() {
        var starts = 0
        let player = AlarmPlayer(sessionSetup: {}, engineStartup: { starts += 1 })
        player.arm()
        XCTAssertEqual(starts, 1)
        player.handleInterruption(ended: false)
        player.ensureRunning()
        XCTAssertNotNil(player.audioFailure)
        XCTAssertEqual(starts, 1, "do not report successful recovery while audio is still interrupted")
        player.handleInterruption(ended: true)
        XCTAssertNil(player.audioFailure)
        XCTAssertEqual(starts, 2)
        player.disarm()
    }

    func testEngineFailureIsRetainedUntilStartupSucceeds() {
        var failing = true
        let player = AlarmPlayer(sessionSetup: {}, engineStartup: { if failing { throw StartupError() } })
        player.arm()
        XCTAssertEqual(player.audioFailure, "Simulated audio failure")
        player.ensureRunning()
        XCTAssertNotNil(player.audioFailure)
        failing = false
        player.ensureRunning()
        XCTAssertNil(player.audioFailure)
        player.disarm()
    }
}

@MainActor
final class MonitoringConsistencyRegressionTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)
    private func fix(_ date: Date, meters: Double = 0) -> Fix {
        Fix(coordinate: Geo.destination(from: origin, bearing: 90, meters: meters), accuracy: 3,
            course: nil, speed: nil, timestamp: date)
    }
    private func engine(_ defaults: UserDefaults? = nil, player: SilentAlarm? = nil, clock: @escaping () -> Date) -> AnchorWatchEngine {
        AnchorWatchEngine(player: player ?? SilentAlarm(), liveActivity: NoLiveActivity(), defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: clock)
    }
    private func assertShared(_ e: AnchorWatchEngine, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(e.watchStatus["state"], e.monitoring.title, file: file, line: line)
        XCTAssertEqual(e.watchStatus["detail"], e.monitoring.detail, file: file, line: line)
        XCTAssertEqual(e.watchStatus["tone"], e.monitoring.tone.rawValue, file: file, line: line)
        XCTAssertEqual(e.snapshot?.headline, e.monitoring.detail, file: file, line: line)
        XCTAssertEqual(e.snapshot?.status, e.monitoring.activityStatus, file: file, line: line)
    }
    func testAllSurfacesAgreeOnNormalLowVolumeStaleGPSAndAlarm() {
        var now = Date()
        let player = SilentAlarm(), e = engine(player: SilentAlarm(), clock: { now })
        e.ingest(fix(now)); e.dropAnchor(rode: 40)
        XCTAssertEqual(e.monitoring.title, "Circle alarm ON")
        assertShared(e)
        let lowVolume = engine(player: player, clock: { now })
        lowVolume.ingest(fix(now)); lowVolume.dropAnchor(rode: 40)
        player.volume = 0.1; lowVolume.safetyChecks()
        XCTAssertEqual(lowVolume.monitoring.tone, .orange)
        XCTAssertEqual(lowVolume.snapshot?.status, .caution)
        assertShared(lowVolume)
        now += 16
        XCTAssertFalse(e.circleMonitoringAvailable)
        XCTAssertEqual(e.snapshot?.distanceText, "--")
        XCTAssertNil(e.watchStatus["boat"])
        assertShared(e)
        now += 15; e.safetyChecks()
        XCTAssertEqual(e.alarm, .gpsLost)
        assertShared(e)
        e.silence()
        XCTAssertNotEqual(e.monitoring.tone, .green)
        assertShared(e)
    }
    func testUnconfirmedAnchorEscalatesAndManualPlacementClearsOnlySetupAlarm() {
        var now = Date()
        let e = engine(clock: { now })
        e.ingest(fix(now)); e.dropAnchor(.settled, rode: 40)
        XCTAssertTrue(e.awaitingSwingFix)
        XCTAssertFalse(e.circleMonitoringAvailable)
        XCTAssertEqual(e.monitoring.tone, .orange)
        assertShared(e)
        now += e.anchorConfirmationTimeout + 1
        e.ingest(fix(now)); e.safetyChecks()
        XCTAssertEqual(e.alarm, .anchorUnconfirmed)
        assertShared(e)
        e.moveAnchor(to: origin)
        XCTAssertNil(e.alarm)
        XCTAssertTrue(e.circleMonitoringAvailable)
        assertShared(e)
        now += 1
        e.radius = 10
        e.ingest(fix(now, meters: 80)); now += 1; e.ingest(fix(now, meters: 80))
        XCTAssertNotNil(e.alarm)
        e.moveAnchor(to: origin)
        XCTAssertNotNil(e.alarm, "Repositioning must not clear a real outside-circle alarm")
    }
    func testConfirmedRodeDoesNotFollowRecommendationsAndSurvivesRelaunch() {
        let now = Date(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = engine(defaults, clock: { now })
        e.ingest(fix(now)); e.dropAnchor(rode: 40)
        XCTAssertTrue(e.rodeConfirmed)
        e.setDepthReading(8); e.scope.tideRise = 3; e.boat.chainLength = 120
        XCTAssertEqual(e.rodeOut, 40)
        XCTAssertNotEqual(e.rodeSuggested, 40)
        let restored = engine(defaults, clock: { now })
        XCTAssertEqual(restored.rodeOut, 40)
        XCTAssertTrue(restored.rodeConfirmed)
        e.confirmRode(50)
        XCTAssertEqual(e.rodeOut, 50)
        e.raiseAnchor()
        XCTAssertNil(e.rodeOutSet)
        XCTAssertFalse(e.rodeConfirmed)
    }
    func testInferredRodeIsFrozenButRequiresExplicitConfirmation() {
        let now = Date(), e = engine(clock: { Date() })
        e.ingest(fix(now)); e.dropAnchor()
        let frozen = e.rodeOut
        XCTAssertFalse(e.rodeConfirmed)
        e.setDepthReading(12)
        XCTAssertEqual(e.rodeOut, frozen)
        e.confirmRode(frozen)
        XCTAssertTrue(e.rodeConfirmed)
    }
    func testUnitsPersistAndInvalidateLocalizedOutlook() {
        let now = Date(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let e = engine(defaults, clock: { now })
        e.units = .meters
        XCTAssertEqual(engine(defaults, clock: { now }).units, .meters)
    }
    func testTrackRevisionContinuesChangingAfterRollover() {
        var now = Date()
        let e = engine(clock: { now })
        e.ingest(fix(now)); e.dropAnchor(rode: 40)
        for i in 1...e.maxTrackPoints { now += 1; e.ingest(fix(now, meters: Double(i))) }
        let revision = e.trackRevision, first = e.track.first, last = e.track.last
        now += 1; e.ingest(fix(now, meters: Double(e.maxTrackPoints + 1)))
        XCTAssertEqual(e.track.count, e.maxTrackPoints)
        XCTAssertGreaterThan(e.trackRevision, revision)
        XCTAssertNotEqual(e.track.first, first)
        XCTAssertNotEqual(e.track.last, last)
    }
    func testForecastWarningUsesTheSameTideAndCurrentAssessmentsAsOutlook() async throws {
        let now = Date(), e = engine(clock: { now })
        e.ingest(fix(now)); e.dropAnchor(rode: 40)
        let station = TideStation(id: "TEST", name: "Test", lat: origin.latitude, lng: origin.longitude)
        e.applyTideSnapshot(TideSnapshot(station: station, events: (0...6).map {
            TideEvent(time: now + Double($0) * 6 * 3600, height: $0 % 2 == 0 ? 0 : 5, isHigh: $0 % 2 != 0)
        }, fetched: now))
        e.setDepthReading(3)
        e.fetchCurrent = { _ in CurrentSnapshot(station: CurrentStation(id: "C", name: "Current", lat: self.origin.latitude, lng: self.origin.longitude), events: (0...6).map {
            CurrentEvent(time: now + Double($0) * 6 * 3600, velocity: $0 % 2 == 0 ? 0 : 2, floodToward: 90, ebbToward: 270)
        }, fetched: now) }
        e.fetchWind = { point in WindSeries(coordinate: point, samples: (0...24).map {
            WindSample(time: now + Double($0) * 3600, speed: 20, direction: 180, gust: 40)
        }, fetched: now) }
        await e.refreshCurrent(); await e.refreshWind(); e.refreshOutlookIfDue()
        let warning = try XCTUnwrap(e.holdingWarning)
        let hour = try XCTUnwrap(e.hourlyHolding.first { $0.time == warning.time })
        XCTAssertEqual(warning.safeGust, try XCTUnwrap(hour.safeGust), accuracy: 0.001)
        XCTAssertEqual(warning.gust, hour.gust)
        XCTAssertNotNil(hour.current)
        XCTAssertGreaterThan(hour.depth, 3)
        XCTAssertTrue(e.outlook.contains { $0.kind == .gusts })
        // Profile edits must immediately invalidate the cached hourly result.
        e.boat.anchorWeight = 1
        e.refreshOutlookIfDue()
        XCTAssertNotEqual(e.hourlyHolding.first?.safeGust, hour.safeGust)
    }
    func testRealSlackIsUsedIndependentlyOfHighAndLowWater() async {
        let now = Date(), e = engine(clock: { now })
        e.ingest(fix(now))
        e.fetchCurrent = { _ in CurrentSnapshot(station: CurrentStation(id: "C", name: "Test", lat: self.origin.latitude, lng: self.origin.longitude), events: [
            CurrentEvent(time: now - 3600, velocity: 1, floodToward: 90, ebbToward: 270),
            CurrentEvent(time: now + 1800, velocity: 0, floodToward: 90, ebbToward: 270),
            CurrentEvent(time: now + 7200, velocity: -1, floodToward: 90, ebbToward: 270)
        ], fetched: now) }
        await e.refreshCurrent()
        XCTAssertEqual(e.nextCurrentSlack, now + 1800)
        XCTAssertNil(e.nextTide)
    }
}

final class ReviewRegressionTests: XCTestCase {
    func testSafeTideSampleSeparatesShallowWindows() {
        let t = Date()
        let windows = TideMath.shallowWindows([(t, 1), (t + 600, 3), (t + 1200, 1)], below: 2)
        XCTAssertEqual(windows.count, 2)
    }
    func testDistantTideStationIsRejected() {
        let p = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        XCTAssertThrowsError(try TideService.coveredStation(near: p, stations: [TideStation(id: "far", name: "Far", lat: 10, lng: 0)]))
    }
    func testMalformedTrackCoordinatesAreIgnored() {
        let entry = AnchorageEntry(name: "Test", latitude: 0, longitude: 0, dropped: Date(), raised: Date(), depth: 5, rodeOut: 40, radius: 50, maxDistance: 20, bottom: "Sand", track: [[], [2], [1, 2], [100, 2]])
        XCTAssertEqual(entry.trackCoordinates.count, 1)
    }
    func testCorruptLogRecoversPreviousAtomicSave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("backup")) }
        XCTAssertNil(AnchorageLog.save([], to: url))
        XCTAssertNil(AnchorageLog.save([], to: url))
        try Data("corrupt".utf8).write(to: url)
        XCTAssertTrue(try AnchorageLog.read(from: url).recovered)
    }
    func testSaveErrorIsReported() {
        let url = URL(fileURLWithPath: "/dev/null/anchorages.json")
        XCTAssertNotNil(AnchorageLog.save([], to: url))
    }
    func testExpiredWindIsNotShown() {
        let now = Date()
        let series = WindSeries(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), samples: [WindSample(time: now, speed: 10, direction: 0, gust: 15)], fetched: now - 3601)
        XCTAssertNil(series.sample(atHour: 0, from: now))
    }
    @MainActor func testMediaResetReplacesEngineAndPreservesArmedState() {
        var starts = 0
        let player = AlarmPlayer(sessionSetup: {}, engineStartup: { starts += 1 })
        player.arm()
        player.handleMediaServicesReset()
        XCTAssertEqual(player.engineGeneration, 1)
        XCTAssertEqual(starts, 2)
        XCTAssertNil(player.audioFailure)
        player.disarm()
    }
}

extension ReviewRegressionTests {
    func testCanadianReadingsSurviveNOAAFailure() async throws {
        let now = Date(), point = CLLocationCoordinate2D(latitude: 48, longitude: -123)
        let reading = StationObservation(id: "CA", name: "Canada", coordinate: point, time: now, windDirection: 0, windSpeed: 10, gust: 12, waveHeight: nil, wavePeriod: nil, pressure: nil, pressureTrend: nil, airTemp: nil, waterTemp: nil, visibility: nil)
        let result = try await ObservationService.fetchNearbyResult(point, now: now, noaa: { throw URLError(.notConnectedToInternet) }, canada: { [reading] })
        XCTAssertEqual(result.stations.map(\.id), ["CA"])
        XCTAssertEqual(result.warnings.count, 1)
    }
    func testHullAndIntermediateSwingAreChecked() {
        let anchor = CLLocationCoordinate2D(latitude: 38, longitude: -76), now = Date()
        let middle = Hazard(kind: .rock, at: Geo.destination(from: anchor, bearing: 45, meters: 65), radius: 1)
        let hull = Hazard(kind: .rock, at: Geo.destination(from: anchor, bearing: 0, meters: 63), radius: 1)
        let hours = [0.0, 1].map { hour in HourlyHolding(time: now + hour * 3600, speed: 15, gust: 20, direction: 180, depth: 5, safeGust: nil, status: .good, lie: hour * 90, push: 1000) }
        let items = Outlook.hazardItems(anchor: anchor, hazards: [middle, hull], hourly: hours, rodeOut: 60, bowHeight: 1, boatLength: 15, minPush: 1, units: .feet, beam: 5)
        XCTAssertEqual(Set(items.map(\.subject)), Set([middle.id.uuidString, hull.id.uuidString]))
        XCTAssertTrue(items.allSatisfy { $0.severity == .danger })
    }
}

extension ReviewRegressionTests {
    func testTileRejectsHTTPErrorAndInvalidImageBodies() {
        let url = URL(string: "https://example.com/tile.png")!
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        func response(_ status: Int, _ mime: String) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!
        }
        XCTAssertTrue(ChartTileOverlay.isValidTile(png, response: response(200, "image/png")))
        XCTAssertFalse(ChartTileOverlay.isValidTile(png, response: response(503, "image/png")))
        XCTAssertFalse(ChartTileOverlay.isValidTile(png, response: response(200, "text/html")))
        XCTAssertFalse(ChartTileOverlay.isValidTile(Data("server error".utf8), response: response(200, "image/png")))
    }
}

@MainActor
final class ChartMapLayoutRegressionTests: XCTestCase {
    func testTransientInvalidSizesNeverReachDrawable() {
        for size in [CGSize.zero, CGSize(width: 320, height: 0), CGSize(width: -1, height: 300), CGSize(width: CGFloat.infinity, height: 300), CGSize(width: 0.01, height: 300)] {
            XCTAssertNil(ChartMapContainer.drawableSize(size, scale: 3))
        }
        XCTAssertEqual(ChartMapContainer.drawableSize(CGSize(width: 320.1, height: 500.1), scale: 3), CGSize(width: 320, height: 500))
    }

    func testMapSurvivesRepeatedPanelSizesAndDetachment() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        let container = ChartMapContainer(frame: window.bounds)
        window.addSubview(container)
        let original = container.map
        for height in [220.0, 650, 300, 800, 220, 500] {
            container.frame.size.height = height
            container.setNeedsLayout()
            container.layoutIfNeeded()
            XCTAssertTrue(container.map === original)
            XCTAssertEqual(container.map.frame.height, height)
        }
        let lastSize = container.map.frame.size
        container.frame.size = .zero
        container.setNeedsLayout()
        container.layoutIfNeeded()
        XCTAssertEqual(container.map.frame.size, lastSize)
        container.removeFromSuperview()
        container.frame.size = CGSize(width: 300, height: 600)
        container.setNeedsLayout()
        container.layoutIfNeeded()
        XCTAssertEqual(container.map.frame.size, lastSize)
    }
}

@MainActor
final class WarningPreferencesTests: XCTestCase {
    func testWarningPreferencesPersistWithoutMutatingWarnings() {
        let suite = "warning-preferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertFalse(engine.hideWarningBanners)
        XCTAssertFalse(engine.muteAdvisoryNotifications)
        let original = engine.outlook
        engine.hideWarningBanners = true
        engine.muteAdvisoryNotifications = true
        XCTAssertEqual(engine.outlook, original)
        let restored = AnchorWatchEngine(player: SilentAlarm(), defaults: defaults, useGPSHardware: false)
        XCTAssertTrue(restored.hideWarningBanners)
        XCTAssertTrue(restored.muteAdvisoryNotifications)
    }

    func testSilencingAdvisoriesDoesNotSilenceAnchorAlarm() {
        let suite = "warning-alarm-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = SilentAlarm()
        let engine = AnchorWatchEngine(player: player, defaults: defaults, useGPSHardware: false)
        engine.hideWarningBanners = true
        engine.muteAdvisoryNotifications = true
        let origin = CLLocationCoordinate2D(latitude: 38.97, longitude: -76.47)
        func fix(_ meters: Double) -> Fix {
            Fix(coordinate: Geo.destination(from: origin, bearing: 90, meters: meters), accuracy: 3, course: nil, speed: nil, timestamp: Date())
        }
        engine.ingest(fix(0)); engine.dropAnchor(); engine.radius = 30
        engine.ingest(fix(40)); engine.ingest(fix(41))
        XCTAssertNotNil(engine.alarm)
        XCTAssertTrue(player.sirenSounding)
        XCTAssertTrue(player.armed)
    }
}

@MainActor
final class RodeChangeRegressionTests: XCTestCase {
    func testRodeChangeDiscardsOldSwingEvidenceButKeepsAnchorAndTrack() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let origin = CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15)
        let engine = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { now })
        engine.ingest(Fix(coordinate: origin, accuracy: 2, course: 0, speed: 0, timestamp: now))
        engine.dropAnchor(rode: 60)
        let anchor = try XCTUnwrap(engine.anchor)
        engine.setRadiusByHand(200)
        for i in 1...240 {
            now += 10
            let bearing = 180 + 70 * sin(Double(i) / 60 * .pi)
            engine.ingest(Fix(coordinate: Geo.destination(from: anchor, bearing: bearing, meters: 62), accuracy: 2, course: nil, speed: nil, timestamp: now))
        }
        engine.updateAnchorEstimate()
        XCTAssertNotNil(engine.anchorEstimate)
        let mark = try XCTUnwrap(engine.anchor), count = engine.track.count
        engine.confirmRode(35)
        XCTAssertNil(engine.anchorEstimate, "Old-radius track must not remain an actionable anchor estimate")
        engine.updateAnchorEstimate()
        XCTAssertNil(engine.anchorEstimate, "Do not fit old track using the new rode radius")
        XCTAssertEqual(engine.anchor, mark)
        XCTAssertEqual(engine.track.count, count, "Keep the visible track")
        XCTAssertEqual(engine.radius, 200, "Manual radius stays fixed")
        XCTAssertNil(engine.anchorDrift)
        XCTAssertNil(engine.distanceTrend)
    }
}

extension AnchorPhysicsTests {
    func testRodeChangeRebuildsCatenaryWithoutMovingAnchor() {
        var p = AnchorPhysics(boat: boat, weather: SimDays.calm)
        _ = p.pull(at: 55, depth: 11)
        let anchor = p.anchor
        p.boat.rode = 90
        XCTAssertEqual(p.pull(at: 55, depth: 11), 0, "New longer chain is slack here; the old cached force curve is invalid")
        p.boat.rode = 40
        var fresh = AnchorPhysics(boat: p.boat, weather: SimDays.calm)
        XCTAssertEqual(p.pull(at: 35, depth: 11), fresh.pull(at: 35, depth: 11), accuracy: 0.001)
        XCTAssertEqual(p.anchor.x, anchor.x)
        XCTAssertEqual(p.anchor.y, anchor.y)
    }
}

extension RodeChangeRegressionTests {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
    private func session(rode: Double = 60) throws -> (AnchorWatchEngine, Clock, CLLocationCoordinate2D) {
        let clock = Clock()
        let engine = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { clock.now })
        engine.ingest(Fix(coordinate: CLLocationCoordinate2D(latitude: 48.6, longitude: -123.15), accuracy: 2, course: nil, speed: nil, timestamp: clock.now))
        engine.dropAnchor(rode: rode)
        return (engine, clock, try XCTUnwrap(engine.anchor))
    }
    private func feed(_ engine: AnchorWatchEngine, _ clock: Clock, center: CLLocationCoordinate2D, radius: Double, bearing: Double) {
        clock.now += 10
        engine.ingest(Fix(coordinate: Geo.destination(from: center, bearing: bearing, meters: radius), accuracy: 2, course: nil, speed: nil, timestamp: clock.now))
    }

    func testFallingBackOnLongerRodeDoesNotBecomeDragOrRelocateAnchor() throws {
        let (engine, clock, anchor) = try session(rode: 35)
        for _ in 0..<120 { feed(engine, clock, center: anchor, radius: 35, bearing: 180) }
        engine.confirmRode(90)
        for i in 0..<240 {
            // Pay out over ten minutes, then hold on the longer rode with only a narrow sheer.
            let radius = min(90, 35 + Double(i) * 55 / 60)
            feed(engine, clock, center: anchor, radius: radius, bearing: 180 + 10 * sin(Double(i) / 20))
            if i % 6 == 5 { engine.updateAnchorEstimate() }
            XCTAssertNil(engine.distanceTrend, "Normal outward movement within the new reach is not drag")
            XCTAssertNil(engine.anchorDrift)
            XCTAssertEqual(engine.anchor, anchor)
            XCTAssertNil(engine.anchorCorrection)
        }
        XCTAssertTrue(engine.circleMonitoringAvailable)
        XCTAssertNil(engine.alarm)
    }

    func testNarrowSwingWithWrongAssumedRadiusNeverOffersAMove() throws {
        let (engine, clock, anchor) = try session(rode: 35)
        // A short arc on a smaller physical circle biases a fixed-radius center toward the arc.
        for i in 0..<240 {
            feed(engine, clock, center: anchor, radius: 20, bearing: 180 + 10 * sin(Double(i) / 20))
        }
        engine.updateAnchorEstimate()
        XCTAssertEqual(engine.anchor, anchor)
        XCTAssertNil(engine.anchorCorrection)
        if let estimate = engine.anchorEstimate {
            XCTAssertEqual(estimate.method, .fixedRadius)
            engine.moveAnchorToEstimate()
            XCTAssertEqual(engine.anchor, anchor, "An assumed-radius fit cannot relocate the anchor")
        }
        XCTAssertNil(engine.anchorDrift)
    }

    func testGenuineDragIsDetectedAgainAfterRodeChange() throws {
        let (engine, clock, anchor) = try session()
        engine.confirmRode(50)
        engine.setRadiusByHand(200)
        var warnedBeforeDrag = false
        for i in 0..<(65 * 6) {
            let minute = Double(i) / 6
            let pivot = Geo.destination(from: anchor, bearing: 90, meters: max(0, minute - 30))
            feed(engine, clock, center: pivot, radius: 52, bearing: 270 + 60 * sin(minute / 10 * 2 * .pi))
            if i % 6 == 5 {
                engine.updateAnchorEstimate()
                if minute < 30 && engine.anchorDrift != nil { warnedBeforeDrag = true }
            }
        }
        XCTAssertFalse(warnedBeforeDrag)
        XCTAssertNotNil(engine.anchorDrift, "Fresh post-change swing must still detect a genuinely moving center")
        XCTAssertEqual(engine.anchor, anchor, "Do not move the alarm center along with a dragging anchor")
    }

    func testRodeEditDoesNotStopAnActiveCircleAlarm() throws {
        let (engine, clock, anchor) = try session()
        engine.setRadiusByHand(40)
        for _ in 0..<3 { feed(engine, clock, center: anchor, radius: 100, bearing: 180) }
        XCTAssertNotNil(engine.alarm)
        engine.confirmRode(80)
        XCTAssertNotNil(engine.alarm)
        XCTAssertEqual(engine.radius, 40)
        XCTAssertTrue(engine.circleMonitoringAvailable)
        XCTAssertEqual(engine.anchor, anchor)
    }

    func testConfirmingUnchangedRodeKeepsExistingSwingEvidence() throws {
        let (engine, clock, anchor) = try session()
        for i in 0..<240 { feed(engine, clock, center: anchor, radius: 62, bearing: 180 + 70 * sin(Double(i) / 60 * .pi)) }
        engine.updateAnchorEstimate()
        let estimate = try XCTUnwrap(engine.anchorEstimate)
        engine.confirmRode(engine.rodeOut)
        XCTAssertEqual(engine.anchorEstimate?.center, estimate.center)
    }
}

extension AnchorPhysicsTests {
    func testShorteningRodeDoesNotInjectAnArtificialDragImpulse() {
        var p = AnchorPhysics(boat: boat, weather: SimDays.calm)
        p.boat.rode = 25
        let anchor = p.anchor
        let maximum = sqrt(25.0 * 25 - pow(boat.depth + boat.bowHeight, 2))
        XCTAssertLessThanOrEqual(distance(p), maximum + 0.001)
        p.step()
        XCTAssertEqual(p.anchor.x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(p.anchor.y, anchor.y, accuracy: 0.001)
    }
    func testChangingChainWeightRebuildsTheForceCurve() {
        var p = AnchorPhysics(boat: boat, weather: SimDays.calm)
        let old = p.pull(at: 55, depth: 11)
        p.boat.chainWeight *= 2
        var fresh = AnchorPhysics(boat: p.boat, weather: SimDays.calm)
        XCTAssertEqual(p.pull(at: 55, depth: 11), fresh.pull(at: 55, depth: 11), accuracy: 0.001)
        XCTAssertGreaterThan(p.pull(at: 55, depth: 11), old)
    }
}

extension AnchorPhysicsTests {
    func testUpdatingRodeUsesCurrentDepthWithoutAddingTheTideTwice() {
        var p = AnchorPhysics(boat: boat, weather: SimDays.calm)
        for _ in 0..<3600 { p.step() }
        let currentDepth = p.boat.depth + p.weather.tide(p.time)
        var update = p.boat
        update.rode = 90
        update.depth = currentDepth
        let anchor = p.anchor
        p.updateBoat(update)
        XCTAssertEqual(p.boat.depth + p.weather.tide(p.time), currentDepth, accuracy: 0.000001)
        XCTAssertEqual(p.anchor.x, anchor.x)
        XCTAssertEqual(p.anchor.y, anchor.y)
    }
}


final class ValidatedBCTideIntegrationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z")!
    private func station(_ code: String = "08074") -> TideStation {
        let r = ValidatedBCTides.records.first { $0.code == code }!
        return TideStation(id: r.chsID, name: r.name, lat: r.latitude, lng: r.longitude, source: TideStation.chs)
    }
    private func cached(age: TimeInterval = 0) -> TideSnapshot {
        TideSnapshot(station: station(), events: [
            TideEvent(time: now - 3600, height: 0.21, isHigh: false),
            TideEvent(time: now + 3600, height: 4.42, isHigh: true),
            TideEvent(time: now + 12 * 3600, height: 0.25, isHigh: false),
            TideEvent(time: now + 30 * 3600, height: 4.1, isHigh: true)
        ], fetched: now - age)
    }

    func testAllTenProductionHeightsMatchValidatedReferenceWithCHSConstant() throws {
        let expected: [(String, Double)] = [
            ("07120", 1.7839384417114408),
            ("07735", 4.122924043800365),
            ("07917", 4.10381077598605),
            ("08074", 3.7307551654396742),
            ("08408", 1.617728268182056),
            ("08976", 1.542157113541153),
            ("09354", 2.910466536177952),
            ("09130", 1.9241987970739507),
            ("07330", 2.7791716152085364),
            ("08545", 0.7316237596539701),
        ]
        XCTAssertEqual(ValidatedBCTides.records.count, 10)
        for (code, value) in expected {
            XCTAssertEqual(try XCTUnwrap(ValidatedBCTides.height(at: now, station: station(code))), value, accuracy: 0.01, code)
        }
        let campbell = try XCTUnwrap(ValidatedBCTides.record(for: station()))
        XCTAssertEqual(campbell.meanWaterLevel, 2.780, accuracy: 0.000001)
        XCTAssertEqual(campbell.constituents.count, 50) // Published model only; no diagnostic fit.
    }

    func testOverridesRequireExactProviderStationIdentityAndPosition() {
        let good = station()
        XCTAssertNil(ValidatedBCTides.record(for: TideStation(id: good.id, name: good.name, lat: good.lat, lng: good.lng)))
        XCTAssertNil(ValidatedBCTides.record(for: TideStation(id: "other", name: good.name, lat: good.lat, lng: good.lng, source: TideStation.chs)))
        XCTAssertNil(ValidatedBCTides.record(for: TideStation(id: good.id, name: good.name, lat: 49, lng: -125, source: TideStation.chs)))
    }

    func testPublishedCHSEventsAreNotShiftedOrRegenerated() async throws {
        let saved = cached()
        let result = try await TideService.snapshot(for: station(), now: now, cached: saved, fetch: { _, _ in
            XCTFail("Fresh cached CHS events should work without a download")
            throw URLError(.notConnectedToInternet)
        })
        XCTAssertTrue(result.fromCache)
        XCTAssertEqual(result.snapshot.events, saved.events)
        XCTAssertEqual(result.snapshot.events[0].height, 0.21)
        let turns = try XCTUnwrap(TideMath.extremes(from: now, hours: 24, snapshot: result.snapshot))
        XCTAssertEqual(turns.high.time, saved.events[1].time)
        XCTAssertEqual(turns.high.height, 4.42) // No +0.161 m correction to an already referenced CHS event.
    }

    func testCoveredOldCacheSurvivesNetworkFailureButExpiredOrWrongStationDoesNot() async throws {
        let saved = cached(age: 10 * 86400)
        let result = try await TideService.snapshot(for: station(), now: now, cached: saved, fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        XCTAssertTrue(result.fromCache)
        XCTAssertEqual(result.snapshot, saved)
        var expired = saved
        expired.events = Array(expired.events.prefix(2))
        XCTAssertNil(TideService.usableCache(expired, station: station(), now: now))
        XCTAssertNil(TideService.usableCache(saved, station: station("07917"), now: now))
        do {
            _ = try await TideService.snapshot(for: station(), now: now, cached: expired, fetch: { _, _ in throw URLError(.notConnectedToInternet) })
            XCTFail("Out-of-coverage cache must not be returned")
        } catch { XCTAssertNotNil(error as? TideService.TideError) }
    }

    func testMalformedCacheAndInsufficientFreshCoverageAreRejected() async {
        var duplicate = cached(); duplicate.events.insert(duplicate.events[0], at: 0)
        XCTAssertNil(TideService.usableCache(duplicate, station: station(), now: now))
        var nonfinite = cached(); nonfinite.events[0] = TideEvent(time: now - 3600, height: .nan, isHigh: false)
        XCTAssertNil(TideService.usableCache(nonfinite, station: station(), now: now))
        do {
            _ = try await TideService.snapshot(for: station(), now: now, cached: nil, fetch: { _, _ in Array(self.cached().events.prefix(2)) })
            XCTFail("Short network response must not replace a usable forecast")
        } catch { }
    }

    func testLegacyDepthReferenceRebasesInsteadOfMixingHeightModels() throws {
        let snapshot = cached()
        let legacy = DepthReading(depth: 5, measured: now, stationID: DepthReading.stationKey(station()), tideHeight: 99)
        XCTAssertEqual(try XCTUnwrap(legacy.depth(at: now, tide: snapshot)), 5, accuracy: 0.000001)
        XCTAssertNil(TideMath.height(at: snapshot.events.last!.time + 1, snapshot: snapshot))
        XCTAssertNil(TideMath.rise(from: now, hours: 48, snapshot: snapshot))
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(DepthReading.self, from: encoded).tideModelID)
    }

    @MainActor func testCHSCachedPredictionAgeRemainsUsableWithinCoverage() {
        let defaults = UserDefaults(suiteName: "BCTideIntegration-" + UUID().uuidString)!
        let engine = AnchorWatchEngine(defaults: defaults, useGPSHardware: false, clock: { self.now })
        engine.applyTideSnapshot(cached(age: 10 * 86400), cached: true)
        XCTAssertNotNil(engine.tideNow)
    }
    @MainActor func testMissingOrExpiredCacheClearsPreviouslyLoadedCampbellTides() async {
        for warm in [false, true] {
            let engine = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { self.now })
            engine.ingest(Fix(coordinate: station().coordinate, accuracy: 3, course: nil, speed: nil, timestamp: now))
            if warm { engine.applyTideSnapshot(cached(), cached: true) }
            engine.fetchTide = { _ in throw TideService.TideError.offline }
            await engine.refreshTide()
            XCTAssertNil(engine.tide)
            XCTAssertNil(engine.tideNow)
            XCTAssertNil(engine.tideRiseEstimate)
            XCTAssertFalse(engine.tideIsSaved)
            XCTAssertTrue(engine.tideStatus.contains("No saved tide predictions"))
        }
    }

}

final class NOAAOfflineMonthTests: XCTestCase {
    func testRequestCrossesYearBoundaryAndRetainsNOAAUnitsDatumAndEvents() {
        let now = ISO8601DateFormatter().date(from: "2026-12-20T22:00:00Z")!
        let station = TideStation(id: "9447130", name: "Seattle", lat: 47.6, lng: -122.3)
        let path = TideService.noaaPredictionPath(station: station, now: now)
        let query = URLComponents(string: "https://example.com" + path)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) })
        XCTAssertEqual(values["begin_date"], "20261219")
        XCTAssertEqual(values["end_date"], "20270117")
        XCTAssertEqual(values["station"], "9447130")
        XCTAssertEqual(values["datum"], "MLLW")
        XCTAssertEqual(values["units"], "metric")
        XCTAssertEqual(values["time_zone"], "gmt")
        XCTAssertEqual(values["interval"], "hilo")
    }
    @MainActor func testOldNOAACacheRemainsUsableWhileCoveredButExpiresWithoutCoverage() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let station = TideStation(id: "9447130", name: "Seattle", lat: 47.6, lng: -122.3)
        let snapshot = TideSnapshot(station: station, events: [
            TideEvent(time: now - 3600, height: 1, isHigh: false),
            TideEvent(time: now + 3600, height: 3, isHigh: true),
            TideEvent(time: now + 25 * 3600, height: 1, isHigh: false)
        ], fetched: now - 26 * 86400)
        let result = try await TideService.snapshot(for: station, now: now, cached: snapshot, fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        XCTAssertTrue(result.fromCache)
        let engine = AnchorWatchEngine(player: SilentAlarm(), liveActivity: NoLiveActivity(), defaults: UserDefaults(suiteName: UUID().uuidString)!, useGPSHardware: false, clock: { now })
        engine.applyTideSnapshot(result.snapshot, cached: true)
        XCTAssertNotNil(engine.tideNow)
        XCTAssertNil(TideService.usableCache(snapshot, station: station, now: now + 7200))
        XCTAssertNil(snapshot.heightModelID) // Validation does not enable US harmonic overrides.
    }
}

final class OfflineENCImportTests: XCTestCase {
    private func coverageCatalogue() -> Data {
        let field = "CD0000000001CA271100\\CA271100.000\u{1f}\u{1f}V01X01\u{1f}BIN48.0000000\u{1f}-128.0000000\u{1f}52.0000000\u{1f}-124.0000000\u{1f}ABCDEF\u{1f}\u{1e}"
        let base = 39
        let leader = String(format: "%05d D     %05d   5504", base + field.utf8.count, base)
        let directory = "CATD" + String(format: "%05d00000", field.utf8.count) + "\u{1e}"
        return Data((leader + directory + field).utf8)
    }

    func testCatalogueProvidesBoundsWithoutOptionalCSV() throws {
        let archive = storedZip([
            ("ENC_ROOT/CATALOG.031", coverageCatalogue()),
            ("ENC_ROOT/CA271100/CA271100.000", Data("base".utf8))
        ])
        let cells = try OfflineENCZip.cellCandidates(in: archive)
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells.first?.bounds, OfflineENCBounds(west: -128, south: 48, east: -124, north: 52))
        XCTAssertThrowsError(try OfflineENCZip.readCatalogueBounds(coverageCatalogue().dropLast()))
        XCTAssertThrowsError(try OfflineENCZip.readCatalogueBounds(Data("corrupt".utf8)))
    }

    func testS57UpdateMetadataCarriesForwardOmittedBaseDSPMFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: root.appendingPathComponent("AnchorWatch/Resources/anchorwatch-s57-bridge.js"), encoding: .utf8)
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(bridge)
        let merge = try XCTUnwrap(context.objectForKeyedSubscript("anchorWatchMergeUpdateMetadata"))
        let previous: [String: Any] = ["name": "CA571551.000", "edition": "1", "update": "0",
                                       "scale": 22_000, "depthUnitCode": 1, "verticalDatumCode": 28,
                                       "horizontalDatumCode": 2, "soundingDatumCode": 27, "dspmFields": ["CSCL", "DUNI", "VDAT", "HDAT", "SDAT"]]
        let update: [String: Any] = ["name": "CA571551.001", "edition": "1", "update": "1",
                                     "scale": 0, "depthUnitCode": 0, "verticalDatumCode": 0,
                                     "horizontalDatumCode": 0, "dspmFields": [String]()]

        let result = try XCTUnwrap(merge.call(withArguments: [previous, update])?.toDictionary() as? [String: Any])
        XCTAssertEqual(result["scale"] as? Int, 22_000)
        XCTAssertEqual(result["depthUnitCode"] as? Int, 1)
        XCTAssertEqual(result["verticalDatumCode"] as? Int, 28)
        XCTAssertEqual(result["soundingDatumCode"] as? Int, 27)
        let explicit = try XCTUnwrap(merge.call(withArguments: [previous, ["soundingDatumCode": 23, "dspmFields": ["SDAT"]]])?.toDictionary() as? [String: Any])
        XCTAssertEqual(explicit["soundingDatumCode"] as? Int, 23)
        XCTAssertEqual(result["horizontalDatumCode"] as? Int, 2)
        XCTAssertEqual(result["update"] as? String, "1")
        XCTAssertEqual(result["name"] as? String, "CA571551.001")
    }

    func testCHSVancouverIslandCollectionFitsBoundedImportLimits() {
        XCTAssertGreaterThanOrEqual(OfflineENCZip.maxArchiveBytes, 170 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(OfflineENCZip.maxExpandedBytes, 420 * 1024 * 1024)
    }

    func testCellPickerUsesCollectionTitleAndOmitsCancelledCells() throws {
        let listing = "Collection,Name,EDT,UPD,ISDT,UADT,SLAT,WLON,NLAT,ELON,Title\r\n" +
            "V-PAC-A,CA570262,6,7,2024-09-04,,50.2,-125.41,50.33,-125.08,\"Okisollo Channel, British Columbia\"\r\n" +
            "V-PAC-A,CA000001,1,0,2026-01-01,,50,-125,51,-124,Cancelled test cell\r\n"
        let archive = storedZip([
            ("V-PAC-A/ENC_ROOT/CATALOG.031", coverageCatalogue()),
            ("V-PAC-A/CHS_COLLECTIONS_ENCS57_20261026.csv", Data(listing.utf8)),
            ("V-PAC-A/ENC_ROOT/CA570262/CA570262.000", Data("active".utf8)),
            ("V-PAC-A/Cancel_Annuler/ENC_ROOT/CA000001/CA000001.000", Data("cancelled".utf8))
        ])

        let candidates = try OfflineENCZip.cellCandidates(in: archive)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].cellID, "CA570262")
        XCTAssertEqual(candidates[0].title, "Okisollo Channel, British Columbia")
        XCTAssertEqual(candidates[0].path, "V-PAC-A/ENC_ROOT/CA570262/CA570262.000")
        XCTAssertEqual(candidates[0].bounds, OfflineENCBounds(west: -125.41, south: 50.2, east: -125.08, north: 50.33))
    }

    func testZipReaderAcceptsStoredExchangeSetFilesAndChecksCRC() throws {
        let archive = storedZip([
            ("ENC_ROOT/CATALOG.031", Data("catalog".utf8)),
            ("ENC_ROOT/CA100001.000", Data("base-cell".utf8))
        ])
        let entries = try OfflineENCZip.entries(in: archive)
        XCTAssertEqual(entries.map(\.name), ["ENC_ROOT/CATALOG.031", "ENC_ROOT/CA100001.000"])
        XCTAssertEqual(try OfflineENCZip.contents(of: entries[0], in: archive), Data("catalog".utf8))
        XCTAssertEqual(try OfflineENCZip.contents(of: entries[1], in: archive), Data("base-cell".utf8))
    }

    func testZipReaderInflatesDeflatedExchangeSetFiles() throws {
        let payload = Data("catalog".utf8)
        let archive = deflatedZip(name: "ENC_ROOT/CATALOG.031", payload: payload,
                                  compressed: Data([75, 78, 44, 73, 204, 201, 79, 7, 0]))
        let entry = try XCTUnwrap(OfflineENCZip.entries(in: archive).first)
        XCTAssertEqual(entry.method, 8)
        XCTAssertEqual(try OfflineENCZip.contents(of: entry, in: archive), payload)
    }

    func testZipReaderRejectsTraversalEncryptedAndCorruptArchives() throws {
        XCTAssertThrowsError(try OfflineENCZip.entries(in: Data("not a zip".utf8)))
        XCTAssertThrowsError(try OfflineENCZip.entries(in: storedZip([("../outside", Data("bad".utf8))]))) { error in
            guard let importError = error as? OfflineENCImportError, case .unsafeArchiveEntry = importError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try OfflineENCZip.entries(in: storedZip([("cell.000", Data("encrypted".utf8))], flags: 1))) { error in
            guard let importError = error as? OfflineENCImportError, case .encryptedArchive = importError else { return XCTFail("Unexpected error: \(error)") }
        }
        var corrupt = storedZip([("ENC_ROOT/CATALOG.031", Data("catalog".utf8))])
        corrupt[30 + "ENC_ROOT/CATALOG.031".utf8.count] ^= 0xFF
        let corruptEntry = try XCTUnwrap(OfflineENCZip.entries(in: corrupt).first)
        XCTAssertThrowsError(try OfflineENCZip.contents(of: corruptEntry, in: corrupt))
    }

    func testUpdateFilesMustBeContiguousAndAreOrdered() throws {
        let names = ["ENC_ROOT/CA100001.002", "ENC_ROOT/CA100001.001", "ENC_ROOT/OTHER.001"]
        XCTAssertEqual(try OfflineENCZip.orderedUpdateSequence(baseCellFilename: "CA100001.000", entryNames: names),
                       ["ENC_ROOT/CA100001.001", "ENC_ROOT/CA100001.002"])
        XCTAssertThrowsError(try OfflineENCZip.orderedUpdateSequence(
            baseCellFilename: "CA100001.000", entryNames: ["ENC_ROOT/CA100001.002"])) { error in
                guard let importError = error as? OfflineENCImportError, case .missingUpdate = importError else { return XCTFail("Unexpected error: \(error)") }
            }
    }

    func testGeometryBoundsAndTapCoordinatesPreserveChartCoordinates() throws {
        let polygon = OfflineJSONValue.array([
            .array([.array([.number(-123.2), .number(48.1)]), .array([.number(-123.0), .number(48.1)]),
                    .array([.number(-123.0), .number(48.3)]), .array([.number(-123.2), .number(48.1)])])
        ])
        let feature = OfflineENCFeature(geometryType: "Polygon", coordinates: polygon,
                                        attributes: ["OBJL": "42", "RCID": "12"], soundingDepths: [])
        let bounds = try XCTUnwrap(OfflineENCBounds(features: [feature]))
        XCTAssertEqual(bounds.west, -123.2, accuracy: 0.0001)
        XCTAssertEqual(bounds.east, -123.0, accuracy: 0.0001)
        XCTAssertEqual(bounds.south, 48.1, accuracy: 0.0001)
        XCTAssertEqual(bounds.north, 48.3, accuracy: 0.0001)
        XCTAssertTrue(bounds.contains(ChartCoordinate(longitude: -123.1, latitude: 48.2)))
        XCTAssertFalse(bounds.contains(ChartCoordinate(longitude: -122.9, latitude: 48.2)))
        XCTAssertEqual(feature.chartCoordinates().count, 4)
    }

    func testZoomToFitIgnoresS57MetadataCoverageExtent() throws {
        func polygon(_ coordinates: [(Double, Double)]) -> OfflineJSONValue {
            .array([.array(coordinates.map { .array([.number($0.0), .number($0.1)]) })])
        }
        let land = OfflineENCFeature(geometryType: "Polygon",
                                     coordinates: polygon([(-124, 48.274), (-123.6, 48.274),
                                                           (-123.6, 48.7), (-124, 48.7), (-124, 48.274)]),
                                     attributes: ["OBJL": "71", "RCID": "1"], soundingDepths: [])
        let coverage = OfflineENCFeature(geometryType: "Polygon",
                                         coordinates: polygon([(-124, 48), (-123.6, 48),
                                                               (-123.6, 48.7), (-124, 48.7), (-124, 48)]),
                                         attributes: ["OBJL": "302", "RCID": "2"], soundingDepths: [])
        let chart = OfflineENCChart(sourceName: "CHS ENC", originalFilename: "V-PAC-A.zip",
                                    sha256: String(repeating: "b", count: 64), importedAt: Date(),
                                    metadata: OfflineENCMetadata(cellID: "CA471209", edition: "1", update: "0",
                                        updateDate: "", issueDate: "", exchangeStandard: "3.1",
                                        compilationScale: 90000, depthUnitCode: 1, verticalDatumCode: 28,
                                        horizontalDatumCode: 2, catalogPresent: true, updateFilesApplied: []),
                                    features: [land, coverage])

        let fitBounds = try XCTUnwrap(chart.bounds)
        XCTAssertEqual(fitBounds.south, 48.274, accuracy: 0.0001)
        XCTAssertEqual(fitBounds.north, 48.7, accuracy: 0.0001)
        XCTAssertFalse(coverage.isPortrayed)
        XCTAssertTrue(coverage.isMetaObject)
    }

    func testPortrayalCountsSeparateChartFeaturesFromMetadata() {
        func feature(_ objectClass: Int, _ geometry: String) -> OfflineENCFeature {
            OfflineENCFeature(geometryType: geometry, coordinates: nil,
                              attributes: ["OBJL": String(objectClass)], soundingDepths: [])
        }
        let features = [feature(153, "Point"), feature(112, "Polygon"),
                        feature(20, "Polygon"), feature(22, "LineString"),
                        feature(121, "Polygon"), feature(121, "Point"),
                        feature(302, "Polygon"),
                        feature(308, "Polygon")]
        XCTAssertTrue(features[0].isPortrayed)
        XCTAssertTrue(features[1].isPortrayed)
        XCTAssertTrue(features[2].isPortrayed)
        XCTAssertTrue(features[3].isPortrayed)
        XCTAssertTrue(features[4].isPortrayed)
        XCTAssertTrue(features[5].isPortrayed)
        XCTAssertFalse(feature(153, "LineString").isPortrayed)
        XCTAssertFalse(feature(112, "Point").isPortrayed)
        XCTAssertFalse(feature(20, "LineString").isPortrayed)
        XCTAssertFalse(feature(22, "Polygon").isPortrayed)
        XCTAssertEqual(features[0].className, "Underwater/awash rock")
        XCTAssertEqual(features[1].className, "Restricted area")

        let chart = OfflineENCChart(sourceName: "CHS ENC", originalFilename: "cell.zip",
                                    sha256: String(repeating: "c", count: 64), importedAt: Date(),
                                    metadata: OfflineENCMetadata(cellID: "CA571551", edition: "1", update: "0",
                                        updateDate: "", issueDate: "", exchangeStandard: "3.1",
                                        compilationScale: 22000, depthUnitCode: 1, verticalDatumCode: 28,
                                        horizontalDatumCode: 2, catalogPresent: true, updateFilesApplied: []),
                                    features: features)
        XCTAssertEqual(chart.unportrayedFeatureCount, 0)
        XCTAssertEqual(chart.unportrayedMetadataCount, 2)
    }

    func testRemainingInformationGeometrySupport() {
        func f(_ code: Int, _ geometry: String) -> OfflineENCFeature {
            .init(geometryType: geometry, coordinates: nil, attributes: ["OBJL": String(code)], soundingDepths: [])
        }
        XCTAssertTrue(f(21, "MultiLineString").isPortrayed)
        XCTAssertFalse(f(21, "Polygon").isPortrayed)
        XCTAssertTrue(f(58, "Point").isPortrayed)
        XCTAssertFalse(f(58, "LineString").isPortrayed)
        for code in [3, 4, 27, 138] {
            XCTAssertTrue(f(code, "Point").isPortrayed)
            XCTAssertTrue(f(code, "MultiPolygon").isPortrayed)
            XCTAssertFalse(f(code, "LineString").isPortrayed)
        }
        XCTAssertTrue(f(1, "Polygon").isPortrayed)
        XCTAssertFalse(f(1, "Point").isPortrayed)
        XCTAssertTrue(f(104, "LineString").isPortrayed)
        XCTAssertFalse(f(104, "Polygon").isPortrayed)
    }

    func testLandAndTurbulenceGeometryAndCategories() {
        func feature(_ code: Int, _ type: String, _ category: String = "") -> OfflineENCFeature {
            OfflineENCFeature(geometryType: type, coordinates: nil,
                attributes: ["OBJL": String(code), "ATTL_69": category], soundingDepths: [])
        }
        for type in ["Point", "LineString", "MultiLineString", "Polygon", "MultiPolygon"] {
            XCTAssertTrue(feature(156, type).isPortrayed)
        }
        XCTAssertFalse(feature(156, "MultiPoint").isPortrayed)
        XCTAssertTrue(feature(72, "LineString").isPortrayed)
        XCTAssertFalse(feature(72, "Polygon").isPortrayed)
        XCTAssertFalse(feature(69, "Point").isPortrayed)
        XCTAssertTrue(feature(69, "MultiPolygon").isPortrayed)
        XCTAssertFalse(feature(126, "Point").isPortrayed)
        XCTAssertFalse(feature(114, "Point").isPortrayed)
        XCTAssertEqual(feature(156, "Point", "2").turbulenceDescription, "Eddies")
        XCTAssertEqual(feature(156, "Point", "4").turbulenceDescription, "Tide rips")
        XCTAssertEqual(feature(156, "Point", "").turbulenceDescription, "Water turbulence (type unspecified)")
    }

    func testKelpStreamsAndFerriesUseSupportedGeometryAndValidBearings() {
        func feature(_ code: Int, _ geometry: String, _ bearing: String = "") -> OfflineENCFeature {
            OfflineENCFeature(geometryType: geometry, coordinates: nil,
                attributes: ["OBJL": String(code), "ATTL_117": bearing], soundingDepths: [])
        }
        XCTAssertTrue(feature(158, "Point").isPortrayed)
        XCTAssertTrue(feature(158, "MultiPolygon").isPortrayed)
        XCTAssertFalse(feature(158, "LineString").isPortrayed)
        XCTAssertTrue(feature(53, "MultiLineString").isPortrayed)
        XCTAssertFalse(feature(53, "Point").isPortrayed)
        XCTAssertTrue(feature(160, "Point").isPortrayed)
        XCTAssertFalse(feature(160, "Polygon").isPortrayed)
        XCTAssertEqual(feature(160, "Point", "360").chartedOrientation, 0)
        XCTAssertEqual(feature(160, "Point", "174").chartedOrientation, 174)
        for bearing in ["", "nan", "-1", "361"] { XCTAssertNil(feature(160, "Point", bearing).chartedOrientation) }
        XCTAssertEqual(feature(53, "LineString").ferryDescription, "Ferry (type unspecified)")
    }

    func testDepthShadingUsesMinimumRangeAndExplicitUnits() {
        func band(_ low: String, _ high: String, _ units: Int = 1) -> OfflineENCDepthBand {
            OfflineENCFeature(geometryType: "Polygon", coordinates: nil,
                              attributes: ["OBJL": "42", "ATTL_87": low, "ATTL_88": high], soundingDepths: []).depthBand(unitCode: units)
        }
        XCTAssertEqual(band("-3", "0"), .drying)
        XCTAssertEqual(band("-1", "3"), .intertidal)
        XCTAssertEqual(band("0", "2"), .under2)
        XCTAssertEqual(band("2", "5"), .under5)
        XCTAssertEqual(band("5", "10"), .under10)
        XCTAssertEqual(band("10", "20"), .under20)
        XCTAssertEqual(band("20", "100"), .deep)
        XCTAssertEqual(band("6", "10", 2), .under2)
        XCTAssertEqual(band("6", "10", 3), .under20)
        XCTAssertEqual(band("2", "1"), .unknown)
        XCTAssertEqual(band("nan", "5"), .unknown)
        XCTAssertEqual(band("", "5"), .unknown)
        XCTAssertEqual(band("0", "5", 0), .unknown)
    }

    func testNewChartFeaturesOnlyClaimSupportedGeometry() {
        func feature(_ code: Int, _ type: String) -> OfflineENCFeature {
            OfflineENCFeature(geometryType: type, coordinates: nil,
                              attributes: ["OBJL": String(code), "ATTL_75": "3, 4"], soundingDepths: [])
        }
        for code in [84, 95, 122] {
            for geometry in ["Point", "LineString", "MultiLineString", "Polygon", "MultiPolygon"] {
                XCTAssertTrue(feature(code, geometry).isPortrayed)
            }
        }
        for code in OfflineENCFeature.aidClasses.union([90]) {
            XCTAssertTrue(feature(code, "Point").isPortrayed)
            XCTAssertFalse(feature(code, "Polygon").isPortrayed)
        }
        XCTAssertTrue(feature(159, "Point").isPortrayed)
        XCTAssertTrue(feature(159, "MultiPolygon").isPortrayed)
        XCTAssertFalse(feature(159, "LineString").isPortrayed)
        XCTAssertEqual(feature(9, "Point").colourCodes, [3, 4])
        XCTAssertFalse(feature(999, "Point").isPortrayed)
    }

    func testDepthUnitsAndDatumStayExplicitAndSoundingsAreNotConverted() throws {
        let feature = OfflineENCFeature(geometryType: "Point",
                                        coordinates: .array([.number(-123.1), .number(48.2)]),
                                        attributes: ["OBJL": "129", "RCID": "9"], soundingDepths: [1.5])
        XCTAssertEqual(feature.soundingDepths, [1.5])
        let metric = OfflineENCMetadata(cellID: "CA100001", edition: "3", update: "2", updateDate: "20261021",
                                        issueDate: "20261001", exchangeStandard: "3.1", compilationScale: 25000,
                                        depthUnitCode: 1, verticalDatumCode: 28, horizontalDatumCode: 2,
                                        catalogPresent: true, updateFilesApplied: ["CA100001.001", "CA100001.002"])
        XCTAssertEqual(metric.depthUnitName, "metres")
        XCTAssertTrue(metric.depthReferenceDescription.contains("unknown"))
        XCTAssertFalse(metric.depthReferenceDescription.contains("28"))
        var corrected = metric
        corrected.soundingDatumCode = 27
        XCTAssertTrue(corrected.depthReferenceDescription.contains("Lower low water large tide"))
        XCTAssertEqual(corrected.verticalDatumCode, 28)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(corrected)) as? [String: Any])
        legacy.removeValue(forKey: "soundingDatumCode")
        XCTAssertNil(try JSONDecoder().decode(OfflineENCMetadata.self, from: JSONSerialization.data(withJSONObject: legacy)).soundingDatumCode)
        XCTAssertEqual(metric.updateFilesApplied.count, 2)
        XCTAssertEqual(OfflineENCMetadata(cellID: "x", edition: "1", update: "0", updateDate: "", issueDate: "",
                                          exchangeStandard: "3.1", compilationScale: 50000, depthUnitCode: 2,
                                          verticalDatumCode: 0, horizontalDatumCode: 0, catalogPresent: true,
                                          updateFilesApplied: []).depthUnitName, "feet")
        XCTAssertEqual(OfflineENCMetadata(cellID: "x", edition: "1", update: "0", updateDate: "", issueDate: "",
                                          exchangeStandard: "3.1", compilationScale: 50000, depthUnitCode: 3,
                                          verticalDatumCode: 0, horizontalDatumCode: 0, catalogPresent: true,
                                          updateFilesApplied: []).depthUnitName, "fathoms")
    }

    func testCellsFromOneExchangeSetHaveDistinctOfflineLibraryIdentity() {
        let digest = String(repeating: "a", count: 64)
        func chart(_ cellID: String) -> OfflineENCChart {
            OfflineENCChart(sourceName: "CHS ENC", originalFilename: "V-PAC-A.zip", sha256: digest,
                            importedAt: Date(),
                            metadata: OfflineENCMetadata(cellID: cellID, edition: "1", update: "0", updateDate: "",
                                                        issueDate: "", exchangeStandard: "3.1", compilationScale: 50000,
                                                        depthUnitCode: 1, verticalDatumCode: 0, horizontalDatumCode: 0,
                                                        catalogPresent: true, updateFilesApplied: []),
                            features: [])
        }
        XCTAssertNotEqual(chart("CA570262").id, chart("CA570263").id)
    }

    func testMosaicBoundsCombineOnlyCellsFromTheSameExchangeSet() throws {
        func chart(_ cellID: String, _ hash: String, _ coordinates: [Double]) -> OfflineENCChart {
            let points = stride(from: 0, to: coordinates.count, by: 2).map { index in
                OfflineJSONValue.array([.number(coordinates[index]), .number(coordinates[index + 1])])
            }
            let line = OfflineENCFeature(geometryType: "LineString",
                                        coordinates: .array(points),
                                        attributes: ["OBJL": "43"], soundingDepths: [])
            // Coverage metadata can describe the rectangular cell extent,
            // including CATCOV=2 regions much larger than actual chart data.
            let broadCoverage = OfflineENCFeature(
                geometryType: "Polygon",
                coordinates: .array([.array([
                    .array([.number(-125), .number(46)]),
                    .array([.number(-125), .number(50)]),
                    .array([.number(-121), .number(50)]),
                    .array([.number(-121), .number(46)])
                ])]),
                attributes: ["OBJL": "302", "ATTL_18": "2"], soundingDepths: [])
            return OfflineENCChart(sourceName: "CHS ENC", originalFilename: "V-PAC-A.zip", sha256: hash,
                                   importedAt: Date(),
                                   metadata: OfflineENCMetadata(cellID: cellID, edition: "1", update: "0", updateDate: "",
                                                               issueDate: "", exchangeStandard: "3.1", compilationScale: 22000,
                                                               depthUnitCode: 1, verticalDatumCode: 28, horizontalDatumCode: 2,
                                                               catalogPresent: true, updateFilesApplied: []),
                                   features: [line, broadCoverage])
        }
        let first = chart("CA571551", "set-a", [-123.2, 48.7, -123.1, 48.8])
        let neighbor = chart("CA571552", "set-a", [-123.1, 48.75, -123.0, 48.9])
        let distant = chart("CA571999", "set-a", [-125.0, 45.0, -124.9, 45.1])
        let unrelated = chart("US000001", "set-b", [-124.0, 48.0, -123.8, 48.2])

        let defaultMosaic = OfflineENCChart.mosaicCharts(in: [first, neighbor, distant, unrelated], exchangeSetHash: "set-a",
                                                        selectedCellIDs: nil, includingCellID: first.id)
        XCTAssertEqual(Set(defaultMosaic.map(\.id)), Set([first.id, neighbor.id, distant.id]), "Default to all imported cells in this exchange set")
        let chosenSubset = OfflineENCChart.mosaicCharts(in: [first, neighbor, distant, unrelated], exchangeSetHash: "set-a",
                                                       selectedCellIDs: [first.id], includingCellID: first.id)
        XCTAssertEqual(chosenSubset.map(\.id), [first.id], "An explicit selection can show only the active cell")
        let nearbyMosaic = OfflineENCChart.mosaicCharts(in: [first, neighbor, distant, unrelated], exchangeSetHash: "set-a",
                                                       selectedCellIDs: [first.id, neighbor.id], includingCellID: first.id)
        XCTAssertEqual(Set(nearbyMosaic.map(\.id)), Set([first.id, neighbor.id]))

        let bounds = try XCTUnwrap(OfflineENCChart.mosaicBounds(in: nearbyMosaic, exchangeSetHash: "set-a"))
        XCTAssertEqual(bounds.west, -123.2, accuracy: 0.0001)
        XCTAssertEqual(bounds.east, -123.0, accuracy: 0.0001)
        XCTAssertEqual(bounds.south, 48.7, accuracy: 0.0001)
        XCTAssertEqual(bounds.north, 48.9, accuracy: 0.0001)

        let localViewport = try XCTUnwrap(OfflineENCChart.viewportBounds(in: nearbyMosaic, focusedCellID: first.id))
        XCTAssertEqual(localViewport.west, -123.2, accuracy: 0.0001)
        XCTAssertEqual(localViewport.east, -123.0, accuracy: 0.0001,
                       "Adjacent selected cells should fit together in the initial view")
        XCTAssertEqual(localViewport.south, 48.7, accuracy: 0.0001)
        XCTAssertEqual(localViewport.north, 48.9, accuracy: 0.0001)

        let wideViewport = try XCTUnwrap(OfflineENCChart.viewportBounds(in: defaultMosaic, focusedCellID: first.id))
        XCTAssertEqual(wideViewport.west, -123.2, accuracy: 0.0001)
        XCTAssertEqual(wideViewport.east, -123.1, accuracy: 0.0001,
                       "Distant imported cells should not shrink the active chart into a tiny overview")
        XCTAssertEqual(wideViewport.south, 48.7, accuracy: 0.0001)
        XCTAssertEqual(wideViewport.north, 48.8, accuracy: 0.0001)
    }

    private func storedZip(_ files: [(String, Data)], flags: UInt16 = 0) -> Data {
        var archive = Data()
        var records: [(name: Data, contents: Data, crc: UInt32, localOffset: UInt32)] = []
        for (path, contents) in files {
            let name = Data(path.utf8)
            let crc = crc32(contents)
            let localOffset = UInt32(archive.count)
            archive.appendLE(UInt32(0x04034b50)); archive.appendLE(UInt16(20)); archive.appendLE(flags)
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(crc)
            archive.appendLE(UInt32(contents.count)); archive.appendLE(UInt32(contents.count))
            archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0)); archive.append(name); archive.append(contents)
            records.append((name, contents, crc, localOffset))
        }
        let centralOffset = UInt32(archive.count)
        for entry in records {
            archive.appendLE(UInt32(0x02014b50)); archive.appendLE(UInt16(0x0314)); archive.appendLE(UInt16(20)); archive.appendLE(flags)
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(entry.crc)
            archive.appendLE(UInt32(entry.contents.count)); archive.appendLE(UInt32(entry.contents.count))
            archive.appendLE(UInt16(entry.name.count)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt32(0)); archive.appendLE(entry.localOffset); archive.append(entry.name)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLE(UInt32(0x06054b50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(records.count)); archive.appendLE(UInt16(records.count)); archive.appendLE(centralSize)
        archive.appendLE(centralOffset); archive.appendLE(UInt16(0))
        return archive
    }

    private func deflatedZip(name path: String, payload: Data, compressed: Data) -> Data {
        let name = Data(path.utf8), crc = crc32(payload), compressedSize = UInt32(compressed.count)
        var archive = Data()
        archive.appendLE(UInt32(0x04034b50)); archive.appendLE(UInt16(20)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(8)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(crc)
        archive.appendLE(compressedSize); archive.appendLE(UInt32(payload.count)); archive.appendLE(UInt16(name.count))
        archive.appendLE(UInt16(0)); archive.append(name); archive.append(compressed)
        let centralOffset = UInt32(archive.count)
        archive.appendLE(UInt32(0x02014b50)); archive.appendLE(UInt16(0x0314)); archive.appendLE(UInt16(20)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(8)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(crc)
        archive.appendLE(compressedSize); archive.appendLE(UInt32(payload.count)); archive.appendLE(UInt16(name.count))
        archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt32(0)); archive.appendLE(UInt32(0)); archive.append(name)
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLE(UInt32(0x06054b50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(1)); archive.appendLE(UInt16(1)); archive.appendLE(centralSize); archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        return archive
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

final class OfflineCoverageAndReferenceRegressionTests: XCTestCase {
 func testCoverageDefaultsAndReferenceMetadata() throws {
  func collection(_ id: String, _ cells: [String]) -> OfflineENCCollection {
   OfflineENCCollection(sourceName: "Test", originalFilename: id + ".zip", sha256: id, importedAt: Date(), cells: cells.map { .init(path: $0 + ".000", cellID: $0, title: $0, bounds: nil) })
  }
  let sample = collection("sample", ["CA479995"])
  let pacific = collection("pacific", ["CA271100", "CA571548", "CA571549"])
  for items in [[sample,pacific], [pacific,sample]] {
   XCTAssertTrue(OfflineENCCollection.defaultCoverage(in: items, preferredID: "")?.id == "pacific")
   XCTAssertTrue(OfflineENCCollection.defaultCoverage(in: items, preferredID: "missing")?.id == "pacific")
   XCTAssertTrue(OfflineENCCollection.defaultCoverage(in: items, preferredID: "sample")?.id == "sample")
  }
  XCTAssertTrue(OfflineENCCollection.defaultCoverage(in: [], preferredID: "") == nil)
  let context = JSContext()!
  context.evaluateScript(try String(contentsOfFile: "/Users/jeffm007/Projects/anchor-watch/AnchorWatch/Resources/anchorwatch-s57-bridge.js", encoding: .utf8))
  let merge = context.objectForKeyedSubscript("anchorWatchMergeUpdateMetadata")!
  let previous: [String:Any] = ["heightUnitCode":2,"depthUnitCode":1]
  let inherited = merge.call(withArguments:[previous,["dspmFields":[]]])!.toDictionary()!
  XCTAssertTrue(inherited["heightUnitCode"] as? Int == 2)
  let explicit = merge.call(withArguments:[previous,["dspmFields":["HUNI"],"heightUnitCode":1]])!.toDictionary()!
  XCTAssertTrue(explicit["heightUnitCode"] as? Int == 1)
  let feature = OfflineENCFeature(geometryType:"Point",coordinates:nil,attributes:["OBJL":"112","ATTL_131":"1,999"],soundingDepths:[])
  XCTAssertTrue(feature.restrictionLabels.count == 2)
  XCTAssertTrue(feature.restrictionLabels.last!.contains("999"))
  XCTAssertTrue(OfflineENCReference.datum(28).contains("Higher high water large tide"))
  let metadata = OfflineENCMetadata(cellID:"TEST", edition:"1", update:"0", updateDate:"", issueDate:"", exchangeStandard:"S-57", compilationScale:12000, depthUnitCode:1, verticalDatumCode:28, horizontalDatumCode:2, catalogPresent:true, updateFilesApplied:[], soundingDatumCode:27, heightUnitCode:2)
  func chart(_ features:[OfflineENCFeature]) -> OfflineENCChart {
   OfflineENCChart(sourceName:"Test",originalFilename:"test.zip",sha256:"test",importedAt:Date(),metadata:metadata,features:features)
  }
  XCTAssertTrue(chart([feature]).heightValue("38",for:feature) == "38 ft")
  XCTAssertTrue(chart([feature]).heightDatum(for:feature).contains("Higher high water large tide"))
  let local = OfflineENCFeature(geometryType:"Polygon",coordinates:nil,attributes:["OBJL":"312"],soundingDepths:[])
  XCTAssertTrue(chart([feature,local]).heightDatum(for:feature).contains("unresolved"))
  let explicitDatum = OfflineENCFeature(geometryType:"LineString",coordinates:nil,attributes:["OBJL":"21","ATTL_185":"3"],soundingDepths:[])
  XCTAssertTrue(chart([explicitDatum,local]).heightDatum(for:explicitDatum).contains("feature VERDAT"))

 }
}

final class OfflinePackageSessionTests: XCTestCase {
    @MainActor
    func testUnavailableCellIsReportedAndCancelledLoadDoesNotReplaceStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OfflineENCStore(root: root)
        let cell = OfflineENCZip.CellCandidate(path: "ABSENT.000", cellID: "ABSENT", title: "Missing", bounds: nil)
        let collection = OfflineENCCollection(sourceName: "Test", originalFilename: "absent.zip", sha256: "absent",
            importedAt: Date(), cells: [cell])
        let session = OfflineENCPackageSession()
        await session.load([cell], collection: collection, store: store)
        XCTAssertTrue(session.cells.isEmpty)
        XCTAssertEqual(session.failures.count, 1)
        XCTAssertTrue(session.failures[0].contains("ABSENT"))
        let status = session.status
        let task = Task { await session.load([], collection: collection, store: store) }
        task.cancel()
        await task.value
        XCTAssertEqual(session.status, status)
        XCTAssertNil(store.selectedChartID)
    }
}

final class OfflinePackageDetailPolicyTests: XCTestCase {
    func testOverviewPreferenceMovesBothPortrayalAndCellDetailTogether() {
        for threshold in [3_000.0, 6_000, 12_000, 24_000] {
            XCTAssertFalse(OfflineENCPackagePolicy.isOverview(metresAcross: threshold, overviewDistance: threshold))
            XCTAssertTrue(OfflineENCPackagePolicy.isOverview(metresAcross: threshold + 1, overviewDistance: threshold))
            XCTAssertEqual(OfflineENCPackagePolicy.maximumUsageBand(metresAcross: threshold, overviewDistance: threshold), 5)
            XCTAssertEqual(OfflineENCPackagePolicy.maximumUsageBand(metresAcross: threshold + 1, overviewDistance: threshold), 4)
        }
        XCTAssertTrue(OfflineENCPackagePolicy.isOverview(metresAcross: 8_000))
        XCTAssertFalse(OfflineENCPackagePolicy.isOverview(metresAcross: 8_000, overviewDistance: 12_000))
        for invalid in [0.0, -1, Double.nan, Double.infinity] {
            XCTAssertEqual(OfflineENCPackagePolicy.validOverviewDistance(invalid), 6_000)
        }
    }

    func testRegionalViewsExcludeHarbourDetailAndZoomRestoresIt() {
        XCTAssertEqual(OfflineENCPackagePolicy.maximumUsageBand(metresAcross: 400_000), 2)
        XCTAssertEqual(OfflineENCPackagePolicy.maximumUsageBand(metresAcross: 40_000), 3)
        XCTAssertEqual(OfflineENCPackagePolicy.maximumUsageBand(metresAcross: 10_000), 4)
        XCTAssertEqual(OfflineENCPackagePolicy.maximumUsageBand(metresAcross: 4_000), 5)
        XCTAssertEqual(OfflineENCPackagePolicy.maximumUsageBand(metresAcross: 1_000), 6)
        XCTAssertTrue(OfflineENCPackagePolicy.isOverview(metresAcross: 6_001))
        XCTAssertFalse(OfflineENCPackagePolicy.isOverview(metresAcross: 6_000))
        XCTAssertEqual(OfflineENCPackagePolicy.maximumUsageBand(metresAcross: 6_001), 4)
        XCTAssertEqual(OfflineENCPackagePolicy.maximumUsageBand(metresAcross: 6_000), 5)
        XCTAssertTrue(OfflineENCPackagePolicy.showsInOverview(objectClass: 71))
        XCTAssertFalse(OfflineENCPackagePolicy.showsInOverview(objectClass: 129))
        XCTAssertFalse(OfflineENCPackagePolicy.showsInOverview(objectClass: 159))
        XCTAssertEqual(OfflineENCPackagePolicy.usageBand(cellID: "CA571548"), 5)
        XCTAssertNil(OfflineENCPackagePolicy.usageBand(cellID: "BAD"))
    }
}

final class OfflineRasterTileTests: XCTestCase {
    func testTilesCoverViewportAtNegativeCoordinatesAndFractionalZoom() {
        for zoom: CGFloat in [0.5, 1, 1.7, 8, 128] {
            let size = CGSize(width: 430, height: 932), pan = CGSize(width: -701, height: 217)
            let tiles = OfflineENCTileAddress.visible(size: size, zoom: zoom, pan: pan)
            XCTAssertFalse(tiles.isEmpty)
            // 216-point tiles: at most 3 columns x 6 rows for this viewport.
            XCTAssertLessThanOrEqual(tiles.count, 18)
            let rasterBytes = tiles.count * Int(pow(OfflineENCTileAddress.side * 2, 2)) * 4
            XCTAssertLessThanOrEqual(rasterBytes, 16 * 1024 * 1024)
            for x in stride(from: CGFloat(1), to: size.width, by: 30) {
                for y in stride(from: CGFloat(1), to: size.height, by: 30) {
                    XCTAssertTrue(tiles.contains { $0.screenRect(size: size, liveZoom: zoom, pan: pan).contains(CGPoint(x: x, y: y)) })
                }
            }
        }
        XCTAssertTrue(OfflineENCTileAddress.visible(size: .zero, zoom: 1, pan: .zero).isEmpty)
        XCTAssertTrue(OfflineENCTileAddress.visible(size: CGSize(width: 400, height: 800), zoom: .nan, pan: .zero).isEmpty)
    }

    @MainActor
    func testRasterCacheBoundEvictionReuseAndCancellation() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let cache = OfflineENCTileCache(byteLimit: 512)
        func key(_ x: Int, scene: String = "edition-1", namespace: String = "sourceA-textOn") -> OfflineENCTileCache.Key {
            .init(namespace: namespace, scene: scene, address: .init(level: 0, x: x, y: 0))
        }
        cache.insert(image, for: key(0)); cache.insert(image, for: key(1)); cache.insert(image, for: key(2))
        XCTAssertLessThanOrEqual(cache.byteCount, 512)
        XCTAssertNil(cache.entries[key(0)])
        await cache.prepare(keys: [key(1), key(2)]) { _ in XCTFail("Cached images must not redraw"); return image }
        XCTAssertEqual(cache.hitCount, 2)
        XCTAssertEqual(cache.renderCount, 0)
        XCTAssertNotEqual(key(1), key(1, scene: "edition-2"))
        XCTAssertNotEqual(key(1), key(1, namespace: "sourceA-textOff"))
        let cancelled = Task { await cache.prepare(keys: [key(9)]) { _ in XCTFail("Cancelled render"); return image } }
        cancelled.cancel(); await cancelled.value
        XCTAssertNil(cache.entries[key(9)])
        cache.clear(); XCTAssertEqual(cache.byteCount, 0)
    }
}

final class OfflineCompactCoordinateTests: XCTestCase {
    func testCompactCoordinatesPreserveJSONAndSoundingZ() throws {
        let source = "[[[-123.1,48.2],[-123.2,48.3,7.25],[-123.1,48.2]]]"
        let data = Data(source.utf8)
        let value = try JSONDecoder().decode(OfflineJSONValue.self, from: data)
        guard case .array(let rings) = value, case .array(let points) = rings[0],
              case .position = points[0], case .position3D(_, _, let z) = points[1] else {
            return XCTFail("Vertices must be inline tuples")
        }
        XCTAssertEqual(z, 7.25)
        var coordinates: [ChartCoordinate] = []
        value.collectCoordinates(into: &coordinates)
        XCTAssertEqual(coordinates.count, 3)
        XCTAssertEqual(coordinates[1].longitude, -123.2)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSArray,
                       try JSONSerialization.jsonObject(with: data) as? NSArray)
        XCTAssertEqual(try JSONDecoder().decode(OfflineJSONValue.self, from: encoded), value)
    }
    func testInvalidCoordinatesAreNotIncludedInBounds() {
        var points: [ChartCoordinate] = []
        OfflineJSONValue.position(181, 0).collectCoordinates(into: &points)
        OfflineJSONValue.position3D(0, 91, 2).collectCoordinates(into: &points)
        XCTAssertTrue(points.isEmpty)
    }
}

final class OfflineBackgroundProjectionTests: XCTestCase {
    func testProjectedCoordinatesMatchOriginalProjectionAndPreserveZ() throws {
        let projector = ENCProjector(bounds: .init(west: -124, south: 48, east: -123, north: 49),
            size: CGSize(width: 390, height: 800), zoom: 4, pan: CGSize(width: -100, height: 30))
        let original = OfflineJSONValue.array([.array([.position3D(-123.5, 48.5, 12.75), .position(-123.4, 48.6)])])
        let projected = try OfflineENCTilePreparation.project(original, using: projector)
        guard case .array(let rings) = projected, case .array(let points) = rings[0],
              case .position3D(let x, let y, let z) = points[0] else { return XCTFail("Lost ring geometry") }
        let expected = projector.screen(ChartCoordinate(longitude: -123.5, latitude: 48.5))
        XCTAssertEqual(x, expected.x); XCTAssertEqual(y, expected.y); XCTAssertEqual(z, 12.75)
        var passthrough = projector; passthrough.coordinatesAreProjected = true
        XCTAssertEqual(passthrough.screen(ChartCoordinate(longitude: x, latitude: y)), expected)
    }
    func testCancelledPreparationDoesNotReturnGeometry() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OfflineENCTilePreparation.prepare(cells: [], featureBounds: [:],
                projector: ENCProjector(bounds: .init(west: 0, south: 0, east: 1, north: 1),
                    size: CGSize(width: 390, height: 800), zoom: 1, pan: .zero), overview: false)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preparation returned") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

final class OfflinePortrayalBudgetTests: XCTestCase {
    func testCellBudgetRejectsOversizeAndReleasesDepartingCells() {
        var budget = OfflineENCWorkingSetBudget(limit: 100)
        XCTAssertTrue(budget.admit("overview", bytes: 30))
        XCTAssertTrue(budget.admit("detailA", bytes: 60))
        XCTAssertFalse(budget.admit("detailB", bytes: 20))
        XCTAssertEqual(budget.usedBytes, 90)
        XCTAssertFalse(budget.admit("oversize", bytes: 101))
        XCTAssertFalse(budget.admit("invalid", bytes: -1))
        budget.retain(["overview"])
        XCTAssertEqual(budget.usedBytes, 30)
        XCTAssertTrue(budget.admit("detailB", bytes: 70))
        XCTAssertEqual(budget.usedBytes, 100)
        XCTAssertTrue(budget.admit("detailB", bytes: 40))
        XCTAssertEqual(budget.usedBytes, 70)
        budget.removeAll()
        XCTAssertEqual(budget.usedBytes, 0)
    }
    func testLayoutCacheReusesAndEvictsLeastRecentlyUsed() {
        var cache = OfflineENCBoundedCache<String, Int>(limit: 2)
        var builds = 0
        func make() -> Int { builds += 1; return builds }
        XCTAssertEqual(cache.value(for: "a", make: make), 1)
        XCTAssertEqual(cache.value(for: "b", make: make), 2)
        XCTAssertEqual(cache.value(for: "a", make: make), 1)
        XCTAssertEqual(cache.value(for: "c", make: make), 3)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(for: "b", make: make), 4)
        XCTAssertEqual(cache.hits, 1)
        cache.clear(); XCTAssertEqual(cache.count, 0)
    }
    @MainActor
    func testTextCacheSeparatesStylesAndColors() {
        let a = OfflineENCPortrayalCache.TextKey(text: "12", style: "depth8", color: .black)
        XCTAssertNotEqual(a, .init(text: "12", style: "depth9", color: .black))
        XCTAssertNotEqual(a, .init(text: "12", style: "depth8", color: .red))
    }
    func testGeometryEstimateGrowsWithVertexCount() {
        let point = OfflineJSONValue.position(-123, 48)
        let small = OfflineJSONValue.array([point, point])
        let large = OfflineJSONValue.array(Array(repeating: point, count: 1000))
        XCTAssertGreaterThan(large.estimatedStorageBytes, small.estimatedStorageBytes * 100)
        XCTAssertGreaterThanOrEqual(large.estimatedStorageBytes, 1000 * MemoryLayout<OfflineJSONValue>.stride)
    }
}

final class OfflineViewportIndexTests: XCTestCase {
    private func fixture() -> OfflineENCChart {
        func point(_ x: Double, _ y: Double) -> OfflineJSONValue { .position(x, y) }
        func feature(_ id: String, _ cls: Int, _ type: String, _ coordinates: OfflineJSONValue, depths: [Double] = []) -> OfflineENCFeature {
            OfflineENCFeature(geometryType: type, coordinates: coordinates,
                attributes: ["OBJL": String(cls), "RCID": id, "ATTL_18": "1"], soundingDepths: depths)
        }
        let exterior = OfflineJSONValue.array([point(-5,-5), point(5,-5), point(5,5), point(-5,5), point(-5,-5)])
        let hole = OfflineJSONValue.array([point(-0.5,-0.5), point(0.5,-0.5), point(0.5,0.5), point(-0.5,-0.5)])
        let features = [feature("1",129,"Point",.position3D(0,0,12.75),depths:[12.75]),
                        feature("2",129,"Point",point(8,8),depths:[9]),
                        feature("3",30,"LineString",.array([point(-4,0),point(4,0)])),
                        feature("4",71,"Polygon",.array([exterior,hole])),
                        feature("5",302,"Polygon",.array([exterior]))]
        let metadata = OfflineENCMetadata(cellID:"TEST",edition:"1",update:"2",updateDate:"20261001",issueDate:"20260901",
            exchangeStandard:"S-57",compilationScale:12000,depthUnitCode:1,verticalDatumCode:28,horizontalDatumCode:2,
            catalogPresent:true,updateFilesApplied:["TEST.001","TEST.002"],soundingDatumCode:27,heightUnitCode:1)
        return OfflineENCChart(sourceName:"Test",originalFilename:"original.zip",sha256:"source-hash",importedAt:Date(),metadata:metadata,features:features)
    }
    func testSpatialReadsKeepCrossingLinesHolesMetadataAndDepths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = fixture()
        try OfflineENCFeatureIndex.build(chart: source, directory: root)
        let window = OfflineENCBounds(west:-1,south:-1,east:1,north:1)
        let first = try OfflineENCFeatureIndex.read(directory: root, viewport: window, overview: false)
        XCTAssertEqual(Set(first.chart.features.map(\.id)), ["129-1","30-3","71-4","302-5"])
        XCTAssertEqual(first.chart.features.first { $0.id == "71-4" }?.coordinates, source.features[3].coordinates)
        XCTAssertEqual(first.chart.features.first { $0.id == "30-3" }?.coordinates, source.features[2].coordinates)
        XCTAssertEqual(first.chart.features.first { $0.id == "129-1" }?.soundingDepths, [12.75])
        XCTAssertEqual(first.chart.metadata, source.metadata)
        XCTAssertEqual(first.chart.sha256, source.sha256)
        let second = try OfflineENCFeatureIndex.read(directory: root, viewport: .init(west:7,south:7,east:9,north:9), overview: false)
        XCTAssertEqual(Set(second.chart.features.map(\.id)), ["129-2","302-5"])
        let again = try OfflineENCFeatureIndex.read(directory: root, viewport: window, overview: false)
        XCTAssertEqual(first.chart.features, again.chart.features)
        XCTAssertLessThan(second.estimatedBytes, OfflineENCWorkingSetBudget.estimate(source))
        let overview = try OfflineENCFeatureIndex.read(directory: root, viewport: window, overview: true)
        XCTAssertFalse(overview.chart.features.contains { $0.objectClass == 129 })
        XCTAssertTrue(overview.chart.features.contains { $0.objectClass == 302 })
    }
    func testTruncatedRecordsFailClearly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try OfflineENCFeatureIndex.build(chart: fixture(), directory: root)
        let file = try FileHandle(forWritingTo: root.appendingPathComponent("features.bin"))
        try file.truncate(atOffset: 4); try file.close()
        XCTAssertThrowsError(try OfflineENCFeatureIndex.read(directory: root, viewport: nil, overview: false))
    }
    func testBufferedViewportContainsVisibleCorners() {
        let projector = ENCProjector(bounds: .init(west:-124,south:48,east:-123,north:49),size:CGSize(width:390,height:800),zoom:4,pan:.zero)
        let window = projector.bufferedGeographicViewport
        let northwest = projector.screen(.init(longitude:window.west,latitude:window.north))
        let southeast = projector.screen(.init(longitude:window.east,latitude:window.south))
        XCTAssertLessThan(northwest.x, 0); XCTAssertLessThan(northwest.y, 0)
        XCTAssertGreaterThan(southeast.x, 390); XCTAssertGreaterThan(southeast.y, 800)
    }
}

final class OfflineStreamedGeometryTests: XCTestCase {
    private func chart(_ features: [OfflineENCFeature]) -> OfflineENCChart {
        let metadata = OfflineENCMetadata(cellID: "STREAM", edition: "1", update: "0", updateDate: "", issueDate: "",
            exchangeStandard: "S-57", compilationScale: 22000, depthUnitCode: 1, verticalDatumCode: 28,
            horizontalDatumCode: 2, catalogPresent: true, updateFilesApplied: [])
        return .init(sourceName: "Test", originalFilename: "original.zip", sha256: "unchanged", importedAt: Date(), metadata: metadata, features: features)
    }
    private func denseRing(_ vertices: [(Double, Double)]) -> OfflineJSONValue {
        var values: [OfflineJSONValue] = []
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            for j in 0..<300 {
                let t = Double(j) / 300
                values.append(.position(a.0 + t * (b.0 - a.0), a.1 + t * (b.1 - a.1)))
            }
        }
        values.append(values[0]); return .array(values)
    }
    private func contains(_ feature: OfflineENCFeature, x: Double, y: Double) -> Bool {
        guard case .array(let rings) = feature.coordinates else { return false }
        var inside = false
        for ring in rings {
            var coordinates: [ChartCoordinate] = []; ring.collectCoordinates(into: &coordinates)
            guard let last = coordinates.last else { continue }
            var a = last
            for b in coordinates {
                if (a.latitude > y) != (b.latitude > y),
                   x < (b.longitude - a.longitude) * (y - a.latitude) / (b.latitude - a.latitude) + a.longitude { inside.toggle() }
                a = b
            }
        }
        return inside
    }
    func testLargePolygonHolesAndAdjacentWindowsHaveNoFillGaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Concave C: clipping can produce disconnected filled regions joined only
        // by cancelling boundary bridges. A hole spans both adjacent windows.
        let outer = denseRing([(-10,-10),(10,-10),(10,-4),(-4,-4),(-4,4),(10,4),(10,10),(-10,10)])
        let hole = denseRing([(-8,-8),(8,-8),(8,-6),(-8,-6)])
        let feature = OfflineENCFeature(geometryType: "Polygon", coordinates: .array([outer,hole]),
            attributes: ["OBJL":"42","RCID":"1","ATTL_87":"2","ATTL_88":"5"], soundingDepths: [])
        let source = chart([feature]); try OfflineENCFeatureIndex.build(chart: source, directory: root)
        let windows = [OfflineENCBounds(west:-2,south:-9,east:0.1,north:9), .init(west:-0.1,south:-9,east:2,north:9)]
        for window in windows {
            let result = try OfflineENCFeatureIndex.read(directory: root, viewport: window, overview: false)
            let clipped = try XCTUnwrap(result.chart.features.first)
            XCTAssertEqual(clipped.attributes, feature.attributes)
            XCTAssertEqual(result.chart.metadata, source.metadata)
            XCTAssertEqual(result.chart.sha256, source.sha256)
            XCTAssertLessThan(result.estimatedBytes, OfflineENCWorkingSetBudget.estimate(source) / 3)
            for x in stride(from: window.west + 0.03, to: window.east, by: 0.13) {
                for y in stride(from: -8.9, to: 8.9, by: 0.19) {
                    XCTAssertEqual(contains(clipped,x:x,y:y),contains(feature,x:x,y:y), "Fill mismatch at \(x),\(y)")
                }
            }
            for point in clipped.chartCoordinates() {
                XCTAssertGreaterThanOrEqual(point.longitude, window.west - 1e-10)
                XCTAssertLessThanOrEqual(point.longitude, window.east + 1e-10)
                XCTAssertGreaterThanOrEqual(point.latitude, window.south - 1e-10)
                XCTAssertLessThanOrEqual(point.latitude, window.north + 1e-10)
            }
        }
        let full = try OfflineENCFeatureIndex.read(directory: root, viewport: nil, overview: false)
        XCTAssertEqual(full.chart.features, source.features)
    }
    func testLongLineChunkBoundariesDoNotLoseCrossingSegments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let points: [OfflineJSONValue] = (0...4096).map { .position(-20 + Double($0) / 102.4, 0) }
        let feature = OfflineENCFeature(geometryType:"LineString",coordinates:.array(points),attributes:["OBJL":"30","RCID":"1"],soundingDepths:[])
        let source = chart([feature]); try OfflineENCFeatureIndex.build(chart: source, directory: root)
        let result = try OfflineENCFeatureIndex.read(directory: root, viewport:.init(west:-0.1,south:-1,east:0.1,north:1), overview:false)
        let clipped = try XCTUnwrap(result.chart.features.first)
        XCTAssertEqual(clipped.geometryType, "MultiLineString")
        let selected = clipped.chartCoordinates()
        XCTAssertEqual(try XCTUnwrap(selected.first).longitude,-0.1,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(selected.last).longitude,0.1,accuracy:1e-10)
        XCTAssertLessThan(selected.count, 30)
        XCTAssertLessThan(result.estimatedBytes, OfflineENCWorkingSetBudget.estimate(source) / 10)
        let repeated = try OfflineENCFeatureIndex.read(directory: root, viewport:.init(west:-0.1,south:-1,east:0.1,north:1), overview:false)
        XCTAssertEqual(repeated.chart.features,result.chart.features)
        // Corrupt a valid-size derived chunk: it must throw, never silently omit it.
        let indexURL = root.appendingPathComponent("index.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(OfflineENCFeatureIndex.self, from: Data(contentsOf:indexURL))
        let chunk = try XCTUnwrap(index.records.first?.geometry?.first?.first?.first)
        let handle = try FileHandle(forWritingTo:root.appendingPathComponent("features.bin"))
        try handle.seek(toOffset:chunk.offset); try handle.write(contentsOf:Data(repeating:0,count:chunk.length)); try handle.close()
        XCTAssertThrowsError(try OfflineENCFeatureIndex.read(directory:root,viewport:nil,overview:false))
    }
    func testEnclosingHoleAndSeparatePolygonsStaySeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = denseRing([(-10,-10),(10,-10),(10,10),(-10,10)])
        let hole = denseRing([(-2,-2),(2,-2),(2,2),(-2,2)])
        let remote = denseRing([(30,30),(31,30),(31,31),(30,31)])
        let feature = OfflineENCFeature(geometryType:"MultiPolygon",coordinates:.array([.array([outer,hole]),.array([remote])]),
            attributes:["OBJL":"71","RCID":"1"],soundingDepths:[])
        try OfflineENCFeatureIndex.build(chart:chart([feature]),directory:root)
        let loaded = try OfflineENCFeatureIndex.read(directory:root,viewport:.init(west:-1,south:-1,east:1,north:1),overview:false)
        let result = try XCTUnwrap(loaded.chart.features.first)
        guard case .array(let polygons) = result.coordinates else { return XCTFail("Missing multipolygon") }
        XCTAssertEqual(polygons.count,1)
        let piece = OfflineENCFeature(geometryType:"Polygon",coordinates:polygons[0],attributes:result.attributes,soundingDepths:[])
        XCTAssertFalse(contains(piece,x:0,y:0),"A surrounding hole must remain water even when none of its source vertices are visible")
        XCTAssertFalse(contains(piece,x:0.8,y:0.8))
    }
    func testClippingUsesMercatorAndPreservesSlopeAcrossWindows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var points = Array(repeating:OfflineJSONValue.position(-2,45),count:1024)
        points.append(.position(2,55))
        let feature = OfflineENCFeature(geometryType:"LineString",coordinates:.array(points),attributes:["OBJL":"30","RCID":"1"],soundingDepths:[])
        try OfflineENCFeatureIndex.build(chart:chart([feature]),directory:root)
        let result = try OfflineENCFeatureIndex.read(directory:root,viewport:.init(west:0,south:40,east:1,north:60),overview:false)
        let first = try XCTUnwrap(result.chart.features.first?.chartCoordinates().first)
        let y = (OfflineENCGeometryStream.Vertex.mercator(45) + OfflineENCGeometryStream.Vertex.mercator(55)) / 2
        let expected = (2 * atan(exp(y)) - Double.pi / 2) * 180 / Double.pi
        XCTAssertEqual(first.longitude,0,accuracy:1e-12)
        XCTAssertEqual(first.latitude,expected,accuracy:1e-10)
        XCTAssertNotEqual(first.latitude,50,"Linear latitude clipping would bend the displayed coastline")
    }
    func testSoundingsMetadataAndThreeDimensionalGeometryAreNotClipped() {
        let ring = denseRing([(-10,-10),(10,-10),(10,10),(-10,10)])
        for cls in [129,302,311] {
            let feature = OfflineENCFeature(geometryType:"Polygon",coordinates:.array([ring]),attributes:["OBJL":String(cls)],soundingDepths:[12.75])
            XCTAssertNil(OfflineENCGeometryStream.groups(feature))
        }
        let points = Array(repeating:OfflineJSONValue.position3D(1,2,3),count:2048)
        let feature = OfflineENCFeature(geometryType:"LineString",coordinates:.array(points),attributes:["OBJL":"43"],soundingDepths:[])
        XCTAssertNil(OfflineENCGeometryStream.groups(feature))
    }
}

final class OfflineCruisingAreaTests: XCTestCase {
    func testSelectedAreaReturnsToRegionalChartAtDisplayThreshold() {
        let bounds = OfflineENCBounds(west: -124, south: 48, east: -123, north: 49)
        let cells = ["CA471221", "CA571548", "CA571549"].map {
            OfflineENCZip.CellCandidate(path: $0 + ".000", cellID: $0, title: $0, bounds: bounds)
        }
        let selected: Set<String> = ["CA571548", "CA571549"]
        for threshold in [3_000.0, 6_000, 12_000, 24_000] {
            func visible(_ distance: Double) -> [String] {
                OfflineENCCruisingArea.renderCells(in: cells, areaID: "CA471221", selected: selected,
                    overview: OfflineENCPackagePolicy.isOverview(metresAcross: distance, overviewDistance: threshold)).map(\.cellID)
            }
            XCTAssertEqual(visible(threshold), ["CA471221", "CA571548", "CA571549"])
            XCTAssertEqual(visible(threshold + 1), ["CA471221"])
            XCTAssertEqual(visible(threshold / 2), ["CA471221", "CA571548", "CA571549"])
        }
    }
    func testPresetIdentifiersAndLabels() {
        XCTAssertEqual(OfflineENCCruisingArea.presets.map(\.name), ["S.VanC","Pender","W. VanC","Georgia"])
        XCTAssertEqual(OfflineENCCruisingArea.presets.map(\.cellID), ["CA471223","CA471221","CA471216","CA471212"])
    }
    func testAreaGridAndRenderingExcludeUnselectedOrOutsideCells() {
        func cell(_ id: String, _ box: OfflineENCBounds?) -> OfflineENCZip.CellCandidate {
            .init(path:id+".000",cellID:id,title:id,bounds:box)
        }
        let region = OfflineENCBounds(west:-124,south:48,east:-123,north:49)
        let cells = [cell("CA471221",region), cell("CA271100",region),
            cell("CA571551",.init(west:-123.8,south:48.2,east:-123.6,north:48.4)),
            cell("CA571552",.init(west:-123.1,south:48.2,east:-122.9,north:48.4)),
            cell("CA571553",.init(west:-122,south:48,east:-121,north:49)),
            cell("CA571554",nil)]
        XCTAssertEqual(OfflineENCCruisingArea.detailCells(in:cells,areaID:"CA471221").map(\.cellID),["CA571551","CA571552"])
        XCTAssertEqual(OfflineENCCruisingArea.renderCells(in:cells,areaID:"CA471221",selected:["CA571551","CA571553"]).map(\.cellID),["CA471221","CA571551"])
        XCTAssertEqual(OfflineENCCruisingArea.renderCells(in:cells,areaID:"CA471221",selected:[]).map(\.cellID),["CA471221"])
        XCTAssertTrue(OfflineENCCruisingArea.detailCells(in:cells,areaID:"missing").isEmpty)
        XCTAssertTrue(OfflineENCCruisingArea.renderCells(in:cells,areaID:"missing",selected:["CA571551"]).isEmpty)
    }
}

@MainActor
final class CoveredChartViewportTests: XCTestCase {
    func testCameraSurvivesMapRecreationWithoutRetainingMap() {
        let engine = AnchorWatchEngine(player: SilentAlarm(), defaults: UserDefaults(suiteName:UUID().uuidString)!, useGPSHardware:false)
        let state = ChartMapViewportState()
        let coordinate = CLLocationCoordinate2D(latitude:48.8,longitude:-123.3)
        let original = MKMapView(frame:CGRect(x:0,y:0,width:320,height:480))
        original.setCamera(MKMapCamera(lookingAtCenter:coordinate,fromDistance:4000,pitch:0,heading:25),animated:false)
        let coordinator = ChartMapView.Coordinator(engine,viewportState:state,navigation:NavigationStore(defaults:UserDefaults(suiteName:UUID().uuidString)!))
        coordinator.saveViewport(original)
        let restored = MKMapView(frame:original.frame)
        ChartMapView.Coordinator(engine,viewportState:state,navigation:NavigationStore(defaults:UserDefaults(suiteName:UUID().uuidString)!)).restoreViewport(restored)
        XCTAssertEqual(restored.camera.centerCoordinate.latitude,original.camera.centerCoordinate.latitude,accuracy:0.00001)
        XCTAssertEqual(restored.camera.centerCoordinate.longitude,original.camera.centerCoordinate.longitude,accuracy:0.00001)
        XCTAssertEqual(restored.camera.heading,original.camera.heading,accuracy:0.1)
        XCTAssertFalse(state.camera === original.camera)
    }
    func testRecenterWhileCoveredTakesPriorityOverSavedCamera() {
        let engine = AnchorWatchEngine(player:SilentAlarm(),defaults:UserDefaults(suiteName:UUID().uuidString)!,useGPSHardware:false)
        let state = ChartMapViewportState()
        state.camera = MKMapCamera(lookingAtCenter:.init(latitude:48.8,longitude:-123.3),fromDistance:4000,pitch:0,heading:25)
        state.recenterTick = engine.recenterTick
        engine.recenter()
        let map = MKMapView(frame:CGRect(x:0,y:0,width:320,height:480))
        let before = map.camera.centerCoordinate
        ChartMapView.Coordinator(engine,viewportState:state,navigation:NavigationStore(defaults:UserDefaults(suiteName:UUID().uuidString)!)).restoreViewport(map)
        XCTAssertEqual(map.camera.centerCoordinate.latitude,before.latitude,accuracy:0.00001)
        XCTAssertEqual(map.camera.centerCoordinate.longitude,before.longitude,accuracy:0.00001)
    }
}

final class OfflineCurrentStationOverlayTests: XCTestCase {
    func testMarkersFollowLiveProjectionAndCullOffscreenStations() {
        let station = CurrentStation(id: "test", name: "Station", lat: 48.5, lng: -123.5)
        let outside = CurrentStation(id: "far", name: "Far", lat: 20, lng: 0)
        let bounds = OfflineENCBounds(west: -124, south: 48, east: -123, north: 49)
        let projector = ENCProjector(bounds: bounds, size: CGSize(width: 390, height: 800), zoom: 3, pan: CGSize(width: 40, height: 20))
        let markers = OfflineCurrentStationMarker.visible([station, outside], projector: projector)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.point, projector.screen(.init(longitude: station.lng, latitude: station.lat)))
        let moved = ENCProjector(bounds: bounds, size: projector.size, zoom: 3, pan: CGSize(width: 80, height: 50))
        let next = OfflineCurrentStationMarker.visible([station], projector: moved)[0]
        XCTAssertEqual(next.point.x - markers[0].point.x, 40, accuracy: 0.001)
        XCTAssertEqual(next.point.y - markers[0].point.y, 30, accuracy: 0.001)
    }
    func testProviderIdentityDeduplicationAndInvalidCoordinates() {
        let noaa = CurrentStation(id: "same", name: "NOAA", lat: 48.5, lng: -123.5)
        let chs = CurrentStation(id: "same", name: "CHS", lat: 48.5, lng: -123.5, provider: .chs)
        let invalid = CurrentStation(id: "bad", name: "Invalid", lat: .nan, lng: 0)
        let projector = ENCProjector(bounds: .init(west: -124, south: 48, east: -123, north: 49), size: CGSize(width: 390, height: 800), zoom: 1, pan: .zero)
        XCTAssertEqual(OfflineCurrentStationMarker.visible([noaa, noaa, chs, invalid], projector: projector).map(\.id), ["noaa:same", "chs:same"])
    }
}

final class OfflineTideOverlayTests: XCTestCase {
    func testOverviewSymbolsAreTinyAndGrowWithDetail() {
        XCTAssertEqual(OfflineStationSymbol.diameter(metresAcross: 200_000), 4)
        XCTAssertEqual(OfflineStationSymbol.diameter(metresAcross: 80_000), 4)
        XCTAssertEqual(OfflineStationSymbol.diameter(metresAcross: 1_000), 28)
        XCTAssertLessThan(OfflineStationSymbol.diameter(metresAcross: 40_000), OfflineStationSymbol.diameter(metresAcross: 10_000))
    }
    func testTideMarkersUseProviderIdentityAndChartProjection() {
        let a = TideStation(id: "1", name: "A", lat: 48.5, lng: -123.5)
        let b = TideStation(id: "1", name: "B", lat: 48.5, lng: -123.5, source: TideStation.chs)
        let far = TideStation(id: "2", name: "Far", lat: 0, lng: 0)
        let projector = ENCProjector(bounds: .init(west: -124, south: 48, east: -123, north: 49), size: CGSize(width: 390, height: 800), zoom: 2, pan: .zero)
        let markers = OfflineTideStationMarker.visible([a, a, b, far], projector: projector)
        XCTAssertEqual(markers.map(\.id), ["noaa:1", "chs:1"])
        XCTAssertEqual(markers[0].point, projector.screen(.init(longitude: a.lng, latitude: a.lat)))
    }
}

final class OfflineAtomicTileTransitionTests: XCTestCase {
    @MainActor
    func testCompleteBatchReplacesOverviewAndFailureKeepsPreviousFrame() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let cache = OfflineENCTileCache(byteLimit: 512)
        let overview = OfflineENCTileCache.Key(namespace: "overview", scene: "1", address: .init(level: 0, x: 0, y: 0))
        let detail = (0...1).map { OfflineENCTileCache.Key(namespace: "detail", scene: "2", address: .init(level: 1, x: $0, y: 0)) }
        await cache.prepare(keys: [overview], displayDomain: "Pender") { _ in image }
        await cache.prepare(keys: detail, displayDomain: "Pender") { _ in
            XCTAssertEqual(cache.displayedEntries.map(\.key), [overview], "No partial batch may become visible")
            return image
        }
        XCTAssertEqual(cache.displayedEntries.map(\.key), detail)
        XCTAssertLessThanOrEqual(cache.byteCount + cache.displayedByteCount, 1024)
        await cache.prepare(keys: [overview], displayDomain: "Pender") { _ in nil }
        XCTAssertEqual(cache.displayedEntries.map(\.key), detail)
        await cache.prepare(keys: [overview], displayDomain: "Pender") { _ in
            cache.clear() // A superseded renderer must not publish after clear.
            return image
        }
        XCTAssertTrue(cache.displayedEntries.isEmpty)
        XCTAssertEqual(cache.byteCount, 0)
        let roomy = OfflineENCTileCache(byteLimit: 1024)
        await roomy.prepare(keys: [overview], displayDomain: "Pender", isOverview: true) { _ in image }
        await roomy.prepare(keys: detail, displayDomain: "Pender") { _ in image }
        XCTAssertEqual(roomy.overviewBackdrop.map(\.key), [overview])
        XCTAssertLessThanOrEqual(roomy.displayedByteCount, roomy.byteLimit)
        await roomy.prepare(keys: detail, displayDomain: "Other chart") { _ in image }
        XCTAssertTrue(roomy.overviewBackdrop.isEmpty, "Never show a background from a different chart/projection")
    }
}

final class OfflineStableRasterIdentityTests: XCTestCase {
    @MainActor
    func testReloadReusesTilesAndChangedWindowOrSourceInvalidates() async throws {
        let viewport = OfflineENCBounds(west: -123.4, south: 48.6, east: -123.2, north: 48.8)
        func identity(_ bounds: OfflineENCBounds? = nil, overview: Bool = false,
                      versions: [String] = ["sha:CA571548:1:0", "sha:CA571549:2:2"],
                      backgrounds: Set<String> = ["CA471221"]) -> String {
            OfflineENCRasterIdentity.make(viewport: bounds ?? viewport, overview: overview,
                overviewCellIDs: backgrounds, cellVersions: versions)
        }
        let original = identity()
        XCTAssertEqual(original, identity(versions: ["sha:CA571549:2:2", "sha:CA571548:1:0"]))
        XCTAssertNotEqual(original, identity(.init(west: -123.3, south: 48.6, east: -123.2, north: 48.8)))
        XCTAssertNotEqual(original, identity(overview: true))
        XCTAssertNotEqual(original, identity(backgrounds: []))
        XCTAssertNotEqual(original, identity(versions: ["sha:CA571548:1:1", "sha:CA571549:2:2"]))
        XCTAssertNotEqual(original, identity(versions: ["new-sha:CA571548:1:0", "sha:CA571549:2:2"]))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let cache = OfflineENCTileCache(byteLimit: 1024)
        func key(_ scene: String) -> OfflineENCTileCache.Key {
            .init(namespace: "source-and-display-options", scene: scene, address: .init(level: 1, x: 0, y: 0))
        }
        await cache.prepare(keys: [key(original)]) { _ in image }
        await cache.prepare(keys: [key(identity(overview: true))], isOverview: true) { _ in image }
        await cache.prepare(keys: [key(identity())]) { _ in XCTFail("Returning to identical detail must hit cache"); return nil }
        XCTAssertEqual(cache.hitCount, 1)
        XCTAssertEqual(cache.renderCount, 2)
        XCTAssertLessThanOrEqual(cache.byteCount, cache.byteLimit)
        XCTAssertLessThanOrEqual(cache.displayedByteCount, cache.byteLimit)
    }
}

final class OfflineMarkerSizingTests: XCTestCase {
    func testSymbolsShrinkMonotonicallyWithReadableHazardAndTextFloors() {
        let near = OfflineENCMarkerSizing(metresAcross: 1_000)
        XCTAssertEqual(near.ordinary, 1)
        var previous = near
        for distance in stride(from: 1_100.0, through: 24_000, by: 100) {
            let size = OfflineENCMarkerSizing(metresAcross: distance)
            XCTAssertLessThanOrEqual(size.ordinary, previous.ordinary)
            XCTAssertLessThanOrEqual(size.important, previous.important)
            XCTAssertLessThanOrEqual(size.text, previous.text)
            XCTAssertGreaterThanOrEqual(size.important, 0.8)
            XCTAssertGreaterThanOrEqual(size.text * 8, 6)
            XCTAssertGreaterThanOrEqual(size.important, size.ordinary)
            previous = size
        }
        XCTAssertEqual(OfflineENCMarkerSizing(metresAcross: 6_000).ordinary, 0.55, accuracy: 0.001)
        XCTAssertEqual(OfflineENCMarkerSizing(metresAcross: .nan).important, 0.8, accuracy: 0.001)
        XCTAssertEqual(OfflineENCMarkerSizing(metresAcross: 0).text, 1)
    }
}

final class OfflineLabelCollisionTests: XCTestCase {
    func testPriorityAndProtectedSymbolsRegardlessOfSubmissionOrder() {
        let layout = OfflineENCLabelLayout()
        var drawn: [String] = []
        let rect = CGRect(x: 10, y: 10, width: 60, height: 12)
        layout.add(rect: rect, priority: 0) { drawn.append("place") }
        layout.add(rect: rect, priority: 1) { drawn.append("depth") }
        layout.add(rect: rect, priority: 3) { drawn.append("aid") }
        layout.add(rect: CGRect(x: 100, y: 10, width: 20, height: 12), priority: 3) { drawn.append("over hazard") }
        layout.protect(CGRect(x: 105, y: 15, width: 8, height: 8))
        layout.draw()
        XCTAssertEqual(drawn, ["aid"])
    }

    func testMeasuredBoundsAcrossBinsAndNegativeTileEdges() {
        var layout = OfflineENCLabelOccupancy()
        XCTAssertTrue(layout.claim(CGRect(x: -15, y: 28, width: 90, height: 12)))
        XCTAssertFalse(layout.claim(CGRect(x: 70, y: 35, width: 100, height: 10)))
        XCTAssertTrue(layout.claim(CGRect(x: 90, y: 50, width: 20, height: 10)))
        XCTAssertFalse(layout.claim(.null))
    }

    func testStableOrderAndIndependentPasses() {
        for _ in 0..<2 {
            let layout = OfflineENCLabelLayout()
            var drawn: [Int] = []
            for index in 0..<3 {
                layout.add(rect: CGRect(x: 0, y: 0, width: 40, height: 10), priority: 1) { drawn.append(index) }
            }
            layout.add(rect: CGRect(x: 100, y: 100, width: 40, height: 10), priority: 0) { drawn.append(3) }
            layout.draw()
            XCTAssertEqual(drawn, [0, 3])
        }
    }
}

final class OfflineSymbolDensityTests: XCTestCase {
    func testIsolatedAndCrowdedSymbolsKeepReadableFloors() {
        let isolated = OfflineENCSymbolDensity(points: [.zero])
        XCTAssertEqual(isolated.scale(at: .zero, base: 0.8, important: true), 0.8)
        let dense = OfflineENCSymbolDensity(points: Array(repeating: .zero, count: 30))
        XCTAssertEqual(dense.scale(at: .zero, base: 0.8, important: true), 0.7, accuracy: 0.0001)
        XCTAssertEqual(dense.scale(at: .zero, base: 0.55, important: false), 0.45, accuracy: 0.0001)
    }

    func testDensityCrossesBinsAndIsOrderAndTranslationIndependent() {
        let points = [CGPoint(x: 23, y: -1), CGPoint(x: 25, y: 1), CGPoint(x: 30, y: 2)]
        let normal = OfflineENCSymbolDensity(points: points)
        let reversed = OfflineENCSymbolDensity(points: points.reversed())
        let translated = OfflineENCSymbolDensity(points: points.map { CGPoint(x: $0.x + 500, y: $0.y - 300) })
        let scale = normal.scale(at: points[0], base: 1, important: true)
        XCTAssertLessThan(scale, 1)
        XCTAssertEqual(scale, reversed.scale(at: points[0], base: 1, important: true))
        XCTAssertEqual(scale, translated.scale(at: CGPoint(x: 523, y: -301), base: 1, important: true))
        XCTAssertEqual(normal.scale(at: CGPoint(x: 500, y: 500), base: 1, important: true), 1)
    }
}

final class OfflineNearbyGroupingTests: XCTestCase {
    func testAidsAndHazardsArePrioritizedWhileOtherDetailsRemainSeparate() {
        for code in OfflineENCFeature.aidClasses.union([21, 27, 58, 86, 112, 153, 156, 159, 160]) {
            XCTAssertEqual(OfflineENCNearbyGroup.group(for: code), .aidsAndHazards)
        }
        XCTAssertEqual(OfflineENCNearbyGroup.group(for: 129), .soundings)
        for code in [30, 42, 43, 71, 121, 3, 4, 999] {
            XCTAssertEqual(OfflineENCNearbyGroup.group(for: code), .other)
        }
        let input = [129, 75, 43, 153, 129, 9, 71]
        let groups: [OfflineENCNearbyGroup] = [.aidsAndHazards, .soundings, .other]
        let grouped = groups.flatMap { group in input.filter { OfflineENCNearbyGroup.group(for: $0) == group } }
        XCTAssertEqual(grouped, [75, 153, 9, 129, 129, 43, 71])
        XCTAssertEqual(grouped.sorted(), input.sorted(), "Grouping must not drop candidates")
    }
}

final class OfflineLandLabelTests: XCTestCase {
    func testLabelFitsEntirelyInsideScreen() throws {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 700)
        let size = CGSize(width: 140, height: 18)
        let safe = OfflineENCLandLabel.safeViewport(viewport, labelSize: size)
        let land = Path(CGRect(x: -300, y: -200, width: 500, height: 1000))
        let point = try XCTUnwrap(OfflineENCLandLabel.position(in: land, viewport: safe))
        XCTAssertTrue(viewport.contains(CGRect(x: point.x - size.width/2, y: point.y - size.height/2, width: size.width, height: size.height)))
        XCTAssertTrue(land.contains(point))
    }
    func testOversizedLabelIsNotClipped() {
        XCTAssertTrue(OfflineENCLandLabel.safeViewport(CGRect(x: 0, y: 0, width: 100, height: 100), labelSize: CGSize(width: 150, height: 18)).isNull)
    }

    func testPlacementAvoidsHoleAndStaysVisible() throws {
        var land = Path(CGRect(x: 0, y: 0, width: 300, height: 200))
        land.addRect(CGRect(x: 100, y: 50, width: 100, height: 100))
        let viewport = CGRect(x: 60, y: 0, width: 200, height: 200)
        let point = try XCTUnwrap(OfflineENCLandLabel.position(in: land, viewport: viewport))
        XCTAssertTrue(land.contains(point, eoFill: true))
        XCTAssertTrue(viewport.contains(point))
    }
    func testOffscreenLandHasNoLabel() {
        XCTAssertNil(OfflineENCLandLabel.position(in: Path(CGRect(x: 300, y: 300, width: 100, height: 100)), viewport: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }
    func testNearbyNamesDeduplicateAcrossFeatures() {
        let layout = OfflineENCLabelLayout()
        XCTAssertTrue(layout.claimLandName("Mayne Island", at: .zero))
        XCTAssertFalse(layout.claimLandName("MAYNE ISLAND", at: CGPoint(x: 40, y: 40)))
        XCTAssertTrue(layout.claimLandName("Galiano Island", at: CGPoint(x: 40, y: 40)))
    }
}

final class OfflineStationCoverageTests: XCTestCase {
    func testCoverageRejectsOutsideAndNoData() {
        var polygon = Path(CGRect(x: 0, y: 0, width: 100, height: 100))
        polygon.addRect(CGRect(x: 20, y: 20, width: 10, height: 10))
        let coverage = OfflineStationCoverage(included: [polygon], excluded: [Path(CGRect(x: 60, y: 60, width: 20, height: 20))])
        XCTAssertTrue(coverage.contains(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(coverage.contains(CGPoint(x: 110, y: 10)))
        XCTAssertFalse(coverage.contains(CGPoint(x: 25, y: 25)))
        XCTAssertFalse(coverage.contains(CGPoint(x: 70, y: 70)))
        XCTAssertFalse(OfflineStationCoverage(included: [], excluded: []).contains(.zero))
    }
    func testOverlappingCoverageRemainsIncluded() {
        let coverage = OfflineStationCoverage(included: [Path(CGRect(x: 0, y: 0, width: 100, height: 100)), Path(CGRect(x: 50, y: 0, width: 100, height: 100))], excluded: [])
        XCTAssertTrue(coverage.contains(CGPoint(x: 75, y: 50)))
    }
}

@MainActor final class GPSNavigationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fix(speed: Double = 2) -> Fix { Fix(coordinate: .init(latitude: 48.7, longitude: -123.3), accuracy: 5, course: 90, speed: speed, timestamp: now) }
    func testDistanceBearingAndETA() throws {
        let origin = fix()
        let target = Geo.destination(from: origin.coordinate, bearing: 90, meters: 1852)
        let destination = NavigationWaypoint(name: "East", latitude: target.latitude, longitude: target.longitude)
        let result = try XCTUnwrap(NavigationMetrics.calculate(fix: origin, destination: destination, speed: 2, now: now))
        XCTAssertEqual(result.distance, 1852, accuracy: 0.1)
        XCTAssertEqual(result.bearing, 90, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(result.seconds), 926, accuracy: 0.1)
    }
    func testStalePoorAndStoppedFixes() {
        let destination = NavigationWaypoint(name: "Port", latitude: 48.8, longitude: -123.2)
        XCTAssertNil(NavigationMetrics.calculate(fix: fix(), destination: destination, speed: 2, now: now.addingTimeInterval(16)))
        var poor = fix(); poor.accuracy = 101
        XCTAssertFalse(NavigationMetrics.usable(poor, now: now))
        let stopped = NavigationMetrics.calculate(fix: fix(speed: 0), destination: destination, speed: 0, now: now)
        XCTAssertNotNil(stopped)
        XCTAssertNil(stopped?.seconds)
        XCTAssertNil(stopped?.course)
    }
    func testWaypointPersistenceEditingAndDeletion() {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: "navigation.waypoints.v1") }
        let store = NavigationStore(defaults: defaults)
        var waypoint = NavigationWaypoint(name: suite, latitude: 48.7, longitude: -123.3)
        XCTAssertTrue(store.save(waypoint))
        waypoint.name = "Renamed"
        XCTAssertTrue(store.save(waypoint))
        let restored = NavigationStore(defaults: defaults)
        XCTAssertEqual(restored.waypoints, [waypoint])
        restored.activeID = waypoint.id
        restored.delete(waypoint)
        XCTAssertNil(restored.active)
        XCTAssertTrue(NavigationStore(defaults: defaults).waypoints.isEmpty)
    }
    func testInvalidCoordinatesAndCorruptStorageAreRejected() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: "navigation.waypoints.v1") }
        let store = NavigationStore(defaults: defaults)
        XCTAssertFalse(store.save(.init(name: "Bad", latitude: 91, longitude: 0)))
        let data = Data("corrupt".utf8)
        defaults.set(data, forKey: "navigation.waypoints.v1")
        let broken = NavigationStore(defaults: defaults)
        XCTAssertNotNil(broken.error)
        XCTAssertFalse(broken.save(.init(name: "Port", latitude: 48, longitude: -123)))
        XCTAssertEqual(defaults.data(forKey: "navigation.waypoints.v1"), data)
    }
    func testSpeedSmoothingAndDuplicateFixes() {
        let store = NavigationStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.ingest(fix(speed: 2), now: now)
        store.ingest(fix(speed: 20), now: now)
        XCTAssertEqual(store.speed, 2)
        var next = fix(speed: 4); next.timestamp = now.addingTimeInterval(2)
        store.ingest(next, now: next.timestamp)
        XCTAssertEqual(store.speed, 3)
        store.ingest(next, now: now.addingTimeInterval(30))
        XCTAssertNil(store.speed)
    }
    func testChartTapProjectionRoundTrip() {
        let projector = ENCProjector(bounds: .init(west: -124, south: 48, east: -123, north: 49), size: .init(width: 390, height: 700), zoom: 3, pan: .init(width: 120, height: -60))
        let coordinate = ChartCoordinate(longitude: -123.6, latitude: 48.6)
        let restored = projector.coordinate(at: projector.screen(coordinate))
        XCTAssertEqual(restored.latitude, coordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(restored.longitude, coordinate.longitude, accuracy: 0.000001)
    }
}
