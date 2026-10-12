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
    case lowBattery(level: Double)

    var message: String {
        switch self {
        case .outsideCircle: return "Boat has left the alarm circle"
        case .gpsLost: return "GPS signal lost"
        case .gpsPoor: return "GPS too inaccurate to watch the anchor"
        case .lowBattery(let level): return String(format: "Phone battery %.0f%% and not charging", level * 100)
        }
    }

    /// Silencing one kind of alarm must not silence the others.
    var kind: String {
        switch self {
        case .outsideCircle: return "outside"
        case .gpsLost: return "gpsLost"
        case .gpsPoor: return "gpsPoor"
        case .lowBattery: return "battery"
        }
    }

    /// A more serious alarm replaces a lesser one that is already sounding.
    var priority: Int {
        switch self {
        case .outsideCircle: return 3
        case .gpsLost, .gpsPoor: return 2
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
    @Published private(set) var track: [Fix] = []
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
        case alarm(AlarmReason)
        /// Outside the circle, including after the alarm was silenced.
        case outside(distance: Double)
        case dragging(AnchorDrift.Result)
        case movingAway(metersPerMinute: Double)
        case holding
    }

    var watchState: WatchState {
        guard anchor != nil else { return .notAnchored }
        if let alarm { return .alarm(alarm) }
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
        if let anchor, let fix, (distance ?? 0) > 1 { return Geo.bearing(from: fix.coordinate, to: anchor) }
        return fix?.course
    }

    var gpsIsPoor: Bool { (fix?.accuracy ?? .infinity) > goodAccuracy }
    /// Too inaccurate to anchor with at all.
    var gpsIsUnusable: Bool { (fix?.accuracy ?? .infinity) > usableLimit(for: fix) }

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
    @Published var radius = 30.0 { didSet { save() } }

    @Published var scope = ScopeSettings() {
        didSet {
            saveScope()
            // A new depth reading belongs to the tide at that moment; the live depth follows the tide from there.
            if scope.depth != oldValue.depth && !loading { depthTideRef = tideNow }
        }
    }

    /// Tide height (above datum) when the depth was last set. Nil until tide data and a depth are both in hand.
    private(set) var depthTideRef: Double? {
        get { defaults.object(forKey: "anchorwatch.depthTideRef") as? Double }
        set { defaults.set(newValue, forKey: "anchorwatch.depthTideRef") }
    }

    /// Depth now: the depth as entered, moved by however much the tide has risen or fallen since.
    var liveDepth: Double {
        guard let ref = depthTideRef, let now = tideNow else { return scope.depth }
        return max(0, scope.depth + now - ref)
    }

    /// Scope with the rode assumed out and the live depth: drops as the tide rises.
    var liveScopeRatio: Double? {
        let height = liveDepth + scope.bowHeight
        return height > 0 ? rodeOutEstimate / height : nil
    }
    @Published var boat = BoatProfile() { didSet { saveBoat() } }

    // MARK: Is the phone ready to keep watch?
    @Published private(set) var batteryLevel: Float?
    @Published private(set) var charging = false
    @Published private(set) var volume: Float?
    @Published private(set) var externalAudioRoute: String?
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
                       accuracy: fix?.accuracy, radius: radius, liveActivity: armed ? liveActivityState : nil,
                       goodAccuracy: goodAccuracy, usableAccuracy: usableLimit(for: fix))
    }

    var watchChecks: [WatchCheck] { Readiness.checks(readinessInput, format: units.format) }
    var watchProblems: [WatchCheck] { watchChecks.filter(\.isProblem) }

    /// Sounds the siren for a few seconds. With a delay you can lock the phone or switch to another app first
    /// to prove the siren works from the background. The audio engine is armed for the test even with no anchor set.
    func testSiren(after delay: TimeInterval = 0) {
        let wasArmed = armed
        if !wasArmed { player.arm() }
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            testingSiren = true                      // shows on the lock screen too, so the whole alarm chain can be checked
            player.test(duration: 4)
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
        Task {
            defer { observationsFetching = false }
            guard let stations = try? await ObservationService.fetchNearby(point) else { return }
            observations = stations
            observationsChecked = Date()
        }
    }

    /// Zooms the chart out to show the boat and the nearby stations, with the overlay turned on.
    @Published private(set) var fitStationsTick = 0

    func fitStations() {
        windOverlayOn = true
        fitStationsTick += 1
    }

    /// Wind actually being measured nearby (the closest station reporting it).
    var observedWind: StationObservation? { observations.first { $0.windSpeed != nil } }

    /// Set when a nearby station reports gusts at or above the warning limit.
    var observedGustAlert: (station: StationObservation, gust: Double)? {
        ObservationMath.gustAlert(observations, limit: gustLimit)
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
        Task {
            defer { alertsFetching = false }
            guard let alerts = try? await AlertService.fetch(near: point) else { return }
            nwsAlerts = alerts
            nwsChecked = Date()
            notifyAboutNew(alerts)
        }
    }

    /// One banner per alert, ever: remembers which alert IDs it has already announced.
    private func notifyAboutNew(_ alerts: [NWSAlert]) {
        var known = Set(defaults.stringArray(forKey: knownAlertsKey) ?? [])
        for alert in alerts where !known.contains(alert.id) {
            known.insert(alert.id)
            if alert.isUrgentForBoaters { player.notice(title: alert.event, message: alert.headline) }
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

    var windNow: WindSample? { windHere?.sample(atHour: 0) }

    var windAlerts: [WindAlert] {
        guard let windHere else { return [] }
        return WindAdvice.alerts(windHere, gustLimit: gustLimit)
    }

    /// Reloads the forecast at the anchorage; called from the 1 s watchdog, so it throttles itself.
    private func refreshWindHereIfDue() {
        guard !windFetching, let point = anchor ?? fix?.coordinate else { return }
        let age = Date().timeIntervalSince(windHere?.fetched ?? .distantPast)
        let sinceAttempt = Date().timeIntervalSince(lastWindAttempt)
        guard (windHere == nil && sinceAttempt > 60) || age > 1800 && sinceAttempt > 60 else { return }
        windFetching = true
        lastWindAttempt = Date()
        Task {
            defer { windFetching = false }
            if let series = try? await WindService.fetch([point]).first { windHere = series }
        }
    }

    /// Loads forecasts for the lattice points under the visible map (debounced; cached for an hour).
    func requestWindGrid(for region: MKCoordinateRegion) {
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
        tide.flatMap { TideMath.rise(from: Date(), hours: tideWindowHours, events: $0.events) }
    }

    var tideNow: Double? { tide.flatMap { TideMath.height(at: Date(), events: $0.events) } }

    func refreshTide() async {
        guard let point = fix?.coordinate ?? anchor else {
            tideStatus = "Waiting for a GPS position to find the nearest tide station…"
            return
        }
        tideStatus = "Finding the nearest tide station…"
        do {
            let result = try await TideService.snapshot(near: point)
            tide = result.snapshot
            if depthTideRef == nil { depthTideRef = tideNow }
            tideIsSaved = result.fromCache
            tideStatus = ""
        } catch {
            tideStatus = error.localizedDescription
        }
    }

    private var tideFetching = false
    private var lastTideAttempt = Date.distantPast

    /// Loads tides for the main screen; called from the 1 s watchdog, so it throttles itself.
    /// Reloads when there's no next high or low left in the predictions, or they're over six hours old.
    private func refreshTideIfDue() {
        guard !tideFetching, fix != nil || anchor != nil, Date().timeIntervalSince(lastTideAttempt) > 300 else { return }
        let age = Date().timeIntervalSince(tide?.fetched ?? .distantPast)
        guard nextTide == nil || age > 6 * 3600 else { return }
        tideFetching = true
        lastTideAttempt = Date()
        Task {
            defer { tideFetching = false }
            await refreshTide()
        }
    }

    func applyTideRise() {
        if let rise = tideRiseEstimate { scope.tideRise = rise }
    }

    var suggestedRadius: Double { ScopeCalculator.suggestedRadius(scope) }
    var rodeToPayOut: Double { ScopeCalculator.rode(scope) }

    /// The four main pages.
    enum Tab: Hashable { case watch, anchor, water, weather }
    @Published var tab = Tab.watch

    /// Depth at the anchorage over the next 24 h, from the live depth and the tide predictions.
    var waterForecast: [(time: Date, depth: Double)] {
        guard let events = tide?.events else { return [] }
        return TideMath.depths(depthNow: liveDepth, events: events, from: Date())
    }

    /// Seabed at the anchorage, chosen on the Anchoring page and used for the forecast check on the main screen.
    @Published var anchorBottom = AnchorConditions.Bottom.mud {
        didSet { defaults.set(anchorBottom.rawValue, forKey: "anchorwatch.bottom") }
    }

    /// Rode assumed out: what the scope calls for, or everything on board if that's less.
    var rodeOutEstimate: Double {
        let carried = BoatMath.rodeCarried(boat)
        return carried > 0 ? min(rodeToPayOut, carried) : rodeToPayOut
    }

    /// Forecast gusts in the next 12 h beyond what this setup can hold.
    var holdingWarning: HoldingWarning? {
        guard let samples = windHere?.samples else { return nil }
        return AnchorMath.forecastWarning(boat, scope: scope, bottom: anchorBottom, rodeOut: rodeOutEstimate, forecast: samples)
    }

    /// The next 24 hours: forecast hours with the safe gust at each hour's depth, and what's coming up.
    /// Recomputed at most once a minute (and as soon as tide or wind data first arrives).
    @Published private(set) var hourlyHolding: [HourlyHolding] = []
    @Published private(set) var outlook: [OutlookItem] = []
    private var lastOutlook = Date.distantPast

    /// The first thing in the outlook worth worrying about.
    var nextRisk: OutlookItem? { Outlook.nextRisk(outlook) }

    private func refreshOutlookIfDue() {
        let hasData = tide != nil || windHere != nil
        guard hasData, Date().timeIntervalSince(lastOutlook) >= 60 || (outlook.isEmpty && hourlyHolding.isEmpty) else { return }
        lastOutlook = Date()
        let depths = waterForecast
        let hourly = Outlook.hourly(boat, scope: scope, bottom: anchorBottom, rodeOut: rodeOutEstimate,
                                    depths: depths, forecast: windHere?.samples ?? [])
        hourlyHolding = hourly
        outlook = Outlook.items(boat, scope: scope, rodeOut: rodeOutEstimate, depths: depths, hourly: hourly,
                                tideTurns: tide?.events ?? [], units: units)
    }

    /// The next predicted high or low.
    var nextTide: TideEvent? { tide.flatMap { TideMath.upcoming($0.events, after: Date(), limit: 1).first } }
    /// How much more rode the scope calls for than the boat carries. Nil when there is enough, or the rode isn't entered.
    var rodeShortfall: Double? {
        let carried = BoatMath.rodeCarried(boat)
        return carried > 0 && rodeToPayOut > carried ? rodeToPayOut - carried : nil
    }

    func applySuggestedRadius() { radius = min(max(suggestedRadius, 10), 300) }

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
    @Published var units: Units = .feet

    /// A real iPhone defaults to its GPS; the iOS Simulator has none, so it defaults to the fake one.
    #if targetEnvironment(simulator)
    @Published var sourceKind: SourceKind = .simulator { didSet { sourceChanged(oldValue) } }
    #else
    @Published var sourceKind: SourceKind = .gps { didSet { sourceChanged(oldValue) } }
    #endif
    @Published var scenario: SimulatedLocationSource.Scenario = .swinging { didSet { simulator.scenario = scenario; simulator.restart() } }
    @Published var simSpeed = 1.0 { didSet { simulator.speed = simSpeed } }

    /// Where the simulated boat starts. Changing it moves the boat, so any anchor set at the old spot is raised
    /// and the position-dependent data (tides, wind, stations, alerts) is reloaded for the new one.
    @Published var simPlace: SimulatedLocationSource.Place = .rocheHarbor {
        didSet {
            guard !loading, simPlace != oldValue else { return }
            defaults.set(simPlace.rawValue, forKey: "anchorwatch.simPlace")
            simulator.origin = simPlace.coordinate
            raiseAnchor()
            fix = nil
            track = []
            tide = nil
            windHere = nil; windGrid = []; lastWindAttempt = .distantPast
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
    private let player: AlarmPlaying
    private let liveActivity: LiveActivityControlling
    private let defaults: UserDefaults
    private var outsideCount = 0
    private var snoozedUntil: [String: Date] = [:]
    private var lastFixArrival: Date?
    private var lastUsableFix: Date?
    private var watchdog: Timer?

    init(player: AlarmPlaying? = nil, liveActivity: LiveActivityControlling? = nil, defaults: UserDefaults = .standard, useGPSHardware: Bool = true) {
        self.player = player ?? AlarmPlayer()
        self.liveActivity = liveActivity ?? LiveActivityController()
        self.defaults = defaults
        self.gps = useGPSHardware ? GPSLocationSource() : nil
        load()
        loading = false
    }

    func start() {
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
                self?.dropAnchor()
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

    /// Everything that guards the anchor, once a second. No network use, so tests can call it.
    func safetyChecks() {
        checkGPSLost()
        checkGPSPoor()
        checkBattery()
        player.ensureRunning()
        pollDevice()
        liveActivity.update(snapshot)
        if liveActivityState != liveActivity.state { liveActivityState = liveActivity.state }
    }

    /// What the lock-screen Live Activity shows; nil when no anchor is set.
    var snapshot: WatchSnapshot? {
        guard armed else { return nil }
        let fraction = radius > 0 ? (distance ?? 0) / radius : 0
        let distanceText = distance.map(units.format) ?? "--"
        if testingSiren, alarm == nil {
            return WatchSnapshot(distanceText: distanceText, radiusText: units.format(radius), fraction: fraction, status: .alarm,
                                 headline: "Siren test, not a real alarm")
        }
        if let alarm {
            return WatchSnapshot(distanceText: distanceText, radiusText: units.format(radius), fraction: fraction, status: .alarm, headline: alarm.message)
        }
        if let problem = watchProblems.first(where: { $0.state == .critical }) {
            return WatchSnapshot(distanceText: distanceText, radiusText: units.format(radius), fraction: fraction, status: .caution, headline: problem.title)
        }
        return WatchSnapshot(distanceText: distanceText, radiusText: units.format(radius), fraction: fraction, status: .holding,
                             headline: fraction < 0.5 ? "Holding well" : "Holding, swinging wide")
    }

    private func refreshData() {
        if Date().timeIntervalSince(lastEstimate) >= max(2, estimateInterval / simTimeScale) { updateAnchorEstimate() }
        refreshPermissionsIfDue()
        refreshWindHereIfDue()
        refreshTideIfDue()
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
        switch sourceKind {
        case .simulator: simulator.restart()
        case .gps: gps?.start()
        }
    }

    // MARK: Anchor control

    func dropAnchor() {
        guard let fix, let position = averagedPosition, let accuracy = averagedAccuracy else { return }
        let placed = placeAtBow(position, accuracy: accuracy, lyingTo: nil)
        setAnchor(placed.coordinate)
        anchorUncertainty = placed.uncertainty
        anchorPlacement = placed
        anchorEstimate = nil
        estimatePending = .collecting(minutes: 0)
        resetDrift()
        pokeControls()
        anchorDropped = Date()
        // Keep the way in when recording under way; otherwise the track starts at the drop.
        if trackWhenUnanchored { if track.last != fix { track.append(fix) } } else { track = [fix] }
        maxDistance = 0
        save()
    }

    /// Relocate the anchor after it was set (drag the pin, tap the map, or snap to the boat).
    func moveAnchor(to coordinate: CLLocationCoordinate2D) {
        guard anchor != nil else { return }
        setAnchor(coordinate)
        anchorUncertainty = nil     // placed by hand, not by GPS
        anchorPlacement = nil
        pokeControls()
        maxDistance = distance ?? 0
        placingAnchor = false
        save()
    }

    func moveAnchorToBoat() {
        guard let position = averagedPosition, let accuracy = averagedAccuracy else { return }
        let placed = placeAtBow(position, accuracy: accuracy, lyingTo: anchor)
        moveAnchor(to: placed.coordinate)
        anchorUncertainty = placed.uncertainty
        anchorPlacement = placed
        save()
    }

    /// Simulated seconds per real second: the sim speed when the simulator is the position source.
    var simTimeScale: Double { sourceKind == .simulator ? simSpeed : 1 }

    /// Refits the anchor position from the swing. Called once a minute; tests call it directly.
    func updateAnchorEstimate() {
        lastEstimate = Date()
        guard let anchor, let anchorDropped else { anchorEstimate = nil; estimatePending = nil; return }
        let wind = windNow
        let modelRadius = ScopeCalculator.horizontalReach(scope) + ScopeCalculator.gpsFromBow(scope)
        switch AnchorEstimate.evaluate(track: track, dropped: anchorDropped, mark: anchor, modelRadius: modelRadius,
                                       windFrom: wind?.direction, windKnots: wind?.speed, timeScale: simTimeScale) {
        case .success(let r): anchorEstimate = r; estimatePending = nil
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

    /// Moves a phone position forward to the bow roller, using the best guess at which way the bow points.
    private func placeAtBow(_ position: CLLocationCoordinate2D, accuracy: Double, lyingTo anchor: CLLocationCoordinate2D?) -> AnchorPlacement.Result {
        let newest = approach.last?.timestamp ?? Date()
        let from = approach.first { newest.timeIntervalSince($0.timestamp) <= approachLookback }?.coordinate
        let wind = windNow
        return AnchorPlacement.place(phone: position, gpsAccuracy: accuracy, bowOffset: ScopeCalculator.gpsFromBow(scope),
                                     approachFrom: from, lyingTo: anchor, windFrom: wind?.direction, windKnots: wind?.speed)
    }

    func raiseAnchor() {
        anchor = nil
        anchorUncertainty = nil
        anchorPlacement = nil
        anchorEstimate = nil
        estimatePending = nil
        resetDrift()
        distance = nil
        anchorDropped = nil
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
        anchor = coordinate
        player.arm()
        gps?.keepsRunningInBackground = true
        outsideCount = 0
        // Distances measured from the old spot don't compare with ones from the new.
        distanceLog = []
        distanceTrend = nil
        if let fix { distance = Geo.distance(coordinate, fix.coordinate) }
        evaluate()
    }

    // MARK: Position handling

    func ingest(_ new: Fix) {
        fix = new                       // always shown, so the screen reports poor accuracy honestly
        let now = Date()
        lastFixArrival = now
        arrivals.append(now)
        arrivals.removeAll { now.timeIntervalSince($0) > 10 }
        updateRate = Double(arrivals.count) / 10
        gpsLog.append((now, new))
        gpsLog.removeAll { now.timeIntervalSince($0.time) > gpsLogWindow }

        // A fix this poor can't tell a boat that has drifted from one that hasn't: leave distance, track
        // and alarm to the last good ones.
        guard new.accuracy <= usableLimit(for: new) else { return }
        lastUsableFix = now

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
        guard let distance, outsideCount >= confirmFixes else { return }
        trigger(.outsideCircle(distance: distance))
    }

    private func checkGPSLost() {
        guard anchor != nil, let lastFixArrival,
              Date().timeIntervalSince(lastFixArrival) > gpsLostAfter else { return }
        trigger(.gpsLost)
    }

    /// Fixes are arriving but none has been accurate enough for a minute.
    private func checkGPSPoor() {
        guard armed, let lastFixArrival, Date().timeIntervalSince(lastFixArrival) <= gpsLostAfter else { return }
        let since = lastUsableFix ?? anchorDropped ?? lastFixArrival
        guard Date().timeIntervalSince(since) > gpsPoorAfter else { return }
        trigger(.gpsPoor)
    }

    // MARK: Alarm

    private func trigger(_ reason: AlarmReason) {
        guard Date() >= (snoozedUntil[reason.kind] ?? .distantPast) else { return }
        if let current = alarm {
            // The siren is already going; only a more serious problem takes over the banner.
            if reason.priority > current.priority { alarm = reason; pokeControls() }
            return
        }
        alarm = reason
        pokeControls()
        player.start(message: reason.message)
    }

    /// Stops the siren. The same kind of alarm re-arms after its snooze if the problem persists.
    func silence(snoozeAfter: Bool = true) {
        if snoozeAfter, let reason = alarm {
            snoozedUntil[reason.kind] = Date().addingTimeInterval(reason.snooze)
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
    }
    private let key = "anchorwatch.saved"
    private let scopeKey = "anchorwatch.scope.v3"
    private let boatKey = "anchorwatch.boat.v3"

    private func saveScope() {
        defaults.set(try? JSONEncoder().encode(scope), forKey: scopeKey)
    }

    private func saveBoat() {
        defaults.set(try? JSONEncoder().encode(boat), forKey: boatKey)
    }

    private func save() {
        guard let anchor else { defaults.removeObject(forKey: key); return }
        let saved = Saved(latitude: anchor.latitude, longitude: anchor.longitude, radius: radius, dropped: anchorDropped,
                          uncertainty: anchorUncertainty)
        defaults.set(try? JSONEncoder().encode(saved), forKey: key)
    }

    private func load() {
        if let raw = defaults.string(forKey: "anchorwatch.simPlace"), let place = SimulatedLocationSource.Place(rawValue: raw) {
            simPlace = place
            simulator.origin = place.coordinate
        }
        if defaults.object(forKey: "anchorwatch.gustLimit") != nil { gustLimit = defaults.double(forKey: "anchorwatch.gustLimit") }
        if let raw = defaults.string(forKey: "anchorwatch.source"), let kind = SourceKind(rawValue: raw) { sourceKind = kind }
        fadeSideButtons = defaults.bool(forKey: "anchorwatch.fadeSideButtons")
        trackWhenUnanchored = defaults.bool(forKey: "anchorwatch.trackUnanchored")
        if let raw = defaults.string(forKey: "anchorwatch.bottom"), let bottom = AnchorConditions.Bottom(rawValue: raw) { anchorBottom = bottom }
        // Dev aid: `-layer "NOAA Charts (US)"` overrides the saved map layer at launch.
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "-layer").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        if let raw = override ?? defaults.string(forKey: "anchorwatch.layer"), let layer = ChartLayer(rawValue: raw) { mapLayer = layer }
        if let data = defaults.data(forKey: scopeKey), let s = try? JSONDecoder().decode(ScopeSettings.self, from: data) { scope = s }
        if let data = defaults.data(forKey: boatKey), let b = try? JSONDecoder().decode(BoatProfile.self, from: data) { boat = b }
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        anchor = CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude)
        radius = s.radius
        anchorDropped = s.dropped
        anchorUncertainty = s.uncertainty
    }
}
