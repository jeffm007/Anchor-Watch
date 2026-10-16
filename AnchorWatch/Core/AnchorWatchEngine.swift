import CoreLocation
import MapKit
import UIKit
import UserNotifications

enum Units: String, CaseIterable, Identifiable {
    case feet = "Feet", meters = "Meters"
    var id: String { rawValue }

    func format(_ meters: Double) -> String {
        switch self {
        case .feet: return String(format: "%.0f ft", meters * 3.28084)
        case .meters: return String(format: "%.0f m", meters)
        }
    }

    /// Air and water temperature: °F alongside feet, °C alongside metres.
    func formatTemp(_ celsius: Double) -> String {
        self == .feet ? String(format: "%.0f°F", celsius * 9 / 5 + 32) : String(format: "%.0f°C", celsius)
    }

    /// One decimal place, for small values like tide heights.
    func formatTenths(_ meters: Double) -> String {
        String(format: "%.1f %@", meters * perMeter, symbol)
    }

    /// Display units per metre, for steppers and text fields.
    var perMeter: Double { self == .feet ? 3.28084 : 1 }
    var symbol: String { self == .feet ? "ft" : "m" }
}

enum AlarmReason: Equatable {
    case outsideCircle(distance: Double)
    case gpsLost
    /// Fixes keep arriving but none is accurate enough to tell whether the anchor is holding.
    case gpsPoor
    case anchorUnconfirmed
    case lowBattery(level: Double)

    var message: String {
        switch self {
        case .outsideCircle: return "Boat has left the alarm circle"
        case .gpsLost: return "GPS signal lost"
        case .gpsPoor: return "GPS too inaccurate to watch the anchor"
        case .anchorUnconfirmed: return "Circle alarm OFF — place the anchor on the chart"
        case .lowBattery(let level): return String(format: "Phone battery %.0f%% and not charging", level * 100)
        }
    }

    /// Silencing one kind of alarm must not silence the others.
    var kind: String {
        switch self {
        case .outsideCircle: return "outside"
        case .gpsLost: return "gpsLost"
        case .gpsPoor: return "gpsPoor"
        case .anchorUnconfirmed: return "anchorUnconfirmed"
        case .lowBattery: return "battery"
        }
    }

    /// A more serious alarm replaces a lesser one that is already sounding.
    var priority: Int {
        switch self {
        case .outsideCircle: return 3
        case .gpsLost, .gpsPoor, .anchorUnconfirmed: return 2
        case .lowBattery: return 1
        }
    }

    /// How long Silence holds off a repeat. A flat battery will not fix itself, so it nags less often.
    var snooze: TimeInterval {
        if case .lowBattery = self { return 600 }
        return 60
    }
}

/// Holds all anchor-watch state and decides when to alarm. Pure logic: feed it
/// fixes with `ingest(_:)`, which is also how the unit tests drive it.
@MainActor
final class AnchorWatchEngine: ObservableObject {
    enum SourceKind: String, CaseIterable, Identifiable {
        case simulator = "Simulator", gps = "iPhone GPS"
        var id: String { rawValue }
    }

    // MARK: Published state
    @Published private(set) var fix: Fix?
    /// Latest raw callback for diagnostics; navigation uses only accepted `fix` values.
    @Published private(set) var rawFix: Fix?
    @Published private(set) var track: [Fix] = [] { didSet { trackRevision &+= 1 } }
    private(set) var trackRevision = 0
    @Published private(set) var anchor: CLLocationCoordinate2D?
    /// How far off the anchor point may be from GPS error alone (metres): the average accuracy of the
    /// fixes averaged into it. Nil when the anchor was placed by hand.
    @Published private(set) var anchorUncertainty: Double?
    /// How the last drop or Anchor → Boat worked out the bow position, for the note under the controls.
    @Published private(set) var anchorPlacement: AnchorPlacement.Result?
    /// Where the swing says the anchor is, once there's enough track to tell.
    @Published private(set) var anchorEstimate: AnchorEstimate.Result?
    /// Why there's no estimate yet.
    @Published private(set) var estimatePending: AnchorEstimate.Pending?
    private var lastEstimate = Date.distantPast
    /// Set when the rolling swing fits show the anchor moving steadily: a red warning, before the boat leaves the circle.
    @Published private(set) var anchorDrift: AnchorDrift.Result?
    /// Metres per minute the boat is steadily getting further from the anchor, past its earlier swing.
    @Published private(set) var distanceTrend: Double?
    /// (Minutes since the drop, distance) once the boat has settled, for `distanceTrend`.
    private var distanceLog: [(minute: Double, distance: Double)] = []

    /// One answer to "is the anchor holding?", worst first.
    enum WatchState: Equatable {
        case notAnchored
        /// Settled drop with no wind to place the mark: the circle alarm waits for the swing fit.
        case awaitingFix
        case acquiringGPS
        case gpsInterrupted
        case retrieving
        case alarm(AlarmReason)
        /// Outside the circle, including after the alarm was silenced.
        case outside(distance: Double)
        case dragging(AnchorDrift.Result)
        case movingAway(metersPerMinute: Double)
        case holding
    }

    var watchState: WatchState {
        guard anchor != nil || retrieveTarget != nil else { return .notAnchored }
        if let alarm { return .alarm(alarm) }
        if !hasFreshPosition { return lastUsableFix == nil && clock().timeIntervalSince(acquisitionStarted) <= gpsLostAfter ? .acquiringGPS : .gpsInterrupted }
        if retrieveTarget != nil { return .retrieving }
        if awaitingSwingFix { return .awaitingFix }
        if let distance, distance > radius { return .outside(distance: distance) }
        if let anchorDrift { return .dragging(anchorDrift) }
        if let distanceTrend { return .movingAway(metersPerMinute: distanceTrend) }
        return .holding
    }
    /// Recent rolling-fit centres, and how many fits in a row have shown drift.
    private(set) var driftSamples: [AnchorDrift.Sample] = []
    private var driftStreak = 0
    /// Seconds between swing fits.
    let estimateInterval: TimeInterval = 60
    @Published private(set) var distance: Double?
    @Published private(set) var maxDistance = 0.0
    /// Fixes received per second over the last ~10 s, to diagnose slow GPS delivery.
    @Published private(set) var updateRate = 0.0
    private var arrivals: [Date] = []
    private var recent: [Fix] = []
    /// The last couple of minutes of fixes, to tell which way the boat came in on.
    private var approach: [Fix] = []
    /// The approach direction is read from the fix about this long before the drop.
    let approachLookback: TimeInterval = 60

    /// Accuracy (metres) above which the anchor point is flagged as unreliable (~25 ft).
    let goodAccuracy = 8.0
    /// Fixes worse than this (~165 ft) are ignored for distance, track and the alarm.
    let usableAccuracy = 50.0
    /// Stricter for an external receiver (~100 ft): a Garmin GLO 2 without a satellite lock reports about ±50 m
    /// while its position wanders hundreds of feet.
    let usableExternalAccuracy = 30.0
    func usableLimit(for fix: Fix?) -> Double { fix?.external == true ? usableExternalAccuracy : usableAccuracy }
    /// Seconds with fixes arriving but none usable before the "GPS too inaccurate" alarm.
    let gpsPoorAfter: TimeInterval = 60
    /// A fix counts as outside the circle only if it is beyond the radius by more than its own accuracy,
    /// up to this fraction of the radius, so one noisy reading can't set off the alarm.
    let accuracyDiscountCap = 0.3
    /// Seconds of recent fixes averaged when setting the anchor.
    let averagingWindow: TimeInterval = 8

    /// Direction the bow points, degrees true. A boat on its rode lies to the anchor, so while
    /// anchored the bow points at it; GPS course is meaningless when barely moving.
    var heading: Double? {
        if hasFreshPosition, let anchor, let fix, (distance ?? 0) > 1 { return Geo.bearing(from: fix.coordinate, to: anchor) }
        return fix?.course
    }

    var gpsIsPoor: Bool { (rawFix?.accuracy ?? .infinity) > goodAccuracy }
    /// Too inaccurate to anchor with at all.
    var gpsIsUnusable: Bool { !hasFreshPosition || (rawFix?.accuracy ?? .infinity) > usableLimit(for: rawFix) }
    let maximumFixAge: TimeInterval = 15
    var lastUsableFixAge: TimeInterval? { lastUsableFix.map { max(0, clock().timeIntervalSince($0)) } }
    var hasFreshPosition: Bool { lastUsableFixAge.map { $0 <= maximumFixAge } ?? false }
    var gpsFreshnessText: String {
        lastUsableFixAge.map { "Last usable GPS fix \(Int($0)) seconds ago" } ?? "No fresh usable GPS fix yet"
    }

    /// Average of the last few seconds of fixes, to smooth out single-fix GPS error.
    private var averagedPosition: CLLocationCoordinate2D? {
        guard let newest = recent.last else { return nil }
        let window = recent.filter { newest.timestamp.timeIntervalSince($0.timestamp) <= averagingWindow }
        let n = Double(window.count)
        return CLLocationCoordinate2D(latitude: window.map(\.coordinate.latitude).reduce(0, +) / n,
                                      longitude: window.map(\.coordinate.longitude).reduce(0, +) / n)
    }

    /// Average accuracy of the fixes in `averagedPosition`. GPS errors drift slowly, so averaging a few
    /// seconds of fixes barely shrinks the error; this doesn't pretend it does.
    private var averagedAccuracy: Double? {
        guard let newest = recent.last else { return nil }
        let window = recent.filter { newest.timestamp.timeIntervalSince($0.timestamp) <= averagingWindow }
        return window.map(\.accuracy).reduce(0, +) / Double(window.count)
    }
    @Published private(set) var alarm: AlarmReason?
    @Published private(set) var anchorDropped: Date?
    /// Where the anchor was first marked when dropped. Kept as a faded mark once the anchor is moved from it,
    /// until it's raised.
    @Published private(set) var originalAnchor: CLLocationCoordinate2D?
    @Published var radius = 30.0 { didSet { save() } }

    @Published var scope = ScopeSettings() {
        didSet {
            saveScope()
            // A new depth reading belongs to the tide at that moment; the live depth follows the tide from there.
            if scope.depth != oldValue.depth && !loading { recordDepthReading() }
            if scope != oldValue { lastOutlook = .distantPast }
            if scope != oldValue { followRode() }
        }
    }

