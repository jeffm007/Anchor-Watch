import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    // `-showSettings` opens the settings sheet at launch, for screenshots.
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-showSettings")
    @State private var showAlerts = false
    // `-showGuide` opens the user guide, `-guideTopic <id>` one topic of it, at launch, for screenshots.
    @State private var showGuide = ProcessInfo.processInfo.arguments.contains("-showGuide")
    @State private var guideTopic: GuideTopic? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-guideTopic"), args.indices.contains(i + 1) else { return nil }
        return UserGuideContent.topics.first { $0.id == args[i + 1] }
    }()
    // `-showCheck` opens the watch check at launch, for screenshots.
    @State private var showWatchCheck = ProcessInfo.processInfo.arguments.contains("-showCheck")
    @State private var showConditions = false
    // `-showDepth` opens the depth sheet at launch, for screenshots.
    @State private var showDepth = ProcessInfo.processInfo.arguments.contains("-showDepth")
    // `-showAnchoring` opens the anchoring conditions screen at launch, for screenshots.
    @State private var showAnchoring = ProcessInfo.processInfo.arguments.contains("-showAnchoring")
    // `-showBoat` opens the boat profile at launch, for screenshots.
    @State private var showBoat = ProcessInfo.processInfo.arguments.contains("-showBoat")

    var body: some View {
        ZStack {
            ChartMapView(engine: engine)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                if let alarm = engine.alarm { AlarmBanner(reason: alarm) }
                if let drift = engine.anchorDrift { DriftBanner(drift: drift) }
                StatsBar()
                WindBar(showConditions: $showConditions)
                AlertsBar(showAlerts: $showAlerts)
                ReadinessBar(show: $showWatchCheck)
                if engine.sourceKind == .simulator {
                    Label("SIMULATED GPS - not your real position", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold()).padding(6)
                        .background(.yellow, in: Capsule()).foregroundStyle(.black)
                }
                Spacer()
                if engine.windOverlayOn { WindTimeBar() }
                if engine.placingAnchor {
                    Text("Tap the map to place the anchor")
                        .padding(8).background(.thinMaterial, in: Capsule())
                }
                ControlsPanel()
                    .opacity(engine.controlsVisible ? 1 : 0)
                    .allowsHitTesting(engine.controlsVisible)   // taps fall through to the map, which brings it back
                    .animation(.easeInOut(duration: 0.6), value: engine.controlsVisible)
            }
            .padding(.horizontal, 12)

            VStack(spacing: 10) {
                Spacer().frame(height: 110)
                RoundButton(icon: "gearshape") { showSettings = true }
                Button { showAnchoring = true } label: { RoundIcon(icon: anchorGlyph, isText: true) }
                    .accessibilityLabel("Anchoring")
                RoundButton(icon: "water.waves") { showDepth = true }
                Menu {
                    Picker("Map", selection: $engine.mapLayer) {
                        ForEach(ChartLayer.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { RoundIcon(icon: "map") }
                Button { engine.windOverlayOn.toggle() } label: {
                    RoundIcon(icon: "wind", active: engine.windOverlayOn)
                }
                RoundButton(icon: "scope") { engine.recenter() }
                RoundButton(icon: "plus") { engine.zoom(by: 0.5) }
                RoundButton(icon: "minus") { engine.zoom(by: 2) }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
            .opacity(engine.sideButtonsVisible ? 1 : 0)
            .allowsHitTesting(engine.sideButtonsVisible)   // taps fall through to the map, which brings them back
            .animation(.easeInOut(duration: 0.6), value: engine.sideButtonsVisible)
            // Using a button restarts the fade timer.
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in engine.pokeControls() })
        }
        // Coming back from a sheet shows the buttons again, rather than leaving them faded.
        .onChange(of: showSettings || showAnchoring || showDepth) { _, open in if !open { engine.pokeControls() } }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showDepth) { DepthView() }
        .sheet(isPresented: $showAlerts) { AlertsView() }
        .sheet(isPresented: $showWatchCheck) { WatchCheckView() }
        .sheet(isPresented: $showGuide) {
            NavigationStack { UserGuideView().toolbar { Button("Done") { showGuide = false } } }
        }
        .sheet(item: $guideTopic) { topic in
            NavigationStack { GuideTopicView(topic: topic).toolbar { Button("Done") { guideTopic = nil } } }
        }
        .sheet(isPresented: $showConditions) { ConditionsView() }
        .sheet(isPresented: $showAnchoring) { AnchoringView() }
        .sheet(isPresented: $showBoat) { NavigationStack { BoatProfileView() } }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
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
            Text(reason.message).bold()
            Spacer()
            Button("Silence") { engine.silence() }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.red)
        }
        .padding(12)
        .background(.red, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }
}

