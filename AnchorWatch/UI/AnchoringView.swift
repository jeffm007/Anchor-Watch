import SwiftUI

/// Conditions knobs, a side view of the rode, and what the boat profile says about holding in them.
struct AnchoringView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss
    @State private var conditions = AnchorConditions()
    @State private var started = false

    private var units: Units { engine.units }
    private var boat: BoatProfile { engine.boat }
    private var result: AnchorAssessment { AnchorMath.assess(boat, scope: engine.scope, conditions) }

    var body: some View {
        let r = result
        NavigationStack {
            Form {
                Section {
                    RodeDiagram(boat: boat, scope: engine.scope, conditions: conditions, result: r, units: units)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                    statusRow(r)
                }

                Section {
                    knob("Water depth", length($engine.scope.depth), 0...max(units == .feet ? 100 : 30, engine.scope.depth * units.perMeter),
                         step: units == .feet ? 1 : 0.5, format: (units == .feet ? "%.0f " : "%.1f ") + units.symbol)
                    knob("Wind", $conditions.wind, 0...60, step: 1, format: "%.0f kt")
                    knob("Gusts", $conditions.gust, 0...70, step: 1, format: "%.0f kt")
                    knob("Current", $conditions.current, 0...4, step: 0.25, format: "%.2g kt")
                    knob("Waves", length($conditions.waveHeight), 0...(units == .feet ? 10 : 3), step: units == .feet ? 0.5 : 0.1,
                         format: "%.1f " + units.symbol)
                    Picker("Bottom", selection: $conditions.bottom) {
                        ForEach(AnchorConditions.Bottom.allCases) { Text($0.rawValue).tag($0) }
                    }
                    knob("Rode out", length($conditions.rodeOut), 0...max(10, rodeMax * units.perMeter), step: units == .feet ? 5 : 1,
                         format: "%.0f " + units.symbol)
                    if engine.windHere != nil {
                        Button("Use the forecast for the next 12 h") { fillFromForecast() }
                    }
                } header: { Text("Conditions") } footer: {
                    Text("Water depth is the same one Depth & Scope uses; the \(units.formatTenths(engine.scope.tideRise)) tide rise from there is added on top. Gusts drive the loads below.")
                }

                Section("Suggestions") {
                    ForEach(AnchorMath.suggestions(boat, scope: engine.scope, conditions, r, units: units), id: \.self) { tip in
                        Label(tip, systemImage: "lightbulb").font(.subheadline)
                    }
                }

                Section {
                    LabeledContent("Load at \(Int(conditions.gust)) kt gusts", value: units.formatForce(r.load.design))
                    LabeledContent("  wind / current (steady)", value: "\(units.formatForce(r.load.wind)) / \(units.formatForce(r.load.current))")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let gust = r.liftOffGust {
                        LabeledContent("Chain lifts off at", value: gust > 0 ? "\(Int(gust)) kt" : "already")
                    }
                    if let holding = r.holding {
                        LabeledContent("Anchor holding (rough)", value: units.formatForce(holding))
                    }
                    if let safe = r.safeGust {
                        LabeledContent("Safe gust limit", value: "\(Int(safe)) kt").bold()
                        Button("Set gust warning to \(Int(min(50, max(10, safe)))) kt") {
                            engine.gustLimit = min(50, max(10, safe.rounded(.down)))
                        }
                    }
                    if let needed = r.rodeNeeded {
                        LabeledContent("Rode for these gusts", value: units.format(needed))
                    }
                    LabeledContent("Chain on the bottom", value: units.format(r.shape.lying))
                    LabeledContent("Pull angle at the anchor", value: String(format: "%.0f°", r.shape.shankAngle))
                } header: { Text("Worked out") } footer: {
                    Text("Loads include an allowance for yawing and waves. Holding is a rough band for a \(boat.anchorType.rawValue.lowercased()) anchor of \(units.formatWeight(boat.anchorWeight)) in \(conditions.bottom.rawValue.lowercased()); a well-set anchor can do much better or worse.")
                }

                Section {
                    NavigationLink {
                        BoatProfileView()
                    } label: {
                        Label("Boat Profile", systemImage: "sailboat")
                    }
                } footer: {
                    Text("Chain size and length, anchor weights, freeboard, cabin height and snubber are guesses until you measure them. Change them in the Boat Profile.")
                }
            }
            .navigationTitle("Anchoring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear(perform: start)
        }
    }

    /// Most rode the slider offers: everything on board, or enough for the scope if more.
    private var rodeMax: Double {
        max(BoatMath.rodeCarried(boat), engine.rodeToPayOut, conditions.rodeOut)
    }

    /// Opens on the scope calculator's rode (capped to what's aboard) and the forecast, once.
    private func start() {
        guard !started else { return }
        started = true
        let carried = BoatMath.rodeCarried(boat)
        conditions.rodeOut = carried > 0 ? min(engine.rodeToPayOut, carried) : engine.rodeToPayOut
        fillFromForecast()
    }

    private func fillFromForecast() {
        guard let series = engine.windHere else { return }
        let now = Date()
        let window = series.samples.filter { $0.time >= now.addingTimeInterval(-1800) && $0.time <= now.addingTimeInterval(12 * 3600) }
        if let wind = window.map(\.speed).max() { conditions.wind = wind.rounded() }
        if let gust = window.map(\.gust).max() { conditions.gust = gust.rounded() }
    }

    private func statusRow(_ r: AnchorAssessment) -> some View {
        let (text, color, icon): (String, Color, String) = switch r.status {
        case .good: ("Holding well", .green, "checkmark.circle.fill")
        case .marginal: ("Marginal", .orange, "exclamationmark.triangle.fill")
        case .danger: ("At risk of dragging", .red, "xmark.octagon.fill")
        }
        return HStack {
            Label(text, systemImage: icon).foregroundStyle(color).bold()
            Spacer()
            if let safe = r.safeGust {
                Text("good to \(Int(safe)) kt").foregroundStyle(.secondary)
            }
        }
    }

    /// A metre value shown in the user's units.
    private func length(_ meters: Binding<Double>) -> Binding<Double> {
        Binding(get: { meters.wrappedValue * units.perMeter }, set: { meters.wrappedValue = max(0, $0 / units.perMeter) })
    }

    private func knob(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title, value: String(format: format, value.wrappedValue))
            Slider(value: value, in: range, step: step)
        }
    }
}