    private(set) var depthReading: DepthReading? {
        get { defaults.data(forKey: "anchorwatch.depthReading.v1").flatMap { try? JSONDecoder().decode(DepthReading.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "anchorwatch.depthReading.v1") }
    }

    private func recordDepthReading() {
        depthReading = DepthReading(depth: scope.depth, measured: clock(),
                                    stationID: tide.map { DepthReading.stationKey($0.station) }, tideHeight: tideNow)
    }

    /// Explicitly confirms a new sounder reading, even when its numeric value is unchanged.
    func setDepthReading(_ depth: Double) {
        guard depth.isFinite, depth >= 0 else { return }
        scope.depth = depth
        recordDepthReading()
        lastOutlook = .distantPast
        followRode()
    }

    func depth(at time: Date) -> Double {
        guard usable("tide") || usingSimulatedTide else { return scope.depth }
        return depthReading?.depth(at: time, tide: tide) ?? scope.depth
    }
    var liveDepth: Double { depth(at: clock()) }

    func plannerScope(at time: Date? = nil, fallbackRise: Double = 0) -> ScopeSettings {
        var value = scope
        value.depth = time.flatMap { (usable("tide") || usingSimulatedTide) ? depthReading?.depth(at: $0, tide: tide) : nil } ?? max(0, liveDepth + fallbackRise)
        value.tideRise = 0
        return value
    }

    func plannerConditions(_ edited: AnchorConditions) -> AnchorConditions {
        var value = edited
        value.bottom = anchorBottom
        return value
    }
    var depthReferenceDetail: String {
        guard let reading = depthReading else { return "Reading time unknown. Confirm a new sounder reading to follow the tide." }
        let time = reading.measured.formatted(date: .abbreviated, time: .shortened)
        guard (usable("tide") || usingSimulatedTide), reading.depth(at: clock(), tide: tide) != nil else {
            return "Sounder reading from \(time). Tide adjustment unavailable; showing the entered depth."
        }
        return "Estimated now from sounder reading at \(time), adjusted using \(tide?.station.name ?? "tide predictions")."
    }

    func applyTideSnapshot(_ snapshot: TideSnapshot, cached: Bool = false) {
        if environmentLocation == nil { bindEnvironment(to: anchor ?? fix?.coordinate ?? snapshot.station.coordinate) }
        tide = snapshot
        record("tide", phase: cached ? .cached : .ready, fetched: snapshot.fetched,
               from: snapshot.events.map(\.time).min(), until: snapshot.events.map(\.time).max(),
               station: snapshot.station.sourceName + " · " + snapshot.station.name + " (" + snapshot.station.id + ")")
        lastOutlook = .distantPast
    }

    /// Scope with the rode assumed out and the live depth: drops as the tide rises.
    var liveScopeRatio: Double? {
        let height = liveDepth + scope.bowHeight
        return height > 0 ? rodeOut / height : nil
    }
    @Published var boat = BoatProfile() {
        didSet {
            saveBoat()
            lastOutlook = .distantPast
            if !loading { followRode() }
        }
    }

    // MARK: Is the phone ready to keep watch?
    @Published private(set) var batteryLevel: Float?
    @Published private(set) var charging = false
    @Published private(set) var volume: Float?
    @Published private(set) var externalAudioRoute: String?
    @Published private(set) var audioFailure: String?
    @Published private(set) var notificationsAllowed: Bool?
    @Published private(set) var locationAlways: Bool?
    @Published private(set) var liveActivityState = LiveActivityState.idle
    private var lowBatteryNoticed = false
    private var lastPermissionCheck = Date.distantPast

    /// True while an anchor is set, i.e. while this phone is on watch.
    var armed: Bool { anchor != nil }

    var readinessInput: ReadinessInput {
        ReadinessInput(volume: volume, audioRoute: externalAudioRoute, batteryLevel: batteryLevel, charging: charging,
                       notificationsAllowed: notificationsAllowed,
                       locationAlways: sourceKind == .gps ? locationAlways : nil,
                       accuracy: hasFreshPosition ? fix?.accuracy : nil, radius: radius, liveActivity: armed ? liveActivityState : nil,
                       audioFailure: audioFailure,
                       goodAccuracy: goodAccuracy, usableAccuracy: usableLimit(for: fix))
    }

    var watchChecks: [WatchCheck] {
        var checks = Readiness.checks(readinessInput, format: units.format)
        if !hasFreshPosition {
            checks.removeAll { $0.id == "gps" }
            checks.append(WatchCheck(id: "gps", title: "Fresh GPS position unavailable", detail: gpsFreshnessText,
                                     state: armed ? .critical : .warning))
        }
        if awaitingSwingFix {
            checks.append(WatchCheck(id: "placement", title: "Circle alarm OFF", detail: "Confirm the anchor position on the chart to enable circle monitoring.", state: .critical))
        }
        if armed && !rodeConfirmed {
            checks.append(WatchCheck(id: "rode", title: "Deployed rode not confirmed", detail: "Confirm the actual amount paid out on the Anchor tab.", state: .warning))
        }
        return checks
    }
    var watchProblems: [WatchCheck] { watchChecks.filter(\.isProblem) }

    /// Sounds the siren for a few seconds. With a delay you can lock the phone or switch to another app first
    /// to prove the siren works from the background. The audio engine is armed for the test even with no anchor set.
    func testSiren(after delay: TimeInterval = 0) {
        let wasArmed = armed
        if !wasArmed { player.arm() }
        pollDevice()
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            testingSiren = true                      // shows on the lock screen too, so the whole alarm chain can be checked
            player.test(duration: 4)
            pollDevice()
            try? await Task.sleep(for: .seconds(4))
            testingSiren = false
            try? await Task.sleep(for: .seconds(1))
            if !wasArmed && !armed { player.disarm() }
        }
    }

    /// True while the test siren is sounding.
    @Published var testingSiren = false

    /// Called by the battery notifications, and directly by tests.
    func setBattery(level: Float?, charging nowCharging: Bool) {
        let wasCharging = charging
        batteryLevel = level
        charging = nowCharging
        if nowCharging { lowBatteryNoticed = false }
        if wasCharging && !nowCharging && armed {
            player.notice(title: "Phone unplugged", message: "Anchor Watch is running on battery" + (level.map { String(format: " (%.0f%%)", $0 * 100) } ?? "") + ".")
        }
    }

