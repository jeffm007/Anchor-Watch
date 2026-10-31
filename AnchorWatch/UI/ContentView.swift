import SwiftUI
import CoreLocation

/// Navigation-first tabs; legacy engine destinations still route to the right conditions page.
struct RootView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @State private var showingMore = false
    @State private var showingPlan = false
    @StateObject private var navigation = NavigationStore()
    private var selection: Binding<Int> {
        Binding(get: { showingPlan ? 4 : showingMore ? 3 : (engine.tab == .watch ? 0 : engine.tab == .anchor ? 1 : 2) }, set: { value in
            showingMore = value == 3
            showingPlan = value == 4
            switch value {
            case 0: engine.tab = .watch
            case 1: engine.tab = .anchor
            case 2: if engine.tab != .water && engine.tab != .weather { engine.tab = .water }
            default: break
            }
        })
    }
    var body: some View {
        TabView(selection: selection) {
            ContentView().tabItem { Label("Charts", systemImage: "map") }.tag(0)
            WaypointPlanView(openCharts: { showingPlan = false; showingMore = false; engine.tab = .watch }).tabItem { Label("Plan", systemImage: "mappin.and.ellipse") }.tag(4)
            AnchoringView()
                .tabItem { Label { Text("Anchor") } icon: { Image(uiImage: AnchorTabIcon.image) } }.tag(1)
            VStack(spacing: 0) {
                Picker("Conditions", selection: Binding(get: { engine.tab == .weather }, set: { engine.tab = $0 ? .weather : .water })) {
                    Text("Water").tag(false)
                    Text("Weather").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal).padding(.top, 8)
                if engine.tab == .weather { ConditionsView() } else { WaterView() }
            }.tabItem { Label("Conditions", systemImage: "water.waves") }.tag(2)
            NavigationMoreView(openCharts: { showingMore = false; engine.tab = .watch }).tabItem { Label("More", systemImage: "ellipsis.circle") }.tag(3)
        }
        .environmentObject(navigation)
        .sheet(item: $navigation.draft) { waypoint in WaypointEditor(waypoint: waypoint).environmentObject(navigation) }
        .onChange(of: engine.rawFix) { _, fix in navigation.ingest(fix) }
        .onChange(of: navigation.activeID) { _, id in if id != nil { showingPlan = false; showingMore = false; engine.tab = .watch } }
        .onChange(of: navigation.placing) { _, placing in if placing { showingPlan = false; showingMore = false; engine.tab = .watch } }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let alarm = engine.alarm {
                AlarmBanner(reason: alarm).padding(.horizontal, 12).padding(.vertical, 4)
            } else if engine.anchor != nil && (showingPlan || showingMore || engine.tab != .anchor) {
                Button { showingPlan = false; showingMore = false; engine.tab = .anchor } label: {
                    Label(engine.monitoring.title, systemImage: engine.monitoring.icon)
                        .font(.caption.bold()).foregroundStyle(engine.monitoring.color)
                        .frame(maxWidth: .infinity).padding(6).background(.thinMaterial)
                }.accessibilityLabel("Open anchor monitoring")
            }
        }
        .onChange(of: engine.tab) { _, _ in showingMore = false; showingPlan = false }
        .fullScreenCover(isPresented: Binding(get: { engine.retrieveTarget != nil },
                                              set: { if !$0 { engine.endRetrieval() } })) { RetrieveView() }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-showAnchoring") { engine.tab = .anchor }
            if args.contains("-showDepth") { engine.tab = .water }
            if args.contains("-showConditions") { engine.tab = .weather }
            if args.contains("-showNudge") { engine.showNudgePad = true }
        }
    }
}

private struct NavigationMoreView: View {
    var openCharts: () -> Void
    @EnvironmentObject var engine: AnchorWatchEngine
    @State private var settings = false
    var body: some View {
        NavigationStack {
            List {
                Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
                NavigationLink { BoatProfileView() } label: { Label("Boat profile", systemImage: "sailboat") }
                Button {
                    engine.mapLayer = .offlineENC
                    openCharts()
                } label: { Label("Offline charts · library and imports", systemImage: "map") }
                NavigationLink { UserGuideView() } label: { Label("User guide", systemImage: "book") }
                NavigationLink { QuickGuideView() } label: { Label("Quick guide", systemImage: "questionmark.circle") }
            }.navigationTitle("More")
        }.sheet(isPresented: $settings) { SettingsView() }
    }
}

/// Arrows that move the anchor a step north, south, east or west, for fine-tuning without dragging.
struct NudgePad: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    var body: some View {
        VStack(spacing: 2) {
            arrow("arrowtriangle.up.fill", 0, "North")
            HStack(spacing: 2) {
                arrow("arrowtriangle.left.fill", 270, "West")
                Button { engine.showNudgePad = false } label: {
                    Image(systemName: "xmark").font(.caption.bold()).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close fine-tune")
                arrow("arrowtriangle.right.fill", 90, "East")
            }
            arrow("arrowtriangle.down.fill", 180, "South")
            Text("\(engine.units.format(engine.nudgeStep)) a tap").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.primary)
    }

    private func arrow(_ icon: String, _ bearing: Double, _ name: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            engine.nudgeAnchor(toward: bearing)
        } label: {
            Image(systemName: icon).font(.system(size: 20)).frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("Move anchor \(name)")
    }
}

/// Simulated time of day, how long the simulation has run and how fast, so the speed-up is visible.
struct SimClockBadge: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            if let clock = engine.simulatedClock {
                let h = Int(clock.elapsed / 3600), m = Int(clock.elapsed / 60) % 60
                Label("\(clock.time.formatted(date: .omitted, time: .shortened)) · +\(h)h \(String(format: "%02d", m))m · \(Int(engine.simSpeed))×",
                      systemImage: "timer")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.yellow, in: Capsule())
            }
        }
        .allowsHitTesting(false)
    }
}

