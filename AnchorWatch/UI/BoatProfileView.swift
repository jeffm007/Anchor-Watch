import SwiftUI

/// The boat and its ground tackle: everything the rode, scope, holding and wind-load maths need.
/// Values are stored metric and shown in the user's units. Blank fields haven't been entered.
struct BoatProfileView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @FocusState private var editing: Bool

    private var units: Units { engine.units }
    private var boat: BoatProfile { engine.boat }

    var body: some View {
        Form {
            Section {
                TextField("Boat name", text: $engine.boat.name)
                    .focused($editing)
                Picker("Type", selection: $engine.boat.hullType) {
                    ForEach(BoatProfile.HullType.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }

            Section {
                length("Length overall", $engine.scope.boatLength)
                length("Waterline length", $engine.boat.waterlineLength)
                length("Beam", $engine.boat.beam)
                length("Draft", $engine.boat.draft)
                number("Dry weight", weight($engine.boat.displacement), unit: units.weightSymbol)
            } header: { Text("Hull") } footer: {
                Text("The length also sizes the boat on the chart and the suggested alarm radius. Dry weight is without fuel, water or waste aboard.")
            }

            Section {
                number("Fuel", volume($engine.boat.fuelCapacity), unit: units.volumeSymbol)
                number("Fresh water", volume($engine.boat.waterCapacity), unit: units.volumeSymbol)
                number("Holding (blackwater)", volume($engine.boat.holdingCapacity), unit: units.volumeSymbol)
                if let loaded = BoatMath.loadedWeight(boat) {
                    LabeledContent("Weight with full tanks", value: units.formatWeight(loaded))
                }
            } header: { Text("Tanks") } footer: {
                Text("Full tanks add weight, and a heavier boat surges harder on the rode in gusts and waves.")
            }

            Section {
                length("Freeboard at the bow", $engine.boat.freeboard)
                length("Cabin above deck", $engine.boat.cabinHeight)
                length(boat.hullType.hasRig ? "Masthead above water" : "Highest point above water", $engine.boat.airDraft)
                if let estimate = BoatMath.estimatedWindage(boat) {
                    LabeledContent("Estimated frontal area", value: units.formatArea(estimate))
                }
                optionalNumber("Measured frontal area", area($engine.boat.windageArea), unit: units.areaSymbol)
            } header: { Text("Windage") } footer: {
                Text("Cabin includes a doghouse or flybridge. Windage is what the wind pushes on when the boat lies head to wind. Leave the measured area blank to use the estimate from the beam and heights.")
            }

            Section {
                Picker("Anchor type", selection: $engine.boat.anchorType) {
                    ForEach(BoatProfile.AnchorType.allCases) { Text($0.rawValue).tag($0) }
                }
                number("Anchor weight", weight($engine.boat.anchorWeight), unit: units.weightSymbol)
                length("Bow roller above water", $engine.scope.bowHeight)
            } header: { Text("Anchor") } footer: {
                Text("\(boat.anchorType.rawValue): \(boat.anchorType.examples).")
            }

            Section {
                Picker("Rode", selection: $engine.boat.rodeType) {
                    ForEach(BoatProfile.RodeType.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if boat.rodeType.hasChain {
                    length("Chain length", $engine.boat.chainLength)
                    sizePicker("Chain size", $engine.boat.chainSize, sizes: units.chainSizes)
                }
                if boat.rodeType.hasRope {
                    length("Rope length", $engine.boat.ropeLength)
                    sizePicker("Rope size", $engine.boat.ropeSize, sizes: units.ropeSizes)
                }
                length("Snubber or bridle", $engine.boat.snubberLength)
            } header: { Text("Rode") }

            Section {
                Toggle("Second anchor", isOn: $engine.boat.hasSecondAnchor)
                if boat.hasSecondAnchor {
                    Picker("Anchor type", selection: $engine.boat.secondAnchorType) {
                        ForEach(BoatProfile.AnchorType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    number("Anchor weight", weight($engine.boat.secondAnchorWeight), unit: units.weightSymbol)
                    Picker("Rode", selection: $engine.boat.secondRodeType) {
                        ForEach(BoatProfile.RodeType.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
            } footer: {
                if boat.hasSecondAnchor {
                    Text("\(boat.secondAnchorType.rawValue): \(boat.secondAnchorType.examples). The rode and scope maths use the main anchor above.")
                }
            }

            Section {
                LabeledContent("Rode on board", value: carried)
                if let deepest = BoatMath.deepestWater(boat, scopeRatio: engine.scope.scopeRatio, bowHeight: engine.scope.bowHeight) {
                    LabeledContent("Deepest water at \(Int(engine.scope.scopeRatio)):1", value: units.format(deepest))
                }
                if let shortfall = engine.rodeShortfall {
                    Label("Today's scope needs \(units.format(shortfall)) more rode than you carry.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let area = BoatMath.windage(boat) {
                    LabeledContent("Windage area", value: units.formatArea(area))
                }
                if let load = BoatMath.windLoad(boat, knots: engine.gustLimit) {
                    LabeledContent("Wind load at \(Int(engine.gustLimit)) kt", value: units.formatForce(load))
                    LabeledContent("Peak with yawing and surge", value: units.formatForce(load * BoatMath.peakFactor))
                }
            } header: { Text("Worked out from your boat") } footer: {
                Text("Wind loads use your gust warning limit from Settings. They are estimates for a boat head to wind; a boat sailing at anchor, or pitching in waves, can load the anchor harder.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(boat.name.isEmpty ? "Boat Profile" : boat.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
    }

    private var carried: String {
        let rode = BoatMath.rodeCarried(boat)
        return rode > 0 ? units.format(rode) : "Not entered"
    }

    // MARK: Fields

    /// A length stored in metres, edited in the user's units.
    private func length(_ title: String, _ meters: Binding<Double>) -> some View {
        number(title, Binding(get: { meters.wrappedValue * units.perMeter },
                              set: { meters.wrappedValue = max(0, $0 / units.perMeter) }),
               unit: units.symbol)
    }

    private func weight(_ kilograms: Binding<Double>) -> Binding<Double> {
        Binding(get: { kilograms.wrappedValue * units.perKilogram },
                set: { kilograms.wrappedValue = max(0, $0 / units.perKilogram) })
    }

    private func volume(_ liters: Binding<Double>) -> Binding<Double> {
        Binding(get: { liters.wrappedValue * units.perLiter },
                set: { liters.wrappedValue = max(0, $0 / units.perLiter) })
    }

    private func area(_ squareMeters: Binding<Double?>) -> Binding<Double?> {
        Binding(get: { squareMeters.wrappedValue.map { $0 * units.perSquareMeter } },
                set: { squareMeters.wrappedValue = $0.flatMap { $0 > 0 ? $0 / units.perSquareMeter : nil } })
    }

    /// Zero shows as a blank field, meaning "not entered".
    private func number(_ title: String, _ value: Binding<Double>, unit: String) -> some View {
        optionalNumber(title, Binding(get: { value.wrappedValue > 0 ? value.wrappedValue : nil },
                                      set: { value.wrappedValue = $0 ?? 0 }),
                       unit: unit)
    }

    private func optionalNumber(_ title: String, _ value: Binding<Double?>, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("—", value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($editing)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    /// Standard sizes for the user's units, plus the saved size if it isn't one of them.
    private func sizePicker(_ title: String, _ mm: Binding<Double>, sizes: [Double]) -> some View {
        let current = mm.wrappedValue
        let options = sizes.contains { abs($0 - current) < 0.01 } || current == 0 ? sizes : (sizes + [current]).sorted()
        return Picker(title, selection: mm) {
            Text("Not set").tag(0.0)
            ForEach(options, id: \.self) { Text(units.formatSize($0)).tag($0) }
        }
    }
}