    private func readBattery() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel >= 0 ? device.batteryLevel : nil
        setBattery(level: level, charging: device.batteryState == .charging || device.batteryState == .full)
    }

    private func checkBattery() {
        guard armed, let level = batteryLevel, !charging else { return }
        if level <= BatteryAdvice.alarmLevel {
            trigger(.lowBattery(level: Double(level)))
        } else if level <= BatteryAdvice.noticeLevel, !lowBatteryNoticed {
            lowBatteryNoticed = true
            player.notice(title: "Phone battery low", message: String(format: "%.0f%% and not charging. Plug in to keep watching the anchor.", level * 100))
        }
    }

    /// Volume and audio output can change at any moment; publish only when they do.
    private func pollDevice() {
        let v = player.volume
        if volume != v { volume = v }
        let route = player.externalRoute
        if externalAudioRoute != route { externalAudioRoute = route }
        if audioFailure != player.audioFailure { audioFailure = player.audioFailure }
    }

    private func refreshPermissionsIfDue() {
        guard Date().timeIntervalSince(lastPermissionCheck) > 30 else { return }
        lastPermissionCheck = Date()
        locationAlways = CLLocationManager().authorizationStatus == .authorizedAlways
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    // MARK: Environmental provenance and location binding

    @Published private(set) var environmentRecords: [String: EnvironmentRecord] = [:]
    private(set) var environmentLocation: CLLocationCoordinate2D?
    private(set) var environmentGeneration = 0
    static let environmentTravelLimit = 2_000.0
    // Injectable provider boundaries keep location races and offline states deterministic in tests.
    var fetchWind: (CLLocationCoordinate2D) async throws -> WindSeries = { point in
        guard let series = try await WindService.fetch([point]).first else { throw URLError(.cannotParseResponse) }
        return series
    }
    var fetchTide: (CLLocationCoordinate2D) async throws -> (snapshot: TideSnapshot, fromCache: Bool) = { try await TideService.snapshot(near: $0) }
    var fetchCurrent: (CLLocationCoordinate2D) async throws -> CurrentSnapshot? = { try await CurrentService.snapshot(near: $0) }

    /// Nearby repositioning reuses data; meaningful travel invalidates data and all older in-flight requests.
    @discardableResult
    func bindEnvironment(to point: CLLocationCoordinate2D) -> Int {
        guard environmentLocation.map({ Geo.distance($0, point) > Self.environmentTravelLimit }) ?? true else { return environmentGeneration }
        let traveled = environmentLocation != nil
        environmentLocation = point
        environmentGeneration += 1
        windHere = nil; tide = nil; currents = nil
        observations = []; observationsChecked = nil; nwsAlerts = []; nwsChecked = nil
        windGrid = []; gridTask?.cancel()
        outlook = []; hourlyHolding = []; hiddenOutlook = []; lockedOutlook = []
        windFetching = false; tideFetching = false; currentFetching = false; observationsFetching = false; alertsFetching = false
        usingSimulatedTide = false
        lastWindAttempt = .distantPast; lastTideAttempt = .distantPast; lastCurrentAttempt = .distantPast
        lastObservationAttempt = .distantPast; lastAlertAttempt = .distantPast; lastOutlook = .distantPast
        if traveled { depthReading = nil }
        environmentRecords = [
            "wind": EnvironmentRecord(source: "Open-Meteo", latitude: point.latitude, longitude: point.longitude, maxAge: 1800),
            "tide": EnvironmentRecord(source: "NOAA / CHS tides", latitude: point.latitude, longitude: point.longitude, maxAge: 6 * 3600),
            "current": EnvironmentRecord(source: "NOAA currents", latitude: point.latitude, longitude: point.longitude, maxAge: 6 * 3600),
            "observations": EnvironmentRecord(source: "NOAA observations", latitude: point.latitude, longitude: point.longitude, maxAge: 600),
            "alerts": EnvironmentRecord(source: "NWS alerts", latitude: point.latitude, longitude: point.longitude, maxAge: 900)
        ]
        if let data = defaults.data(forKey: "anchorwatch.windSnapshot.v1"),
           let saved = try? JSONDecoder().decode(WindSeries.self, from: data),
           Geo.distance(saved.coordinate, point) <= Self.environmentTravelLimit {
            acceptWind(saved, cached: true)
        }
        return environmentGeneration
    }

    private func record(_ name: String, phase: EnvironmentRecord.Phase, fetched: Date? = nil,
                        from: Date? = nil, until: Date? = nil, station: String? = nil) {
        guard var value = environmentRecords[name] else { return }
        value.phase = phase
        if phase == .noCoverage { value.fetched = nil; value.validFrom = nil; value.validUntil = nil; value.station = nil }
        if let fetched { value.fetched = fetched; value.validFrom = from; value.validUntil = until; value.station = station }
        environmentRecords[name] = value
    }
    private func acceptWind(_ series: WindSeries, cached: Bool = false) {
        windHere = series
        record("wind", phase: cached ? .cached : .ready, fetched: series.fetched,
               from: series.samples.map(\.time).min(), until: series.samples.map(\.time).max())
        if !cached { defaults.set(try? JSONEncoder().encode(series), forKey: "anchorwatch.windSnapshot.v1") }
        lastOutlook = .distantPast
    }
    private func usable(_ name: String) -> Bool { environmentRecords[name]?.isUsable(at: clock()) ?? false }
    var environmentCoverage: EnvironmentCoverage {
        let now = clock()
        let tideEnd = usable("tide") ? EnvironmentCoverage.through(tide?.events.map(\.time) ?? [], now: now, maxGap: 13 * 3600) : nil
        let depthEnd = waterForecast.last?.time
        let tideDepthEnd = tideEnd.flatMap { t in depthEnd.map { min(t, $0) } }
        return EnvironmentCoverage(
            windThrough: usable("wind") ? EnvironmentCoverage.through(windHere?.samples.map(\.time) ?? [], now: now, maxGap: 5400, startTolerance: 1800) : nil,
            tideThrough: tideDepthEnd,
            currentThrough: usable("current") ? EnvironmentCoverage.through(currents?.events.map(\.time) ?? [], now: now, maxGap: 13 * 3600) : nil,
            now: now, refreshUncertain: ["wind", "tide", "current"].contains { environmentRecords[$0]?.phase != .ready })
    }
    var outlookSummaryTitle: String {
        hiddenOutlookCount > 0 ? "\(hiddenOutlookCount) warnings hidden" : "No issues found in available data"
    }
    var environmentDetails: [String] {
        ["wind", "tide", "current", "observations", "alerts"].compactMap { environmentRecords[$0]?.description(at: clock()) }
    }
    var adviceAssumptions: String {
        "Advice uses the entered depth wherever tide/depth coverage is missing; missing current uses an assumed 0.5 kt and waves use an assumed 0.3 m. Swing direction omits current when it is unavailable. Boat and seabed settings are user inputs. Chart downloads do not establish complete offline chart coverage. GPS circle monitoring operates independently of forecast downloads."
    }

    func refreshWind() async {
        guard let point = anchor ?? fix?.coordinate else { return }
        let generation = bindEnvironment(to: point)
        record("wind", phase: .loading)
        do {
            let series = try await fetchWind(point)
            guard generation == environmentGeneration else { return }
            guard Geo.distance(series.coordinate, point) <= Self.environmentTravelLimit else { throw URLError(.badServerResponse) }
            acceptWind(series)
        } catch {
            guard generation == environmentGeneration else { return }
            record("wind", phase: .failed(error.localizedDescription))
        }
    }

    func refreshCurrent() async {
        guard let point = anchor ?? fix?.coordinate else { return }
        let generation = bindEnvironment(to: point)
        record("current", phase: .loading)
        do {
            let result = try await fetchCurrent(point)
            guard generation == environmentGeneration else { return }
            currents = result
            if let result {
                record("current", phase: result.fromCache == true ? .cached : .ready, fetched: result.fetched,
                       from: result.events.map(\.time).min(), until: result.events.map(\.time).max(), station: result.station.name + " (" + result.station.id + ")")
            } else { record("current", phase: .noCoverage) }
            lastOutlook = .distantPast
        } catch {
            guard generation == environmentGeneration else { return }
            record("current", phase: .failed(error.localizedDescription))
        }
    }

    func retryEnvironment() {
        lastWindAttempt = .distantPast; lastTideAttempt = .distantPast; lastCurrentAttempt = .distantPast
        lastObservationAttempt = .distantPast; observationsChecked = nil
        lastAlertAttempt = .distantPast; nwsChecked = nil
        refreshObservationsIfDue(); refreshAlertsIfDue()
        Task { await refreshWind(); await refreshTide(); await refreshCurrent() }
    }

    // MARK: Live observations (NOAA buoys and coastal stations)
    @Published private(set) var observations: [StationObservation] = []
    @Published private(set) var observationsChecked: Date?
    private var observationsFetching = false
    private var lastObservationAttempt = Date.distantPast

    /// Refreshes every 10 minutes (stations report about every 10 to 60); throttles itself.
    private func refreshObservationsIfDue() {
        guard !observationsFetching, let point = anchor ?? fix?.coordinate else { return }
        let sinceAttempt = Date().timeIntervalSince(lastObservationAttempt)
        let sinceSuccess = Date().timeIntervalSince(observationsChecked ?? .distantPast)
        guard sinceAttempt > 60, sinceSuccess > 600 else { return }
        observationsFetching = true
        lastObservationAttempt = Date()
        let generation = environmentGeneration
        record("observations", phase: .loading)
        Task {
            defer { if generation == environmentGeneration { observationsFetching = false } }
            do {
                let result = try await ObservationService.fetchNearbyResult(point)
                let stations = result.stations
                guard generation == environmentGeneration else { return }
                observations = stations
                observationsChecked = clock()
                record("observations", phase: result.warnings.isEmpty ? .ready : .partial(result.warnings.joined(separator: "; ")), fetched: clock(), from: stations.map(\.time).min() ?? clock(), until: (stations.map(\.time).max() ?? clock()) + 3600,
                       station: stations.map { $0.id + " " + $0.name }.joined(separator: ", "))
            } catch {
                guard generation == environmentGeneration else { return }
                record("observations", phase: .failed(error.localizedDescription))
            }
        }
    }

    /// Zooms the chart out to show the boat and the nearby stations, with the overlay turned on.
    @Published private(set) var fitStationsTick = 0

    func fitStations() {
        windOverlayOn = true
        fitStationsTick += 1
    }

    /// Wind actually being measured nearby (the closest station reporting it).
    var freshObservations: [StationObservation] { observations.filter { clock().timeIntervalSince($0.time) >= -60 && clock().timeIntervalSince($0.time) <= 3 * 3600 } }
    var activeAlerts: [NWSAlert] { nwsAlerts.filter { ($0.ends ?? .distantFuture) > clock() } }
    var observedWind: StationObservation? { freshObservations.first { $0.windSpeed != nil } }

    /// Set when a nearby station reports gusts at or above the warning limit.
    var observedGustAlert: (station: StationObservation, gust: Double)? {
        ObservationMath.gustAlert(freshObservations, limit: gustLimit)
    }

    // MARK: National Weather Service alerts
    @Published private(set) var nwsAlerts: [NWSAlert] = []
    /// When alerts were last successfully checked, so the screen can say "no alerts" with confidence.
    @Published private(set) var nwsChecked: Date?
    private var alertsFetching = false
    private var lastAlertAttempt = Date.distantPast
    private let knownAlertsKey = "anchorwatch.knownAlerts"

    /// Polls every 15 minutes; called from the 1 s watchdog, so it throttles itself.
    private func refreshAlertsIfDue() {
        guard !alertsFetching, let point = anchor ?? fix?.coordinate else { return }
        let sinceAttempt = Date().timeIntervalSince(lastAlertAttempt)
        let sinceSuccess = Date().timeIntervalSince(nwsChecked ?? .distantPast)
        guard sinceAttempt > 60, sinceSuccess > 900 else { return }
        alertsFetching = true
        lastAlertAttempt = Date()
        let generation = environmentGeneration
        record("alerts", phase: .loading)
        Task {
            defer { if generation == environmentGeneration { alertsFetching = false } }
            do {
                let alerts = try await AlertService.fetch(near: point)
                guard generation == environmentGeneration else { return }
                nwsAlerts = alerts
                nwsChecked = clock()
                record("alerts", phase: .ready, fetched: clock(), from: clock(), until: clock() + 900)
                notifyAboutNew(alerts)
            } catch {
                guard generation == environmentGeneration else { return }
                record("alerts", phase: .failed(error.localizedDescription))
            }
        }
    }

    /// One banner per alert, ever: remembers which alert IDs it has already announced.
    private func notifyAboutNew(_ alerts: [NWSAlert]) {
        var known = Set(defaults.stringArray(forKey: knownAlertsKey) ?? [])
        for alert in alerts where !known.contains(alert.id) {
            known.insert(alert.id)
            if alert.isUrgentForBoaters && !muteAdvisoryNotifications { player.notice(title: alert.event, message: alert.headline) }
        }
        defaults.set(Array(known.suffix(200)), forKey: knownAlertsKey)
    }

    // MARK: Wind (Open-Meteo forecasts)
    @Published var windOverlayOn = false
    /// Hours ahead of now shown by the overlay.
    @Published var windHour = 0.0
    /// Forecast points covering the visible map, for the arrow overlay.
    @Published private(set) var windGrid: [WindSeries] = []
    /// Forecast at the anchorage (or the boat, before anchoring), for the readout and warnings.
    @Published private(set) var windHere: WindSeries?
    @Published var gustLimit = 25.0 { didSet { defaults.set(gustLimit, forKey: "anchorwatch.gustLimit") } }

    private var windCache: [String: WindSeries] = [:]
    private var windFetching = false
    private var lastWindAttempt = Date.distantPast
    private var gridTask: Task<Void, Never>?

    /// The wind now: the simulator's own in a physics scenario (so placement and the swing fit see the wind the
    /// simulated boat feels), otherwise the forecast.
    var windNow: WindSample? {
        if sourceKind == .simulator, let simulated = simulator.windNow { return simulated }
        return usable("wind") ? windHere?.sample(atHour: 0, from: clock()) : nil
    }

    var windForAdvice: WindSeries? { usable("wind") ? windHere : nil }
    var alertsAreCurrent: Bool { usable("alerts") }

    var windAlerts: [WindAlert] {
        guard usable("wind"), let windHere else { return [] }
        return WindAdvice.alerts(windHere, gustLimit: gustLimit)
    }

    /// Reloads the forecast at the anchorage; called from the 1 s watchdog, so it throttles itself.
    private func refreshWindHereIfDue() {
        guard !windFetching, anchor != nil || fix != nil else { return }
        let age = Date().timeIntervalSince(windHere?.fetched ?? .distantPast)
        let sinceAttempt = Date().timeIntervalSince(lastWindAttempt)
        guard (windHere == nil && sinceAttempt > 60) || age > 1800 && sinceAttempt > 60 else { return }
        windFetching = true
        lastWindAttempt = Date()
        let generation = environmentGeneration
        Task {
            defer { if generation == environmentGeneration { windFetching = false } }
            await refreshWind()
        }
    }

    /// Loads forecasts for the lattice points under the visible map (debounced; cached for an hour).
    private var windRegion: MKCoordinateRegion?
    private var lastGridAttempt = Date.distantPast
    func requestWindGrid(for region: MKCoordinateRegion) {
        windRegion = region
        lastGridAttempt = Date()
        gridTask?.cancel()
        gridTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let points = WindGrid.lattice(for: region)
            let key: (CLLocationCoordinate2D) -> String = { "\($0.latitude),\($0.longitude)" }
            let stale = Date().addingTimeInterval(-3600)
            let missing = points.filter { (windCache[key($0)]?.fetched ?? .distantPast) < stale }
            if !missing.isEmpty, let fresh = try? await WindService.fetch(missing) {
                for series in fresh { windCache[key(series.coordinate)] = series }
            }
            guard !Task.isCancelled else { return }
            windCache = windCache.filter { $0.value.fetched >= stale }
            if windCache.count > 256 {
                windCache = Dictionary(uniqueKeysWithValues: windCache.sorted { $0.value.fetched > $1.value.fetched }.prefix(256).map { ($0.key, $0.value) })
            }
            windGrid = points.compactMap { windCache[key($0)] }
        }
    }

    // MARK: Tide (NOAA predictions for the station nearest the boat)
    @Published private(set) var tide: TideSnapshot?
    @Published private(set) var tideStatus = ""
    @Published private(set) var tideIsSaved = false
    @Published var tideWindowHours = 12.0

    /// Expected rise above the current water level within the chosen window.
    var tideRiseEstimate: Double? {
        guard usable("tide") || usingSimulatedTide else { return nil }
        return tide.flatMap { TideMath.rise(from: clock(), hours: tideWindowHours, events: $0.events) }
    }

    var tideNow: Double? { guard usable("tide") || usingSimulatedTide else { return nil }; return tide.flatMap { TideMath.height(at: clock(), events: $0.events) } }

    func refreshTide() async {
        guard let point = anchor ?? fix?.coordinate else {
            tideStatus = "Waiting for a GPS position to find the nearest tide station…"
            return
        }
        let generation = bindEnvironment(to: point)
        record("tide", phase: .loading)
        tideStatus = "Finding the nearest tide station…"
        do {
            let result = try await fetchTide(point)
            guard generation == environmentGeneration else { return }
            applyTideSnapshot(result.snapshot, cached: result.fromCache)
            tideIsSaved = result.fromCache
            tideStatus = ""
        } catch {
            guard generation == environmentGeneration else { return }
            tideStatus = error.localizedDescription
            if let error = error as? TideService.TideError, case .noCoverage = error {
                tide = nil
                record("tide", phase: .noCoverage)
            } else { record("tide", phase: .failed(error.localizedDescription)) }
        }
    }

    private var tideFetching = false
    private var lastTideAttempt = Date.distantPast

    /// Loads tides for the main screen; called from the 1 s watchdog, so it throttles itself.
    /// Reloads when there's no next high or low left in the predictions, or they're over six hours old.
    /// In a physics simulation the tide comes from the model, so the tiles, depth and outlook follow it.
    private var usingSimulatedTide = false

    private func syncSimulatedTide() {
        if sourceKind == .simulator, let simulated = simulator.tideSnapshot(now: Date()) {
            if !usingSimulatedTide {
                usingSimulatedTide = true
                // The depth as set is the depth at the start of the simulated tide.
                tide = simulated
                recordDepthReading()
            }
            tide = simulated
            record("tide", phase: .ready, fetched: simulated.fetched, from: simulated.events.first?.time,
                   until: simulated.events.last?.time, station: "Simulated tide")
        } else if usingSimulatedTide || tide?.station.id == "simulated" {
            // Back to the real predictions.
            usingSimulatedTide = false
            tide = nil
            lastTideAttempt = .distantPast
        }
    }

    private func refreshTideIfDue() {
        guard !usingSimulatedTide, !tideFetching, fix != nil || anchor != nil, Date().timeIntervalSince(lastTideAttempt) > 300 else { return }
        let age = Date().timeIntervalSince(tide?.fetched ?? .distantPast)
        guard nextTide == nil || age > 6 * 3600 else { return }
        tideFetching = true
        lastTideAttempt = Date()
        let generation = environmentGeneration
        Task {
            defer { if generation == environmentGeneration { tideFetching = false } }
            await refreshTide()
        }
    }

    func applyTideRise() {
        if let rise = tideRiseEstimate { scope.tideRise = rise }
    }

    /// Scope distance: how far the rode out reaches across the bottom when taut, at the lowest water in the next
    /// 24 hours (when it reaches farthest).
    var scopeReach: Double {
        let shallowest = waterForecast.map(\.depth).min() ?? liveDepth
        let h = shallowest + scope.bowHeight
        return rodeOut > h ? (rodeOut * rodeOut - h * h).squareRoot() : 0
    }

    /// Default alarm radius: the swing radius (scope distance plus half the boat, to the phone amidships) plus the
    /// margin (20 ft unless changed), so the alarm only sounds once the boat is past anywhere its rode lets it go.
    var suggestedRadius: Double { swingRadius + scope.margin }

    /// The alarm radius follows the rode (set on Drop, and when the rode or depth change) until it's moved by hand.
    @Published var radiusFollowsRode = true {
        didSet { defaults.set(radiusFollowsRode, forKey: "anchorwatch.radiusFollows") }
    }

    /// The radius slider: a hand-set radius stays put when the rode changes.
    func setRadiusByHand(_ meters: Double) {
        radius = meters
        radiusFollowsRode = false
    }

    private func followRode() {
        syncSimulatorRode()
        if anchor != nil && radiusFollowsRode && !loading { radius = min(max(suggestedRadius, 10), 300) }
    }

    /// The simulated boat swings on the same rode the app thinks is out, so the circles and the boat agree.
    private func syncSimulatorRode() {
        let reach = swingRadius
        if reach > 0 { simulator.rode = reach }
        simulator.physicsBoat = physicsBoat
    }

    /// The boat, rode and anchor from the settings, for the physics simulation.
    private var physicsBoat: AnchorPhysics.Boat {
        let chain = boat.rodeType.hasChain && boat.chainSize > 0 ? AnchorMath.chainWeight(sizeMM: boat.chainSize) : 3
        let underwater = boat.beam > 0 && boat.draft > 0 ? boat.beam * boat.draft * AnchorMath.underwaterFill : 5
        let holding = boat.anchorWeight > 0
            ? boat.anchorWeight * AnchorMath.gravity * AnchorMath.holdingRatio(boat.anchorType, anchorBottom) : 8_000
        return AnchorPhysics.Boat(
            rode: rodeOut, depth: liveDepth, bowHeight: scope.bowHeight, chainWeight: chain,
            frontWindage: BoatMath.windage(boat) ?? 15,
            sideWindage: BoatMath.sideWindage(boat, length: scope.boatLength) ?? 45,
            underwater: underwater, mass: max(boat.displacement, 5_000) * 1.1,
            bowToPhone: ScopeCalculator.gpsFromBow(scope), holding: holding)
    }
    var highWaterScope: ScopeSettings {
        var value = scope
        value.depth = depthAtNextHigh.depth
        value.tideRise = 0
        return value
    }
    var rodeToPayOut: Double { ScopeCalculator.rode(highWaterScope) }

    /// The four main pages.
    enum Tab: Hashable { case watch, anchor, water, weather }
    @Published var tab = Tab.watch

    /// Depth at the anchorage over the next 24 h, from the live depth and the tide predictions.
    var waterForecast: [(time: Date, depth: Double)] {
        guard usable("tide") || usingSimulatedTide, let tide, let reading = depthReading, reading.depth(at: clock(), tide: tide) != nil else { return [] }
        return stride(from: 0.0, through: 24 * 3600, by: 600).compactMap { offset in
            let time = clock().addingTimeInterval(offset)
            return reading.depth(at: time, tide: tide).map { (time: time, depth: $0) }
        }
    }

    /// Seabed at the anchorage, chosen on the Anchoring page and used for the forecast check on the main screen.
    @Published var anchorBottom = AnchorConditions.Bottom.mud {
        didSet { defaults.set(anchorBottom.rawValue, forKey: "anchorwatch.bottom"); lastOutlook = .distantPast }
    }

    /// Rode actually let out, set with the Rode out slider on the Anchor tab. Nil until then; cleared on Raise.
    @Published var rodeOutSet: Double? {
        didSet {
            if let rodeOutSet { defaults.set(rodeOutSet, forKey: "anchorwatch.rodeOut") } else { defaults.removeObject(forKey: "anchorwatch.rodeOut") }
            lastOutlook = .distantPast
            followRode()
        }
    }

    @Published private(set) var rodeConfirmed = false

    func confirmRode(_ meters: Double) {
        guard meters.isFinite, meters > 0 else { return }
        rodeOutSet = meters
        rodeConfirmed = true
        save()
    }

    /// What the scope calls for, or everything on board if that's less.
    var rodeSuggested: Double {
        let carried = BoatMath.rodeCarried(boat)
        return carried > 0 ? min(rodeToPayOut, carried) : rodeToPayOut
    }

    /// Rode out, as set, else the suggestion: what the Scope tile, outlook, swing circle and gust limits use.
    var rodeOut: Double { rodeOutSet ?? rodeSuggested }

    /// Forecast gusts in the next 12 h beyond what this setup can hold.
    var holdingWarning: HoldingWarning? {
        let end = clock().addingTimeInterval(12 * 3600)
        guard let worst = forecastAssessments.filter({ h in h.time <= end && h.safeGust.map { h.gust > $0 } == true }).max(by: { ($0.gust - ($0.safeGust ?? 0)) < ($1.gust - ($1.safeGust ?? 0)) }) else { return nil }
        return HoldingWarning(gust: worst.gust, time: worst.time, safeGust: worst.safeGust ?? 0, rodeOut: rodeOut)
    }

    /// The next 24 hours: forecast hours with the safe gust at each hour's depth, and what's coming up.
    /// Recomputed at most once a minute (and as soon as tide or wind data first arrives).
    @Published private(set) var hourlyHolding: [HourlyHolding] = []
    @Published private(set) var outlook: [OutlookItem] = []
    private var forecastCache: (minute: Int, generation: Int, hours: [HourlyHolding])?
    private var lastOutlook = Date.distantPast {
        didSet { if lastOutlook == .distantPast { forecastCache = nil } }
    }

    /// How far the boat can swing from the anchor over the next 24 hours, and the arc it's predicted to lie in.
    var swingRadius: Double {
        let shallowest = waterForecast.map(\.depth).min() ?? liveDepth
        return Outlook.swingRadius(rodeOut: rodeOut, shallowest: shallowest, bowHeight: scope.bowHeight,
                                   bowToPhone: ScopeCalculator.gpsFromBow(scope))
    }

    var predictedSwingArc: (from: Double, width: Double)? {
        Outlook.arc(hourlyHolding.filter { $0.push >= Outlook.minPush(boat) }.map(\.lie))
    }

    /// The first thing in the outlook worth worrying about.
    var nextRisk: OutlookItem? { Outlook.nextRisk(visibleOutlook) }

    /// Warnings swiped away in the Next 24 hours list. Cleared on a new anchoring.
    @Published private(set) var hiddenOutlook: [HiddenOutlook] = []
    var visibleOutlook: [OutlookItem] { outlook.filter { item in !hiddenOutlook.contains { $0.covers(item) } } }
    var hiddenOutlookCount: Int { outlook.count - visibleOutlook.count }
    func hideOutlook(_ item: OutlookItem) {
        guard !isLocked(item) else { return }
        hiddenOutlook.append(HiddenOutlook(item))
    }
    func showHiddenOutlook() { hiddenOutlook = [] }

    /// Warnings locked so they can't be deleted. Cleared on a new anchoring.
    @Published private(set) var lockedOutlook: [HiddenOutlook] = []
    func isLocked(_ item: OutlookItem) -> Bool { lockedOutlook.contains { $0.matches(item) } }
    func lockOutlook(_ item: OutlookItem) {
        guard !isLocked(item) else { return }
        lockedOutlook.append(HiddenOutlook(item))
    }
    func unlockOutlook(_ item: OutlookItem) { lockedOutlook.removeAll { $0.matches(item) } }

    var forecastAssessments: [HourlyHolding] {
        let now = clock(), minute = Int(clock().timeIntervalSince1970 / 60)
        if let cached = forecastCache, cached.minute == minute, cached.generation == environmentGeneration { return cached.hours }
        var adviceScope = scope
        adviceScope.depth = liveDepth
        let hours = Outlook.hourly(boat, scope: adviceScope, bottom: anchorBottom, rodeOut: rodeOut,
                                   depths: waterForecast, forecast: windForAdvice?.samples ?? [],
                                   current: usable("current") ? { [weak self] in self?.currentHere(at: $0) } : nil, now: now)
        forecastCache = (minute, environmentGeneration, hours)
        return hours
    }

    func refreshOutlookIfDue() {
        guard clock().timeIntervalSince(lastOutlook) >= 60 || (outlook.isEmpty && hourlyHolding.isEmpty) else { return }
        lastOutlook = clock()
        hourlyHolding = forecastAssessments
        outlook = Outlook.items(boat, scope: scope, rodeOut: rodeOut, depths: waterForecast, hourly: hourlyHolding,
                                tideTurns: usable("tide") ? tide?.events ?? [] : [], currentEvents: scaledCurrentEvents,
                                anchor: anchor, hazards: hazards, units: units, now: clock())
    }

    var nextCurrentSlack: Date? { scaledCurrentEvents?.first { $0.isSlack && $0.time > clock() }?.time }

    var forecastStatusText: String {
        if depthReading == nil { return "Forecast incomplete — confirm water depth" }
        return environmentCoverage.complete ? "Forecast inputs available for 24 hours" : "Forecast incomplete — some inputs are missing or cached"
    }

    // MARK: Tidal current (NOAA predictions for the nearest current station)

    @Published private(set) var currents: CurrentSnapshot?
    /// Stations sit in channels; the anchorage usually runs slower. The share of the station's speed to use.
    @Published var currentFactor = 0.5 {
        didSet { defaults.set(currentFactor, forKey: "anchorwatch.currentFactor"); lastOutlook = .distantPast }
    }
    private var currentFetching = false
    private var lastCurrentAttempt = Date.distantPast

    /// Current at the anchorage at `time`: the station's prediction scaled by `currentFactor`.
    func currentHere(at time: Date) -> CurrentAt? {
        guard usable("current"), let events = currents?.events, let flow = CurrentMath.at(time, events: events) else { return nil }
        let flooding = flow.toward == events.first!.floodToward
        return CurrentAt(speed: flow.speed * currentFactor, toward: flow.toward, flooding: flooding)
    }

    /// The predicted slacks and maximums with speeds scaled to the anchorage.
    var scaledCurrentEvents: [CurrentEvent]? {
        (usable("current") ? currents?.events : nil)?.map { CurrentEvent(time: $0.time, velocity: $0.velocity * currentFactor,
                                            floodToward: $0.floodToward, ebbToward: $0.ebbToward) }
    }

    /// Loads current predictions once there's a position, then every six hours. No station nearby leaves it nil.
    private func refreshCurrentsIfDue() {
        guard !currentFetching, anchor != nil || fix != nil,
              Date().timeIntervalSince(lastCurrentAttempt) > (currents == nil ? 600 : 6 * 3600) else { return }
        currentFetching = true
        lastCurrentAttempt = Date()
        let generation = environmentGeneration
        Task {
            defer { if generation == environmentGeneration { currentFetching = false } }
            await refreshCurrent()
        }
    }

    /// Depth at the next high water: today's depth plus how much the tide rises to it, and when. Without tide
    /// predictions, the rise entered on the Water tab.
    var depthAtNextHigh: (depth: Double, time: Date?) {
        if (usable("tide") || usingSimulatedTide), let high = tide.flatMap({ TideMath.upcoming($0.events, after: clock(), limit: 4).first(where: \.isHigh) }),
           let depth = depthReading?.depth(at: high.time, tide: tide) {
            return (depth, high.time)
        }
        return (liveDepth + scope.tideRise, nil)
    }

    /// The next predicted high or low.
    var nextTide: TideEvent? { guard usable("tide") || usingSimulatedTide else { return nil }; return tide.flatMap { TideMath.upcoming($0.events, after: clock(), limit: 1).first } }
    /// How much more rode the scope calls for than the boat carries. Nil when there is enough, or the rode isn't entered.
    var rodeShortfall: Double? {
        let carried = BoatMath.rodeCarried(boat)
        return carried > 0 && rodeToPayOut > carried ? rodeToPayOut - carried : nil
    }

    func applySuggestedRadius() {
        radius = min(max(suggestedRadius, 10), 300)
        radiusFollowsRode = true
    }

    /// The bottom control panel fades out when idle; any tap on the map brings it back.
    @Published private(set) var controlsVisible = true
    /// The buttons down the right edge fade too, when the user turns this on in Settings.
    @Published var fadeSideButtons = false {
        didSet { defaults.set(fadeSideButtons, forKey: "anchorwatch.fadeSideButtons"); pokeControls() }
    }
    @Published private(set) var sideButtonsVisible = true

    /// Every position received in the last `gpsLogWindow`, usable or not, stamped with when it arrived: for GPS Quality.
    @Published private(set) var gpsLog: [(time: Date, fix: Fix)] = []
    let gpsLogWindow: TimeInterval = 15 * 60
    func clearGPSLog() { gpsLog = [] }

    /// Latest position from each receiver, before the app picks one: for the Testing page.
    @Published private(set) var receiverFix: Fix?
    @Published private(set) var phoneFix: Fix?
    /// Settable so tests needn't wait the full delay.
    var controlsFadeDelay: TimeInterval = 6
    private var hideTask: Task<Void, Never>?

    @Published var placingAnchor = false
    @Published var recenterTick = 0
    @Published private(set) var zoomTick = 0
    private(set) var zoomFactor = 1.0
    @Published var mapLayer: ChartLayer = .seaMap { didSet { defaults.set(mapLayer.rawValue, forKey: "anchorwatch.layer") } }
    @Published var units: Units = .feet {
        didSet { defaults.set(units.rawValue, forKey: "anchorwatch.units"); lastOutlook = .distantPast }
    }

    /// A real iPhone defaults to its GPS; the iOS Simulator has none, so it defaults to the fake one.
    #if targetEnvironment(simulator)
    @Published var sourceKind: SourceKind = .simulator { didSet { sourceChanged(oldValue) } }
    #else
    @Published var sourceKind: SourceKind = .gps { didSet { sourceChanged(oldValue) } }
    #endif
    @Published var scenario: SimulatedLocationSource.Scenario = .swinging {
        didSet {
            simulator.scenario = scenario
            simulator.restart()
            usingSimulatedTide = false      // a new simulated day: take the depth's tide reference afresh
        }
    }
    @Published var simSpeed = 1.0 { didSet { simulator.speed = simSpeed } }

    /// Where the simulated boat starts. Changing it moves the boat, so any anchor set at the old spot is raised
    /// and the position-dependent data (tides, wind, stations, alerts) is reloaded for the new one.
    @Published var simPlace: SimulatedLocationSource.Place = .rocheHarbor {
        didSet {
            guard !loading, simPlace != oldValue else { return }
            defaults.set(simPlace.rawValue, forKey: "anchorwatch.simPlace")
            simulator.origin = simPlace.coordinate
            raiseAnchor()
            bindEnvironment(to: simPlace.coordinate)
            fix = nil
            track = []
            tide = nil
            windHere = nil; windGrid = []; lastWindAttempt = .distantPast
            currents = nil; lastCurrentAttempt = .distantPast
            observations = []; observationsChecked = nil; lastObservationAttempt = .distantPast
            nwsAlerts = []; nwsChecked = nil; lastAlertAttempt = .distantPast
            if started && sourceKind == .simulator { simulator.restart() }
            recenter()
        }
    }
    private var loading = true
    private var started = false

    // MARK: Tunables
    let maxTrackPoints = 5000
    /// Record the track under way too, not only once anchored. The way in is kept when the anchor goes down.
    @Published var trackWhenUnanchored = false {
        didSet {
            defaults.set(trackWhenUnanchored, forKey: "anchorwatch.trackUnanchored")
            if !trackWhenUnanchored && anchor == nil { track = [] }
        }
    }
    let gpsLostAfter: TimeInterval = 30
    /// Consecutive outside-the-circle fixes needed before alarming, to ignore a single GPS glitch.
    let confirmFixes = 2

    private let simulator = SimulatedLocationSource()
    private let gps: GPSLocationSource?
    /// The Apple Watch app's line to the phone (not in tests).
    private let watchLink: WatchLink?
    private let player: AlarmPlaying
    private let liveActivity: LiveActivityControlling
    private let defaults: UserDefaults
    private var outsideCount = 0
    private var snoozedUntil: [String: Date] = [:]
    private var lastFixArrival: Date?
    private var lastUsableFix: Date?
    private var watchdog: Timer?
    private let clock: () -> Date
    private var acquisitionStarted: Date
    private var newestMeasurement: Date?
    @Published private(set) var monitoringTick = 0

    init(player: AlarmPlaying? = nil, liveActivity: LiveActivityControlling? = nil, defaults: UserDefaults = .standard, useGPSHardware: Bool = true, clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        self.acquisitionStarted = clock()
        self.player = player ?? AlarmPlayer()
        self.liveActivity = liveActivity ?? LiveActivityController()
        self.defaults = defaults
        self.gps = useGPSHardware ? GPSLocationSource() : nil
        self.watchLink = useGPSHardware ? WatchLink() : nil
        load()
        loading = false
    }

    func start() {
        guard !started else { return }
        started = true
        pokeControls()
        let demo = ProcessInfo.processInfo.arguments.contains("-autoDrop")
        // Dev aid: `-demoAlert` shows a sample Small Craft Advisory without waiting for a real one.
        if ProcessInfo.processInfo.arguments.contains("-demoAlert") { nwsAlerts = [.sample]; nwsChecked = Date() }
        // Dev aid: `-scenario "Dragging anchor"` and `-simSpeed 10` pick the simulator scenario and its speed.
        let launchArgs = ProcessInfo.processInfo.arguments
        func argument(after flag: String) -> String? {
            launchArgs.firstIndex(of: flag).flatMap { launchArgs.indices.contains($0 + 1) ? launchArgs[$0 + 1] : nil }
        }
        if let speed = argument(after: "-simSpeed").flatMap(Double.init) { simSpeed = speed }
        // Dev aid: `-origin 48.65,-123.39` starts the simulated boat somewhere else, e.g. to try Canadian waters.
        if let text = argument(after: "-origin") {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                simulator.origin = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
                if sourceKind == .simulator { simulator.restart() }
            }
        }
        // Dev aid: `-gustLimit 2` lowers the warning threshold so a warning shows in calm weather.
        if let limit = argument(after: "-gustLimit").flatMap(Double.init) { gustLimit = limit }
        if let name = argument(after: "-scenario"), let chosen = SimulatedLocationSource.Scenario(rawValue: name) { scenario = chosen }
        // Dev aid: `-fitStations` zooms out to the nearby stations once their readings arrive.
        if ProcessInfo.processInfo.arguments.contains("-fitStations") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in self?.fitStations() }
        }
        // Dev aid: `-showWind` turns the wind overlay on at launch, for screenshots.
        if ProcessInfo.processInfo.arguments.contains("-showWind") { windOverlayOn = true }
        // Dev aid: `-keepControls` stops the controls fading, for screenshots.
        if ProcessInfo.processInfo.arguments.contains("-keepControls") { controlsFadeDelay = 1_000_000 }
        #if !targetEnvironment(simulator)
        if !demo { player.prepare() }
        #endif
        syncSimulatorRode()
        startBarometer()
        // Dev aid: `-demoPressure` fills in three hours of falling pressure, as no simulator has a barometer.
        if launchArgs.contains("-demoPressure") {
            pressureHistory = []
            let now = Date()
            for minute in stride(from: 180, through: 0, by: -1) {
                record(pressure: 1013 - 4.5 * Double(180 - minute) / 180, at: now.addingTimeInterval(-Double(minute) * 60))
            }
        }
        simulator.onFix = { [weak self] in self?.ingest($0) }
        gps?.onFix = { [weak self] in self?.ingest($0) }
        gps?.onReading = { [weak self] fix in
            if fix.external { self?.receiverFix = fix } else { self?.phoneFix = fix }
        }
        switchSource()
        // Dev aid: `-autoDrop` drops a fresh anchor shortly after launch (raising any saved one first),
        // for screenshots and demos.
        if demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.anchor != nil { self?.raiseAnchor() }
                self?.dropAnchor(.settled)
                // Dev aid: `-demoHazard` marks a rock just outside the swing, for screenshots.
                if let self, launchArgs.contains("-demoHazard"), self.hazards.isEmpty, let anchor = self.anchor {
                    self.addHazard(Hazard(kind: .rock, at: Geo.destination(from: anchor, bearing: 45, meters: self.sternReach + 20),
                                          name: "Demo rock"))
                }
                // Dev aid: `-showHazardSheet` opens the mark-a-hazard sheet, for screenshots.
                if let self, launchArgs.contains("-showHazardSheet"), let anchor = self.anchor {
                    self.pendingHazard = .init(coordinate: Geo.destination(from: anchor, bearing: 120, meters: 90))
                }
                // Dev aid: `-showHazardEdit` opens the first hazard's edit sheet (use with `-demoHazard`).
                if let self, launchArgs.contains("-showHazardEdit"), let first = self.hazards.first {
                    self.editHazard(first.id)
                }
                // Dev aid: `-showRetrieve` starts retrieving a few seconds after the drop, for screenshots.
                if launchArgs.contains("-showRetrieve") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.startRetrieval() }
                }
            }
        }
        if armed { player.arm() }
        gps?.keepsRunningInBackground = armed
        readBattery()
        let center = NotificationCenter.default
        center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery() }
        }
        center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery() }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.safetyChecks(); self?.refreshData() }
        }
    }

    /// The drop sheet is open: the GPS goes to full accuracy so the drop gets a precise position.
    @Published var preparingDrop = false {
        didSet { saveBattery() }
    }

    /// Full GPS accuracy while anchored, retrieving, about to drop, placing the anchor, or with Track on.
    var wantsPreciseGPS: Bool {
        anchor != nil || retrieveTarget != nil || preparingDrop || placingAnchor || trackWhenUnanchored
    }

    /// The screen stays on only while anchored or retrieving; otherwise it sleeps as usual.
    var keepsScreenOn: Bool { anchor != nil || retrieveTarget != nil }

    /// With nothing to watch, let the screen sleep and ease off the GPS.
    private func saveBattery() {
        gps?.precise = wantsPreciseGPS
        if UIApplication.shared.isIdleTimerDisabled != keepsScreenOn { UIApplication.shared.isIdleTimerDisabled = keepsScreenOn }
    }

    /// Everything that guards the anchor, once a second. No network use, so tests can call it.
    func safetyChecks() {
        monitoringTick &+= 1
        saveBattery()
        checkGPSLost()
        checkGPSPoor()
        if awaitingSwingFix, let anchorDropped, clock().timeIntervalSince(anchorDropped) >= anchorConfirmationTimeout {
            trigger(.anchorUnconfirmed)
        }
        checkBattery()
        player.ensureRunning()
        pollDevice()
        liveActivity.update(snapshot)
        if liveActivityState != liveActivity.state { liveActivityState = liveActivity.state }
    }

    /// One presentation for the phone, wrist, night view, chart and lock screen.
    struct MonitoringPresentation: Equatable {
        enum Tone: String { case gray, green, orange, red, purple }
        var title: String
        var detail: String
        var icon: String
        var tone: Tone
        var activityStatus: AnchorWatchAttributes.Status
    }

    var circleMonitoringAvailable: Bool { armed && !awaitingSwingFix && hasFreshPosition }
    let anchorConfirmationTimeout: TimeInterval = 5 * 60

    var monitoring: MonitoringPresentation {
        typealias P = MonitoringPresentation
        if let alarm {
            return P(title: "ALARM", detail: alarmHeadline ?? alarm.message, icon: "exclamationmark.octagon.fill", tone: .red, activityStatus: .alarm)
        }
        if testingSiren && audioFailure == nil {
            return P(title: "Siren test", detail: "Siren test, not a real alarm", icon: "speaker.wave.3.fill", tone: .orange, activityStatus: .alarm)
        }
        switch watchState {
        case .notAnchored:
            return P(title: "Circle alarm OFF", detail: "No anchor set", icon: "circle.dashed", tone: .gray, activityStatus: .caution)
        case .retrieving:
            return P(title: "Retrieving", detail: "Circle alarm OFF — retrieving anchor", icon: "arrow.up", tone: .purple, activityStatus: .caution)
        case .acquiringGPS, .gpsInterrupted:
            return P(title: "Monitoring interrupted", detail: "Circle alarm unavailable — " + gpsFreshnessText, icon: "location.slash", tone: .orange, activityStatus: .caution)
        case .awaitingFix:
            return P(title: "Circle alarm OFF", detail: "Circle alarm OFF — confirm anchor position. GPS and battery checks remain active.", icon: "exclamationmark.triangle.fill", tone: .orange, activityStatus: .caution)
        case .outside:
            return P(title: "Outside circle", detail: "Outside the alarm circle — check the boat", icon: "exclamationmark.octagon.fill", tone: .red, activityStatus: .caution)
        case .dragging:
            return P(title: "Possible dragging", detail: "Swing estimates show the anchor moving", icon: "exclamationmark.triangle.fill", tone: .red, activityStatus: .caution)
        case .movingAway:
            return P(title: "Moving away", detail: "Distance from the anchor is increasing", icon: "exclamationmark.triangle.fill", tone: .orange, activityStatus: .caution)
        case .alarm: break // handled above
        case .holding: break
        }
        if let problem = watchProblems.first(where: { $0.state == .critical }) {
            return P(title: "Check alarm readiness", detail: problem.title, icon: "exclamationmark.triangle.fill", tone: .orange, activityStatus: .caution)
        }
        return P(title: "Circle alarm ON", detail: "Circle alarm ON · Holding", icon: "checkmark.shield.fill", tone: .green, activityStatus: .holding)
    }

    /// What the lock-screen Live Activity shows; nil when no anchor is set.
    var snapshot: WatchSnapshot? {
        guard armed || retrieveTarget != nil else { return nil }
        let presentation = monitoring
        return WatchSnapshot(distanceText: hasFreshPosition ? distance.map(units.format) ?? "--" : "--",
                             radiusText: units.format(radius), fraction: hasFreshPosition && radius > 0 ? (distance ?? 0) / radius : 0,
                             status: presentation.activityStatus, headline: presentation.detail, boatName: boat.name)
    }

    private func refreshData() {
        if windOverlayOn, Date().timeIntervalSince(lastGridAttempt) > 60, let region = windRegion {
            requestWindGrid(for: region)
        }
        if let point = anchor ?? fix?.coordinate { bindEnvironment(to: point) }
        if Date().timeIntervalSince(lastEstimate) >= max(2, estimateInterval / simTimeScale) { updateAnchorEstimate() }
        refreshPermissionsIfDue()
        refreshWindHereIfDue()
        syncSimulatedTide()
        publishToWatch()
        refreshTideIfDue()
        refreshCurrentsIfDue()
        refreshOutlookIfDue()
        refreshAlertsIfDue()
        refreshObservationsIfDue()
    }

    private func sourceChanged(_ old: SourceKind) {
        guard sourceKind != old else { return }
        defaults.set(sourceKind.rawValue, forKey: "anchorwatch.source")
        switchSource()
    }

    private func switchSource() {
        simulator.stop()
        gps?.stop()
        lastFixArrival = nil
        lastUsableFix = nil
        newestMeasurement = nil
        acquisitionStarted = clock()
        fix = nil
        rawFix = nil
        recent = []; approach = []; outsideCount = 0
        distance = nil
        switch sourceKind {
        case .simulator: simulator.restart()
        case .gps: gps?.start()
        }
    }

    // MARK: Anchor control

    /// When Drop is tapped: as the anchor goes down under the bow, or once the boat has fallen back on its rode.
    enum DropMoment { case goingDown, settled }

    /// How far ahead of the phone the last drop put the anchor, for the note under the radius controls.
    @Published private(set) var dropOffset = 0.0

    /// Rode reach across the bottom at today's depth, plus the bow-to-phone distance: where a settled boat's
    /// phone is from its anchor.
    var settledOffset: Double {
        let h = liveDepth + scope.bowHeight
        let reach = rodeOut > h ? (rodeOut * rodeOut - h * h).squareRoot() : 0
        return reach + ScopeCalculator.gpsFromBow(scope)
    }

    func dropAnchor(_ moment: DropMoment = .goingDown, rode: Double? = nil) {
        guard !gpsIsUnusable, let fix, let position = averagedPosition, let accuracy = averagedAccuracy else { return }
        let deployed = rode ?? rodeOut
        guard deployed.isFinite, deployed > 0 else { return }
        rodeConfirmed = rode != nil || rodeOutSet != nil
        rodeOutSet = deployed
        retrieveTarget = nil
        hiddenOutlook = []
        lockedOutlook = []
        // Settled: the anchor is a whole scope distance upwind. The last minute's movement is the boat falling
        // back, not the way the bow points, so only the wind gives the direction.
        let offset = moment == .settled ? settledOffset : ScopeCalculator.gpsFromBow(scope)
        let placed = placeAtBow(position, accuracy: accuracy, lyingTo: nil, offset: offset, useApproach: moment == .goingDown)
        dropOffset = offset
        estimateAutoApplied = false
        anchorCorrection = nil
        // Settled with no wind to say which way the anchor lies: the mark could be a whole scope distance out,
        // so the circle alarm waits for the swing fit rather than going off as the boat swings.
        awaitingSwingFix = moment == .settled && placed.source == .unknown
        setAnchor(placed.coordinate)
        anchorUncertainty = placed.uncertainty
        anchorPlacement = placed
        anchorEstimate = nil
        estimatePending = .collecting(minutes: 0)
        resetDrift()
        pokeControls()
        anchorDropped = clock()
        originalAnchor = anchor
        // A new anchorage gets the default radius from its rode and depth, and the chart frames it.
        applySuggestedRadius()
        recenter()
        // Keep the way in when recording under way; otherwise the track starts at the drop.
        if trackWhenUnanchored { if track.last != fix { track.append(fix) } } else { track = [fix] }
        maxDistance = 0
        save()
    }

    /// Relocate the anchor after it was set (drag the pin, tap the map, or snap to the boat).
    func moveAnchor(to coordinate: CLLocationCoordinate2D) {
        guard anchor != nil else { return }
        estimateAutoApplied = true      // a mark set by hand (or from the swing) isn't corrected again
        awaitingSwingFix = false
        if alarm == .anchorUnconfirmed { silence(snoozeAfter: false) }
        setAnchor(coordinate)
        anchorUncertainty = nil     // placed by hand, not by GPS
        anchorPlacement = nil
        pokeControls()
        maxDistance = distance ?? 0
        placingAnchor = false
        save()
    }

    func moveAnchorToBoat() {
        guard !gpsIsUnusable, let position = averagedPosition, let accuracy = averagedAccuracy else { return }
        let placed = placeAtBow(position, accuracy: accuracy, lyingTo: anchor)
        dropOffset = ScopeCalculator.gpsFromBow(scope)
        moveAnchor(to: placed.coordinate)
        anchorUncertainty = placed.uncertainty
        anchorPlacement = placed
        save()
    }

    /// Simulated seconds per real second: the sim speed when the simulator is the position source.
    var simTimeScale: Double { sourceKind == .simulator ? simSpeed : 1 }
    /// The simulated clock in a physics scenario, for the overlay on the chart.
    var simulatedClock: (time: Date, elapsed: Double)? { sourceKind == .simulator ? simulator.clock : nil }

    /// What a physics simulation is doing, for the Testing page.
    var simulatorStatus: String? { sourceKind == .simulator ? simulator.status : nil }

    /// Refits the anchor position from the swing. Called once a minute; tests call it directly.
    func updateAnchorEstimate() {
        lastEstimate = Date()
        guard let anchor, let anchorDropped else { anchorEstimate = nil; estimatePending = nil; return }
        let wind = windNow
        let modelRadius = Outlook.swingRadius(rodeOut: rodeOut, shallowest: liveDepth, bowHeight: scope.bowHeight,
                                              bowToPhone: ScopeCalculator.gpsFromBow(scope))
        switch AnchorEstimate.evaluate(track: track, dropped: anchorDropped, mark: anchor, modelRadius: modelRadius,
                                       windFrom: wind?.direction, windKnots: wind?.speed, timeScale: simTimeScale) {
        case .success(let r): anchorEstimate = r; estimatePending = nil; correctFromSwing(r)
        case .failure(let p): anchorEstimate = nil; estimatePending = p.pending
        }
        updateDrift(anchor: anchor, dropped: anchorDropped, modelRadius: modelRadius)
    }

    private func updateDrift(anchor: CLLocationCoordinate2D, dropped: Date, modelRadius: Double) {
        guard let sample = AnchorDrift.rollingSample(track: track, dropped: dropped, mark: anchor,
                                                     modelRadius: modelRadius, timeScale: simTimeScale) else { return }
        if let last = driftSamples.last, sample.minute <= last.minute { return }     // no new track since the last fit
        driftSamples.append(sample)
        driftSamples.removeAll { sample.minute - $0.minute > AnchorDrift.windowMinutes * 2 }
        if let drift = AnchorDrift.assess(driftSamples) {
            driftStreak += 1
            if driftStreak >= AnchorDrift.confirmations { anchorDrift = drift }
        } else {
            driftStreak = 0
            anchorDrift = nil
        }
    }

    private func resetDrift() {
        distanceLog = []
        distanceTrend = nil
        anchorDrift = nil
        driftSamples = []
        driftStreak = 0
    }

    /// Moves the anchor mark to the swing estimate; the dotted circle becomes its error ellipse's long axis.
    func moveAnchorToEstimate() {
        guard let estimate = anchorEstimate else { return }
        moveAnchor(to: estimate.center)
        anchorUncertainty = estimate.semiMajor
        save()
        updateAnchorEstimate()
    }

    /// Moved by the first swing fit, so the banner can say how far and offer Undo.
    struct AnchorCorrection: Equatable {
        let meters: Double
        let bearing: Double
        let previous: CLLocationCoordinate2D
    }
    @Published private(set) var anchorCorrection: AnchorCorrection?
    /// The circle alarm is held until the swing fit (or a hand-placed mark) says where the anchor is.
    @Published private(set) var awaitingSwingFix = false
    /// The first swing fit after a drop may move the mark; after that, or once the mark is moved by hand, a moving
    /// estimate is left to the drag warning, so a dragging anchor never takes the circle with it.
    private var estimateAutoApplied = false
    static let autoCorrectWithinMinutes = 90.0

    private func correctFromSwing(_ r: AnchorEstimate.Result) {
        guard !estimateAutoApplied, r.windAgrees != false, let anchor, let anchorDropped else { return }
        estimateAutoApplied = true
        awaitingSwingFix = false        // the swing has spoken: arm the circle alarm
        if alarm == .anchorUnconfirmed { silence(snoozeAfter: false) }
        save()
        let minutes = Date().timeIntervalSince(anchorDropped) * max(simTimeScale, 1) / 60
        let off = Geo.distance(anchor, r.center)
        guard minutes <= Self.autoCorrectWithinMinutes, off > max(r.semiMajor, 5) else { return }
        moveAnchorToEstimate()
        anchorCorrection = AnchorCorrection(meters: off, bearing: Geo.bearing(from: anchor, to: r.center), previous: anchor)
        recenter()          // the circle has moved: bring it into view
        // The mark was what was wrong: if that put the boat back inside, stop the outside alarm.
        if case .outsideCircle? = alarm, let distance, distance <= radius { silence(snoozeAfter: false) }
    }

    /// The mark sits where the swing says the anchor is: the chart then shows just the anchor, without the swing
    /// marker or the uncertainty ring. If the swing later moves away from the mark, they come back.
    var anchorAgreesWithSwing: Bool {
        guard let anchor, let estimate = anchorEstimate else { return false }
        return Geo.distance(anchor, estimate.center) <= estimate.semiMajor
    }

    // MARK: Apple Watch

    /// What the watch shows, sent when it changes (WatchLink decides).
    /// The phone is in night mode; the watch follows it.
    var nightMode = false

    var monitoringHeadline: String { monitoring.detail }

    /// Testable payload uses exactly the same readiness decision as the phone and Live Activity.
    var watchStatus: [String: String] {
        let presentation = monitoring
        var status = ["state": presentation.title, "tone": presentation.tone.rawValue,
                      "distance": armed && hasFreshPosition ? distance.map(units.format) ?? "--" : "--",
                      "radius": armed ? "Circle " + units.format(radius) : "",
                      "detail": presentation.detail, "night": nightMode ? "1" : "0",
                      "circleActive": circleMonitoringAvailable ? "1" : "0"]
        if let w = windNow { status["wind"] = "Wind \(Int(w.speed.rounded())) kt \(Compass.name(w.direction)), gusts \(Int(w.gust.rounded()))" }
        if let alarmHeadline { status["alarm"] = alarmHeadline }
        if let anchor {
            status.merge(WatchLink.chart(anchor: anchor, radius: radius, boat: hasFreshPosition ? fix?.coordinate : nil,
                                         track: track.suffix(720).map(\.coordinate))) { $1 }
        }
        if let guide = retrievalGuide {
            status["distance"] = units.format(guide.distance)
            status["radius"] = "bow to anchor"
            status["detail"] = presentation.detail + ". " + guide.steer
        }
        return status
    }

    private func publishToWatch() {
        guard let watchLink else { return }
        if watchLink.onSilence == nil { watchLink.onSilence = { [weak self] in self?.silence() } }
        watchLink.publish(watchStatus)
    }

    // MARK: Anchorage log

    /// Past anchorages, newest first. Saved to a file; tests point `logURL` somewhere of their own.
    @Published private(set) var anchorages: [AnchorageEntry] = []
    @Published var chartStatus: String?
    @Published private(set) var persistenceError: String?
    private var logLoadFailed = false
    var logURL: URL? { didSet { loadAnchorageLog() } }
    func loadAnchorageLog() {
        do {
            let result = try AnchorageLog.read(from: logURL)
            if logLoadFailed {
                let retained = Set(anchorages.map(\.id))
                anchorages += result.entries.filter { !retained.contains($0.id) }
                anchorages.sort { $0.dropped > $1.dropped }
            } else { anchorages = result.entries }
            logLoadFailed = false
            persistenceError = result.recovered ? "Anchorage log recovered from backup. The latest changes may be missing. Review the log, then retry saving." : nil
        } catch {
            logLoadFailed = true
            persistenceError = "Cannot read the anchorage log: " + error.localizedDescription + " Original files have been kept."
        }
    }
    func retrySavingAnchorages() {
        guard !logLoadFailed else { loadAnchorageLog(); return }
        persistenceError = AnchorageLog.save(anchorages, to: logURL).map { "Anchorage log is not saved: " + $0.localizedDescription + " Keep the app open and retry." }
    }

    func setAnchorageLocked(_ id: UUID, _ locked: Bool) {
        guard var entry = anchorages.first(where: { $0.id == id }) else { return }
        entry.isLocked = locked
        updateAnchorage(entry)
    }

    func updateAnchorage(_ entry: AnchorageEntry) {
        guard let i = anchorages.firstIndex(where: { $0.id == entry.id }) else { return }
        anchorages[i] = entry
        retrySavingAnchorages()
    }

    /// Locked entries are kept.
    func deleteAnchorage(_ id: UUID) {
        anchorages.removeAll { $0.id == id && !$0.isLocked }
        retrySavingAnchorages()
    }

    /// An earlier stay at this spot, while anchored.
    var previousVisit: AnchorageEntry? {
        guard let anchor else { return nil }
        return AnchorageLog.previousVisit(near: anchor, in: anchorages, before: anchorDropped ?? Date())
    }

    /// Uses the earlier visit's rode and bottom.
    func applyPreviousVisit() {
        guard let visit = previousVisit else { return }
        rodeOutSet = visit.rodeOut
        if let bottom = AnchorConditions.Bottom(rawValue: visit.bottom) { anchorBottom = bottom }
    }

    /// Called as the anchor is raised: a stay of ten minutes or more goes in the log, named from the map.
    private func logStay() {
        guard let anchor, let anchorDropped,
              Date().timeIntervalSince(anchorDropped) * max(simTimeScale, 1) >= AnchorageLog.minimumStay else { return }
        let entry = AnchorageEntry(
            name: "Anchorage, " + anchorDropped.formatted(.dateTime.day().month(.abbreviated)),
            latitude: anchor.latitude, longitude: anchor.longitude, dropped: anchorDropped, raised: Date(),
            depth: scope.depth, rodeOut: rodeOut, radius: radius, maxDistance: maxDistance, bottom: anchorBottom.rawValue,
            track: AnchorageLog.thin(track.map(\.coordinate)))
        anchorages.insert(entry, at: 0)
        retrySavingAnchorages()
        let id = entry.id
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)) { [weak self] places, _ in
            guard let place = places?.first, let name = place.name ?? place.locality else { return }
            Task { @MainActor in
                guard let self, var named = self.anchorages.first(where: { $0.id == id }) else { return }
                named.name = name
                self.updateAnchorage(named)
            }
        }
    }

    /// Presentation and advisory notifications only; siren and monitoring checks are independent.
    @Published var hideWarningBanners = false {
        didSet { defaults.set(hideWarningBanners, forKey: "anchorwatch.hideWarningBanners") }
    }
    @Published var muteAdvisoryNotifications = false {
        didSet { defaults.set(muteAdvisoryNotifications, forKey: "anchorwatch.muteAdvisoryNotifications") }
    }

    // MARK: Barometer

    /// The last 12 hours of barometer readings, about one a minute. Saved, so a restart keeps the trend.
    @Published private(set) var pressureHistory: [PressureReading] = []
    private let barometer = Barometer()
    private var lastPressureAlert = PressureTrend.Level.steady

    /// Change over the last three hours (hPa), once there's that much history.
    var pressureChange: Double? { PressureTrend.change(pressureHistory) }
    var pressureLevel: PressureTrend.Level { PressureTrend.level(pressureChange) }

    private func startBarometer() {
        barometer.onReading = { [weak self] hPa in self?.record(pressure: hPa) }
        barometer.start()
    }

    /// Keeps one reading a minute, trims to 12 hours, and notifies once when the fall crosses a threshold.
    func record(pressure hPa: Double, at time: Date = Date()) {
        if let last = pressureHistory.last, time.timeIntervalSince(last.time) < 60 { return }
        pressureHistory.append(PressureReading(time: time, hPa: hPa))
        pressureHistory.removeAll { time.timeIntervalSince($0.time) > 12 * 3600 }
        defaults.set(try? JSONEncoder().encode(pressureHistory), forKey: "anchorwatch.pressure")
        let level = pressureLevel
        if level > lastPressureAlert, !muteAdvisoryNotifications, let change = pressureChange {
            let content = UNMutableNotificationContent()
            content.title = level == .fallingFast ? "Barometer falling very fast" : "Barometer falling quickly"
            content.body = String(format: "%.1f hPa in 3 hours. ", change)
                + (level == .fallingFast ? "Gale risk: check the anchor and the forecast." : "Wind likely: check the anchor.")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        lastPressureAlert = level
    }

    // MARK: Hazards

    /// Active and hidden marks share one saved collection, so raising never overwrites earlier marks.
    @Published private var savedHazards: [Hazard] = [] {
        didSet {
            defaults.set(try? JSONEncoder().encode(savedHazards), forKey: "anchorwatch.hazards")
            lastOutlook = .distantPast
            // Cached warnings must disappear immediately, before the next forecast refresh.
            let activeIDs = Set(hazards.map { $0.id.uuidString })
            outlook.removeAll { $0.kind == .hazard && !activeIDs.contains($0.subject) }
            hiddenOutlook.removeAll { $0.kind == .hazard && !activeIDs.contains($0.subject) }
            lockedOutlook.removeAll { $0.kind == .hazard && !activeIDs.contains($0.subject) }
        }
    }
    var hazards: [Hazard] { savedHazards.filter { $0.hidden != true } }
    var hiddenHazards: [Hazard] { savedHazards.filter { $0.hidden == true } }

    private func hideHazards() {
        pendingHazard = nil
        savedHazards = savedHazards.map { mark in
            var hidden = mark
            hidden.hidden = true
            return hidden
        }
    }

    func restoreHazard(_ id: UUID) {
        guard let i = savedHazards.firstIndex(where: { $0.id == id && $0.hidden == true }) else { return }
        savedHazards[i].hidden = nil
        refreshOutlookIfDue()
    }
    /// A long-press on empty chart: where a new hazard would go, while its details are chosen.
    @Published var pendingHazard: PendingHazard?
    struct PendingHazard: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        /// Set when editing a hazard already marked.
        var hazard: Hazard? = nil
    }

    func addHazard(_ hazard: Hazard) {
        var active = hazard
        active.hidden = nil
        savedHazards.append(active)
    }
    /// Kind, keep-off distance or name changed.
    func updateHazard(_ hazard: Hazard) {
        guard let i = savedHazards.firstIndex(where: { $0.id == hazard.id && $0.hidden != true }) else { return }
        var active = hazard
        active.hidden = nil
        savedHazards[i] = active
    }
    func editHazard(_ id: UUID) {
        guard let hazard = hazards.first(where: { $0.id == id }) else { return }
        pendingHazard = .init(coordinate: hazard.coordinate, hazard: hazard)
    }
    func removeHazard(_ id: UUID) {
        if pendingHazard?.hazard?.id == id { pendingHazard = nil }
        savedHazards.removeAll { $0.id == id }
    }

    /// Dragged to a new spot on the chart.
    func moveHazard(_ id: UUID, to coordinate: CLLocationCoordinate2D) {
        guard let i = savedHazards.firstIndex(where: { $0.id == id && $0.hidden != true }) else { return }
        savedHazards[i].latitude = coordinate.latitude
        savedHazards[i].longitude = coordinate.longitude
    }

    /// How far the stern reaches at full swing: the rode taut at the lowest water, plus the whole boat.
    var sternReach: Double { scopeReach + scope.boatLength }

    /// The nearest hazard to the swing and the gap to it (negative when the swing reaches into it).
    var nearestHazard: (hazard: Hazard, clearance: Double)? {
        guard let anchor else { return nil }
        return Clearance.nearest(anchor: anchor, sternReach: sternReach, hazards: hazards)
    }

    /// The arrows on the chart that nudge the anchor a step at a time; shown after a drag or from the Anchor tab.
    @Published var showNudgePad = false
    /// One nudge: 5 ft, or 1 m in metric.
    var nudgeStep: Double { units == .feet ? 1.524 : 1.0 }

    /// Moves the anchor one step toward `bearing` (degrees true), as a hand placement.
    func nudgeAnchor(toward bearing: Double) {
        guard let anchor else { return }
        beginAnchorDrag()
        moveAnchor(to: Geo.destination(from: anchor, bearing: bearing, meters: nudgeStep))
    }

    /// A drag of the anchor pin is starting: if there's no official spot to measure the move from (an anchor saved
    /// before this existed, or one already promoted), the anchor's current spot becomes it.
    func beginAnchorDrag() {
        if originalAnchor == nil, let anchor { originalAnchor = anchor; save() }
    }

    /// Long-pressing the faded original-drop mark removes it and makes the current anchor spot the official one:
    /// the next move measures from here and leaves its faded mark here.
    func clearOriginalAnchor() {
        originalAnchor = anchor
        save()
    }

    func undoAnchorCorrection() {
        guard let previous = anchorCorrection?.previous else { return }
        moveAnchor(to: previous)
        anchorCorrection = nil
    }

    func dismissAnchorCorrection() { anchorCorrection = nil }

    /// Moves a phone position forward to the bow roller, using the best guess at which way the bow points.
    private func placeAtBow(_ position: CLLocationCoordinate2D, accuracy: Double, lyingTo anchor: CLLocationCoordinate2D?,
                            offset: Double? = nil, useApproach: Bool = true) -> AnchorPlacement.Result {
        let newest = approach.last?.timestamp ?? Date()
        let from = useApproach ? approach.first { newest.timeIntervalSince($0.timestamp) <= approachLookback }?.coordinate : nil
        let wind = windNow
        return AnchorPlacement.place(phone: position, gpsAccuracy: accuracy, bowOffset: offset ?? ScopeCalculator.gpsFromBow(scope),
                                     approachFrom: from, lyingTo: anchor, windFrom: wind?.direction, windKnots: wind?.speed)
    }

    // MARK: Retrieving

    /// While raising: where the anchor lies, so the helm can steer up to it. Nil when not retrieving.
    @Published private(set) var retrieveTarget: CLLocationCoordinate2D?
    private var retrieveDepth = 0.0

    /// Bow to anchor, and which way to steer, from the latest fix.
    var retrievalGuide: RetrievalGuide? {
        guard hasFreshPosition, let retrieveTarget, let fix else { return nil }
        return .make(phone: fix, anchor: retrieveTarget, bowOffset: ScopeCalculator.gpsFromBow(scope), depth: retrieveDepth)
    }

    /// Ends the watch as Raise does, but keeps the anchor's position to steer back to it.
    func startRetrieval() {
        guard let anchor else { return }
        let depth = liveDepth
        raiseAnchor()
        retrieveTarget = anchor
        retrieveDepth = depth
    }

    func endRetrieval() { retrieveTarget = nil }

    func raiseAnchor() {
        logStay()
        hideHazards()
        hiddenOutlook = []
        lockedOutlook = []
        anchor = nil
        anchorUncertainty = nil
        anchorPlacement = nil
        anchorEstimate = nil
        estimatePending = nil
        resetDrift()
        distance = nil
        anchorDropped = nil
        originalAnchor = nil
        showNudgePad = false
        anchorCorrection = nil
        awaitingSwingFix = false
        rodeOutSet = nil
        rodeConfirmed = false
        placingAnchor = false
        outsideCount = 0
        track = []
        maxDistance = 0
        silence(snoozeAfter: false)
        player.disarm()
        gps?.keepsRunningInBackground = false
        pokeControls()
        save()
    }

    func recenter() { recenterTick += 1 }

    /// Shows the controls and restarts the idle countdown. Nothing hides while an alarm is active or
    /// while the user is placing the anchor. The bottom panel also stays up until there is an anchor;
    /// the side buttons (if set to fade) don't wait for one.
    func pokeControls() {
        controlsVisible = true
        sideButtonsVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let delay = self?.controlsFadeDelay else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let busy = self.alarm != nil || self.placingAnchor
            if self.fadeSideButtons, !busy { self.sideButtonsVisible = false }
            if self.anchor != nil, !busy { self.controlsVisible = false }
            // Something couldn't hide yet: check again after another delay.
            if self.controlsVisible || (self.fadeSideButtons && self.sideButtonsVisible) { self.scheduleHide() }
        }
    }

    /// factor < 1 zooms in, > 1 zooms out.
    func zoom(by factor: Double) {
        zoomFactor = factor
        zoomTick += 1
    }

    private func setAnchor(_ coordinate: CLLocationCoordinate2D) {
        bindEnvironment(to: coordinate)
        anchor = coordinate
        player.arm()
        pollDevice()
        gps?.keepsRunningInBackground = true
        outsideCount = 0
        // Distances measured from the old spot don't compare with ones from the new.
        distanceLog = []
        distanceTrend = nil
        if let fix { distance = Geo.distance(coordinate, fix.coordinate) }
        evaluate()
    }

    // MARK: Position handling

    func ingest(_ new: Fix, receivedAt: Date? = nil) {
        rawFix = new                    // rejected callbacks remain available in diagnostics
        let now = receivedAt ?? clock()
        lastFixArrival = now
        arrivals.append(now)
        arrivals.removeAll { now.timeIntervalSince($0) > 10 }
        updateRate = Double(arrivals.count) / 10
        gpsLog.append((now, new))
        gpsLog.removeAll { now.timeIntervalSince($0.time) > gpsLogWindow }

        // A fix this poor can't tell a boat that has drifted from one that hasn't: leave distance, track
        // and alarm to the last good ones.
        guard CLLocationCoordinate2DIsValid(new.coordinate), new.accuracy.isFinite, new.accuracy >= 0,
              now.timeIntervalSince(new.timestamp) >= -2,
              now.timeIntervalSince(new.timestamp) <= maximumFixAge,
              newestMeasurement.map({ new.timestamp > $0 }) ?? true else { return }
        newestMeasurement = new.timestamp
        guard new.accuracy <= usableLimit(for: new) else { return }
        lastUsableFix = new.timestamp
        fix = new
        if anchor == nil { bindEnvironment(to: new.coordinate) }

        recent.append(new)
        recent.removeAll { new.timestamp.timeIntervalSince($0.timestamp) > averagingWindow }
        approach.append(new)
        approach.removeAll { new.timestamp.timeIntervalSince($0.timestamp) > approachLookback * 2 }

        if let last = track.last {
            if Geo.distance(last.coordinate, new.coordinate) >= 0.5 || new.timestamp.timeIntervalSince(last.timestamp) >= 10 {
                track.append(new)
            }
        } else if anchor != nil || trackWhenUnanchored {
            track.append(new)
        }
        if track.count > maxTrackPoints { track.removeFirst(track.count - maxTrackPoints) }

        if let anchor {
            let d = Geo.distance(anchor, new.coordinate)
            distance = d
            maxDistance = max(maxDistance, d)
            if let anchorDropped {
                let minute = now.timeIntervalSince(anchorDropped) * max(simTimeScale, 1) / 60
                if minute >= AnchorEstimate.settleMinutes {
                    distanceLog.append((minute, d))
                    distanceLog.removeAll { minute - $0.minute > 30 }
                    distanceTrend = AnchorDrift.distanceTrend(distanceLog, accuracy: new.accuracy)
                }
            }
            // Outside only when beyond the radius by more than the fix's own error (capped, so a very
            // noisy fix can't postpone a real alarm for long). Back inside resets the count; in the
            // grey zone the count is left alone.
            let benefit = min(new.accuracy, radius * accuracyDiscountCap)
            if d - benefit > radius { outsideCount += 1 } else if d <= radius { outsideCount = 0 }
            evaluate()
        }
    }

    private func evaluate() {
        guard let distance, outsideCount >= confirmFixes, !awaitingSwingFix else { return }
        trigger(.outsideCircle(distance: distance))
    }

    private func checkGPSLost() {
        guard armed, clock().timeIntervalSince(lastFixArrival ?? acquisitionStarted) > gpsLostAfter else { return }
        trigger(.gpsLost)
    }

    /// Fixes are arriving but none has been accurate enough for a minute.
    private func checkGPSPoor() {
        guard armed, let lastFixArrival, clock().timeIntervalSince(lastFixArrival) <= gpsLostAfter else { return }
        let since = lastUsableFix ?? acquisitionStarted
        guard clock().timeIntervalSince(since) > gpsPoorAfter else { return }
        trigger(.gpsPoor)
    }

    // MARK: Alarm

    var alarmHeadline: String? {
        alarm.map { $0.message + (audioFailure == nil ? "" : " — siren unavailable") }
    }

    private func trigger(_ reason: AlarmReason) {
        guard clock() >= (snoozedUntil[reason.kind] ?? .distantPast) else { return }
        if let current = alarm {
            // The siren is already going; only a more serious problem takes over the banner.
            if reason.priority > current.priority { alarm = reason; pokeControls() }
            return
        }
        alarm = reason
        pokeControls()
        player.start(message: reason.message)
        pollDevice()
    }

    /// Stops the siren. The same kind of alarm re-arms after its snooze if the problem persists.
    func silence(snoozeAfter: Bool = true) {
        if snoozeAfter, let reason = alarm {
            snoozedUntil[reason.kind] = clock().addingTimeInterval(reason.snooze)
        } else if !snoozeAfter {
            snoozedUntil = [:]
        }
        alarm = nil
        outsideCount = 0
        player.stop()
        pokeControls()
    }

    // MARK: Persistence (so a relaunch keeps the watch)

    private struct Saved: Codable {
        var latitude: Double, longitude: Double, radius: Double, dropped: Date?
        var uncertainty: Double?
        var originalLatitude: Double?, originalLongitude: Double?
        var awaitingSwingFix: Bool?
        var estimateAutoApplied: Bool?
        var rodeConfirmed: Bool?
    }
    private let key = "anchorwatch.saved"
    private let scopeKey = "anchorwatch.scope.v3"
    private let boatKey = "anchorwatch.boat.v3"

    @Published private(set) var settingsError: String?
    private func encodeSetting<T: Encodable>(_ value: T, key: String) {
        do { defaults.set(try JSONEncoder().encode(value), forKey: key); settingsError = nil }
        catch { settingsError = "Settings could not be saved: " + error.localizedDescription + " Previous saved values have been kept." }
    }
    private func saveScope() { encodeSetting(scope, key: scopeKey) }

    private func saveBoat() {
        encodeSetting(boat, key: boatKey)
    }

    private func save() {
        guard let anchor else { defaults.removeObject(forKey: key); return }
        let saved = Saved(latitude: anchor.latitude, longitude: anchor.longitude, radius: radius, dropped: anchorDropped,
                          uncertainty: anchorUncertainty,
                          originalLatitude: originalAnchor?.latitude, originalLongitude: originalAnchor?.longitude, awaitingSwingFix: awaitingSwingFix,
                          estimateAutoApplied: estimateAutoApplied, rodeConfirmed: rodeConfirmed)
        encodeSetting(saved, key: key)
    }

    private func load() {
        if let raw = defaults.string(forKey: "anchorwatch.units"), let saved = Units(rawValue: raw) { units = saved }
        if let raw = defaults.string(forKey: "anchorwatch.simPlace"), let place = SimulatedLocationSource.Place(rawValue: raw) {
            simPlace = place
            simulator.origin = place.coordinate
        }
        if defaults.object(forKey: "anchorwatch.gustLimit") != nil { gustLimit = defaults.double(forKey: "anchorwatch.gustLimit") }
        if let raw = defaults.string(forKey: "anchorwatch.source"), let kind = SourceKind(rawValue: raw) { sourceKind = kind }
        hideWarningBanners = defaults.bool(forKey: "anchorwatch.hideWarningBanners")
        muteAdvisoryNotifications = defaults.bool(forKey: "anchorwatch.muteAdvisoryNotifications")
        fadeSideButtons = defaults.bool(forKey: "anchorwatch.fadeSideButtons")
        trackWhenUnanchored = defaults.bool(forKey: "anchorwatch.trackUnanchored")
        rodeOutSet = defaults.object(forKey: "anchorwatch.rodeOut") as? Double
        // Tests get an empty log of their own rather than the phone's.
        if defaults === UserDefaults.standard { loadAnchorageLog() }
        if let data = defaults.data(forKey: "anchorwatch.pressure"), let saved = try? JSONDecoder().decode([PressureReading].self, from: data) {
            pressureHistory = saved
            lastPressureAlert = pressureLevel
        }
        if let data = defaults.data(forKey: "anchorwatch.hazards"), let saved = try? JSONDecoder().decode([Hazard].self, from: data) {
            savedHazards = saved.filter { CLLocationCoordinate2DIsValid($0.coordinate) && $0.radius.isFinite && $0.radius >= 0 }
            if savedHazards.count != saved.count { persistenceError = "Invalid saved hazard coordinates were ignored. Review your hazard marks." }
        }
        if defaults.object(forKey: "anchorwatch.radiusFollows") != nil { radiusFollowsRode = defaults.bool(forKey: "anchorwatch.radiusFollows") }
        if defaults.object(forKey: "anchorwatch.currentFactor") != nil { currentFactor = defaults.double(forKey: "anchorwatch.currentFactor") }
        if let raw = defaults.string(forKey: "anchorwatch.bottom"), let bottom = AnchorConditions.Bottom(rawValue: raw) { anchorBottom = bottom }
        // Dev aid: `-layer "NOAA Charts (US)"` overrides the saved map layer at launch.
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "-layer").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        if let raw = override ?? defaults.string(forKey: "anchorwatch.layer"), let layer = ChartLayer(rawValue: raw) { mapLayer = layer }
        if let data = defaults.data(forKey: scopeKey), let s = try? JSONDecoder().decode(ScopeSettings.self, from: data) { scope = s }
        if let data = defaults.data(forKey: boatKey), let b = try? JSONDecoder().decode(BoatProfile.self, from: data) { boat = b }
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        let savedAnchor = CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude)
        guard CLLocationCoordinate2DIsValid(savedAnchor), s.radius.isFinite, s.radius > 0 else {
            persistenceError = "The saved anchor position or radius is invalid. Set and verify the anchor again before relying on monitoring."
            return
        }
        anchor = savedAnchor
        radius = s.radius
        anchorDropped = s.dropped
        anchorUncertainty = s.uncertainty
        rodeConfirmed = s.rodeConfirmed ?? false
        if rodeOutSet == nil { rodeOutSet = rodeSuggested }
        awaitingSwingFix = s.awaitingSwingFix ?? false
        // Older saves cannot tell us whether the mark was hand placed: preserve it unless still finding the anchor.
        estimateAutoApplied = s.estimateAutoApplied ?? !awaitingSwingFix
        if let lat = s.originalLatitude, let lon = s.originalLongitude { let point = CLLocationCoordinate2D(latitude: lat, longitude: lon); if CLLocationCoordinate2DIsValid(point) { originalAnchor = point } }
    }
}