/// SF Symbols has no anchor, so the tab icon is the anchor glyph drawn as a template image.
enum AnchorTabIcon {
    static let image: UIImage = {
        let font = UIFont.systemFont(ofSize: 22, weight: .regular)
        let text = anchorGlyph as NSString
        let size = text.size(withAttributes: [.font: font])
        return UIGraphicsImageRenderer(size: size).image { _ in
            text.draw(at: .zero, withAttributes: [.font: font, .foregroundColor: UIColor.black])
        }.withRenderingMode(.alwaysTemplate)
    }()
}

struct ContentView: View {
    @EnvironmentObject var navigation: NavigationStore
    @State private var chartViewport = ChartMapViewportState()
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dynamicTypeSize) private var textSize
    // `-showSettings` opens the settings sheet at launch, for screenshots.
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-showSettings")
    @State private var showAlerts = false
    @State private var showHiddenHazards = false
    // `-showGuide` opens the user guide, `-guideTopic <id>` one topic of it, at launch, for screenshots.
    @State private var showGuide = ProcessInfo.processInfo.arguments.contains("-showGuide")
    // `-night` opens night mode at launch, for screenshots.
    @State private var showNight = ProcessInfo.processInfo.arguments.contains("-night")
    // `-showQuickGuide` opens the quick guide at launch, for screenshots.
    @State private var showQuickGuide = ProcessInfo.processInfo.arguments.contains("-showQuickGuide")
    @State private var guideTopic: GuideTopic? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-guideTopic"), args.indices.contains(i + 1) else { return nil }
        return UserGuideContent.topics.first { $0.id == args[i + 1] }
    }()
    // `-showCheck` opens the watch check at launch, for screenshots.
    @State private var showWatchCheck = ProcessInfo.processInfo.arguments.contains("-showCheck")
    // `-showBoat` opens the boat profile at launch, for screenshots.
    @State private var showBoat = ProcessInfo.processInfo.arguments.contains("-showBoat")

    @AppStorage("anchorwatch.dashboardExpanded") private var dashboardExpanded = true
    @State private var watchPanelHeights: [String: CGFloat] = [:]
    @State private var offlineENCZoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Charts").font(.headline)
                Spacer()
                Button { engine.tab = .anchor } label: { Text("Anchor") }
                Menu {
                    Picker("Chart source", selection: $engine.mapLayer) {
                        ForEach(ChartLayer.allCases) { Text($0.displayName).tag($0) }
                    }
                } label: { Label("Source", systemImage: "map") }
            }.padding(.horizontal).padding(.vertical, 8)
            if engine.sourceKind == .simulator {
                Text("Simulated GPS · not your real position").font(.caption.bold()).foregroundStyle(.yellow)
            }
            if navigation.placing {
                HStack { Text("Tap chart to save a waypoint"); Button("Cancel") { navigation.placing = false } }.font(.caption).padding(8)
            }
            chartPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            NavigationReadout().padding(.horizontal, 8)
            if engine.mapLayer != .offlineENC { controlRow.padding(.horizontal, 8).padding(.vertical, 4) }
        }
        .background(Color(red: 0.06, green: 0.09, blue: 0.15))
        .preferredColorScheme(.dark)
        // Coming back from a sheet shows the buttons again, rather than leaving them faded.
        .onChange(of: showSettings) { _, open in if !open { engine.pokeControls() } }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAlerts) { AlertsView() }
        .sheet(isPresented: $showHiddenHazards) { HiddenHazardsView() }
        .sheet(isPresented: $showWatchCheck) { WatchCheckView() }
        .sheet(item: $engine.pendingHazard) { pending in HazardSheet(coordinate: pending.coordinate, existing: pending.hazard) }
        .fullScreenCover(isPresented: $showNight) { NightModeView() }
        .sheet(isPresented: $showQuickGuide) {
            NavigationStack { QuickGuideView().toolbar { Button("Done") { showQuickGuide = false } } }
        }
        .sheet(isPresented: $showGuide) {
            NavigationStack { UserGuideView().toolbar { Button("Done") { showGuide = false } } }
        }
        .sheet(item: $guideTopic) { topic in
            NavigationStack { GuideTopicView(topic: topic).toolbar { Button("Done") { guideTopic = nil } } }
        }
        .sheet(isPresented: $showBoat) { NavigationStack { BoatProfileView() } }
    }

    private var dashboard: some View {
        DisclosureGroup(isExpanded: $dashboardExpanded) {
            DashboardTiles(openConditions: { engine.tab = .weather }, openDepth: { engine.tab = .water },
                           openAnchoring: { engine.tab = .anchor }).padding(.top, 6)
        } label: {
            Text("Dashboard").font(.caption.bold()).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("dashboardGrid")
    }

    private var secondaryDetails: some View {
        VStack(spacing: 10) {
            AnchorCorrectionBanner()
            if let drift = engine.anchorDrift { DriftBanner(drift: drift) }
            if !engine.hiddenHazards.isEmpty {
                Button("Hidden hazards (\(engine.hiddenHazards.count))") { showHiddenHazards = true }
                    .font(.footnote).accessibilityIdentifier("hiddenHazards")
            }
            NoticesCard(openAnchoring: { engine.tab = .anchor }, openConditions: { engine.tab = .weather },
                        openAlerts: { showAlerts = true }, openWatchCheck: { showWatchCheck = true })
        }
    }

    /// The chart with status, wind-time and anchor-placement overlays.
    private var chartPanel: some View {
        ZStack(alignment: .bottom) {
            Group {
                if engine.mapLayer == .offlineENC {
                    OfflineENCView(engine: engine, zoom: $offlineENCZoom, fullScreen: true)
                } else {
                    ChartMapView(engine: engine, viewportState: chartViewport)
                }
            }
            VStack(spacing: 8) {
                if let status = engine.chartStatus {
                    Text(status).font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if engine.windOverlayOn {
                    WindTimeBar()
                        .opacity(engine.controlsVisible ? 1 : 0)
                        .allowsHitTesting(engine.controlsVisible)
                        .animation(.easeInOut(duration: 0.6), value: engine.controlsVisible)
                        // Dragging the hour slider keeps the controls up.
                        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in engine.pokeControls() })
                }
                if engine.placingAnchor {
                    HStack {
                        Text("Tap the map to place the anchor")
                        Button("Cancel") { engine.placingAnchor = false }.bold()
                    }
                    .padding(8).padding(.horizontal, 6).background(.thinMaterial, in: Capsule())
                }

            }
            .padding(8)
        }
        .overlay(alignment: .topLeading) { SimClockBadge().padding(8) }
        .overlay(alignment: .bottomLeading) {
            if engine.mapLayer == .seaMap || engine.mapLayer == .satellite {
                Link("© OpenStreetMap contributors · OpenSeaMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    .font(.caption2).foregroundStyle(.primary).padding(4).background(.regularMaterial).padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if engine.showNudgePad && engine.anchor != nil { NudgePad().padding(10) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    /// The tools that used to run down the right edge of the chart.
    private var controlRow: some View {
        HStack(spacing: 0) {
            Group {
                RoundButton(icon: "gearshape", label: "Settings") { showSettings = true }
                Menu {
                    Button { engine.mapLayer = .offlineENC } label: {
                        Label("Charts", systemImage: "map.fill")
                    }
                    Divider()
                    Picker("Map", selection: $engine.mapLayer) {
                        ForEach(ChartLayer.allCases) { Text($0.displayName).tag($0) }
                    }
                } label: { RoundIcon(icon: "map") }.accessibilityLabel("Chart layer")
                Button { engine.windOverlayOn.toggle() } label: {
                    RoundIcon(icon: "wind", active: engine.windOverlayOn)
                }.accessibilityLabel(engine.windOverlayOn ? "Hide wind overlay" : "Show wind overlay")
                Button { engine.toggleTideStationsOverlay() } label: {
                    RoundIcon(icon: "water.waves", active: engine.tideStationsOverlayOn)
                }.accessibilityLabel(engine.tideStationsOverlayOn ? "Hide tide stations" : "Show tide stations")
                RoundButton(icon: "scope", label: "Recenter chart") { engine.recenter() }
                RoundButton(icon: "moon.fill", label: "Night mode") { showNight = true }
                RoundButton(icon: "plus", label: "Zoom in") {
                    if engine.mapLayer == .offlineENC { offlineENCZoom = min(24, offlineENCZoom * 2) }
                    else { engine.zoom(by: 0.5) }
                }
                RoundButton(icon: "minus", label: "Zoom out") {
                    if engine.mapLayer == .offlineENC { offlineENCZoom = max(0.5, offlineENCZoom / 2) }
                    else { engine.zoom(by: 2) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(true)
        // Using a button restarts the fade timer.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in engine.pokeControls() })
    }
}

/// Measure only the content around the map, so the map can consume all remaining height.
private struct WatchPanelHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Red warning when the rolling swing fits show the anchor moving: it can come well before the boat
/// leaves the alarm circle.
struct DriftBanner: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    let drift: AnchorDrift.Result

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.up").font(.title3.bold())
                .rotationEffect(.degrees(drift.bearing))        // points the way the anchor is moving (north up)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.25), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Anchor appears to be dragging").bold()
                Text("\(engine.units.format(drift.distance)) \(Compass.name(drift.bearing)) in \(Int(drift.minutes.rounded())) min (\(engine.units.format(drift.metersPerMinute * 10)) per 10 min). Check your position and be ready to re-anchor.")
                    .font(.footnote)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.red, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

struct AlarmBanner: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    let reason: AlarmReason

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(engine.alarmHeadline ?? reason.message).bold()
            Spacer()
            Button("Silence") { engine.silence() }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.red)
        }
        .padding(12)
        .background(.red, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }
}

/// Alarm radius, swing fit and the anchor buttons, for the Anchoring page once anchored.
/// `onMove` runs when Move Anchor is tapped, so the page can close and leave the chart free for the tap.
struct AnchorRadiusControls: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    let onMove: () -> Void
    @State private var showScope = false
    @State private var raising = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Button { showScope = true } label: {
                    Label("Scope calculator · suggests \(engine.units.format(engine.suggestedRadius))", systemImage: "ruler")
                }.font(.footnote)
                if engine.awaitingSwingFix {
                    Text("Finding anchor. The circle alarm is not armed until a swing fit succeeds or you place the anchor yourself.")
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                    Button("Place anchor on chart") { engine.placingAnchor = true; onMove() }.font(.footnote.bold())
                }
                swingFit
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Button { engine.placingAnchor = true; onMove() } label: {
                        Label("Move Anchor", systemImage: "hand.tap").frame(maxWidth: .infinity)
                    }
                    Button { engine.moveAnchorToBoat() } label: {
                        Label("Anchor → Boat", systemImage: "location").frame(maxWidth: .infinity)
                    }
                }
                GridRow {
                    Button { engine.showNudgePad = true; onMove() } label: {
                        Label("Fine-tune", systemImage: "arrow.up.and.down.and.arrow.left.and.right").frame(maxWidth: .infinity)
                    }
                    Button(role: .destructive) { raising = true } label: {
                        Label("Raise", systemImage: "arrow.up.to.line").frame(maxWidth: .infinity)
                    }
                    .confirmationDialog("Raise the anchor", isPresented: $raising, titleVisibility: .visible) {
                        Button("Retrieve Anchor") { engine.startRetrieval() }
                        Button("Raise Anchor", role: .destructive) { engine.raiseAnchor() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Both end the watch and hide marked hazards. You can restore them from Hidden hazards. Retrieve then shows the way from the bow to the anchor.")
                    }
                }
            }
            .buttonStyle(.bordered).font(.footnote).labelStyle(.titleOnly).lineLimit(1)
            if let placed = engine.anchorPlacement {
                Text(placementNote(placed)).font(.caption2).foregroundStyle(.secondary)
            }
            Text("Long-press and drag the ⚓ pin on the chart to fine-tune its position.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showScope) { ScopeView() }
    }

    /// What the swing says about where the anchor really is, with an offer to move the mark there.
    @ViewBuilder private var swingFit: some View {
        let units = engine.units
        if let estimate = engine.anchorEstimate, let anchor = engine.anchor {
            let off = Geo.distance(anchor, estimate.center)
            let error = units.format(estimate.semiMajor)
            if estimate.method == .fixedRadius {
                Text("Not enough swing to locate the anchor independently. This estimate assumes the rode reach; the anchor mark stays fixed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if off <= estimate.semiMajor {
                Label("Swing agrees with your anchor mark (±\(error))", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("Swing puts the anchor \(units.format(off)) \(Compass.name(Geo.bearing(from: anchor, to: estimate.center))) of your mark (±\(error))",
                          systemImage: "scope")
                        .font(.caption).foregroundStyle(.purple)
                    Spacer(minLength: 4)
                    if estimate.windAgrees != false {
                        Button("Move there") { engine.moveAnchorToEstimate() }
                            .font(.caption.bold()).buttonStyle(.bordered).tint(.purple)
                    }
                }
            }
            if estimate.windAgrees == false {
                Text("The wind direction doesn't match this yet; give it more time.").font(.caption2).foregroundStyle(.orange)
            }
        } else if let pending = engine.estimatePending {
            switch pending {
            case .collecting(let minutes):
                Text("Finding the anchor from the swing: \(Int(minutes)) of \(Int(AnchorEstimate.minMinutes)) min").font(.caption2).foregroundStyle(.secondary)
            case .tooUncertain(let semiMajor):
                Text("Not enough swing yet to pin down the anchor (±\(units.format(semiMajor)))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Says how the drop point was moved from the phone to the bow roller.
    private func placementNote(_ placed: AnchorPlacement.Result) -> String {
        let offset = engine.units.format(engine.dropOffset)
        let toward = placed.bowBearing.map { " toward \(Compass.name($0))" } ?? ""
        switch placed.source {
        case .approach: return "Anchor set \(offset) ahead of the phone\(toward), the way you came in."
        case .wind: return "Anchor set \(offset) ahead of the phone\(toward), into the wind."
        case .anchor: return "Anchor set \(offset) ahead of the phone\(toward), along the rode."
        case .unknown: return "Bow direction unknown, so the anchor is at the phone; the dotted circle allows for it."
        }
    }

    /// Slider works in metres; steps are 5 m regardless of display units.
}

struct SettingsView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        QuickGuideView()
                    } label: {
                        Label("Quick Guide", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("quickGuide")
                    NavigationLink {
                        UserGuideView()
                    } label: {
                        Label("User Guide", systemImage: "book")
                    }
                    .accessibilityIdentifier("userGuide")
                    NavigationLink {
                        BoatProfileView()
                    } label: {
                        Label("Boat Profile", systemImage: "sailboat")
                    }
                    .accessibilityIdentifier("boatProfile")
                    NavigationLink {
                        AnchorageLogView()
                    } label: {
                        Label("Anchorage Log", systemImage: "book.closed")
                    }
                    .accessibilityIdentifier("anchorageLog")
                }
                Section {
                    Toggle("Hide warning banners", isOn: $engine.hideWarningBanners)
                        .accessibilityIdentifier("hideWarningBanners")
                    Toggle("Silence advisory notifications", isOn: $engine.muteAdvisoryNotifications)
                        .accessibilityIdentifier("muteAdvisoryNotifications")
                    NavigationLink("Review warnings") { WarningReviewView() }
                } header: {
                    Text("Warnings")
                } footer: {
                    Text("Review warnings from the Alarm ON menu at any time. Hiding banners keeps forecast and advisory warnings off the dashboard. Silencing stops new weather and barometer notifications. Anchor alarms, drift warnings and critical monitoring problems stay active.")
                }
                Section {
                    Stepper(value: $engine.gustLimit, in: 10...50, step: 5) {
                        LabeledContent("Gust Warning", value: "\(Int(engine.gustLimit)) kt")
                    }
                    Toggle("Track", isOn: $engine.trackWhenUnanchored)
                    Toggle("Fade Buttons", isOn: $engine.fadeSideButtons)
                    LabeledContent("Units") {
                        Picker("Units", selection: $engine.units) {
                            Text("Metric").tag(Units.meters)
                            Text("Feet").tag(Units.feet)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                Section {
                    NavigationLink {
                        TestingView()
                    } label: {
                        Label("Testing", systemImage: "wrench.and.screwdriver")
                    }
                    .accessibilityIdentifier("testing")
                }
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About NavAide", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("about")
                } footer: {
                    Text("Version " + AppVersion.version + " · Build " + AppVersion.build)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Read the installed app's metadata so the screen always identifies the binary actually running.
private enum AppVersion {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown" }
    static var environment: String {
        #if targetEnvironment(simulator)
        "iOS Simulator"
        #else
        "iPhone"
        #endif
    }
}

struct AboutView: View {
    var body: some View {
        Form {
            Section {
                Label("NavAide", systemImage: "info.circle.fill").font(.title2.bold())
                Text("Anchor monitoring and anchorage planning").foregroundStyle(.secondary)
            }
            Section("Installed version") {
                LabeledContent("Version", value: AppVersion.version)
                LabeledContent("Build number", value: AppVersion.build)
            }
            .textSelection(.enabled)
            Section("Running on") {
                LabeledContent("Environment", value: AppVersion.environment)
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
            }
        }
        .navigationTitle("About NavAide")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Position source, the simulator and the watch check: things for trying the app out, kept off the main settings.
struct TestingView: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    var body: some View {
        Form {
            Section("Position source") {
                Picker("Source", selection: $engine.sourceKind) {
                    ForEach(AnchorWatchEngine.SourceKind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            if engine.sourceKind == .gps {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 8) {
                            reading("External (GLO)", engine.receiverFix, now: context.date)
                            phoneReading(now: context.date)
                            LabeledContent("In use", value: engine.fix.map { $0.external ? "External" : "iPhone" } ?? "--")
                        }
                    }
                } header: { Text("GPS receiver") } footer: {
                    Text("While an external receiver is connected, iOS sends only its positions. If it goes quiet for \(Int(FixSelector.timeout)) s, the iPhone's own GPS takes over.")
                }
            }
            if engine.sourceKind == .simulator {
                Section("Simulator") {
                    Picker("Start location", selection: $engine.simPlace) {
                        ForEach(SimulatedLocationSource.Place.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Scenario", selection: $engine.scenario) {
                        ForEach(SimulatedLocationSource.Scenario.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Speed", selection: $engine.simSpeed) {
                        ForEach([1.0, 5, 10, 30, 60, 120, 300], id: \.self) { Text("\(Int($0))×").tag($0) }
                    }
                    if engine.scenario.weather != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if let status = engine.simulatorStatus {
                                Text(status).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Text("A day of wind, tidal current and tide moving the boat on its rode: it wanders in the slack in light air and swings when wind or tide takes hold. Uses your boat, rode out and depth. At 300× a day takes under 5 minutes.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("At 30× or 60×, swing-fit waits and the track speed up too: at 60× the anchor estimate appears about 22 seconds after you drop. Try the Wide swing scenario.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                NavigationLink {
                    GPSQualityView()
                } label: {
                    Label("GPS Quality", systemImage: "scope")
                }
            }
            Section {
                NavigationLink {
                    WatchCheckList().navigationTitle("Watch check").navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Watch check and test siren", systemImage: "checklist")
                }
            }
        }
        .navigationTitle("Testing")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// iOS stops sending the iPhone's own positions while an external receiver reports; say so rather than show a stale one.
    private func phoneReading(now: Date) -> some View {
        let receiverActive = engine.receiverFix.map { now.timeIntervalSince($0.timestamp) < FixSelector.timeout } ?? false
        let phoneStale = engine.phoneFix.map { now.timeIntervalSince($0.timestamp) >= FixSelector.timeout } ?? true
        return Group {
            if receiverActive && phoneStale {
                LabeledContent("iPhone", value: "Not reporting while an external receiver is connected")
            } else {
                reading("iPhone", engine.phoneFix, now: now)
            }
        }
    }

    private func reading(_ title: String, _ fix: Fix?, now: Date) -> some View {
        LabeledContent(title, value: fix.map {
            "±\(engine.units.format($0.accuracy)) · \(max(0, Int(now.timeIntervalSince($0.timestamp))))s ago"
        } ?? "Nothing yet")
    }
}

/// Plain anchor glyph (text style, not emoji); SF Symbols has no anchor.
let anchorGlyph = "\u{2693}\u{FE0E}"

struct RoundIcon: View {
    let icon: String
    var active = false
    /// Draws `icon` as text instead of an SF Symbol, for glyphs SF Symbols lacks.
    var isText = false
    var body: some View {
        Group {
            if isText { Text(icon).font(.title2) } else { Image(systemName: icon) }
        }
            .font(.system(size: 20))
            .frame(width: 44, height: 44)
            .background(active ? AnyShapeStyle(Color.orange.opacity(0.35)) : AnyShapeStyle(.regularMaterial), in: Circle())
            .overlay(Circle().stroke(active ? Color.orange : .clear, lineWidth: 2))
    }
}

struct RoundButton: View {
    let icon: String
    var label: String = ""
    let action: () -> Void
    var body: some View { Button(action: action) { RoundIcon(icon: icon) }.accessibilityLabel(label.isEmpty ? icon : label) }
}

struct ScopeView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Your boat and anchorage") {
                    field("Water depth", \.depth, step: 1)
                    field("Expected tide rise", \.tideRise, step: 1)
                    field("Bow roller height above water", \.bowHeight, step: 0.5)
                    field("Boat length (phone amidships)", \.boatLength, step: 1)
                    field("Safety margin", \.margin, step: 1)
                    Picker("Scope ratio", selection: $engine.scope.scopeRatio) {
                        ForEach([3.0, 5.0, 7.0, 10.0], id: \.self) { Text("\(Int($0)):1").tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section("Result") {
                    row("Rode to pay out", engine.rodeToPayOut)
                    row("Horizontal reach", ScopeCalculator.horizontalReach(engine.highWaterScope))
                    row("Suggested alarm radius", engine.suggestedRadius).bold()
                    Button("Use suggested radius") { engine.applySuggestedRadius(); dismiss() }
                    if let shortfall = engine.rodeShortfall {
                        Label("That's \(engine.units.format(shortfall)) more rode than the boat carries.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    Text("Enter a new sounder reading when you measure the depth. Estimated depth follows tide changes from that reading time and station. " + engine.depthReferenceDetail)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Scope")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func row(_ title: String, _ meters: Double) -> some View {
        LabeledContent(title, value: engine.units.format(meters))
    }

    /// Stepper that edits a metre value in the user's display units.
    private func field(_ title: String, _ key: WritableKeyPath<ScopeSettings, Double>, step: Double) -> some View {
        let u = engine.units
        let binding = Binding(
            get: { (key == \ScopeSettings.depth ? engine.liveDepth : engine.scope[keyPath: key]) * u.perMeter },
            set: {
                if key == \ScopeSettings.depth { engine.setDepthReading(max(0, $0 / u.perMeter)) }
                else { engine.scope[keyPath: key] = max(0, $0 / u.perMeter) }
            })
        return Stepper(value: binding, in: 0...500, step: step) {
            LabeledContent(title, value: String(format: "%.1f %@", binding.wrappedValue, u.symbol))
        }
    }
}

/// Quick depth entry. The depth feeds the scope calculation (rode to pay out and suggested radius).
/// The depth you read off the sounder: the first thing on the Water page.
struct DepthEntrySection: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @FocusState private var editingDepth: Bool

    private var units: Units { engine.units }

    private var depth: Binding<Double> {
        Binding(get: { engine.liveDepth * units.perMeter },
                set: { engine.setDepthReading(max(0, $0 / units.perMeter)) })
    }

    private var step: Double { units == .feet ? 1 : 0.5 }

    var body: some View {
        Section("Water depth below the surface") {
            HStack {
                Button { depth.wrappedValue = max(0, depth.wrappedValue - step) } label: {
                    Image(systemName: "minus.circle.fill").font(.largeTitle).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Decrease water depth")
                TextField("Depth", value: depth, format: .number.precision(.fractionLength(0...1)))
                    .focused($editingDepth).accessibilityLabel("Water depth in " + units.symbol)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text(units.symbol).font(.title3).foregroundStyle(.secondary)
                Button { depth.wrappedValue += step } label: {
                    Image(systemName: "plus.circle.fill").font(.largeTitle).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Increase water depth")
            }
            .buttonStyle(.borderless)
            Text("Use depth from the water surface to the seabed. Correct sounder readings shown below the keel or transducer before entering.").font(.footnote).foregroundStyle(.secondary)
            Text(engine.depthReferenceDetail).font(.caption).foregroundStyle(.secondary)
            Button("Confirm this depth as a new sounder reading") { engine.setDepthReading(engine.liveDepth); editingDepth = false }.font(.footnote)
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editingDepth = false } }
        }
    }
}

/// Tide and scope settings: the lower part of the Water page.
struct DepthSections: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    private var units: Units { engine.units }

    private var tide: Binding<Double> {
        Binding(get: { engine.scope.tideRise * units.perMeter },
                set: { engine.scope.tideRise = max(0, $0 / units.perMeter) })
    }

    private var step: Double { units == .feet ? 1 : 0.5 }

    /// NOAA tide predictions for the nearest station, with a button to copy the expected rise.
    @ViewBuilder private var tideData: some View {
        if let tide = engine.tide, let here = engine.fix?.coordinate {
            let km = Geo.distance(tide.station.coordinate, here) / 1000
            VStack(alignment: .leading, spacing: 2) {
                Text(tide.station.name).font(.subheadline.bold())
                Text(String(format: "%.0f km away · ", km) + "\(tide.station.sourceName) · heights above chart datum").font(.caption).foregroundStyle(.secondary)
                if tide.heightModelID != nil {
                    Text("Offline harmonic heights · CHS chart datum. High/low events: CHS.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(ValidatedBCTides.attribution).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let now = engine.tideNow {
                LabeledContent("Right now (estimated)", value: units.formatTenths(now))
            }
            ForEach(TideMath.upcoming(tide.events, after: Date(), limit: 4), id: \.time) { event in
                LabeledContent(event.isHigh ? "High" : "Low") {
                    Text("\(event.time.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · \(units.formatTenths(event.height))")
                }
            }
            Picker("Cover the next", selection: $engine.tideWindowHours) {
                Text("6 h").tag(6.0); Text("12 h").tag(12.0); Text("24 h").tag(24.0)
            }.pickerStyle(.segmented)
            if let rise = engine.tideRiseEstimate {
                Button("Use tide data: +\(units.formatTenths(rise))") { engine.applyTideRise() }
            }
            if engine.tideIsSaved {
                Text("Cached predictions fetched \(tide.fetched.formatted(.relative(presentation: .named))).")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } else if engine.tideStatus.isEmpty == false {
            Label("Tides unavailable", systemImage: "exclamationmark.triangle")
                .font(.subheadline.bold())
            Text(engine.tideStatus).font(.footnote).foregroundStyle(.secondary)
        }
        if let record = engine.environmentRecords["tide"] { Text(record.description(at: Date())).font(.caption).foregroundStyle(.secondary) }
        Button("Refresh tide data") { Task { await engine.refreshTide() } }
            .font(.footnote)
    }

    var body: some View {
        Section("Tide") {
            tideData
            Text("Stations are selected by distance, not by matching the local tide regime. Verify these predictions for your anchorage before using tide-adjusted depth.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button { tide.wrappedValue = max(0, tide.wrappedValue - step) } label: {
                    Image(systemName: "minus.circle.fill").font(.title)
                }
                Spacer()
                VStack {
                    TextField("Tide", value: tide, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("expected rise above this depth (\(units.symbol))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { tide.wrappedValue += step } label: {
                    Image(systemName: "plus.circle.fill").font(.title)
                }
            }
            .buttonStyle(.borderless)
            LabeledContent("Depth to cover at high water", value: units.format(engine.depthAtNextHigh.depth))
        }
        Section("Scope") {
            Picker("Scope ratio", selection: $engine.scope.scopeRatio) {
                ForEach([3.0, 5.0, 7.0, 10.0], id: \.self) { Text("\(Int($0)):1").tag($0) }
            }.pickerStyle(.segmented)
            LabeledContent("Rode to pay out", value: units.format(engine.rodeToPayOut)).bold()
            if let shortfall = engine.rodeShortfall {
                Label("That's \(units.format(shortfall)) more rode than the boat carries.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
            LabeledContent("Suggested alarm radius", value: units.format(engine.suggestedRadius))
            Button("Use suggested radius") { engine.applySuggestedRadius() }
            Text("Rode = ratio × (depth + tide + \(units.format(engine.scope.bowHeight)) bow height). Change the bow height and boat length in Settings → Boat Profile.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

enum StationName {
    static func short(_ name: String) -> String {
        let parts = name.components(separatedBy: " - ")
        guard parts.count > 1 else { return name }
        return parts[0].allSatisfy(\.isNumber) ? parts[1] : parts[0]
    }
}

/// Every nearby station's latest readings.
struct ConditionsView: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    private var units: Units { engine.units }

    var body: some View {
        NavigationStack {
            List {
                if let now = engine.windNow {
                    Section(engine.sourceKind == .simulator ? "Simulated wind now" : "Forecast at your position") {
                        Label("\(Int(now.speed.rounded())) kt · gusts \(Int(now.gust.rounded())) kt", systemImage: "wind").font(.title2.bold())
                        Text("From " + Compass.name(now.direction)).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup(engine.forecastStatusText) {
                        Text(engine.environmentCoverage.summary).font(.footnote)
                        ForEach(engine.environmentDetails, id: \.self) { Text($0).font(.caption) }
                        Text(engine.adviceAssumptions).font(.footnote)
                        Button("Retry all environmental data") { engine.retryEnvironment() }
                    }
                }
                WindOutlookSections()
                BarometerSection()
                if !engine.observations.isEmpty {
                    Section {
                        Button { engine.fitStations(); engine.tab = .watch } label: {
                            Label("Show these stations on the chart", systemImage: "mappin.and.ellipse")
                        }
                    }
                }
                if engine.observations.isEmpty {
                    Section { Text(engine.environmentRecords["observations"]?.description(at: Date()) ?? "Nearby observations not loaded.")
                        .foregroundStyle(.secondary) }
                }
                ForEach(engine.observations) { obs in
                    Section {
                        row(obs)
                    } header: {
                        Text(StationName.short(obs.name)).textCase(nil)
                    } footer: {
                        Text("\(obs.id) · \(Int(obs.distanceKm.rounded())) km \(Compass.name(obs.bearing)) · \(obs.time.formatted(.relative(presentation: .named)))")
                    }
                }
                Section {
                    Text("Observations from NOAA and Environment Canada, refreshed about every 10 minutes. Forecast wind comes from a computer model and can differ from what a nearby station measures.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Weather")
            .navigationBarTitleDisplayMode(.inline)
            
        }
    }

    @ViewBuilder private func row(_ obs: StationObservation) -> some View {
        if let speed = obs.windSpeed {
            LabeledContent("Wind", value: (obs.windDirection.map { "\(Compass.name($0)) " } ?? "")
                + "\(Int(speed.rounded())) kt" + (obs.gust.map { ", gusts \(Int($0.rounded()))" } ?? ""))
        }
        if let height = obs.waveHeight {
            LabeledContent("Waves", value: units.formatTenths(height) + (obs.wavePeriod.map { String(format: " at %.0f s", $0) } ?? ""))
        }
        if let pressure = obs.pressure {
            LabeledContent("Pressure", value: String(format: "%.1f hPa", pressure) + (obs.trendArrow.map { " \($0)" } ?? ""))
        }
        if let air = obs.airTemp { LabeledContent("Air", value: units.formatTemp(air)) }
        if let water = obs.waterTemp { LabeledContent("Water", value: units.formatTemp(water)) }
        if let vis = obs.visibility { LabeledContent("Visibility", value: String(format: "%.1f nm", vis)) }
    }
}

/// Chooses which forecast hour the wind arrows show.
struct WindTimeBar: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    private var label: String {
        if engine.windHour == 0 { return "Wind forecast: now" }
        let date = Date().addingTimeInterval(engine.windHour * 3600)
        return "Wind forecast: +\(Int(engine.windHour)) h · \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.bold())
            Slider(value: $engine.windHour, in: 0...48, step: 1)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension NWSSeverity {
    var color: Color {
        switch self {
        case .extreme, .severe: return .red
        case .moderate: return .orange
        case .minor, .unknown: return .yellow
        }
    }
}

struct AlertsView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if engine.nwsAlerts.isEmpty {
                    Text(engine.alertsAreCurrent ? "No active alerts returned by the latest check for this location." : "Current alert status unavailable. Check data age or retry.").foregroundStyle(.secondary)
                }
                ForEach(engine.activeAlerts) { alert in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(alert.event, systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(alert.severity.color)
                        if let ends = alert.ends {
                            Text("Until \(ends.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))")
                                .font(.subheadline.bold())
                        }
                        if !alert.areaDesc.isEmpty { Text(alert.areaDesc).font(.caption).foregroundStyle(.secondary) }
                        if !alert.description.isEmpty { Text(alert.description).font(.footnote) }
                        if !alert.instruction.isEmpty { Text(alert.instruction).font(.footnote.italic()) }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    if let record = engine.environmentRecords["alerts"] { Text(record.description(at: Date())) }
                    if let checked = engine.nwsChecked {
                        Text("National Weather Service · checked \(checked.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("National Weather Service · not checked yet")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Weather Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct WatchCheckView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WatchCheckList()
                .navigationTitle("Watch check")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct WatchCheckList: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    var body: some View {
        List {
            Section {
                ForEach(engine.watchChecks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(check.state)).foregroundStyle(color(check.state)).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).font(.subheadline.bold())
                            if !check.detail.isEmpty { Text(check.detail).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            } header: {
                Text(engine.armed ? "Keeping watch" : "Before you set the anchor")
            }
            Section {
                Button { engine.testSiren() } label: { Label("Test siren now (4 seconds)", systemImage: "speaker.wave.3.fill") }
                Button { engine.testSiren(after: 15) } label: { Label("Test siren in 15 seconds", systemImage: "timer") }
            } header: {
                Text("Siren test")
            } footer: {
                Text("The second one waits 15 seconds so you can lock the phone or switch to another app first, to prove the siren sounds from the background.")
            }
        }
    }

    private func icon(_ s: WatchCheck.State) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(_ s: WatchCheck.State) -> Color {
        switch s {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .gray
        }
    }
}


/// Raised-anchor marks are kept out of the chart and warnings until explicitly restored.
struct HiddenHazardsView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: Hazard?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(engine.hiddenHazards) { hazard in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(hazard.label).font(.headline)
                            Text("\(hazard.kind.rawValue) · Keep \(engine.units.format(hazard.radius)) off")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Restore") { engine.restoreHazard(hazard.id) }
                                Spacer()
                                Button("Delete permanently", role: .destructive) { deleting = hazard }
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                    if engine.hiddenHazards.isEmpty { Text("No hidden hazards").foregroundStyle(.secondary) }
                } footer: {
                    Text("Hidden hazards do not appear on the chart or affect clearance and warnings. Restore keeps the original map position; you can then drag the mark to adjust it. Dropping anchor does not restore marks automatically.")
                }
            }
            .navigationTitle("Hidden hazards")
            .toolbar { Button("Done") { dismiss() } }
            .alert("Delete hazard permanently?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { hazard in
                Button("Delete permanently", role: .destructive) {
                    engine.removeHazard(hazard.id)
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { hazard in
                Text("\(hazard.label) will be deleted and cannot be restored.")
            }
        }
    }
}


/// Stages keypad edits until Done, so entering a multi-digit radius never changes the alarm mid-entry.
struct NumericAdjustment: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                HStack {
                    TextField(title, text: $draft)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .frame(minWidth: 70, maxWidth: 100).focused($editing)
                        .accessibilityLabel(title + " in " + unit)
                    Text(unit).foregroundStyle(.secondary)
                }
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title).accessibilityValue(String(format: "%.1f ", value) + unit)
        }
        .onAppear { refreshDraft() }
        .onChange(of: value) { _, _ in if !editing { refreshDraft() } }
        .onChange(of: editing) { _, active in if !active { commit() } }
        .toolbar {
            if editing {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } }
            }
        }
    }

    private func refreshDraft() { draft = value.formatted(.number.precision(.fractionLength(0...2))) }
    private func commit() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if let number = formatter.number(from: draft)?.doubleValue, number.isFinite {
            value = min(range.upperBound, max(range.lowerBound, number))
        }
        refreshDraft()
    }
}


struct WaypointPlanView: View {
    var openCharts: () -> Void
    @EnvironmentObject var navigation: NavigationStore
    @EnvironmentObject var engine: AnchorWatchEngine
    var body: some View {
        NavigationStack {
            List {
                Section("Add waypoint") {
                    Button("Choose on chart") { engine.placingAnchor = false; navigation.placing = true }
                    Button("Use GPS position") { if let fix = engine.rawFix { navigation.pick(fix.coordinate) } }
                        .disabled(!NavigationMetrics.usable(engine.rawFix, now: Date()))
                    Button("Enter coordinates") { navigation.draft = .init(name: "Waypoint", latitude: 0, longitude: 0) }
                }
                if let error = navigation.error { Text(error).foregroundStyle(.orange) }
                Section("Saved waypoints") {
                    if navigation.waypoints.isEmpty { Text("No saved waypoints yet").foregroundStyle(.secondary) }
                    ForEach(navigation.waypoints) { waypoint in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(waypoint.name).font(.headline)
                            Text(String(format: "%.5f°, %.5f°", waypoint.latitude, waypoint.longitude)).font(.caption)
                            HStack {
                                Button("Go To") { navigation.activeID = waypoint.id; openCharts() }
                                Spacer()
                                Button("Edit") { navigation.draft = waypoint }
                            }.buttonStyle(.bordered)
                        }.swipeActions { Button("Delete", role: .destructive) { navigation.delete(waypoint) } }
                    }
                }
                Text("Go To draws a direct bearing line. It does not check depths, land, hazards, or safe passage.").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("Plan")
        }
    }
}

struct WaypointEditor: View {
    @EnvironmentObject var navigation: NavigationStore
    @Environment(\.dismiss) private var dismiss
    let waypoint: NavigationWaypoint
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var validation: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Latitude, decimal degrees", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude, decimal degrees", text: $longitude).keyboardType(.numbersAndPunctuation)
                Text("North/east are positive; south/west are negative. Example: 48.75, -123.25.").font(.caption)
                if let validation { Text(validation).foregroundStyle(.orange) }
            }.navigationTitle("Waypoint")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        guard let lat = Double(latitude), let lon = Double(longitude) else { validation = "Enter decimal-degree coordinates."; return }
                        var updated = waypoint; updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines); updated.latitude = lat; updated.longitude = lon
                        if navigation.save(updated) { dismiss() } else { validation = navigation.error }
                    } }
                }
        }.onAppear { name = waypoint.name; latitude = String(format: "%.6f", waypoint.latitude); longitude = String(format: "%.6f", waypoint.longitude) }
    }
}

struct NavigationReadout: View {
    @EnvironmentObject var navigation: NavigationStore
    @EnvironmentObject var engine: AnchorWatchEngine
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let valid = NavigationMetrics.usable(engine.rawFix, now: timeline.date)
            let speed = valid ? navigation.speed : nil
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("SOG " + (speed.map { String(format: "%.1f kt", $0 * 1.943844) } ?? "—"))
                    Spacer()
                    let course = valid && (speed ?? 0) >= 0.5 ? engine.rawFix?.course : nil
                    Text("COG " + (course.map { String(format: "%.0f°T", $0) } ?? "—"))
                }
                if let destination = navigation.active {
                    HStack { Text("To " + destination.name).bold(); Spacer(); Button("Stop") { navigation.activeID = nil } }
                    if let metrics = NavigationMetrics.calculate(fix: engine.rawFix, destination: destination, speed: speed, now: timeline.date) {
                        Text(String(format: "%.2f NM · Bearing %.0f°T", metrics.distance / 1852, metrics.bearing))
                        if let seconds = metrics.seconds, seconds < 86400 * 30 {
                            Text("Time \(Int(seconds / 3600))h \(Int(seconds / 60) % 60)m · ETA \(timeline.date.addingTimeInterval(seconds).formatted(date: .abbreviated, time: .shortened))")
                        } else { Text("Time / ETA unavailable at this speed") }
                        Text("Direct line · ETA assumes recent SOG · not a safe route").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !valid { Text("Waiting for a recent, usable GPS position").foregroundStyle(.orange) }
            }.font(.caption.monospacedDigit()).padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