struct StatsBar: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    var body: some View {
        HStack {
            stat("Distance", engine.distance.map(engine.units.format) ?? "--")
            stat("Radius", engine.anchor == nil ? "--" : engine.units.format(engine.radius))
            stat("Max", engine.anchor == nil ? "--" : engine.units.format(engine.maxDistance))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                stat("GPS ± · age", engine.fix.map {
                    "\(engine.units.format($0.accuracy)) · \(max(0, Int(context.date.timeIntervalSince($0.timestamp))))s"
                } ?? "--")
            }
            stat("Fixes/s", String(format: "%.1f", engine.updateRate))
            stat("Depth", engine.units.format(engine.scope.depth))   // manual for now; Phase 2: Raspberry Pi sonar
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).bold()).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ControlsPanel: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @State private var showScope = false

    var body: some View {
        VStack(spacing: 10) {
            if engine.anchor == nil {
                Button { showScope = true } label: {
                    Label("Scope: pay out \(engine.units.format(engine.rodeToPayOut)) of rode", systemImage: "ruler")
                }.font(.footnote)
                if engine.fix == nil {
                    Text("Waiting for a GPS position…").font(.footnote).foregroundStyle(.secondary)
                } else if engine.gpsIsUnusable, let fix = engine.fix {
                    Label("GPS accuracy is only ±\(engine.units.format(fix.accuracy)), too poor to set an anchor. Wait, or move the phone near a window.",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.footnote).foregroundStyle(.red)
                } else if engine.gpsIsPoor, let fix = engine.fix {
                    Label("GPS accuracy is only ±\(engine.units.format(fix.accuracy)). The anchor point may be off; waiting a minute usually helps.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button { engine.dropAnchor() } label: {
                    Label(engine.gpsIsPoor ? "Drop Anchor Anyway" : "Drop Anchor Here", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(engine.gpsIsPoor ? .orange : .accentColor)
                .disabled(engine.fix == nil || engine.gpsIsUnusable)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alarm radius: \(engine.units.format(engine.radius))").font(.subheadline)
                    Slider(value: radiusBinding, in: 10...300, step: 5)
                    Button { showScope = true } label: {
                        Label("Scope calculator · suggests \(engine.units.format(engine.suggestedRadius))", systemImage: "ruler")
                    }.font(.footnote)
                    swingFit
                }
                HStack {
                    Button { engine.placingAnchor.toggle() } label: {
                        Label("Move Anchor", systemImage: "hand.tap")
                    }.tint(engine.placingAnchor ? .orange : .accentColor)
                    Button { engine.moveAnchorToBoat() } label: {
                        Label("Anchor → Boat", systemImage: "location")
                    }
                    Button(role: .destructive) { engine.raiseAnchor() } label: {
                        Label("Raise", systemImage: "arrow.up.to.line")
                    }
                }
                .buttonStyle(.bordered).font(.footnote)
                if let placed = engine.anchorPlacement {
                    Text(placementNote(placed)).font(.caption2).foregroundStyle(.secondary)
                }
                Text("Long-press and drag the ⚓ pin to fine-tune its position.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 8)
        // Any touch inside the panel (slider, buttons) restarts the fade timer.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in engine.pokeControls() })
        .onChange(of: showScope) { _, _ in engine.pokeControls() }
        .sheet(isPresented: $showScope) { ScopeView() }
    }

    /// What the swing says about where the anchor really is, with an offer to move the mark there.
    @ViewBuilder private var swingFit: some View {
        let units = engine.units
        if let estimate = engine.anchorEstimate, let anchor = engine.anchor {
            let off = Geo.distance(anchor, estimate.center)
            let error = units.format(estimate.semiMajor)
            if off <= estimate.semiMajor {
                Label("Swing agrees with your anchor mark (±\(error))", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("Swing puts the anchor \(units.format(off)) \(Compass.name(Geo.bearing(from: anchor, to: estimate.center))) of your mark (±\(error))",
                          systemImage: "scope")
                        .font(.caption).foregroundStyle(.purple)
                    Spacer(minLength: 4)
                    Button("Move there") { engine.moveAnchorToEstimate() }
                        .font(.caption.bold()).buttonStyle(.bordered).tint(.purple)
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
        let offset = engine.units.format(ScopeCalculator.gpsFromBow(engine.scope))
        let toward = placed.bowBearing.map { " toward \(Compass.name($0))" } ?? ""
        switch placed.source {
        case .approach: return "Anchor set \(offset) ahead of the phone\(toward), the way you came in."
        case .wind: return "Anchor set \(offset) ahead of the phone\(toward), into the wind."
        case .anchor: return "Anchor set \(offset) ahead of the phone\(toward), along the rode."
        case .unknown: return "Bow direction unknown, so the anchor is at the phone; the dotted circle allows for it."
        }
    }

    /// Slider works in metres; steps are 5 m regardless of display units.
    private var radiusBinding: Binding<Double> {
        Binding(get: { engine.radius }, set: { engine.radius = $0 })
    }
}

struct SettingsView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        UserGuideView()
                    } label: {
                        Label("User Guide", systemImage: "book")
                    }
                    .accessibilityIdentifier("userGuide")
                } footer: {
                    Text("How to use every part of the app.")
                }
                Section {
                    NavigationLink {
                        BoatProfileView()
                    } label: {
                        LabeledContent {
                            Text(engine.boat.name)
                        } label: {
                            Label("Boat Profile", systemImage: "sailboat")
                        }
                    }
                    .accessibilityIdentifier("boatProfile")
                } footer: {
                    Text("Size, windage and ground tackle, for the rode, scope, holding and wind-load calculations.")
                }
                Section("Position source") {
                    Picker("Source", selection: $engine.sourceKind) {
                        ForEach(AnchorWatchEngine.SourceKind.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
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
                            Text("1×").tag(1.0); Text("5×").tag(5.0); Text("10×").tag(10.0); Text("30×").tag(30.0); Text("60×").tag(60.0)
                        }.pickerStyle(.segmented)
                        Text("At 30× or 60×, swing-fit waits and the track speed up too: at 60× the anchor estimate appears about 22 seconds after you drop. Try the Wide swing scenario.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    NavigationLink {
                        WatchCheckList().navigationTitle("Watch check").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Watch check and test siren", systemImage: "checklist")
                    }
                } footer: {
                    Text("Checks volume, battery, permissions and GPS, and lets you hear the siren.")
                }
                Section {
                    Stepper(value: $engine.gustLimit, in: 10...50, step: 5) {
                        LabeledContent("Warn when gusts reach", value: "\(Int(engine.gustLimit)) kt")
                    }
                } header: { Text("Wind warnings") } footer: {
                    Text("A heads-up on the main screen, not the drag alarm. Also warns of wind shifts of 60° or more in the next 12 hours.")
                }
                Section {
                    Toggle("Record track before anchoring", isOn: $engine.trackWhenUnanchored)
                } header: { Text("Track") } footer: {
                    Text("Draws the purple track while you're under way too, not just at anchor, and keeps the way in when you drop the anchor. Raising the anchor clears the track. Records while the app is open.")
                }
                Section {
                    Toggle("Fade the side buttons", isOn: $engine.fadeSideButtons)
                } header: { Text("Screen") } footer: {
                    Text("Hide the buttons down the right edge after \(Int(engine.controlsFadeDelay)) seconds without a touch, for more chart. Tap the chart to bring them back. They stay up during an alarm.")
                }
                Section("Units") {
                    Picker("Distance", selection: $engine.units) {
                        ForEach(Units.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
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
            .frame(width: 44, height: 44)
            .background(active ? AnyShapeStyle(Color.orange.opacity(0.35)) : AnyShapeStyle(.regularMaterial), in: Circle())
            .overlay(Circle().stroke(active ? Color.orange : .clear, lineWidth: 2))
    }
}

struct RoundButton: View {
    let icon: String
    let action: () -> Void
    var body: some View { Button(action: action) { RoundIcon(icon: icon) } }
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
                    row("Horizontal reach", ScopeCalculator.horizontalReach(engine.scope))
                    row("Suggested alarm radius", engine.suggestedRadius).bold()
                    Button("Use suggested radius") { engine.applySuggestedRadius(); dismiss() }
                    if let shortfall = engine.rodeShortfall {
                        Label("That's \(engine.units.format(shortfall)) more rode than the boat carries.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    Text("Depth is entered by hand for now. Phase 2 will read it from the sonar. The tide rise is added to the depth so the rode covers high water.")
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
            get: { engine.scope[keyPath: key] * u.perMeter },
            set: { engine.scope[keyPath: key] = max(0, $0 / u.perMeter) })
        return Stepper(value: binding, in: 0...500, step: step) {
            LabeledContent(title, value: String(format: "%.1f %@", binding.wrappedValue, u.symbol))
        }
    }
}

/// Quick depth entry. The depth feeds the scope calculation (rode to pay out and suggested radius).
struct DepthView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss

    private var units: Units { engine.units }

    /// Depth in the display units; stored in metres.
    private var depth: Binding<Double> {
        Binding(get: { engine.scope.depth * units.perMeter },
                set: { engine.scope.depth = max(0, $0 / units.perMeter) })
    }

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
                Text("Offline: showing predictions saved \(tide.fetched.formatted(.relative(presentation: .named))).")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } else if engine.tideStatus.isEmpty == false {
            Text(engine.tideStatus).font(.footnote).foregroundStyle(.secondary)
        }
        Button("Refresh tide data") { Task { await engine.refreshTide() } }
            .font(.footnote)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Water depth at the anchorage") {
                    HStack {
                        Button { depth.wrappedValue = max(0, depth.wrappedValue - step) } label: {
                            Image(systemName: "minus.circle.fill").font(.largeTitle)
                        }
                        TextField("Depth", value: depth, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                        Text(units.symbol).font(.title3).foregroundStyle(.secondary)
                        Button { depth.wrappedValue += step } label: {
                            Image(systemName: "plus.circle.fill").font(.largeTitle)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Section("Tide") {
                    tideData
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
                    LabeledContent("Depth to cover at high water", value: units.format(engine.scope.designDepth))
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
                    Button("Use suggested radius") { engine.applySuggestedRadius(); dismiss() }
                    Text("Rode = ratio × (depth + tide + \(units.format(engine.scope.bowHeight)) bow height). Change the bow height and boat length in Settings → Boat Profile.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .task { await engine.refreshTide() }
            .navigationTitle("Depth & Scope")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Forecast wind at the anchorage, the nearest real measurement, and any gust or wind-shift warnings.
/// Tap for the full list of nearby stations.
struct WindBar: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Binding var showConditions: Bool

    var body: some View {
        if showsCard {
            Button { showConditions = true } label: { content }
                .buttonStyle(.plain)
                .padding(.trailing, 60)     // keep clear of the round buttons down the right edge
        }
    }

    private var hasWarnings: Bool { engine.observedGustAlert != nil || !engine.windAlerts.isEmpty }

    /// The full card appears only with the wind overlay. Gust and wind-shift warnings are safety
    /// notices, so they stay up (as a slim card) even when the overlay is off.
    private var showsCard: Bool {
        engine.windOverlayOn ? (engine.windNow != nil || engine.observedWind != nil || hasWarnings) : hasWarnings
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            if engine.windOverlayOn, let now = engine.windNow {
                HStack(spacing: 6) {
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.degrees(now.direction + 180))     // points the way the wind is blowing
                    Text("Forecast \(Compass.name(now.direction)) \(Int(now.speed.rounded())) kt, gusts \(Int(now.gust.rounded()))")
                        .font(.caption.bold())
                }
            }
            if engine.windOverlayOn, let obs = engine.observedWind, let speed = obs.windSpeed {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.blue)
                    Text("Now at \(shortName(obs.name)) (\(Int(obs.distanceKm.rounded())) km): "
                         + (obs.windDirection.map { "\(Compass.name($0)) " } ?? "")
                         + "\(Int(speed.rounded())) kt"
                         + (obs.gust.map { ", gusts \(Int($0.rounded()))" } ?? ""))
                        .font(.caption.bold())
                }
            }
            if let hit = engine.observedGustAlert {
                Label("Observed gusts \(Int(hit.gust.rounded())) kt at \(shortName(hit.station.name))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(engine.windAlerts, id: \.title) { alert in
                Label("\(alert.title) · \(alert.time.formatted(.dateTime.weekday(.abbreviated).hour().minute()))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if engine.windOverlayOn && engine.nwsChecked != nil && engine.nwsAlerts.isEmpty {
                Text("No active National Weather Service alerts").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "9449880 - Friday Harbor, WA" → "Friday Harbor, WA"; "NEW DUNGENESS - 17 NM NE of Port Angeles" → "NEW DUNGENESS".
    private func shortName(_ name: String) -> String { StationName.short(name) }
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
    @Environment(\.dismiss) private var dismiss

    private var units: Units { engine.units }

    var body: some View {
        NavigationStack {
            List {
                if let now = engine.windNow {
                    Section("Forecast at your position") {
                        Text("\(Compass.name(now.direction)) \(Int(now.speed.rounded())) kt, gusts \(Int(now.gust.rounded())) kt")
                    }
                }
                if !engine.observations.isEmpty {
                    Section {
                        Button { engine.fitStations(); dismiss() } label: {
                            Label("Show these stations on the chart", systemImage: "mappin.and.ellipse")
                        }
                    }
                }
                if engine.observations.isEmpty {
                    Section { Text(engine.observationsChecked == nil ? "Looking for nearby stations…" : "No stations reporting within 200 km.")
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
                    Text("Observations from the NOAA National Data Buoy Center, refreshed about every 10 minutes. Forecast wind comes from a computer model and can differ from what a nearby station measures.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Conditions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
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

/// Active National Weather Service alerts for the boat's position. Tap to read the full text.
struct AlertsBar: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Binding var showAlerts: Bool

    var body: some View {
        if !engine.nwsAlerts.isEmpty {
            Button { showAlerts = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(engine.nwsAlerts.prefix(2)) { alert in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(alert.severity.color)
                            Text(alert.event).font(.caption.bold())
                            if let ends = alert.ends {
                                Text("until \(ends.formatted(.dateTime.weekday(.abbreviated).hour().minute()))").font(.caption)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if engine.nwsAlerts.count > 2 {
                        Text("+\(engine.nwsAlerts.count - 2) more").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(engine.nwsAlerts[0].severity.color, lineWidth: 2))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 60)     // keep clear of the round buttons down the right edge
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
                    Text("No active alerts for your position.").foregroundStyle(.secondary)
                }
                ForEach(engine.nwsAlerts) { alert in
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

/// A heads-up on the main screen when the phone isn't ready to keep watch. Tap for the full checklist.
struct ReadinessBar: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Binding var show: Bool

    var body: some View {
        let problems = engine.watchProblems.sorted { $0.state == .critical && $1.state != .critical }
        if engine.armed, let first = problems.first {
            let critical = first.state == .critical
            Button { show = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(critical ? .red : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first.title).font(.caption.bold())
                        if problems.count > 1 { Text("+\(problems.count - 1) more to check").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(critical ? Color.red : Color.orange, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 60)
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
