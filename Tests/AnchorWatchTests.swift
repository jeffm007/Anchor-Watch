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
        XCTAssertFalse(AnchorMath.suggestions(b, scope: scope, c, r, units: .feet, tideTurn: turn).contains { $0.contains("reverses") })
        c.currentDirection = .against
        XCTAssertTrue(AnchorMath.suggestions(b, scope: scope, c, r, units: .feet, tideTurn: turn).contains { $0.contains("reverses") })
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
        let json = #"{"stations":[{"id":"PUG1719","name":"Spieden Channel","lat":48.6,"lng":-123.1,"currbin":19},{"id":"PUG1719","name":"Spieden Channel","lat":48.6,"lng":-123.1,"currbin":7}]}"#
        XCTAssertEqual(try CurrentMath.parseStations(Data(json.utf8)).count, 1)
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
        XCTAssertEqual(e.snapshot?.headline, "Finding anchor — circle alarm not armed")
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