/// Side view: wind and current from the left, the anchor on the seabed, the rode hanging up to the bow,
/// and the boat lying downwind. Depth is stretched so the curve of the chain shows.
struct RodeDiagram: View {
    let boat: BoatProfile
    let scope: ScopeSettings
    let conditions: AnchorConditions
    let result: AnchorAssessment
    let units: Units

    /// Seabed sand, drawn solid and again see-through over the buried part of the anchor.
    private let seabed = Color(red: 0.80, green: 0.71, blue: 0.58)
    private let steel = Color(white: 0.32)

    var body: some View {
        Canvas { ctx, size in
            let shape = result.shape
            let boatLength = max(scope.boatLength, 5)
            // The boat is drawn larger than life so its detail reads next to a long rode.
            let boatScale = 1.8
            let worldWidth = max(shape.reach, 1) + boatLength * boatScale
            let padLeft = 48.0, padRight = 12.0
            let sx = (size.width - padLeft - padRight) / worldWidth
            let cabin = max(boat.cabinHeight, 1.5)
            let topRoom = scope.bowHeight + cabin * 1.45 + 0.5
            let worldHeight = result.height + topRoom
            let seabedY = size.height - 40
            let sy = (seabedY - 30) / worldHeight
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: padLeft + x * sx, y: seabedY - y * sy) }

            let waterLevel = result.height - scope.bowHeight

            // Water, with waves on the surface.
            var water = Path()
            water.move(to: CGPoint(x: 0, y: seabedY))
            let amplitude = min(conditions.waveHeight * sy / 2, 8)
            for i in 0...60 {
                let x = size.width * Double(i) / 60
                water.addLine(to: CGPoint(x: x, y: p(0, waterLevel).y + sin(Double(i) * 0.9) * amplitude))
            }
            water.addLine(to: CGPoint(x: size.width, y: seabedY))
            water.closeSubpath()
            ctx.fill(water, with: .color(.blue.opacity(0.18)))

            let seabedRect = Path(CGRect(x: 0, y: seabedY, width: size.width, height: size.height - seabedY))
            ctx.fill(seabedRect, with: .color(seabed))

            drawBoat(&ctx, bow: { x, y in p(shape.reach + x * boatScale, waterLevel + y) }, length: boatLength, sx: sx * boatScale, sy: sy)

