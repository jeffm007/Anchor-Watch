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
                length("Length overall", $engine.scope.boatLength)
                length("Waterline length", $engine.boat.waterlineLength)
                length("Beam", $engine.boat.beam)
                length("Draft", $engine.boat.draft)
                number("Dry weight", weight($engine.boat.displacement), unit: units.weightSymbol)
            } header: { Text("Hull") }

            Section {
                number("Fuel", volume($engine.boat.fuelCapacity), unit: units.volumeSymbol)
                number("Fresh water", volume($engine.boat.waterCapacity), unit: units.volumeSymbol)
                number("Holding (blackwater)", volume($engine.boat.holdingCapacity), unit: units.volumeSymbol)
                if let loaded = BoatMath.loadedWeight(boat) {
                    LabeledContent("Weight with full tanks", value: units.formatWeight(loaded))
                }
            } header: { Text("Tanks") }

            Section {
                length("Freeboard at the bow", $engine.boat.freeboard)
                length("Cabin above deck", $engine.boat.cabinHeight)
                optionalNumber("Windage (Front)", area($engine.boat.windageArea, estimate: BoatMath.estimatedWindage(boat)),
                               unit: units.areaSymbol)
                optionalNumber("Windage (Side)", area($engine.boat.sideWindageArea,
                                                     estimate: BoatMath.estimatedSideWindage(boat, length: engine.scope.boatLength)),
                               unit: units.areaSymbol)
            } header: { Text("Windage") }

            Section {
                Picker("Anchor type", selection: $engine.boat.anchorType) {
                    ForEach(BoatProfile.AnchorType.allCases) { Text($0.rawValue).tag($0) }
                }
                number("Anchor weight", weight($engine.boat.anchorWeight), unit: units.weightSymbol)
                length("Bow roller above water", $engine.scope.bowHeight)
            } header: { Text("Anchor") }

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
                Toggle("Snubber or bridle", isOn: snubberOn)
                if boat.hasSnubber {
                    length("Snubber length", $engine.boat.snubberLength)
                }
            } header: { Text("Rode") }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("\(boat.name) - 2005 Selene 47'")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
    }

    /// Turning the snubber on with no length entered starts it at 20 ft.
    private var snubberOn: Binding<Bool> {
        Binding(get: { boat.hasSnubber },
                set: { on in
                    engine.boat.hasSnubber = on
                    if on && engine.boat.snubberLength == 0 { engine.boat.snubberLength = 6.096 }
                })
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

    /// An area that shows the estimate until one is entered; clearing it goes back to the estimate.
    private func area(_ squareMeters: Binding<Double?>, estimate: Double?) -> Binding<Double?> {
        Binding(get: { (squareMeters.wrappedValue ?? estimate).map { $0 * units.perSquareMeter } },
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