            // Rode: the part on the bottom in green, the hanging part orange once it pulls up on the anchor.
            if shape.lying > 0 {
                var lying = Path()
                lying.move(to: p(0, 0)); lying.addLine(to: p(shape.lying, 0))
                ctx.stroke(lying, with: .color(.green), lineWidth: 4)
            }
            var hanging = Path()
            let hangingPoints = shape.points.filter { $0.x >= shape.lying }
            if let first = hangingPoints.first {
                hanging.move(to: p(first.x, first.y))
                for point in hangingPoints.dropFirst() { hanging.addLine(to: p(point.x, point.y)) }
            }
            let rodeColor: Color = shape.shankAngle >= 10 ? .red : shape.shankAngle > 0 ? .orange : .primary
            ctx.stroke(hanging, with: .color(rodeColor), style: StrokeStyle(lineWidth: 2.5, dash: boat.rodeType == .allChain ? [] : [6, 3]))

            // Anchor on the end of the rode, flukes dug in: the shank comes out of a mound of sand it ploughed up,
            // and the buried part shows faintly through the bottom.
            let shackle = CGPoint(x: p(0, 0).x, y: seabedY - 3)
            var mound = Path()
            mound.move(to: CGPoint(x: shackle.x - 30, y: seabedY))
            mound.addQuadCurve(to: CGPoint(x: shackle.x - 6, y: seabedY), control: CGPoint(x: shackle.x - 20, y: seabedY - 10))
            mound.closeSubpath()
            ctx.fill(mound, with: .color(seabed))
            drawAnchor(&ctx, at: shackle, angle: shape.shankAngle)
            ctx.fill(seabedRect, with: .color(seabed.opacity(0.55)))
            var surface = Path()
            surface.move(to: CGPoint(x: 0, y: seabedY)); surface.addLine(to: CGPoint(x: size.width, y: seabedY))
            ctx.stroke(surface, with: .color(.brown.opacity(0.5)), lineWidth: 1)

            // Wind above the water, current below.
            arrow(&ctx, from: CGPoint(x: 12, y: 16), length: 46 + min(conditions.gust, 60), color: .secondary,
                  label: "Wind \(Int(conditions.wind)) G\(Int(conditions.gust)) kt")
            if conditions.current > 0 {
                arrow(&ctx, from: CGPoint(x: 12, y: p(0, waterLevel).y + 20), length: 30 + conditions.current * 20, color: .blue,
                      label: String(format: "Current %.2g kt", conditions.current))
            }

            // Depth and rode labels along the bottom.
            let labelY = size.height - 9
            ctx.draw(Text("\(units.format(result.height - scope.bowHeight)) at high water").font(.caption2).foregroundStyle(.black.opacity(0.6)),
                     at: CGPoint(x: size.width - 8, y: labelY), anchor: .trailing)
            ctx.draw(Text("\(units.format(conditions.rodeOut)) out · \(units.format(shape.lying)) on bottom").font(.caption2).foregroundStyle(.black.opacity(0.6)),
                     at: CGPoint(x: 8, y: labelY), anchor: .leading)
        }
        .accessibilityLabel("Side view of the rode: \(units.format(conditions.rodeOut)) out, \(units.format(result.shape.lying)) lying on the bottom")
    }

    /// A plow-style anchor in screen points: shackle at `at`, shank running back and down to the crown,
    /// fluke curling down into the bottom. Tilts up by `angle` degrees as the rode lifts it.
    private func drawAnchor(_ ctx: inout GraphicsContext, at shackle: CGPoint, angle: Double) {
        var a = ctx
        a.translateBy(x: shackle.x, y: shackle.y)
        a.rotate(by: .degrees(-angle))

        var shank = Path()
        shank.move(to: .zero); shank.addLine(to: CGPoint(x: -30, y: 10))
        a.stroke(shank, with: .color(steel), style: StrokeStyle(lineWidth: 4, lineCap: .round))

        var fluke = Path()
        fluke.move(to: CGPoint(x: -34, y: 6))
        fluke.addQuadCurve(to: CGPoint(x: -11, y: 23), control: CGPoint(x: -32, y: 23))
        fluke.addLine(to: CGPoint(x: -16, y: 15))
        fluke.addQuadCurve(to: CGPoint(x: -28, y: 9), control: CGPoint(x: -23, y: 14))
        fluke.closeSubpath()
        a.fill(fluke, with: .color(steel))

        a.stroke(Path(ellipseIn: CGRect(x: -1, y: -5, width: 7, height: 7)), with: .color(steel), lineWidth: 2)
    }

    /// A trawler in profile, drawn from the bow roller aft. `bow(x, y)` maps metres aft of the bow and
    /// above the waterline to the canvas.
    private func drawBoat(_ ctx: inout GraphicsContext, bow b: (Double, Double) -> CGPoint, length L: Double, sx: Double, sy: Double) {
        let bowFreeboard = scope.bowHeight
        let sternFreeboard = bowFreeboard * 0.7
        let C = max(boat.cabinHeight, 1.5)
        let D = max(boat.draft, 0.5)
        func deck(_ x: Double) -> Double { bowFreeboard - (bowFreeboard - sternFreeboard) * pow(x / L, 0.8) }
        let white = Color.white, trim = Color.gray.opacity(0.7), glass = Color(red: 0.12, green: 0.16, blue: 0.22)
        let navy = Color(red: 0.08, green: 0.13, blue: 0.36)

        // Hull: raked stem, long keel, transom, and a sheer that falls toward the stern.
        var hull = Path()
        hull.move(to: b(0, bowFreeboard))
        hull.addQuadCurve(to: b(0.06 * L, 0), control: b(0.01 * L, bowFreeboard * 0.4))
        hull.addQuadCurve(to: b(0.2 * L, -D * 0.6), control: b(0.09 * L, -D * 0.45))
        hull.addLine(to: b(0.62 * L, -D))
        hull.addLine(to: b(0.77 * L, -D))
        hull.addLine(to: b(0.8 * L, -D * 0.4))
        hull.addLine(to: b(0.97 * L, -0.15))
        hull.addLine(to: b(L, sternFreeboard * 0.2))
        hull.addLine(to: b(L, sternFreeboard))
        let sheer = stride(from: 1.0, through: 0, by: -0.05).map { b($0 * L, deck($0 * L)) }
        for point in sheer { hull.addLine(to: point) }
        hull.closeSubpath()
        ctx.fill(hull, with: .color(navy))
        ctx.drawLayer { layer in
            layer.clip(to: hull)
            // Antifouling below the waterline and a white boot stripe on it.
            layer.fill(Path(CGRect(x: b(0, 0).x - 10, y: b(0, -0.05).y, width: L * sx + 20, height: D * sy + 20)),
                       with: .color(Color(white: 0.12)))
            var stripe = Path()
            stripe.move(to: b(0, 0.12)); stripe.addLine(to: b(L, 0.12))
            layer.stroke(stripe, with: .color(white), lineWidth: 2)
        }
        // Teak cap rail along the sheer.
        var cap = Path()
        cap.addLines(sheer)
        ctx.stroke(cap, with: .color(Color(red: 0.72, green: 0.48, blue: 0.27)), lineWidth: 2)
        // Portholes forward.
        for x in [0.16, 0.21, 0.26] {
            let c = b(x * L, deck(x * L) * 0.55)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(Color(white: 0.85)))
        }

        // Pilothouse and saloon, with a roof that overhangs the aft deck.
        let base = deck(0.3 * L)
        let roof = base + C * 0.48
        var house = Path()
        house.move(to: b(0.3 * L, deck(0.3 * L)))
        house.addLine(to: b(0.27 * L, base + C * 0.52))      // reverse-raked pilothouse front
        house.addLine(to: b(0.33 * L, roof))
        house.addLine(to: b(0.96 * L, roof))
        house.addLine(to: b(0.96 * L, roof - C * 0.06))
        house.addLine(to: b(0.86 * L, roof - C * 0.06))
        house.addLine(to: b(0.86 * L, deck(0.86 * L)))
        for x in stride(from: 0.86, through: 0.3, by: -0.04) { house.addLine(to: b(x * L, deck(x * L))) }
        house.closeSubpath()
        ctx.fill(house, with: .color(white))
        ctx.stroke(house, with: .color(trim), lineWidth: 0.75)
        // Post under the overhang.
        var post = Path()
        post.move(to: b(0.95 * L, roof - C * 0.06)); post.addLine(to: b(0.95 * L, deck(0.95 * L)))
        ctx.stroke(post, with: .color(trim), lineWidth: 1)

        // Pilothouse windows (front raked to match) and saloon windows.
        var pilothouse = Path()
        pilothouse.move(to: b(0.296 * L, base + C * 0.27))
        pilothouse.addLine(to: b(0.281 * L, base + C * 0.44))
        pilothouse.addLine(to: b(0.44 * L, base + C * 0.44))
        pilothouse.addLine(to: b(0.44 * L, base + C * 0.27))
        pilothouse.closeSubpath()
        ctx.fill(pilothouse, with: .color(glass))
        for (from, to) in [(0.5, 0.6), (0.62, 0.72), (0.74, 0.83)] {
            let top = b(from * L, deck(from * L) + C * 0.38), bottom = b(to * L, deck(to * L) + C * 0.2)
            ctx.fill(Path(roundedRect: CGRect(x: top.x, y: top.y, width: bottom.x - top.x, height: bottom.y - top.y), cornerRadius: 1.5),
                     with: .color(glass))
        }

        // Flybridge: coaming with a windscreen, hardtop on posts, radar mast and dome.
        let coaming = roof + C * 0.2
        var bridge = Path()
        bridge.move(to: b(0.4 * L, roof))
        bridge.addLine(to: b(0.44 * L, coaming))
        bridge.addLine(to: b(0.82 * L, coaming))
        bridge.addLine(to: b(0.82 * L, roof))
        bridge.closeSubpath()
        ctx.fill(bridge, with: .color(white))
        ctx.stroke(bridge, with: .color(trim), lineWidth: 0.75)
        var screen = Path()
        screen.move(to: b(0.415 * L, roof + C * 0.08)); screen.addLine(to: b(0.44 * L, coaming))
        ctx.stroke(screen, with: .color(glass), lineWidth: 2)

        let hardtop = coaming + C * 0.42
        for x in [0.5, 0.78] {
            var support = Path()
            support.move(to: b(x * L, coaming)); support.addLine(to: b(x * L, hardtop))
            ctx.stroke(support, with: .color(trim), lineWidth: 1.2)
        }
        let topLeft = b(0.46 * L, hardtop + C * 0.06), topRight = b(0.82 * L, hardtop)
        ctx.fill(Path(roundedRect: CGRect(x: topLeft.x, y: topLeft.y, width: topRight.x - topLeft.x, height: topRight.y - topLeft.y),
                      cornerRadius: 2), with: .color(white))
        ctx.stroke(Path(roundedRect: CGRect(x: topLeft.x, y: topLeft.y, width: topRight.x - topLeft.x, height: topRight.y - topLeft.y),
                        cornerRadius: 2), with: .color(trim), lineWidth: 0.75)

        var mast = Path()
        mast.move(to: b(0.66 * L, hardtop + C * 0.06)); mast.addLine(to: b(0.69 * L, hardtop + C * 0.4))
        mast.move(to: b(0.69 * L, hardtop + C * 0.4)); mast.addLine(to: b(0.7 * L, hardtop + C * 0.6))   // antenna
        ctx.stroke(mast, with: .color(trim), lineWidth: 1.5)
        let dome = b(0.69 * L, hardtop + C * 0.4)
        ctx.fill(Path(ellipseIn: CGRect(x: dome.x - 6, y: dome.y - 4, width: 12, height: 7)), with: .color(white))
        ctx.stroke(Path(ellipseIn: CGRect(x: dome.x - 6, y: dome.y - 4, width: 12, height: 7)), with: .color(trim), lineWidth: 0.75)

        // Tender on the boat deck aft.
        let tenderL = b(0.84 * L, roof + C * 0.14), tenderR = b(0.95 * L, roof)
        ctx.fill(Path(roundedRect: CGRect(x: tenderL.x, y: tenderL.y, width: tenderR.x - tenderL.x, height: tenderR.y - tenderL.y),
                      cornerRadius: 3), with: .color(Color(white: 0.75)))

        // Bow rail on stanchions over the foredeck.
        let railHeight = 0.8
        var rail = Path()
        rail.move(to: b(0.02 * L, deck(0.02 * L) + railHeight))
        for x in stride(from: 0.02, through: 0.28, by: 0.02) { rail.addLine(to: b(x * L, deck(x * L) + railHeight)) }
        for x in stride(from: 0.04, through: 0.28, by: 0.06) {
            rail.move(to: b(x * L, deck(x * L))); rail.addLine(to: b(x * L, deck(x * L) + railHeight))
        }
        ctx.stroke(rail, with: .color(Color.gray), lineWidth: 1)
    }

    private func arrow(_ ctx: inout GraphicsContext, from start: CGPoint, length: Double, color: Color, label: String) {
        let end = CGPoint(x: start.x + length, y: start.y)
        var line = Path()
        line.move(to: start); line.addLine(to: end)
        line.move(to: CGPoint(x: end.x - 6, y: end.y - 4)); line.addLine(to: end); line.addLine(to: CGPoint(x: end.x - 6, y: end.y + 4))
        ctx.stroke(line, with: .color(color), lineWidth: 2)
        ctx.draw(Text(label).font(.caption2.bold()).foregroundStyle(color), at: CGPoint(x: end.x + 6, y: end.y), anchor: .leading)
    }
}
