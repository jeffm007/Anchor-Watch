import MapKit
import SwiftUI
import UniformTypeIdentifiers

private struct OfflineENCFeatureSelection: Identifiable {
    let chart: OfflineENCChart
    let feature: OfflineENCFeature
    var id: String { "\(chart.id):\(feature.id)" }
}

/// Experimental vector viewer. The chart and all safety overlays remain separate from MapKit's live chart.
struct OfflineENCView: View {
    @EnvironmentObject var navigation: NavigationStore
    @ObservedObject var engine: AnchorWatchEngine
    @Binding var zoom: CGFloat
    var fullScreen = false
    @State private var didInitializeViewport = false
    @StateObject private var store = OfflineENCStore()
    @StateObject private var packageSession = OfflineENCPackageSession()
    @StateObject private var tileCache = OfflineENCTileCache()
    @StateObject private var portrayalCache = OfflineENCPortrayalCache()
    @AppStorage("offlineENC.showInformationCards") private var showInformationCards = true
    @State private var informationVisible = true
    @State private var informationActivity = UUID()
    @GestureState private var isTouchingChart = false
    @State private var isPackagePanning = false
    @State private var packageFitBounds: OfflineENCBounds?
    @State private var packageFitCollectionID = ""
    @State private var browseWholePackage = false
    @State private var profileWholePackageAtArea = false
    @State private var cruisingAreaID: String?
    @State private var areaSelectedCellIDs: Set<String> = []
    @AppStorage("offlineENC.overviewDistance") private var overviewDistance = 6_000.0
    @AppStorage("offlineENC.showText") private var showChartText = true
    @AppStorage("offlineENC.showSoundings") private var showChartSoundings = true
    @AppStorage("offlineENC.showContours") private var showChartContours = true
    @AppStorage("offlineENC.showOutlines") private var showChartOutlines = true
    @State private var showSourcePicker = false
    @State private var showFileImporter = false
    @State private var importSource: OfflineENCImportSource = .chs
    @State private var coverageCollection: OfflineENCCollection?
    @AppStorage("offlineENC.coverageCollectionID") private var preferredCoverageCollectionID = ""
    @State private var showsCoverageOverview = true
    @State private var importStatus = ""
    @State private var importError = ""
    @State private var isImporting = false
    @State private var detailBackgroundStatus = ""
    @State private var supportingNote = ""
    @State private var selectedTideStation: TideStation?
    @State private var selectedCurrentStation: CurrentStation?
    @State private var inspectedFeature: OfflineENCFeatureSelection?
    @State private var nearbyFeatures: [OfflineENCFeatureSelection] = []
    /// High-resolution chart cells are an explicit selection. Other catalogue
    /// cells remain in the lightweight coverage overview until prepared.
    @State private var selectedMosaicCellIDs: Set<String>? = []
    @State private var magnifyStartZoom: CGFloat = 1
    @State private var magnifyStartPan = CGSize.zero
    @State private var isMagnifying = false
    @State private var pan = CGSize.zero
    @State private var lastPan = CGSize.zero

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.57, green: 0.76, blue: 0.82)
            if showsCoverageOverview, browseWholePackage, let collection = activeCoverageCollection {
                packageCanvas(collection).id(collection.id)
            } else if showsCoverageOverview, let collection = activeCoverageCollection {
                OfflineENCCollectionMap(
                    store: store,
                    collection: collection,
                    importedCellIDs: Set(store.charts.filter { $0.sha256 == collection.sha256 && !["CA271100", "CA271101"].contains($0.metadata.cellID) }.map { $0.metadata.cellID }),
                    initialSelectedCellIDs: cruisingAreaID == nil ? selectedCellIDs(in: collection) : areaSelectedCellIDs,
                    areaID: cruisingAreaID,
                    onChooseArea: { chooseArea($0, in: collection) },
                    onPrepare: { candidates in
                        if cruisingAreaID != nil {
                            areaSelectedCellIDs = Set(candidates.map(\.cellID))
                            browseWholePackage = true; resetChartViewport(); revealInformation()
                        } else { importSelectedCells(candidates, from: collection) }
                    },
                    onOpenPreparedCharts: { openPreparedChart(in: collection) },
                    onImportAnother: { showSourcePicker = true },
                    onChooseCollection: { coverageCollection = $0; cruisingAreaID = nil; areaSelectedCellIDs = [] },
                    onBrowsePackage: {
                        guard engine.anchor == nil else {
                            importError = "Whole-package preview is unavailable while anchor watch is active because its memory use is still being optimized. The existing chart viewer remains available."
                            return
                        }
                        chooseArea(nil, in: collection)
                    }
                )
                .id(collection.id + (cruisingAreaID ?? ""))
                .padding(.bottom, !fullScreen && engine.anchor == nil ? 100 : 0)
            } else if let chart = store.selectedChart, !showsCoverageOverview {
                chartCanvas(chart)
                    .task(id: chart.id) { await prepareDetailBackground(for: chart) }
                    .overlay(alignment: .topLeading) { chartHeader(chart).padding(8) }
                    .overlay(alignment: .bottomLeading) {
                        if showInformationCards && informationVisible { limitations(chart).padding(8).transition(.opacity) }
                    }
            } else {
                emptyLibrary
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: fullScreen ? 0 : 16))
        .overlay(RoundedRectangle(cornerRadius: fullScreen ? 0 : 16).stroke(Color.white.opacity(fullScreen ? 0 : 0.12), lineWidth: 1))
        .overlay { if isImporting { importProgressCard } }
        .overlay {
            if let station = selectedCurrentStation {
                OfflineCurrentStationPopup(station: station) { selectedCurrentStation = nil }
                    .id(station.provider.rawValue + ":" + station.id)
                    .frame(width: 320, height: 270)
                    .overlay(alignment: .topTrailing) { popupCloseButton("Close current station predictions") { selectedCurrentStation = nil } }
            } else if let station = selectedTideStation {
                OfflineTideStationPopup(station: station, units: engine.units) { selectedTideStation = nil }
                    .id(station.source + ":" + station.id + ":" + engine.units.rawValue)
                    .frame(width: 320, height: 390)
                    .overlay(alignment: .topTrailing) { popupCloseButton("Close tide station predictions") { selectedTideStation = nil } }
            }
        }
        .onChange(of: navigation.placing) { _, placing in
            if placing { inspectedFeature = nil; selectedTideStation = nil; selectedCurrentStation = nil; if showsCoverageOverview { browseWholePackage = true } }
        }
        .onChange(of: engine.tideStationsOverlayOn) { _, enabled in
            if !enabled { selectedTideStation = nil }
        }
        .onChange(of: engine.currentStationsOverlayOn) { _, enabled in
            if !enabled { selectedCurrentStation = nil }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .updating($isTouchingChart) { _, touching, _ in touching = true })
        .onChange(of: isTouchingChart) { _, _ in revealInformation() }
        .task(id: informationActivity) {
            do { try await Task.sleep(for: .seconds(5)); try Task.checkCancellation() }
            catch { return }
            guard !isTouchingChart else { return }
            withAnimation(.easeOut(duration: 0.45)) { informationVisible = false }
        }
        .confirmationDialog("Choose the source for this local chart import", isPresented: $showSourcePicker, titleVisibility: .visible) {
            Button("CHS Chart 9995 sample · fictitious, not for navigation") { beginImport(.chs) }
            Button("NOAA ENC") { beginImport(.noaa) }
            Button("Other S-57 exchange set") { beginImport(.other) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This source label is recorded as your selection. The app does not verify chart licensing or update status.")
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            importFile(result)
        }
        .sheet(item: $inspectedFeature, onDismiss: { if inspectedFeature == nil { nearbyFeatures = [] } }) { selection in
            featureDetails(selection.feature, chart: selection.chart)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Chart import", isPresented: Binding(get: { !importError.isEmpty }, set: { if !$0 { importError = "" } })) {
            Button("OK", role: .cancel) { importError = "" }
        } message: { Text(importError) }
        .onChange(of: engine.recenterTick) { _, _ in
            zoom = 1
            pan = .zero
            lastPan = .zero
        }
        .onChange(of: store.selectedChartID) { _, _ in
            // Every cell has its own coordinate extent. Do not carry a pan or
            // zoom from the previous chart into the newly selected one.
            zoom = 1
            pan = .zero
            lastPan = .zero
        }
        .onChange(of: store.selectedChart?.sha256) { _, _ in
            // A newly selected exchange set begins focused on its active cell.
            if let chart = store.selectedChart { selectedMosaicCellIDs = [chart.id] }
            else { selectedMosaicCellIDs = nil }
        }
        .onChange(of: coverageCollection?.id) { _, id in
            if let id { preferredCoverageCollectionID = id }
        }
        .onChange(of: browseWholePackage) { _, browsing in
            if !browsing { tileCache.clear(); portrayalCache.clear(); packageSession.reset() }
        }
        .onDisappear { tileCache.clear(); portrayalCache.clear(); packageSession.reset() }
        .onChange(of: engine.anchor != nil) { _, watching in
            if watching { browseWholePackage = false }
        }
        .onAppear {
            engine.loadTideStationsForOverlay()
            revealInformation()
            if !didInitializeViewport {
                didInitializeViewport = true
                showsCoverageOverview = true
                browseWholePackage = fullScreen && engine.anchor == nil
                resetChartViewport()
            }
        }
    }

    private func revealInformation() {
        informationActivity = UUID()
        withAnimation(.easeIn(duration: 0.15)) { informationVisible = true }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            Image(systemName: "map")
                .font(.system(size: 34)).foregroundStyle(.white)
            Text("CHS Charts").font(.headline).foregroundStyle(.white)
            Text("Import an unencrypted S-57 exchange set. Collections can contain many cells; browse their coverage map and decode cells as needed. PDF, TIFF, BSB/RNC, loose .000 files, and encrypted charts are not supported. The original ZIP is stored unchanged on this device.")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 22)
            Button { showSourcePicker = true } label: {
                Label("Import chart from Files", systemImage: "square.and.arrow.down")
                    .font(.subheadline.bold()).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.white, in: Capsule()).foregroundStyle(.black)
            }
            if !store.collections.isEmpty {
                ForEach(store.collections) { collection in
                    Button {
                        coverageCollection = collection
                        showsCoverageOverview = true
                    } label: {
                        Label("\(collection.originalFilename) · cell coverage", systemImage: "square.grid.3x3")
                            .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.white.opacity(0.9), in: Capsule()).foregroundStyle(.black)
                    }
                }
            }
            if !importStatus.isEmpty { Text(importStatus).font(.caption).foregroundStyle(.white).multilineTextAlignment(.center) }
            Text("Development viewer · NOT FOR NAVIGATION").font(.caption2.bold()).foregroundStyle(.yellow)
        }
        .padding(20)
    }

    private var importProgressCard: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(importStatus.isEmpty ? "Importing chart…" : importStatus)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            Text("Large CHS collections can take a little while. Keep Anchor Watch open.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("offlineENCImportProgress")
    }

    private func chooseArea(_ areaID: String?, in collection: OfflineENCCollection) {
        if let areaID, collection.cells.first(where: { $0.cellID == areaID })?.bounds == nil {
            importError = "This package does not contain coverage bounds for \(areaID)."
            return
        }
        if cruisingAreaID != areaID { areaSelectedCellIDs = [] }
        profileWholePackageAtArea = false
        cruisingAreaID = areaID
        coverageCollection = collection
        showsCoverageOverview = true
        browseWholePackage = areaID == nil
        packageSession.reset(); tileCache.clear(); portrayalCache.clear()
        packageFitBounds = nil; packageFitCollectionID = ""
        resetChartViewport(); revealInformation()
    }

    private func areasMenu(_ collection: OfflineENCCollection) -> some View {
        Menu {
            ForEach(OfflineENCCruisingArea.presets) { area in
                Button("\(area.name) (\(area.cellID))") { chooseArea(area.cellID, in: collection) }
                    .disabled(!collection.cells.contains { $0.cellID == area.cellID && $0.bounds != nil })
            }
            #if DEBUG
            if cruisingAreaID != nil {
                Divider()
                Button(profileWholePackageAtArea ? "Profile: selected cells at same view" : "Profile: whole package at same view") {
                    profileWholePackageAtArea.toggle()
                    packageSession.reset(); tileCache.clear(); portrayalCache.clear()
                    revealInformation()
                    print("ENC PROFILE mode=\(profileWholePackageAtArea ? "whole" : "area") zoom=\(zoom) pan=\(pan)")
                }
            }
            #endif
            Divider()
            Button("Whole coverage") { chooseArea(nil, in: collection) }
            Button("Fit current view") { resetChartViewport() }
        } label: { Text("Areas") }
        .accessibilityLabel("Areas")
    }

    private func scalePackage(by factor: CGFloat) {
        let next = min(2048, max(0.5, zoom * factor))
        let ratio = next / max(zoom, 0.0001)
        pan = CGSize(width: pan.width * ratio, height: pan.height * ratio)
        lastPan = pan; zoom = next
    }

    private func packageBounds(_ collection: OfflineENCCollection) -> OfflineENCBounds? {
        if let cruisingAreaID { return collection.cells.first { $0.cellID == cruisingAreaID }?.bounds }
        if packageFitCollectionID == collection.id, let packageFitBounds { return packageFitBounds }
        let overviews = collection.cells.filter { ["CA271100", "CA271101"].contains($0.cellID.uppercased()) }.compactMap(\.bounds)
        let boxes = overviews.isEmpty ? collection.cells.compactMap(\.bounds) : overviews
        guard let west = boxes.map(\.west).min(), let east = boxes.map(\.east).max(),
              let south = boxes.map(\.south).min(), let north = boxes.map(\.north).max() else { return nil }
        return OfflineENCBounds(west: west, south: south, east: east, north: north)
    }

    private func packageCandidates(_ collection: OfflineENCCollection, projector: ENCProjector) -> [OfflineENCZip.CellCandidate] {
        let screen = CGRect(origin: .zero, size: projector.size).insetBy(dx: -40, dy: -40)
        let available = (profileWholePackageAtArea ? nil : cruisingAreaID).map {
            OfflineENCCruisingArea.renderCells(in: collection.cells, areaID: $0, selected: areaSelectedCellIDs,
                overview: OfflineENCPackagePolicy.isOverview(metresAcross: projector.detailMetresAcross, overviewDistance: overviewDistance))
        } ?? collection.cells
        return available.compactMap { cell -> (OfflineENCZip.CellCandidate, Double)? in
            guard let box = cell.bounds else { return nil }
            if cruisingAreaID == nil || profileWholePackageAtArea, let band = OfflineENCPackagePolicy.usageBand(cellID: cell.cellID),
               band > OfflineENCPackagePolicy.maximumUsageBand(metresAcross: projector.detailMetresAcross, overviewDistance: overviewDistance) { return nil }
            let rect = projector.rect(box)
            guard rect.intersects(screen), cruisingAreaID != nil || min(rect.width, rect.height) >= 40 else { return nil }
            // Overview cells first, then cells nearest the centre. The full package
            // remains available as the viewport moves; only the working set is bounded.
            let isOverview = ["CA271100", "CA271101"].contains(cell.cellID.uppercased())
            let distance = hypot(rect.midX - screen.midX, rect.midY - screen.midY)
            return (cell, isOverview ? -1 : distance)
        }.sorted { $0.1 == $1.1 ? $0.0.cellID < $1.0.cellID : $0.1 < $1.1 }.map { $0.0 }
    }

    private func coveragePath(_ chart: OfflineENCChart, projector: ENCProjector) -> Path {
        var result = Path()
        for feature in chart.features where feature.objectClass == 302 && feature.attributes["ATTL_18"] == "1" {
            guard feature.geometryType == "Polygon", let coordinates = feature.coordinates else { continue }
            for ring in coordinates.rings { result.addPath(path(for: ring, projector: projector, close: true)) }
        }
        return result
    }

    private func popupCloseButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22)).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel(label)
    }

    private func stationSymbol(projector: ENCProjector, color: Color, glyph: String) -> some View {
        let diameter = OfflineStationSymbol.diameter(metresAcross: projector.detailMetresAcross)
        return ZStack {
            Circle().fill(color)
            if diameter >= 14 {
                Image(systemName: glyph).font(.system(size: diameter / 2, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: diameter >= 14 ? 1 : 0.4))
        .frame(width: max(12, diameter + 6), height: max(12, diameter + 6))
        .contentShape(Circle())
    }

    private func currentStationOverlay(projector: ENCProjector, charts: [OfflineENCChart]) -> some View {
        let coverage = charts.map { chart in
            var included: [Path] = [], excluded: [Path] = []
            for feature in chart.features where feature.objectClass == 302 {
                guard let coordinates = feature.coordinates else { continue }
                let polygons: [OfflineJSONValue]
                if feature.geometryType == "Polygon" { polygons = [coordinates] }
                else if feature.geometryType == "MultiPolygon", case .array(let parts) = coordinates { polygons = parts }
                else { continue }
                for coordinates in polygons {
                    var polygon = Path()
                    for ring in coordinates.rings { polygon.addPath(path(for: ring, projector: projector, close: true)) }
                    if feature.attributes["ATTL_18"] == "1" { included.append(polygon) }
                    if feature.attributes["ATTL_18"] == "2" { excluded.append(polygon) }
                }
            }
            return OfflineStationCoverage(included: included, excluded: excluded)
        }
        return ZStack(alignment: .topLeading) {
            if engine.currentStationsOverlayOn {
                ForEach(OfflineCurrentStationMarker.visible(engine.chartCurrentStations, projector: projector).filter { marker in coverage.contains { $0.contains(marker.point) } }) { marker in
                    Button {
                        inspectedFeature = nil
                        selectedTideStation = nil
                        selectedCurrentStation = marker.station
                    } label: {
                        stationSymbol(projector: projector, color: .purple, glyph: "water.waves")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Current station: \(marker.station.name), \(marker.station.providerName)")
                    .accessibilityIdentifier("offlineCurrentStation-" + marker.id)
                    .position(marker.point)
                }
            }
            if engine.tideStationsOverlayOn {
                ForEach(OfflineTideStationMarker.visible(engine.chartTideStations, projector: projector).filter { marker in coverage.contains { $0.contains(marker.point) } }) { marker in
                    Button {
                        inspectedFeature = nil
                        selectedCurrentStation = nil
                        selectedTideStation = marker.station
                    } label: {
                        stationSymbol(projector: projector, color: .teal, glyph: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tide station: \(marker.station.name)")
                    .position(marker.point)
                }
            }
        }
        .frame(width: projector.size.width, height: projector.size.height)
        .clipped()
    }

    private var displayOptions: some View {
        Menu {
            Toggle("Show information cards", isOn: $showInformationCards)
                .onChange(of: showInformationCards) { _, enabled in if enabled { revealInformation() } }
            Toggle("Place names and descriptions", isOn: $showChartText)
            Toggle("Depth soundings", isOn: $showChartSoundings)
            Toggle("Depth contours", isOn: $showChartContours)
            Toggle("Chart coverage outlines", isOn: $showChartOutlines)
            Toggle("Show tide stations", isOn: Binding(
                get: { engine.tideStationsOverlayOn },
                set: { enabled in
                    if enabled != engine.tideStationsOverlayOn { engine.toggleTideStationsOverlay() }
                }))
            Toggle("Show current stations", isOn: Binding(
                get: { engine.currentStationsOverlayOn },
                set: { enabled in
                    if enabled != engine.currentStationsOverlayOn { engine.toggleCurrentStationsOverlay() }
                }))
            Picker("Switch to overview", selection: $overviewDistance) {
                Text("3 km / 1.6 nm — overview sooner").tag(3_000.0)
                Text("6 km / 3.2 nm — default").tag(6_000.0)
                Text("12 km / 6.5 nm — detail longer").tag(12_000.0)
                Text("24 km / 13 nm — detail longest").tag(24_000.0)
            }
            Text("Distance across a phone-width view. Larger values keep detail when zooming out.")
        } label: { Image(systemName: "slider.horizontal.3") }
        .accessibilityLabel("Display")
    }

    @MainActor
    private func rasterTile(_ address: OfflineENCTileAddress, bounds: OfflineENCBounds, viewport: CGSize,
                            renderedCells: [OfflineENCChart], overview: Bool, featureBounds: [String: [String: OfflineENCBounds]]) async -> CGImage? {
        let side = OfflineENCTileAddress.side
        let size = CGSize(width: side, height: side)
        let projector = ENCProjector(bounds: bounds, size: viewport, zoom: address.zoom,
            pan: CGSize(width: -viewport.width / 2 - CGFloat(address.x) * side,
                        height: -viewport.height / 2 - CGFloat(address.y) * side), clippingSize: size)
        guard let prepared = try? await OfflineENCTilePreparation.prepare(cells: renderedCells,
            featureBounds: featureBounds, projector: projector, overview: overview), !Task.isCancelled else { return nil }
        var preparedProjector = projector
        preparedProjector.coordinatesAreProjected = true
        let tileProjector = preparedProjector
        let rasterStarted = Date()
        let canvas = Canvas { context, _ in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.83, green: 0.84, blue: 0.85)))
                    let cells = prepared
                    let labelLayout = OfflineENCLabelLayout()
                    let symbolDensity = symbolDensity(cells.flatMap(\.features), projector: tileProjector)
                    let coverage = cells.map { coveragePath($0, projector: tileProjector) }
                    for (index, cell) in cells.enumerated() {
                        var soundings = Set<String>(); var labels = Set<String>()
                        var layer = context
                        if !coverage[index].isEmpty { layer.clip(to: coverage[index], style: FillStyle(eoFill: true)) }
                        // Finer cells replace coarser portrayal only inside their real
                        // CATCOV=1 polygons, never their rectangular catalogue extents.
                        for mask in coverage.dropFirst(index + 1) where !mask.isEmpty {
                            layer.clip(to: mask, style: FillStyle(eoFill: true), options: .inverse)
                        }
                        if !coverage[index].isEmpty {
                            layer.fill(coverage[index], with: .color(Color(red: 0.74, green: 0.87, blue: 0.9)), style: FillStyle(eoFill: true))
                        }
                        let units = cell.features.contains { $0.objectClass == 311 } ? 0 : cell.metadata.depthUnitCode
                        for feature in cell.features where feature.isPortrayed {
                            draw(feature, in: &layer, projector: tileProjector, soundingCells: &soundings, aidCells: &labels, depthUnitCode: units, labelLayout: labelLayout, symbolDensity: symbolDensity)
                        }
                    }
                    labelLayout.draw()
                    if showChartOutlines {
                        for outline in coverage where !outline.isEmpty {
                            context.stroke(outline, with: .color(.green.opacity(0.5)), lineWidth: 0.8)
                        }
                    }
        }.frame(width: side, height: side).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        renderer.isOpaque = true
        let image = autoreleasepool { renderer.cgImage }
        print("ENC raster mainMs=\(Int(Date().timeIntervalSince(rasterStarted) * 1000))")
        fflush(stdout)
        return image
    }

    private func packageCanvas(_ collection: OfflineENCCollection) -> some View {
        GeometryReader { geometry in
            if let bounds = packageBounds(collection) {
                let projector = ENCProjector(bounds: bounds, size: geometry.size, zoom: zoom, pan: pan)
                let overview = OfflineENCPackagePolicy.isOverview(metresAcross: projector.detailMetresAcross, overviewDistance: overviewDistance)
                let candidates = packageCandidates(collection, projector: projector)
                let requested = candidates
                let viewport = projector.bufferedGeographicViewport
                let requestID = collection.id + requested.map(\.cellID).joined(separator: ":") + ":\(viewport):\(overview):\(isPackagePanning):\(isMagnifying)"
                let cells = packageSession.cells.filter { $0.sha256 == collection.sha256 }
                let scene = packageSession.rasterIdentity + ":\(zoom >= 2):\(zoom >= 3):\(zoom >= 5)"
                let displayDomain = "\(collection.sha256):\(bounds):\(geometry.size):\(showChartText):\(showChartSoundings):\(showChartContours):\(showChartOutlines)"
                let namespace = "raster-v9:\(overview):\(displayDomain)"
                let addresses = OfflineENCTileAddress.visible(size: geometry.size, zoom: zoom, pan: pan)
                let keys = addresses.map { OfflineENCTileCache.Key(namespace: namespace, scene: scene, address: $0) }
                let tileRequestID = "\(keys):\(isPackagePanning):\(isMagnifying):\(packageSession.isLoading)"
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.83, green: 0.84, blue: 0.85)))
                    // Keep the last complete viewport, including across overview/detail changes.
                    // Source, projection and display settings must still match.
                    let images = tileCache.displayDomain == displayDomain ? tileCache.overviewBackdrop + tileCache.displayedEntries : []
                    for entry in images {
                        let rect = entry.key.address.screenRect(size: size, liveZoom: zoom, pan: pan)
                        guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
                        context.draw(Image(decorative: entry.image, scale: 2), in: rect)
                    }
                    drawIslandNames(cells, in: &context, projector: projector)
                    drawBoatAndAnchor(in: &context, projector: projector)
                }
                .task(id: tileRequestID) {
                    guard !isPackagePanning, !isMagnifying, !packageSession.isLoading, !packageSession.rasterIdentity.isEmpty, !cells.isEmpty else { return }
                    do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation() }
                    catch { return }
                    await tileCache.prepare(keys: keys, displayDomain: displayDomain, isOverview: overview) { address in
                        await rasterTile(address, bounds: bounds, viewport: geometry.size,
                                   renderedCells: cells, overview: overview, featureBounds: packageSession.featureBounds)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    guard !isMagnifying else { return }
                    isPackagePanning = true
                    pan = CGSize(width: lastPan.width + value.translation.width, height: lastPan.height + value.translation.height)
                }.onEnded { _ in lastPan = pan; isPackagePanning = false })
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if !isMagnifying { isMagnifying = true; magnifyStartZoom = zoom; magnifyStartPan = pan }
                    let next = min(2048, max(0.5, magnifyStartZoom * value.magnification))
                    let ratio = next / max(magnifyStartZoom, 0.0001)
                    let x = value.startLocation.x - geometry.size.width / 2
                    let y = value.startLocation.y - geometry.size.height / 2
                    pan = CGSize(width: x * (1 - ratio) + magnifyStartPan.width * ratio,
                                 height: y * (1 - ratio) + magnifyStartPan.height * ratio)
                    zoom = next
                }.onEnded { _ in lastPan = pan; isMagnifying = false })
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    if navigation.placing {
                        let coordinate = projector.coordinate(at: value.location)
                        navigation.pick(.init(latitude: coordinate.latitude, longitude: coordinate.longitude))
                        return
                    }
                    // Inspect the uppermost chart actually portrayed at this point.
                    for cell in packageSession.cells.reversed() {
                        let mask = coveragePath(cell, projector: projector)
                        guard mask.isEmpty || mask.contains(value.location, eoFill: true) else { continue }
                        inspectFeatures([cell], at: value.location, size: geometry.size, extent: bounds)
                        break
                    }
                })
                .overlay { currentStationOverlay(projector: projector, charts: cells) }
                .task(id: requestID) {
                    guard !isPackagePanning, !isMagnifying else { return }
                    do { try await Task.sleep(for: .milliseconds(50)); try Task.checkCancellation() }
                    catch { return }
                    await packageSession.load(requested, collection: collection, store: store, viewport: viewport, overview: overview,
                                              overviewCellIDs: Set(profileWholePackageAtArea ? [] : cruisingAreaID.map { [$0] } ?? []))
                    // Catalogue boxes can include broad no-data areas. Once the
                    // overview is decoded, fit its actual geometry once, before gestures.
                    if !Task.isCancelled, packageFitCollectionID != collection.id,
                       zoom == 1, pan == .zero,
                       let actual = OfflineENCBounds(features: packageSession.cells
                            .filter { ["CA271100", "CA271101"].contains($0.metadata.cellID) }
                            .flatMap { $0.features.filter { !$0.isMetaObject } }) {
                        packageFitBounds = actual; packageFitCollectionID = collection.id
                    }
                }
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Button("Cells") { browseWholePackage = false; resetChartViewport() }
                            Spacer()
                            displayOptions
                            Button { scalePackage(by: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom out")
                            Button { scalePackage(by: 2) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom in")
                            areasMenu(collection)
                        }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        if showInformationCards && informationVisible {
                            VStack(alignment: .leading, spacing: 5) {
                            Text(profileWholePackageAtArea ? "PROFILE: whole package at same view" : cruisingAreaID.map { "\($0) · \(areaSelectedCellIDs.count) detail cells selected" }
                                ?? "\(collection.originalFilename) · \(collection.cells.count) cells available").font(.caption.bold())
                            Text(packageSession.status).font(.caption2)
                            Text(packageSession.memorySummary).font(.caption2)
                            Text(tileCache.status).font(.caption2)
                            if overview { Text("Overview · symbols and soundings hidden · zoom in for detail").font(.caption2.bold()) }
                            Text("Depth units: " + Set(packageSession.cells.map { $0.features.contains(where: { $0.objectClass == 311 }) ? "local units unresolved" : $0.metadata.depthUnitName }).sorted().joined(separator: ", ")).font(.caption2)
                            if !showChartText || !showChartSoundings || !showChartContours {
                                Text("Hidden: " + [showChartText ? nil : "names", showChartSoundings ? nil : "soundings", showChartContours ? nil : "contours"].compactMap { $0 }.joined(separator: ", ")).font(.caption2)
                            }
                            Text("Development preview · performance unvalidated · updates unverified").font(.caption2.bold())
                            
                            if !packageSession.failures.isEmpty {
                                Button("Show chart load details") { importError = packageSession.failures.joined(separator: "\n") }.font(.caption)
                            }
                        }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .transition(.opacity)
                        }
                    }.padding(8)
                }
                .overlay(alignment: .bottom) {
                    if showInformationCards && informationVisible {
                    Text("NOT FOR NAVIGATION · Grey: no loaded coverage · Automatic detail by zoom · Charted depths, not current water depth.")
                        .font(.caption2).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
                        .transition(.opacity)
                    }
                }
            } else {
                ContentUnavailableView("Package bounds unavailable", systemImage: "map", description: Text("Open Cells to use the collection list."))
                    .overlay(alignment: .top) { Button("Cells") { browseWholePackage = false } }
            }
        }
        .accessibilityIdentifier("offlineENCPackageCanvas")
    }

    private func detailBackgrounds(for chart: OfflineENCChart) -> [OfflineENCChart] {
        store.charts.filter { $0.sha256 == chart.sha256 && ["CA271100", "CA271101"].contains($0.metadata.cellID) }
    }

    @MainActor
    private func prepareDetailBackground(for chart: OfflineENCChart) async {
        guard let collection = collection(for: chart), let extent = canvasBounds(selected: chart) else { return }
        let candidates = collection.cells.filter { cell in
            guard ["CA271100", "CA271101"].contains(cell.cellID), let box = cell.bounds else { return false }
            return box.west < extent.east && box.east > extent.west && box.south < extent.north && box.north > extent.south
        }
        detailBackgroundStatus = "Loading overview context…"
        do {
            for cell in candidates {
                try Task.checkCancellation()
                if !store.charts.contains(where: { $0.sha256 == collection.sha256 && $0.metadata.cellID == cell.cellID }) {
                    _ = try await store.importCell(cell, from: collection, select: false)
                }
            }
            try Task.checkCancellation()
            detailBackgroundStatus = candidates.isEmpty ? "Overview context unavailable for this area." : "Overview context: 1:700,000 · land and coastlines only."
        } catch is CancellationError { return }
        catch { detailBackgroundStatus = "Overview context unavailable: \(error.localizedDescription)" }
    }

    private func chartCanvas(_ chart: OfflineENCChart) -> some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let charts = chartsToRender(selected: chart)
                guard let bounds = canvasBounds(selected: chart), size.width > 0, size.height > 0 else { return }
                let projector = ENCProjector(bounds: bounds, size: size, zoom: zoom, pan: pan)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.57, green: 0.76, blue: 0.82)))
                for background in detailBackgrounds(for: chart) {
                    drawBackground(background, in: &context, projector: projector)
                }
                let labelLayout = OfflineENCLabelLayout()
                var soundingCells = Set<String>()
                var aidCells = Set<String>()
                let features = charts.flatMap { chart in
                    let units = chart.features.contains(where: { $0.objectClass == 311 }) ? 0 : chart.metadata.depthUnitCode
                    return chart.features.map { (feature: $0, scale: chart.metadata.compilationScale, units: units) }
                }.sorted {
                    let leftOrder = drawOrder($0.feature), rightOrder = drawOrder($1.feature)
                    return leftOrder == rightOrder ? $0.scale > $1.scale : leftOrder < rightOrder
                }
                let symbolDensity = symbolDensity(features.map(\.feature), projector: projector)
                for item in features where item.feature.isPortrayed {
                    draw(item.feature, in: &context, projector: projector, soundingCells: &soundingCells, aidCells: &aidCells, depthUnitCode: item.units, labelLayout: labelLayout, symbolDensity: symbolDensity)
                }
                labelLayout.draw()
                // Show actual data coverage, rather than treating each catalogue box as a full tile.
                for cell in charts where showChartOutlines {
                    for feature in cell.features where feature.objectClass == 302 && feature.attributes["ATTL_18"] == "1" {
                        guard feature.geometryType == "Polygon", let coordinates = feature.coordinates else { continue }
                        for ring in coordinates.rings {
                            context.stroke(path(for: ring, projector: projector, close: true),
                                with: .color(.indigo.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                        }
                    }
                }
                drawIslandNames(charts + detailBackgrounds(for: chart), in: &context, projector: projector)
                drawBoatAndAnchor(in: &context, projector: projector)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged {
                guard !isMagnifying else { return }
                pan = CGSize(width: lastPan.width + $0.translation.width, height: lastPan.height + $0.translation.height)
            }
                .onEnded { _ in lastPan = pan })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if !isMagnifying {
                    isMagnifying = true
                    magnifyStartZoom = zoom
                    magnifyStartPan = pan
                }
                let baseZoom = max(magnifyStartZoom, 0.0001)
                let nextZoom = min(24, max(0.5, magnifyStartZoom * value.magnification))
                let ratio = nextZoom / baseZoom
                let centerX = geometry.size.width / 2
                let centerY = geometry.size.height / 2
                let anchorX = value.startLocation.x - centerX
                let anchorY = value.startLocation.y - centerY

                // Keep the chart coordinate under the fingers fixed on screen as
                // the scale changes around the pinch's start location.
                pan = CGSize(width: anchorX * (1 - ratio) + magnifyStartPan.width * ratio,
                             height: anchorY * (1 - ratio) + magnifyStartPan.height * ratio)
                zoom = nextZoom
            }
                .onEnded { _ in
                    lastPan = pan
                    isMagnifying = false
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                if navigation.placing, let bounds = canvasBounds(selected: chart) {
                    let coordinate = ENCProjector(bounds: bounds, size: geometry.size, zoom: zoom, pan: pan).coordinate(at: value.location)
                    navigation.pick(.init(latitude: coordinate.latitude, longitude: coordinate.longitude))
                    return
                }
                inspectFeatures(chartsToRender(selected: chart), at: value.location, size: geometry.size)
            })
            .overlay {
                if let bounds = canvasBounds(selected: chart) {
                    currentStationOverlay(projector: ENCProjector(bounds: bounds, size: geometry.size, zoom: zoom, pan: pan), charts: chartsToRender(selected: chart) + detailBackgrounds(for: chart))
                }
            }
        }
        .accessibilityIdentifier("offlineENCChartCanvas")
    }

    private func chartHeader(_ chart: OfflineENCChart) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("CHS Charts · NOT FOR NAVIGATION").font(.caption2.bold()).foregroundStyle(.black)
                Spacer(minLength: 0)
                let exchangeSetCells = importedCells(inSameExchangeAs: chart)
                let visibleCellCount = chartsToRender(selected: chart).count
                let catalogCollection = collection(for: chart)
                let availableCellCount = catalogCollection?.cells.count ?? exchangeSetCells.count
                if availableCellCount > 1, let catalogCollection {
                    Button {
                        coverageCollection = catalogCollection
                        showsCoverageOverview = true
                    } label: {
                        Label("Coverage \(visibleCellCount)/\(availableCellCount)", systemImage: "square.3.layers.3d")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .tint(.black)
                    .accessibilityLabel("Open cell coverage map; \(visibleCellCount) high-resolution cells prepared")
                }
                Menu {
                    Section("Display") { displayOptions }
                    Button("Import another chart…") { showSourcePicker = true }
                    if let catalogCollection {
                        Button("Cell coverage overview…") {
                            coverageCollection = catalogCollection
                            showsCoverageOverview = true
                        }
                    }
                    if !store.collections.isEmpty {
                        Section("Chart collections") {
                            ForEach(store.collections) { collection in
                                Button("\(collection.originalFilename) · \(collection.cells.count) cells") {
                                    coverageCollection = collection
                                    showsCoverageOverview = true
                                }
                            }
                        }
                    }
                    if !store.charts.isEmpty {
                        Section("Offline chart cells") {
                            ForEach(store.charts) { item in
                                Button("\(item.metadata.cellID) · 1:\(item.metadata.compilationScale)") {
                                    store.select(item)
                                    zoom = 1; pan = .zero; lastPan = .zero
                                }
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle.fill").font(.title3).foregroundStyle(.black) }
                .accessibilityLabel("Offline chart options")
            }
            if showInformationCards && informationVisible {
                VStack(alignment: .leading, spacing: 3) {
                Text("\(chart.sourceName) · \(chart.metadata.cellID)").font(.caption.bold()).foregroundStyle(.black)
                let availableCellCount = catalogCellCount(for: chart)
                if availableCellCount > 1 {
                    Text("\(chartsToRender(selected: chart).count) high-resolution cell(s) selected · \(availableCellCount) cells in overview")
                        .font(.caption2.bold()).foregroundStyle(.black)
                }
                Text(chartsToRender(selected: chart).map { $0.metadata.cellID }.sorted().joined(separator: " + "))
                    .font(.caption2.monospaced()).foregroundStyle(.black)
                Text("Edition \(chart.metadata.edition), update \(chart.metadata.update) · 1:\(chart.metadata.compilationScale)")
                    .font(.caption2).foregroundStyle(.black)
                Text("\(chart.metadata.depthReferenceDescription) · update status unverified")
                    .font(.caption2).foregroundStyle(.black)
                Text("\(chartsToRender(selected: chart).reduce(0) { $0 + $1.unportrayedFeatureCount }) chart features and \(chartsToRender(selected: chart).reduce(0) { $0 + $1.unportrayedMetadataCount }) metadata objects not shown")
                    .font(.caption2.bold()).foregroundStyle(.black)
            }.transition(.opacity)
            }
        }
        .padding(8).background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
    }

    private func limitations(_ chart: OfflineENCChart) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Not for navigation. Tap symbols for source details.").bold()
            DisclosureGroup("Legend and portrayal limitations") {
            VStack(alignment: .leading, spacing: 3) {
            Text("Dashed blue outlines mark detailed coverage. Outside: simplified overview only, not detailed chart coverage.")
            if !detailBackgroundStatus.isEmpty { Text(detailBackgroundStatus) }
            Text("Zoom in for detail. Tap a feature for its stored attributes.")
            Text("Badges identify overhead cables, cautions, anchorages and source information. Brown = land context; purple waves = charted turbulence. Wk = wreck; green fronds = kelp; purple arrows = charted streams (not live); dashed purple = ferry. Aid shapes/stripes are simplified; some patterns, topmarks and light sectors remain incomplete.")
            HStack(spacing: 5) {
                ForEach([OfflineENCDepthBand.under2, .under5, .under10, .under20, .deep], id: \.self) { band in
                    Rectangle().fill(depthColour(band)).frame(width: 18, height: 8)
                }
                Text("Minimum depth: <2 / 2–5 / 5–10 / 10–20 / ≥20 m")
            }
            Text("Green = drying/intertidal; gray = unknown range/units. Colours are not a safe-depth assessment.")
            Text("Not for navigation. Charted depth is not current depth or under-keel clearance.")
        }
            }
            }
        .font(.caption2).foregroundStyle(.black)
        .padding(7).background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
    }

    private func nearbyFeatureRow(_ candidate: OfflineENCFeatureSelection) -> some View {
        Button {
            inspectedFeature = candidate
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(candidate.feature.className)
                    if let name = candidate.feature.attributes["ATTL_116"], !name.isEmpty { Text(name).font(.caption) }
                    Text("\(candidate.chart.metadata.cellID) · feature \(candidate.feature.attributes["RCID"] ?? candidate.feature.id)").font(.caption2)
                }
                Spacer()
                if candidate.id == inspectedFeature?.id { Image(systemName: "checkmark") }
            }
        }
    }

    private func featureDetails(_ feature: OfflineENCFeature, chart: OfflineENCChart) -> some View {
        NavigationStack {
            List {
                if nearbyFeatures.count > 1 {
                    Section {
                        DisclosureGroup("Nearby features · \(nearbyFeatures.count)") {
                            let priority = nearbyFeatures.filter { OfflineENCNearbyGroup.group(for: $0.feature.objectClass) == .aidsAndHazards }
                            let soundings = nearbyFeatures.filter { OfflineENCNearbyGroup.group(for: $0.feature.objectClass) == .soundings }
                            let other = nearbyFeatures.filter { OfflineENCNearbyGroup.group(for: $0.feature.objectClass) == .other }
                            if !priority.isEmpty {
                                Text("Navigation aids & hazards · \(priority.count)").font(.caption.bold()).foregroundStyle(.secondary)
                                ForEach(priority) { nearbyFeatureRow($0) }
                            }
                            if !soundings.isEmpty {
                                DisclosureGroup("Soundings · \(soundings.count)") {
                                    ForEach(soundings) { nearbyFeatureRow($0) }
                                }
                            }
                            if !other.isEmpty {
                                DisclosureGroup("Other chart details · \(other.count)") {
                                    ForEach(other) { nearbyFeatureRow($0) }
                                }
                            }
                        }
                    }
                }
                Section("Feature") {
                    LabeledContent("Class", value: feature.className)
                    LabeledContent("Cell feature ID", value: feature.attributes["RCID"] ?? "unknown")
                    LabeledContent("Geometry", value: feature.geometryType ?? "not available")
                    if !feature.isPortrayed { Text("This feature class is not portrayed by this prototype.").foregroundStyle(.orange) }
                    if [3, 4].contains(feature.objectClass) {
                        Text("Charted anchorage/berth; not a recommendation or permission to anchor. Check restrictions and source notes.").font(.caption)
                    }
                    if feature.objectClass == 21 {
                        ForEach(["181", "184"], id: \.self) { code in
                            if let value = feature.attributes["ATTL_" + code], !value.isEmpty {
                                LabeledContent(code == "181" ? "Source clearance (VERCLR)" : "Source safe clearance (VERCSA)", value: chart.heightValue(value, for: feature))
                            }
                        }
                        LabeledContent("Clearance reference", value: chart.heightDatum(for: feature))
                        Text("Charted physical clearance and authorized safe clearance are different. A missing safe-clearance value is not inferred. No current water-level or vessel-clearance adjustment is made.").font(.caption)
                    }
                    if let info = feature.attributes["ATTL_102"], !info.isEmpty { Text(info).textSelection(.enabled) }
                    if !feature.restrictionLabels.isEmpty {
                        LabeledContent("Charted restrictions", value: feature.restrictionLabels.joined(separator: "\n"))
                    } else if [3, 4, 27, 112].contains(feature.objectClass) {
                        Text("No restriction code supplied; this does not establish permission.").font(.caption)
                    }
                    if !feature.statusLabels.isEmpty { LabeledContent("Charted status", value: feature.statusLabels.joined(separator: "\n")) }
                    ForEach(["86", "85", "119", "118"], id: \.self) { code in
                        if let value = feature.attributes["ATTL_" + code], !value.isEmpty {
                            LabeledContent(["86": "Source start date", "85": "Source end date", "119": "Season start", "118": "Season end"][code]!, value: value)
                        }
                    }
                    if let channel = feature.attributes["ATTL_77"] { LabeledContent("Charted radio channel", value: channel) }
                    if feature.objectClass == 58 { Text("Charted fog signal; operation/status and signal attributes must be checked. No sound is played.").font(.caption) }
                    if feature.objectClass == 138 { Text("Source tidal information only; no live current prediction is inferred.").font(.caption) }
                    if feature.objectClass == 156 {
                        LabeledContent("Turbulence", value: feature.turbulenceDescription)
                        Text("Charted turbulence location, not a live forecast of conditions.").font(.caption)
                    }
                    if let elevation = feature.attributes["ATTL_90"] {
                        LabeledContent("Charted elevation", value: chart.heightValue(elevation, for: feature))
                        Text("Elevation is not water depth.").font(.caption)
                        LabeledContent("Elevation reference", value: chart.heightDatum(for: feature))
                    }
                    if feature.objectClass == 160 {
                        Text("Charted tidal stream — not the current flow at this time.").foregroundStyle(.purple)
                        LabeledContent("Charted direction", value: feature.chartedOrientation.map { String(format: "%.0f° true", $0) } ?? "Not supplied")
                        Text("No current speed or timing is inferred from this symbol.").font(.caption)
                    }
                    if feature.objectClass == 53 { Text(feature.ferryDescription) }
                    if OfflineENCFeature.aidClasses.contains(feature.objectClass) {
                        Text("Simplified symbol. Inspect original attributes for shape, colour, light characteristics and sectors; not full S-52 portrayal.").font(.caption)
                    }
                    if let name = feature.attributes["ATTL_116"] { LabeledContent("Name", value: name) }
                    if let depth = feature.attributes["ATTL_179"] {
                        LabeledContent("Charted depth (VALSOU)", value: depth + " " + chart.metadata.depthUnitName)
                    }
                    if feature.objectClass == 42 {
                        LabeledContent("Depth range", value: "\(feature.attributes["ATTL_87"] ?? "?") – \(feature.attributes["ATTL_88"] ?? "?") \(chart.metadata.depthUnitName)")
                    }
                    if [42, 43, 129, 153, 159].contains(feature.objectClass) {
                        Text(chart.metadata.depthReferenceDescription).font(.footnote)
                        Text("Local sounding datum/unit overrides still require separate interpretation.").font(.caption)
                    }
                    if !feature.soundingDepths.isEmpty {
                        LabeledContent("Charted sounding", value: feature.soundingDepths.map { String(format: "%g", $0) }.joined(separator: ", ") + " \(chart.metadata.depthUnitName)")
                        Text(chart.metadata.depthReferenceDescription).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let note = feature.attributes["ATTL_158"], !note.isEmpty {
                    Section("Source supporting text · " + note) {
                        Text(supportingNote.isEmpty ? "Loading local source text…" : supportingNote).textSelection(.enabled)
                    }
                }
                Section("S-57 attributes") {
                    ForEach(feature.attributes.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: feature.attributes[key] ?? "")
                            .font(.footnote.monospaced())
                    }
                }
            }
            .task(id: chart.id + feature.id) {
                supportingNote = ""
                if let note = feature.attributes["ATTL_158"], !note.isEmpty {
                    let text = await store.supportingText(named: note, chart: chart)
                    if !Task.isCancelled { supportingNote = text }
                }
            }
            .navigationTitle(feature.className)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { inspectedFeature = nil } } }
        }
    }

    private func beginImport(_ source: OfflineENCImportSource) {
        importSource = source
        showFileImporter = true
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            isImporting = true
            importStatus = "Reading and checking the exchange set…"
            let source = importSource
            Task { @MainActor in
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let (data, candidates) = try await Task.detached(priority: .userInitiated) {
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        return (data, try OfflineENCZip.cellCandidates(in: data))
                    }.value
                    guard !Task.isCancelled else { return }
                    let collection = try await store.registerCollection(data, filename: url.lastPathComponent,
                                                                         source: source, candidates: candidates)
                    coverageCollection = collection
                    showsCoverageOverview = true
                    if candidates.count == 1, let onlyCandidate = candidates.first {
                        await importSelectedCell(onlyCandidate, from: collection, data: data)
                    } else {
                        importStatus = ""
                    }
                } catch let error as OfflineENCImportError {
                    importError = error.localizedDescription
                } catch {
                    if (error as NSError).code != NSUserCancelledError {
                        importError = "Import failed. \(error.localizedDescription)"
                    }
                }
            }
        } catch let error as OfflineENCImportError {
            importError = error.localizedDescription
        } catch {
            if (error as NSError).code == NSUserCancelledError { return }
            importError = "Import failed. \(error.localizedDescription)"
        }
    }

    private func importSelectedCells(_ candidates: [OfflineENCZip.CellCandidate], from collection: OfflineENCCollection) {
        guard !isImporting, !candidates.isEmpty else { return }
        isImporting = true
        importStatus = "Preparing selected chart cells…"
        Task { @MainActor in
            var preparedIDs = Set<String>()
            var failures: [String] = []
            for (index, candidate) in candidates.enumerated() {
                importStatus = "Preparing cell \(index + 1) of \(candidates.count) · \(candidate.cellID)…"
                do {
                    let chart = try await store.importCell(candidate, from: collection)
                    preparedIDs.insert(chart.id)
                } catch {
                    failures.append("\(candidate.cellID): \(error.localizedDescription)")
                }
            }
            if let last = candidates.last(where: { candidate in
                preparedIDs.contains("\(collection.sha256):\(candidate.cellID)")
            }), let chart = store.charts.first(where: { $0.metadata.cellID == last.cellID && $0.sha256 == collection.sha256 }) {
                store.select(chart)
            }
            if !preparedIDs.isEmpty {
                selectedMosaicCellIDs = preparedIDs
                resetChartViewport()
                importStatus = "Prepared \(preparedIDs.count) chart cell\(preparedIDs.count == 1 ? "" : "s") for offline viewing."
            } else {
                importStatus = "No chart cells were prepared."
            }
            if !failures.isEmpty { importError = failures.joined(separator: "\n") }
            isImporting = false
        }
    }

    private func importSelectedCell(_ candidate: OfflineENCZip.CellCandidate,
                                    from collection: OfflineENCCollection, data: Data?) async {
        isImporting = true
        importStatus = "Decoding \(candidate.cellID) and saving it for offline use…"
        do {
            let chart: OfflineENCChart
            if let data {
                chart = try await store.importCell(candidate, from: collection, data: data)
            } else {
                chart = try await store.importCell(candidate, from: collection)
            }
            importStatus = "Imported \(candidate.title) · \(chart.features.count) features · saved for offline use."
            selectedMosaicCellIDs = [chart.id]
            zoom = 1; pan = .zero; lastPan = .zero
        } catch let error as OfflineENCImportError {
            importError = error.localizedDescription
            importStatus = ""
        } catch {
            importError = "Import failed. \(error.localizedDescription)"
            importStatus = ""
        }
        isImporting = false
    }

    private func symbolDensity(_ features: [OfflineENCFeature], projector: ENCProjector) -> OfflineENCSymbolDensity {
        OfflineENCSymbolDensity(points: features.compactMap { feature in
            guard feature.isPortrayed, feature.geometryType == "Point", feature.objectClass != 129,
                  let point = feature.coordinates?.coordinate else { return nil }
            return projector.screen(point)
        })
    }

    private func drawOrder(_ feature: OfflineENCFeature) -> Int {
        switch feature.objectClass {
        case 42: return 0 // depth areas
        case 71: return 1 // land
        case 13, 69, 72, 73, 114, 116, 119, 126: return 2
        case 43: return 2 // depth contours
        case 30: return 3 // coastline
        case 20, 121: return 4 // cable and seabed areas
        case 1, 3, 4, 27, 138: return 5
        case 112: return 5 // restricted areas overlay chart background
        case 21, 22, 53, 104: return 6 // cables over areas
        case 129: return 7 // soundings
        default: return 8 // selected navigation aids and hazards
        }
    }

    private func scaledMarkerContext(_ original: GraphicsContext, at point: CGPoint, scale: CGFloat) -> GraphicsContext {
        var context = original
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -point.x, y: -point.y)
        return context
    }

    /// Names are live viewport annotations, never clipped into cached chart tiles.
    private func drawIslandNames(_ charts: [OfflineENCChart], in context: inout GraphicsContext, projector: ENCProjector) {
        guard showChartText else { return }
        var groups: [String: (name: String, paths: [Path])] = [:]
        for chart in charts {
            for feature in chart.features where feature.objectClass == 71 {
                guard let name = feature.attributes["ATTL_116"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, let coordinates = feature.coordinates else { continue }
                let polygons: [OfflineJSONValue]
                if feature.geometryType == "Polygon" { polygons = [coordinates] }
                else if feature.geometryType == "MultiPolygon", case .array(let parts) = coordinates { polygons = parts }
                else { continue }
                for coordinates in polygons {
                    var polygon = Path()
                    for ring in coordinates.rings { polygon.addPath(path(for: ring, projector: projector, close: true)) }
                    guard polygon.boundingRect.intersects(CGRect(origin: .zero, size: projector.size)) else { continue }
                    let key = name.lowercased()
                    if groups[key] == nil { groups[key] = (name, []) }
                    groups[key]?.paths.append(polygon)
                }
            }
        }
        var occupied = OfflineENCLabelOccupancy()
        let viewport = CGRect(origin: .zero, size: projector.size)
        for key in groups.keys.sorted() {
            guard let group = groups[key] else { continue }
            let fontSize = 13 * OfflineENCMarkerSizing(metresAcross: projector.detailMetresAcross).text
            let text = context.resolve(Text(group.name).font(.system(size: fontSize, weight: .semibold)).foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.16)))
            let measured = text.measure(in: CGSize(width: 10_000, height: 1_000))
            let safe = OfflineENCLandLabel.safeViewport(viewport, labelSize: measured)
            guard !safe.isNull else { continue }
            // Prefer the largest visible land fragment; try others if its label collides.
            let paths = group.paths.sorted { left, right in
                let l = left.boundingRect.intersection(viewport), r = right.boundingRect.intersection(viewport)
                return l.width * l.height > r.width * r.height
            }
            for polygon in paths {
                guard let point = OfflineENCLandLabel.position(in: polygon, viewport: safe) else { continue }
                let rect = CGRect(x: point.x - measured.width / 2, y: point.y - measured.height / 2, width: measured.width, height: measured.height)
                guard occupied.claim(rect.insetBy(dx: -4, dy: -3)) else { continue }
                context.draw(text, at: point)
                break
            }
        }
    }

    private func chartText(_ text: String, font: Font, style: String, color: Color,
                           at point: CGPoint, anchor: UnitPoint = .center, context: inout GraphicsContext, scale: CGFloat = 1, labelLayout: OfflineENCLabelLayout) {
        let context = scaledMarkerContext(context, at: point, scale: scale)
        let key = OfflineENCPortrayalCache.TextKey(text: text, style: style, color: color)
        let resolved = portrayalCache.text(key) { context.resolve(Text(text).font(font).foregroundColor(color)) }
        let measured = resolved.measure(in: CGSize(width: 10_000, height: 1_000))
        let rect = CGRect(x: point.x - measured.width * anchor.x,
                          y: point.y - measured.height * anchor.y,
                          width: measured.width, height: measured.height).applying(context.transform)
        let integral = ["info9", "wk10", "ts10"].contains(style)
        if integral {
            labelLayout.protect(rect)
            context.draw(resolved, at: point, anchor: anchor)
        } else {
            let priority = style == "island13" ? 4 : style == "aid9" ? 3 : (style == "turbulence9" ? 2 : (style.hasPrefix("sounding") ? 1 : 0))
            labelLayout.add(rect: rect, priority: priority) { context.draw(resolved, at: point, anchor: anchor) }
        }
    }

    private func draw(_ feature: OfflineENCFeature, in context: inout GraphicsContext, projector: ENCProjector,
                      soundingCells: inout Set<String>, aidCells: inout Set<String>, depthUnitCode: Int = 1, labelLayout: OfflineENCLabelLayout, symbolDensity: OfflineENCSymbolDensity) {
        guard let coordinates = feature.coordinates else { return }
        let objectClass = feature.objectClass
        let sizing = OfflineENCMarkerSizing(metresAcross: projector.detailMetresAcross)
        let important = OfflineENCFeature.aidClasses.contains(objectClass) || OfflineENCFeature.informationClasses.contains(objectClass) || [21, 27, 58, 104, 153, 156, 159, 160].contains(objectClass)
        var symbolScale = important ? sizing.important : sizing.ordinary
        if objectClass == 129 && !showChartSoundings { return }
        if objectClass == 43 && !showChartContours { return }
        switch feature.geometryType {
        case "Point":
            guard let point = coordinates.coordinate else { return }
            let p = projector.screen(point)
            guard projector.visible(p) else { return }
            symbolScale = symbolDensity.scale(at: p, base: symbolScale, important: important)
            if important {
                labelLayout.protect(CGRect(x: p.x - 11 * symbolScale, y: p.y - 16 * symbolScale,
                                           width: 22 * symbolScale, height: 32 * symbolScale))
            }
            if objectClass == 129 {
                guard claim(p, grid: &soundingCells) else { return }
                let value = feature.soundingDepths.first.map { String(format: "%g", $0) } ?? "?"
                chartText(value, font: .system(size: 9, weight: .medium, design: .rounded), style: "sounding9rounded", color: .black, at: p, context: &context, scale: sizing.text, labelLayout: labelLayout)
            } else if OfflineENCFeature.informationClasses.contains(objectClass) {
                drawInformation(feature, at: p, context: &context, scale: symbolScale, labelLayout: labelLayout)
            } else if objectClass == 156 {
                drawTurbulence(feature, at: p, context: &context, scale: symbolScale, labelLayout: labelLayout)
            } else if OfflineENCFeature.landContextClasses.contains(objectClass) {
                drawContextMarker(feature, at: p, context: &context, labelCells: &aidCells, scale: symbolScale, labelLayout: labelLayout)
            } else if objectClass == 158 {
                drawKelp(at: p, context: &context, scale: symbolScale)
            } else if objectClass == 160 {
                drawTidalStream(feature, at: p, context: &context, scale: symbolScale, labelLayout: labelLayout)
            } else if objectClass == 153 {
                drawRock(at: p, context: &context, scale: symbolScale)
            } else if objectClass == 121 {
                drawSeabedSample(at: p, context: &context, scale: symbolScale)
            } else if objectClass == 159 {
                drawWreck(at: p, context: &context, scale: symbolScale, labelLayout: labelLayout)
            } else if OfflineENCFeature.structureClasses.contains(objectClass) {
                let context = scaledMarkerContext(context, at: p, scale: symbolScale)
                let symbol = objectClass == 90 ? Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                    : Path(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                context.fill(symbol, with: .color(.gray))
                context.stroke(symbol, with: .color(.black), lineWidth: 1.5)
            } else if OfflineENCFeature.aidClasses.contains(objectClass) {
                // Do not silently remove aid symbols when their text labels overlap.
                drawAid(feature, at: p, context: &context, scale: symbolScale)
                if showChartText && zoom >= 2, let name = feature.attributes["ATTL_116"] {
                    chartText(name, font: .system(size: 9, weight: .semibold), style: "aid9", color: .black, at: CGPoint(x: p.x + 16, y: p.y + 10), anchor: .leading, context: &context, scale: sizing.text, labelLayout: labelLayout)
                }
            } else {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(.black))
            }
        case "MultiPoint":
            for (index, point) in coordinates.coordinateList.enumerated() {
                let p = projector.screen(point)
                guard projector.visible(p) else { continue }
                guard claim(p, grid: &soundingCells) else { continue }
                let value = feature.soundingDepths.indices.contains(index) ? String(format: "%g", feature.soundingDepths[index]) : "?"
                chartText(value, font: .system(size: 8, weight: .medium), style: "sounding8", color: .black, at: p, context: &context, scale: sizing.text, labelLayout: labelLayout)
            }
        case "LineString":
            let path = path(for: coordinates.coordinateList, projector: projector, close: false)
            if objectClass == 21 || objectClass == 104 {
                context.stroke(path, with: .color(.white), lineWidth: 4)
                context.stroke(path, with: .color(objectClass == 21 ? .red : .purple), style: StrokeStyle(lineWidth: 2, dash: objectClass == 21 ? [7, 3, 1, 3] : [4, 4]))
                if let point = coordinates.coordinateList.dropFirst(coordinates.coordinateList.count / 2).first { drawInformation(feature, at: projector.screen(point), context: &context, scale: symbolScale, labelLayout: labelLayout) }
            } else if objectClass == 156 {
                context.stroke(path, with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                if let point = coordinates.coordinateList.first { drawTurbulence(feature, at: projector.screen(point), context: &context, scale: symbolScale, labelLayout: labelLayout) }
            } else if OfflineENCFeature.landContextClasses.contains(objectClass) {
                let color: Color = objectClass == 114 ? .blue : (objectClass == 116 ? .gray : .brown)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: objectClass == 116 ? 1.5 : 0.8, dash: objectClass == 126 ? [3, 2] : []))
            } else if objectClass == 53 {
                context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 3)
                context.stroke(path, with: .color(.purple), style: StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
                if showChartText && zoom >= 2, let point = coordinates.coordinateList.dropFirst(coordinates.coordinateList.count / 2).first {
                    chartText(feature.ferryDescription, font: .system(size: 10, weight: .semibold), style: "ferry10", color: .purple, at: projector.screen(point), context: &context, scale: sizing.text, labelLayout: labelLayout)
                }
            } else if OfflineENCFeature.structureClasses.contains(objectClass) {
                context.stroke(path, with: .color(.black), lineWidth: 3.5)
                context.stroke(path, with: .color(.gray), lineWidth: 1.6)
            } else if objectClass == 22 {
                let cable = Color(red: 0.88, green: 0.35, blue: 0.04)
                context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 4)
                context.stroke(path, with: .color(cable), style: StrokeStyle(lineWidth: 2.2, dash: [7, 4]))
            } else {
                let color: Color = objectClass == 43 ? .blue.opacity(0.9) : .black.opacity(0.85)
                context.stroke(path, with: .color(color), lineWidth: objectClass == 43 ? 1.1 : 1.4)
            }
        case "Polygon":
            let rings = coordinates.rings
            var polygon = Path()
            for ring in rings { polygon.addPath(path(for: ring, projector: projector, close: true)) }
            if OfflineENCFeature.informationClasses.contains(objectClass) {
                let color: Color = objectClass == 27 ? .orange : .purple
                context.stroke(polygon, with: .color(color.opacity(objectClass == 1 ? 0.4 : 1)), style: StrokeStyle(lineWidth: objectClass == 1 ? 0.7 : 1.5, dash: [5, 3]))
                if let first = rings.first?.first { drawInformation(feature, at: projector.screen(first), context: &context, scale: symbolScale, labelLayout: labelLayout) }
                break
            }
            if objectClass == 156 {
                context.fill(polygon, with: .color(.purple.opacity(0.08)), style: FillStyle(eoFill: true))
                context.stroke(polygon, with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                if let first = rings.first?.first { drawTurbulence(feature, at: projector.screen(first), context: &context, scale: symbolScale, labelLayout: labelLayout) }
                break
            }
            if OfflineENCFeature.landContextClasses.contains(objectClass) {
                let water = objectClass == 69 || objectClass == 114
                if water || objectClass == 13 {
                    context.fill(polygon, with: .color(water ? Color(red: 0.65, green: 0.82, blue: 0.9) : .gray.opacity(0.22)), style: FillStyle(eoFill: true))
                }
                // Named regions are outlines only: never turn their entire extent into land.
                context.stroke(polygon, with: .color(water || objectClass == 119 ? .blue.opacity(0.6) : .brown.opacity(0.6)), lineWidth: 0.8)
                if let first = rings.first?.first { drawContextMarker(feature, at: projector.screen(first), context: &context, labelCells: &aidCells, scale: symbolScale, labelLayout: labelLayout) }
                break
            }
            if objectClass == 158 {
                context.fill(polygon, with: .color(.green.opacity(0.12)), style: FillStyle(eoFill: true))
                context.stroke(polygon, with: .color(.green), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
                if let first = rings.first?.first { drawKelp(at: projector.screen(first), context: &context, scale: symbolScale) }
                break
            }
            if objectClass == 159 {
                context.fill(polygon, with: .color(.purple.opacity(0.2)), style: FillStyle(eoFill: true))
                context.stroke(polygon, with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                if let first = rings.first?.first { drawWreck(at: projector.screen(first), context: &context, scale: symbolScale, labelLayout: labelLayout) }
                break
            }
            if OfflineENCFeature.structureClasses.contains(objectClass) {
                context.fill(polygon, with: .color(Color(white: 0.62)), style: FillStyle(eoFill: true))
                context.stroke(polygon, with: .color(.black), lineWidth: 1.5)
                break
            }
            if objectClass == 42 {
                let band = feature.depthBand(unitCode: depthUnitCode)
                context.fill(polygon, with: .color(depthColour(band)), style: FillStyle(eoFill: true))
                break
            }
            if objectClass == 112 {
                let restrictedColor = Color(red: 0.68, green: 0.0, blue: 0.42)
                context.fill(polygon, with: .color(restrictedColor.opacity(0.16)), style: FillStyle(eoFill: true))
                context.stroke(polygon, with: .color(restrictedColor), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                break
            }
            if objectClass == 20 {
                let cable = Color(red: 0.88, green: 0.35, blue: 0.04)
                context.fill(polygon, with: .color(cable.opacity(0.12)), style: FillStyle(eoFill: true))
                context.stroke(polygon, with: .color(cable), style: StrokeStyle(lineWidth: 1.8, dash: [6, 3]))
                break
            }
            if objectClass == 121 {
                let seabed = Color(red: 0.66, green: 0.47, blue: 0.18)
                context.fill(polygon, with: .color(seabed.opacity(0.20)), style: FillStyle(eoFill: true))
                context.stroke(polygon, with: .color(seabed.opacity(0.75)), lineWidth: 1)
                break
            }
            let fill: Color = objectClass == 71 ? Color(red: 0.88, green: 0.84, blue: 0.69) : Color(red: 0.68, green: 0.82, blue: 0.84)
            context.fill(polygon, with: .color(fill), style: FillStyle(eoFill: true))
            if objectClass == 30 { context.stroke(polygon, with: .color(.black), lineWidth: 1.4) }
        case "MultiPolygon", "MultiLineString":
            if case .array(let parts) = coordinates {
                for part in parts {
                    let piece = OfflineENCFeature(geometryType: feature.geometryType == "MultiPolygon" ? "Polygon" : "LineString",
                        coordinates: part, attributes: feature.attributes, soundingDepths: feature.soundingDepths)
                    draw(piece, in: &context, projector: projector, soundingCells: &soundingCells, aidCells: &aidCells, depthUnitCode: depthUnitCode, labelLayout: labelLayout, symbolDensity: symbolDensity)
                }
            }
        default:
            break
        }
    }

    private func claim(_ point: CGPoint, grid: inout Set<String>) -> Bool {
        let spacing: CGFloat = zoom < 2 ? 18 : (zoom < 5 ? 12 : 8)
        let x = Int(floor(point.x / spacing)), y = Int(floor(point.y / spacing))
        return grid.insert("\(x):\(y)").inserted
    }

    private func depthColour(_ band: OfflineENCDepthBand) -> Color {
        switch band {
        case .drying: return Color(red: 0.57, green: 0.67, blue: 0.43)
        case .intertidal: return Color(red: 0.72, green: 0.79, blue: 0.55)
        case .under2: return Color(red: 0.30, green: 0.64, blue: 0.85)
        case .under5: return Color(red: 0.48, green: 0.75, blue: 0.91)
        case .under10: return Color(red: 0.66, green: 0.84, blue: 0.95)
        case .under20: return Color(red: 0.83, green: 0.93, blue: 0.98)
        case .deep: return Color(red: 0.97, green: 0.98, blue: 0.97)
        case .unknown: return Color(white: 0.72)
        }
    }

    private func drawInformation(_ feature: OfflineENCFeature, at p: CGPoint, context: inout GraphicsContext, scale: CGFloat = 1, labelLayout: OfflineENCLabelLayout) {
        var context = scaledMarkerContext(context, at: p, scale: scale)
        let color: Color = feature.objectClass == 21 ? .red : (feature.objectClass == 27 ? .orange : .purple)
        let width: CGFloat = feature.objectClass == 27 ? 18 : 42
        let badge = Path(roundedRect: CGRect(x: p.x - width / 2, y: p.y - 8, width: width, height: 16), cornerRadius: 3)
        context.fill(badge, with: .color(.white.opacity(0.95)))
        context.stroke(badge, with: .color(color), lineWidth: 1.3)
        chartText(feature.informationSymbol, font: .system(size: 9, weight: .bold), style: "info9", color: color, at: p, context: &context, labelLayout: labelLayout)
    }

    private func drawContextMarker(_ feature: OfflineENCFeature, at p: CGPoint, context: inout GraphicsContext, labelCells: inout Set<String>, scale: CGFloat = 1, labelLayout: OfflineENCLabelLayout) {
        var context = scaledMarkerContext(context, at: p, scale: scale)
        let water = feature.objectClass == 119 || feature.objectClass == 69 || feature.objectClass == 114
        let color: Color = water ? .blue : .brown
        let rect = CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)
        context.fill(Path(rect), with: .color(.white))
        context.stroke(Path(rect), with: .color(color), lineWidth: 1)
        if showChartText && zoom >= 2 {
            let name = feature.attributes["ATTL_116"].flatMap { $0.isEmpty ? nil : $0 }
            chartText(name ?? feature.contextSymbolLabel, font: .system(size: 9, weight: .medium), style: "context9", color: color, at: CGPoint(x: p.x + 5, y: p.y - 5), anchor: .leading, context: &context, scale: max(1, 0.75 / scale), labelLayout: labelLayout)
        }
    }

    private func drawTurbulence(_ feature: OfflineENCFeature, at p: CGPoint, context: inout GraphicsContext, scale: CGFloat = 1, labelLayout: OfflineENCLabelLayout) {
        var context = scaledMarkerContext(context, at: p, scale: scale)
        labelLayout.protect(CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18).applying(context.transform))
        var waves = Path()
        for y: CGFloat in [-4, 2] {
            waves.move(to: CGPoint(x: p.x - 7, y: p.y + y))
            waves.addCurve(to: CGPoint(x: p.x + 7, y: p.y + y), control1: CGPoint(x: p.x - 2, y: p.y + y - 7), control2: CGPoint(x: p.x + 2, y: p.y + y + 7))
        }
        context.stroke(waves, with: .color(.white), lineWidth: 4)
        context.stroke(waves, with: .color(.purple), lineWidth: 2)
        if showChartText && zoom >= 3 { chartText(feature.turbulenceDescription, font: .system(size: 9, weight: .semibold), style: "turbulence9", color: .purple, at: CGPoint(x: p.x, y: p.y + 24), context: &context, labelLayout: labelLayout) }
    }

    private func drawKelp(at p: CGPoint, context: inout GraphicsContext, scale: CGFloat = 1) {
        let context = scaledMarkerContext(context, at: p, scale: scale)
        var fronds = Path()
        for offset: CGFloat in [-5, 0, 5] {
            fronds.move(to: CGPoint(x: p.x, y: p.y + 6))
            fronds.addCurve(to: CGPoint(x: p.x + offset, y: p.y - 7),
                control1: CGPoint(x: p.x + offset - 5, y: p.y), control2: CGPoint(x: p.x + offset + 5, y: p.y - 3))
        }
        context.stroke(fronds, with: .color(.white), lineWidth: 3)
        context.stroke(fronds, with: .color(Color(red: 0.05, green: 0.4, blue: 0.15)), lineWidth: 1.5)
    }

    private func drawTidalStream(_ feature: OfflineENCFeature, at p: CGPoint, context: inout GraphicsContext, scale: CGFloat = 1, labelLayout: OfflineENCLabelLayout) {
        var context = scaledMarkerContext(context, at: p, scale: scale)
        guard let degrees = feature.chartedOrientation else {
            chartText("TS?", font: .system(size: 10, weight: .bold), style: "ts10", color: .purple, at: p, context: &context, labelLayout: labelLayout)
            return
        }
        // Canvas is north-up. ORIENT is clockwise from true north.
        let angle = degrees * .pi / 180
        let dx = sin(angle), dy = -cos(angle)
        let tip = CGPoint(x: p.x + 10 * dx, y: p.y + 10 * dy)
        var arrow = Path()
        arrow.move(to: CGPoint(x: p.x - 10 * dx, y: p.y - 10 * dy)); arrow.addLine(to: tip)
        arrow.move(to: CGPoint(x: tip.x - 6 * dx + 4 * dy, y: tip.y - 6 * dy - 4 * dx))
        arrow.addLine(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - 6 * dx - 4 * dy, y: tip.y - 6 * dy + 4 * dx))
        context.stroke(arrow, with: .color(.white), lineWidth: 4)
        context.stroke(arrow, with: .color(.purple), lineWidth: 1.8)
    }

    private func topmarkPath(_ shape: Int, at p: CGPoint) -> Path {
        var result = Path()
        func cone(_ y: CGFloat, up: Bool) -> Path {
            var t = Path(); let direction: CGFloat = up ? -1 : 1
            t.move(to: CGPoint(x: p.x, y: y + direction * 4))
            t.addLine(to: CGPoint(x: p.x + 4, y: y - direction * 3))
            t.addLine(to: CGPoint(x: p.x - 4, y: y - direction * 3)); t.closeSubpath(); return t
        }
        switch shape {
        case 1, 24: return cone(p.y, up: true)
        case 2, 25: return cone(p.y, up: false)
        case 3, 26: return Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
        case 4:
            for y in [p.y - 5, p.y + 5] { result.addEllipse(in: CGRect(x: p.x - 3, y: y - 3, width: 6, height: 6)) }
        case 10, 11, 13, 14:
            result.addPath(cone(p.y - 5, up: shape == 11 || shape == 13))
            result.addPath(cone(p.y + 5, up: shape == 10 || shape == 13))
        case 5, 6, 19, 20, 21: result.addRect(CGRect(x: p.x - 4, y: p.y - 5, width: 8, height: 10))
        case 7, 8:
            let d: CGFloat = shape == 7 ? 4 : 0
            result.move(to: CGPoint(x: p.x - d, y: p.y - 5)); result.addLine(to: CGPoint(x: p.x + d, y: p.y + 5))
            result.move(to: CGPoint(x: p.x - 5, y: p.y + d)); result.addLine(to: CGPoint(x: p.x + 5, y: p.y - d))
        default:
            // Unimplemented topmark shape is conspicuously generic, never guessed.
            result.addRect(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
        }
        return result
    }

    private func drawWreck(at p: CGPoint, context: inout GraphicsContext, scale: CGFloat = 1, labelLayout: OfflineENCLabelLayout) {
        var context = scaledMarkerContext(context, at: p, scale: scale)
        let oval = Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 5, width: 16, height: 10))
        context.fill(oval, with: .color(.white))
        context.stroke(oval, with: .color(.purple), lineWidth: 2)
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - 7, y: p.y - 7)); cross.addLine(to: CGPoint(x: p.x + 7, y: p.y + 7))
        cross.move(to: CGPoint(x: p.x - 7, y: p.y + 7)); cross.addLine(to: CGPoint(x: p.x + 7, y: p.y - 7))
        context.stroke(cross, with: .color(.purple), lineWidth: 1.7)
        chartText("Wk", font: .system(size: 10, weight: .bold), style: "wk10", color: .purple, at: CGPoint(x: p.x, y: p.y + 14), context: &context, labelLayout: labelLayout)
    }

    private func drawAid(_ feature: OfflineENCFeature, at p: CGPoint, context: inout GraphicsContext, scale: CGFloat = 1) {
        let context = scaledMarkerContext(context, at: p, scale: scale)
        func colour(_ code: Int) -> Color {
            switch code { case 1: return .white; case 2: return .black; case 3: return .red
            case 4: return .green; case 5: return .blue; case 6: return .yellow
            case 7: return .gray; case 8: return .brown; case 9: return .orange; default: return .gray }
        }
        let key = "\(feature.objectClass)|\(feature.attributes["ATTL_4"] ?? "")|\(feature.attributes["ATTL_171"] ?? "")"
        let symbol = portrayalCache.symbol(key) { aidShape(feature) }
            .applying(CGAffineTransform(translationX: p.x, y: p.y))
        let codes = feature.colourCodes
        context.fill(symbol, with: .color(codes.first.map(colour) ?? .gray))
        // Only depict stripe orientations explicitly supplied by COLPAT.
        let pattern = feature.attributes["ATTL_76"]
        if codes.count > 1 && (pattern == "1" || pattern == "2") {
            var clipped = context; clipped.clip(to: symbol)
            for (i, code) in codes.enumerated() {
                let band = 18 / CGFloat(codes.count)
                let rect = pattern == "2"
                    ? CGRect(x: p.x - 9 + CGFloat(i) * band, y: p.y - 9, width: band, height: 18)
                    : CGRect(x: p.x - 9, y: p.y - 9 + CGFloat(i) * band, width: 18, height: band)
                clipped.fill(Path(rect), with: .color(colour(code)))
            }
        } else if codes.count > 1 {
            context.fill(symbol, with: .color(.gray))
        }
        context.stroke(symbol, with: .color(.white), lineWidth: 2.5)
        context.stroke(symbol, with: .color(.black), lineWidth: 1)
    }

    private func aidShape(_ feature: OfflineENCFeature) -> Path {
        let p = CGPoint.zero
        let cls = feature.objectClass
        var symbol = Path()
        if cls == 75 {
            for i in 0..<10 {
                let angle = Double(i) * .pi / 5 - .pi / 2
                let r: Double = i.isMultiple(of: 2) ? 7 : 3
                let q = CGPoint(x: p.x + cos(angle) * r, y: p.y + sin(angle) * r)
                if i == 0 { symbol.move(to: q) } else { symbol.addLine(to: q) }
            }
            symbol.closeSubpath()
        } else if cls == 144 || cls == 39 {
            symbol = topmarkPath(Int(feature.attributes["ATTL_171"] ?? "") ?? 0, at: p)
        } else if (14...19).contains(cls) {
            switch feature.attributes["ATTL_4"] {
            case "1":
                symbol.move(to: CGPoint(x: p.x, y: p.y - 7)); symbol.addLine(to: CGPoint(x: p.x + 6, y: p.y + 6)); symbol.addLine(to: CGPoint(x: p.x - 6, y: p.y + 6)); symbol.closeSubpath()
            case "2", "6", "7", "8": symbol = Path(CGRect(x: p.x - 5, y: p.y - 6, width: 10, height: 12))
            case "3": symbol = Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            case "4": symbol = Path(CGRect(x: p.x - 3, y: p.y - 8, width: 6, height: 16))
            case "5": symbol = Path(CGRect(x: p.x - 1.5, y: p.y - 8, width: 3, height: 16))
            default: symbol = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 6, width: 10, height: 12))
            }
        } else if (5...9).contains(cls) {
            symbol.move(to: CGPoint(x: p.x, y: p.y - 7))
            symbol.addLine(to: CGPoint(x: p.x + 6, y: p.y + 5))
            symbol.addLine(to: CGPoint(x: p.x - 6, y: p.y + 5)); symbol.closeSubpath()
        } else {
            symbol = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 6, width: 10, height: 12))
        }
        return symbol
    }

    /// A conspicuous prototype hazard mark, deliberately distinct from navigation aids.
    private func drawRock(at point: CGPoint, context: inout GraphicsContext, scale: CGFloat = 1) {
        let context = scaledMarkerContext(context, at: point, scale: scale)
        let half: CGFloat = 6
        var diamond = Path()
        diamond.move(to: CGPoint(x: point.x, y: point.y - half))
        diamond.addLine(to: CGPoint(x: point.x + half, y: point.y))
        diamond.addLine(to: CGPoint(x: point.x, y: point.y + half))
        diamond.addLine(to: CGPoint(x: point.x - half, y: point.y))
        diamond.closeSubpath()
        context.fill(diamond, with: .color(Color(red: 0.82, green: 0.08, blue: 0.08)))
        context.stroke(diamond, with: .color(.white), lineWidth: 1.5)
        var cross = Path()
        cross.move(to: CGPoint(x: point.x - 2.5, y: point.y - 2.5))
        cross.addLine(to: CGPoint(x: point.x + 2.5, y: point.y + 2.5))
        cross.move(to: CGPoint(x: point.x + 2.5, y: point.y - 2.5))
        cross.addLine(to: CGPoint(x: point.x - 2.5, y: point.y + 2.5))
        context.stroke(cross, with: .color(.white), lineWidth: 1.3)
    }

    /// An unobtrusive sample mark for a point Seabed Area object; attributes carry the classification.
    private func drawSeabedSample(at point: CGPoint, context: inout GraphicsContext, scale: CGFloat = 1) {
        let context = scaledMarkerContext(context, at: point, scale: scale)
        let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        let color = Color(red: 0.66, green: 0.47, blue: 0.18)
        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.9)))
        context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1)
    }

    private func drawBoatAndAnchor(in context: inout GraphicsContext, projector: ENCProjector) {
        for waypoint in navigation.waypoints {
            let point = projector.screen(.init(longitude: waypoint.longitude, latitude: waypoint.latitude))
            guard projector.visible(point) else { continue }
            context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(waypoint.id == navigation.activeID ? .orange : .blue))
            context.draw(Text(waypoint.name).font(.caption2.bold()).foregroundColor(.black), at: CGPoint(x: point.x + 9, y: point.y), anchor: .leading)
        }
        if let destination = navigation.active, NavigationMetrics.usable(engine.rawFix, now: Date()), let fix = engine.rawFix {
            let bearing = Geo.bearing(from: fix.coordinate, to: destination.coordinate)
            let distance = Geo.distance(fix.coordinate, destination.coordinate)
            let coordinates = (0...32).map { index -> ChartCoordinate in
                let point = Geo.destination(from: fix.coordinate, bearing: bearing, meters: distance * Double(index) / 32)
                return .init(longitude: point.longitude, latitude: point.latitude)
            }
            context.stroke(path(for: coordinates, projector: projector, close: false), with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        }
        if engine.track.count > 1 {
            let points = engine.track.map { ChartCoordinate(longitude: $0.coordinate.longitude, latitude: $0.coordinate.latitude) }
            context.stroke(path(for: points, projector: projector, close: false), with: .color(.purple), lineWidth: 2)
        }
        if let anchor = engine.anchor {
            let center = ChartCoordinate(longitude: anchor.longitude, latitude: anchor.latitude)
            if engine.radius > 0 {
                let ring = (0...48).map { i -> ChartCoordinate in
                    let p = Geo.destination(from: anchor, bearing: Double(i) * 7.5, meters: engine.radius)
                    return ChartCoordinate(longitude: p.longitude, latitude: p.latitude)
                }
                context.stroke(path(for: ring, projector: projector, close: true), with: .color(engine.alarm == nil ? .orange : .red), lineWidth: 1.5)
            }
            let p = projector.screen(center)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.orange))
            context.draw(Text("⚓").font(.system(size: 13, weight: .bold)).foregroundColor(.black), at: p)
        }
        if let fix = engine.fix {
            let p = projector.screen(ChartCoordinate(longitude: fix.coordinate.longitude, latitude: fix.coordinate.latitude))
            var boat = Path(); boat.move(to: CGPoint(x: p.x, y: p.y - 8)); boat.addLine(to: CGPoint(x: p.x + 6, y: p.y + 6)); boat.addLine(to: CGPoint(x: p.x - 6, y: p.y + 6)); boat.closeSubpath()
            context.fill(boat, with: .color(.blue)); context.stroke(boat, with: .color(.white), lineWidth: 1)
        }
    }

    private func path(for coordinates: [ChartCoordinate], projector: ENCProjector, close: Bool) -> Path {
        var path = Path()
        guard let first = coordinates.first else { return path }
        path.move(to: projector.screen(first))
        for coordinate in coordinates.dropFirst() { path.addLine(to: projector.screen(coordinate)) }
        if close { path.closeSubpath() }
        return path
    }

    private func inspectFeatures(_ charts: [OfflineENCChart], at tap: CGPoint, size: CGSize, extent: OfflineENCBounds? = nil) {
        nearbyFeatures = featuresNear(charts, at: tap, size: size, extent: extent)
        inspectedFeature = nearbyFeatures.first
    }

    private func featuresNear(_ charts: [OfflineENCChart], at tap: CGPoint, size: CGSize, extent: OfflineENCBounds? = nil) -> [OfflineENCFeatureSelection] {
        guard let bounds = extent ?? canvasBounds(selected: store.selectedChart) else { return [] }
        let projector = ENCProjector(bounds: bounds, size: size, zoom: zoom, pan: pan)
        let matches: [(OfflineENCFeatureSelection, CGFloat)] = charts.flatMap { chart in
            chart.features.compactMap { feature -> (OfflineENCFeatureSelection, CGFloat)? in
                // Metadata boundaries must not intercept taps on visible chart objects.
                guard feature.isPortrayed, !feature.isMetaObject, let coordinates = feature.coordinates else { return nil }
                // Information badges have a larger visible target than their source geometry.
                if OfflineENCFeature.informationClasses.contains(feature.objectClass) {
                    let location: ChartCoordinate?
                    switch feature.geometryType {
                    case "Point": location = coordinates.coordinate
                    case "LineString": location = coordinates.coordinateList.dropFirst(coordinates.coordinateList.count / 2).first
                    case "Polygon": location = coordinates.rings.first?.first
                    default: location = nil
                    }
                    if let location {
                        let p = projector.screen(location)
                        let width: CGFloat = feature.objectClass == 27 ? 18 : 42
                        if CGRect(x: p.x - width / 2, y: p.y - 8, width: width, height: 16).contains(tap) {
                            return (OfflineENCFeatureSelection(chart: chart, feature: feature), -20)
                        }
                    }
                }
                var distance = feature.chartCoordinates().map { hypot(projector.screen($0).x - tap.x, projector.screen($0).y - tap.y) }.min() ?? .infinity
                func lineDistance(_ points: [ChartCoordinate]) -> CGFloat {
                    let screen = points.map(projector.screen)
                    return zip(screen, screen.dropFirst()).map { a, b in
                        let dx = b.x - a.x, dy = b.y - a.y
                        let length = dx * dx + dy * dy
                        let t = length > 0 ? min(1, max(0, ((tap.x - a.x) * dx + (tap.y - a.y) * dy) / length)) : 0
                        return hypot(tap.x - a.x - t * dx, tap.y - a.y - t * dy)
                    }.min() ?? .infinity
                }
                if feature.geometryType == "LineString" {
                    distance = min(distance, lineDistance(coordinates.coordinateList))
                } else if feature.geometryType == "MultiLineString" || feature.geometryType == "Polygon" {
                    for ring in coordinates.rings { distance = min(distance, lineDistance(ring)) }
                }
                // Prefer the visible point symbol over a nearby area boundary.
                let point = feature.geometryType == "Point" || feature.geometryType == "MultiPoint"
                guard distance <= 22 else { return nil }
                return (OfflineENCFeatureSelection(chart: chart, feature: feature), distance + (point ? 0 : 10))
            }
        }
        let ordered = matches.sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
            return lhs.1 < rhs.1
        }
        return ordered.map { $0.0 }
    }

    private func chartsToRender(selected chart: OfflineENCChart) -> [OfflineENCChart] {
        OfflineENCChart.mosaicCharts(in: store.charts, exchangeSetHash: chart.sha256,
                                     selectedCellIDs: selectedMosaicCellIDs, includingCellID: chart.id)
    }

    private func canvasBounds(selected chart: OfflineENCChart?) -> OfflineENCBounds? {
        guard let chart else { return nil }
        return OfflineENCChart.viewportBounds(in: chartsToRender(selected: chart), focusedCellID: chart.id) ?? chart.bounds
    }

    private func importedCells(inSameExchangeAs chart: OfflineENCChart) -> [OfflineENCChart] {
        store.charts.filter { $0.sha256 == chart.sha256 }
    }

    private var activeCoverageCollection: OfflineENCCollection? {
        if let coverageCollection,
           let saved = store.collections.first(where: { $0.id == coverageCollection.id }) {
            return saved
        }
        return OfflineENCCollection.defaultCoverage(in: store.collections,
            preferredID: preferredCoverageCollectionID)
    }

    private func selectedCellIDs(in collection: OfflineENCCollection) -> Set<String> {
        Set(store.charts
            .filter { $0.sha256 == collection.sha256 && (selectedMosaicCellIDs?.contains($0.id) ?? false) }
            .map { $0.metadata.cellID })
    }

    private func openPreparedChart(in collection: OfflineENCCollection) {
        let available = store.charts.filter { $0.sha256 == collection.sha256 && !["CA271100", "CA271101"].contains($0.metadata.cellID) }
        guard !available.isEmpty else { return }
        let selected = available.first(where: { $0.id == store.selectedChartID })
            ?? available.first(where: { selectedMosaicCellIDs?.contains($0.id) ?? false })
            ?? available[0]
        store.select(selected)
        showsCoverageOverview = false
        resetChartViewport()
    }

    private func collection(for chart: OfflineENCChart) -> OfflineENCCollection? {
        store.collections.first { $0.sha256 == chart.sha256 }
    }

    private func catalogCellCount(for chart: OfflineENCChart) -> Int {
        collection(for: chart)?.cells.count ?? importedCells(inSameExchangeAs: chart).count
    }

    private func resetChartViewport() {
        zoom = 1
        pan = .zero
        lastPan = .zero
    }
}

struct ENCProjector: Sendable {
    let minX: Double, maxX: Double, minY: Double, maxY: Double
    let size: CGSize, zoom: CGFloat, pan: CGSize
    let clippingSize: CGSize
    var coordinatesAreProjected = false

    init(bounds: OfflineENCBounds, size: CGSize, zoom: CGFloat, pan: CGSize, clippingSize: CGSize? = nil) {
        func x(_ lon: Double) -> Double { lon * .pi / 180 }
        func y(_ lat: Double) -> Double { log(tan(.pi / 4 + min(85.0511, max(-85.0511, lat)) * .pi / 360)) }
        minX = x(bounds.west); maxX = x(bounds.east); minY = y(bounds.south); maxY = y(bounds.north)
        self.size = size; self.zoom = zoom; self.pan = pan; self.clippingSize = clippingSize ?? size
    }

    var metresAcross: Double {
        let fit = min(Double(size.width) / max(maxX - minX, 1e-10), Double(size.height) / max(maxY - minY, 1e-10)) * 0.94
        let latitude = 2 * atan(exp((minY + maxY) / 2)) - .pi / 2
        return Double(size.width) / max(fit * Double(zoom), 1e-10) * 6_378_137 * cos(latitude)
    }

    // Normalize to a phone-width viewport so rotation does not change detail density.
    var detailMetresAcross: Double { metresAcross * 390 / max(Double(size.width), 1) }

    var bufferedGeographicViewport: OfflineENCBounds {
        let width = maxX - minX, height = maxY - minY
        let scale = min(Double(size.width) / max(width, 1e-10), Double(size.height) / max(height, 1e-10)) * 0.94 * Double(zoom)
        func coordinate(_ x: Double, _ y: Double) -> ChartCoordinate {
            let mx = (x - Double(size.width / 2 + pan.width)) / scale + (minX + maxX) / 2
            let my = (Double(size.height / 2 + pan.height) - y) / scale + (minY + maxY) / 2
            return .init(longitude: mx * 180 / .pi, latitude: (2 * atan(exp(my)) - .pi / 2) * 180 / .pi)
        }
        let a = coordinate(0, 0), b = coordinate(Double(size.width), Double(size.height))
        let dx = max((b.longitude - a.longitude) / 4, 0.000001)
        let dy = max((a.latitude - b.latitude) / 4, 0.000001)
        return .init(west: max(-180, (floor(a.longitude / dx) - 1) * dx),
                     south: max(-85, (floor(b.latitude / dy) - 1) * dy),
                     east: min(180, (ceil(b.longitude / dx) + 1) * dx),
                     north: min(85, (ceil(a.latitude / dy) + 1) * dy))
    }

    func visible(_ point: CGPoint) -> Bool {
        CGRect(origin: .zero, size: clippingSize).insetBy(dx: -96, dy: -96).contains(point)
    }

    func rect(_ bounds: OfflineENCBounds) -> CGRect {
        let a = screen(ChartCoordinate(longitude: bounds.west, latitude: bounds.north))
        let b = screen(ChartCoordinate(longitude: bounds.east, latitude: bounds.south))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
    }

    func coordinate(at point: CGPoint) -> ChartCoordinate {
        let fit = min(Double(size.width) / max(maxX - minX, 1e-10), Double(size.height) / max(maxY - minY, 1e-10)) * 0.94
        let scale = max(fit * Double(zoom), 1e-10)
        let x = Double(point.x - size.width / 2 - pan.width) / scale + (minX + maxX) / 2
        let y = Double(size.height / 2 + pan.height - point.y) / scale + (minY + maxY) / 2
        let longitude = (x * 180 / .pi + 180).truncatingRemainder(dividingBy: 360)
        return .init(longitude: (longitude < 0 ? longitude + 360 : longitude) - 180, latitude: (2 * atan(exp(y)) - .pi / 2) * 180 / .pi)
    }

    func screen(_ coordinate: ChartCoordinate) -> CGPoint {
        if coordinatesAreProjected { return CGPoint(x: coordinate.longitude, y: coordinate.latitude) }
        let x = coordinate.longitude * .pi / 180
        let y = log(tan(.pi / 4 + min(85.0511, max(-85.0511, coordinate.latitude)) * .pi / 360))
        let width = maxX - minX, height = maxY - minY
        let fit = min(Double(size.width) / max(width, 1e-10), Double(size.height) / max(height, 1e-10)) * 0.94
        let scale = fit * Double(zoom)
        return CGPoint(x: size.width / 2 + CGFloat((x - (minX + maxX) / 2) * scale) + pan.width,
                       y: size.height / 2 - CGFloat((y - (minY + maxY) / 2) * scale) + pan.height)
    }
}

private struct OfflineENCCollectionMap: View {
    @ObservedObject var store: OfflineENCStore
    @AppStorage("encOverviewBackgroundCellID") private var backgroundCellID = "CA271100"
    @State private var showCellList = false
    @State private var backgroundChart: OfflineENCChart?
    @State private var backgroundStatus = ""
    @State private var backgroundLoading = false
    let collection: OfflineENCCollection
    let importedCellIDs: Set<String>
    let initialSelectedCellIDs: Set<String>
    let areaID: String?
    let onChooseArea: (String?) -> Void
    let onPrepare: ([OfflineENCZip.CellCandidate]) -> Void
    let onOpenPreparedCharts: () -> Void
    let onImportAnother: () -> Void
    let onChooseCollection: (OfflineENCCollection) -> Void
    let onBrowsePackage: () -> Void
    @State private var search = ""
    @State private var selectedCellIDs: Set<String>
    @State private var overviewZoom: CGFloat = 1
    @State private var overviewPan = CGSize.zero
    @State private var overviewPanStart = CGSize.zero
    @State private var overviewSize = CGSize(width: 320, height: 230)

    init(store: OfflineENCStore, collection: OfflineENCCollection, importedCellIDs: Set<String>,
         initialSelectedCellIDs: Set<String>,
         areaID: String? = nil,
         onChooseArea: @escaping (String?) -> Void,
         onPrepare: @escaping ([OfflineENCZip.CellCandidate]) -> Void,
         onOpenPreparedCharts: @escaping () -> Void,
         onImportAnother: @escaping () -> Void,
         onChooseCollection: @escaping (OfflineENCCollection) -> Void,
         onBrowsePackage: @escaping () -> Void) {
        self.store = store
        self.collection = collection
        self.importedCellIDs = importedCellIDs
        self.initialSelectedCellIDs = initialSelectedCellIDs
        self.areaID = areaID
        self.onChooseArea = onChooseArea
        self.onPrepare = onPrepare
        self.onOpenPreparedCharts = onOpenPreparedCharts
        self.onImportAnother = onImportAnother
        self.onChooseCollection = onChooseCollection
        self.onBrowsePackage = onBrowsePackage
        _selectedCellIDs = State(initialValue: initialSelectedCellIDs)
    }

    private var effectiveBackgroundID: String { areaID ?? backgroundCellID }
    private var overviewCells: [OfflineENCZip.CellCandidate] {
        if let areaID { return collection.cells.filter { $0.cellID == areaID } }
        return collection.cells.filter { ["CA271100", "CA271101"].contains($0.cellID.uppercased()) }
    }

    private var sectionCells: [OfflineENCZip.CellCandidate] {
        if let areaID { return OfflineENCCruisingArea.detailCells(in: collection.cells, areaID: areaID) }
        guard let extent = overviewCells.first(where: { $0.cellID == effectiveBackgroundID })?.bounds else {
            return collection.cells
        }
        return collection.cells.filter { cell in
            guard !overviewCells.contains(where: { $0.cellID == cell.cellID }), let box = cell.bounds else { return false }
            return box.west < extent.east && box.east > extent.west && box.south < extent.north && box.north > extent.south
        }
    }

    private var bounds: OfflineENCBounds? {
        if let box = overviewCells.first(where: { $0.cellID == effectiveBackgroundID })?.bounds { return box }
        if let box = backgroundChart?.bounds { return box }
        let boxes = collection.cells.compactMap(\.bounds)
        guard let west = boxes.map(\.west).min(), let east = boxes.map(\.east).max(),
              let south = boxes.map(\.south).min(), let north = boxes.map(\.north).max(),
              west < east, south < north else { return nil }
        return OfflineENCBounds(west: west, south: south, east: east, north: north)
    }

    private var filteredCells: [OfflineENCZip.CellCandidate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sectionCells }
        return sectionCells.filter {
            $0.cellID.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Menu {
                    ForEach(store.collections) { candidate in
                        Button {
                            onChooseCollection(candidate)
                        } label: {
                            Label("\(candidate.originalFilename) · \(candidate.cells.count) cells",
                                  systemImage: candidate.id == collection.id ? "checkmark" : "map")
                        }
                    }
                } label: {
                    Label("\(collection.originalFilename) · \(collection.cells.count) cells",
                          systemImage: "chevron.down")
                        .font(.subheadline.weight(.semibold)).padding(8)
                }
                .accessibilityLabel("Choose chart collection")
                Button(action: onBrowsePackage) {
                    Label("Browse whole package · preview", systemImage: "map.fill")
                }.buttonStyle(.bordered).padding(.bottom, 4)
                Text("Cached chart preview. iPhone performance validation is still pending.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
                Menu {
                    ForEach(OfflineENCCruisingArea.presets) { area in
                        Button("\(area.name) (\(area.cellID))") { onChooseArea(area.cellID) }
                            .disabled(!collection.cells.contains { $0.cellID == area.cellID && $0.bounds != nil })
                    }
                    Button("Whole coverage") { onChooseArea(nil) }
                } label: { Label("Areas", systemImage: "map") }
                if !overviewCells.isEmpty {
                    if let areaID {
                        Text("\(OfflineENCCruisingArea.presets.first { $0.cellID == areaID }?.name ?? areaID) · \(areaID)").font(.headline)
                    } else {
                    Picker("Overview chart", selection: $backgroundCellID) {
                        ForEach(overviewCells) { cell in
                            Text("\(cell.title) · \(cell.cellID)").tag(cell.cellID)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Overview background chart")
                    }
                    if backgroundLoading { ProgressView("Preparing overview…").font(.caption) }
                    if !backgroundStatus.isEmpty {
                        Text(backgroundStatus).font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
                        if backgroundChart == nil && !backgroundLoading {
                            Button("Retry background") { Task { await loadBackground() } }
                        }
                    }
                }

                if let bounds {
                    HStack(spacing: 8) {
                        Button { overviewZoom = max(1, overviewZoom / 1.4) } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .accessibilityLabel("Zoom out")
                        Button { overviewZoom = min(18, overviewZoom * 1.4) } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .accessibilityLabel("Zoom in")
                        Menu {
                            ForEach(sectionCells) { cell in
                                Button("\(cell.cellID) · \(cell.title)") {
                                    guard let cellBounds = cell.bounds else { return }
                                    focus(cellBounds, in: bounds, size: overviewSize)
                                }
                            }
                        } label: {
                            Label("Zoom to chart area", systemImage: "location.magnifyingglass")
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button("Overview") { overviewZoom = 1; overviewPan = .zero; overviewPanStart = .zero }
                            .disabled(overviewZoom == 1 && overviewPan == .zero)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.top, 10)
                    GeometryReader { mapGeometry in
                    Canvas { context, size in
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.76, green: 0.88, blue: 0.92)))
                        if let backgroundChart {
                            drawBackground(backgroundChart, in: &context,
                                           projector: ENCProjector(bounds: bounds, size: size, zoom: overviewZoom, pan: overviewPan))
                        }
                        for cell in sectionCells {
                            guard let cellBounds = cell.bounds,
                                  let rect = projectedRect(cellBounds, in: bounds, size: size,
                                                           zoom: overviewZoom, pan: overviewPan) else { continue }
                            let selected = selectedCellIDs.contains(cell.cellID)
                            let imported = importedCellIDs.contains(cell.cellID)
                            let fill = selected ? Color.cyan.opacity(0.20)
                                : (imported ? Color.green.opacity(0.10) : Color.red.opacity(0.02))
                            let stroke = selected ? Color.cyan : (imported ? Color.green : Color.red)
                            context.fill(Path(rect), with: .color(fill))
                            context.stroke(Path(rect), with: .color(stroke), lineWidth: selected ? 2 : 0.8)
                            if rect.width >= 24, rect.height >= 12 {
                                let label = String(cell.cellID.dropFirst(2))
                                context.draw(Text(label).font(.system(size: 7, weight: .bold)).foregroundColor(.black),
                                             at: CGPoint(x: rect.midX, y: rect.midY))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            overviewPan = CGSize(width: overviewPanStart.width + value.translation.width,
                                                 height: overviewPanStart.height + value.translation.height)
                        }
                        .onEnded { _ in overviewPanStart = overviewPan })
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        let hits = sectionCells.compactMap { cell -> (OfflineENCZip.CellCandidate, CGFloat)? in
                            guard let cellBounds = cell.bounds,
                                  let rect = projectedRect(cellBounds, in: bounds, size: mapGeometry.size,
                                                           zoom: overviewZoom, pan: overviewPan),
                                  rect.insetBy(dx: -8, dy: -8).contains(tap.location) else { return nil }
                            return (cell, rect.width * rect.height)
                        }.sorted { $0.1 < $1.1 }
                        if let hit = hits.first { toggle(hit.0) }
                    })
                    .onAppear { overviewSize = mapGeometry.size }
                    .onChange(of: mapGeometry.size) { _, size in overviewSize = size }
                    }
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 8) {
                            legendDot(.cyan, label: "Selected")
                            legendDot(.green, label: "Prepared")
                            legendDot(.red, label: "Available")
                        }
                        .font(.caption2.bold()).padding(6)
                            .background(.regularMaterial, in: Capsule()).padding(.trailing, 22).padding(.bottom, 8)
                    }
                } else {
                    ContentUnavailableView("Coverage bounds unavailable", systemImage: "map", description: Text("Use the searchable cell list below."))
                        .frame(height: 180)
                }
                Text("Tap boxes to select cells. Simplified overview—not for navigation. Boxes are approximate extents.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 8)
                Button("Browse \(sectionCells.count) cells · \(selectedCellIDs.count) selected") { showCellList = true }
                    .font(.caption).padding(4)

            }
            .navigationTitle("Chart cell coverage")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "\(collection.id):\(effectiveBackgroundID)") { await loadBackground() }
            .onAppear { selectedCellIDs = initialSelectedCellIDs }
            .onChange(of: initialSelectedCellIDs) { _, newSelection in selectedCellIDs = newSelection }
            .sheet(isPresented: $showCellList) {
                NavigationStack {
                List(filteredCells) { cell in
                    Button { toggle(cell) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedCellIDs.contains(cell.cellID) ? "checkmark.circle.fill" :
                                    (importedCellIDs.contains(cell.cellID) ? "arrow.down.circle.fill" : "circle"))
                                .foregroundStyle(selectedCellIDs.contains(cell.cellID) ? Color.cyan :
                                    (importedCellIDs.contains(cell.cellID) ? Color.green : Color.gray))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cell.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text(cell.cellID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if importedCellIDs.contains(cell.cellID) {
                                Text("PREPARED").font(.caption2.bold()).foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(selectedCellIDs.contains(cell.cellID) ? "Deselect" : "Select") \(cell.title), chart cell \(cell.cellID)")
                }
                .listStyle(.plain)
                .searchable(text: $search, prompt: "Search chart title or ENC cell ID")
                    .navigationTitle("Cells in this section")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCellList = false } } }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if areaID == nil {
                        Button("Open prepared") { onOpenPreparedCharts() }
                            .disabled(importedCellIDs.isEmpty)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onImportAnother) {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import another chart collection")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Clear") { selectedCellIDs.removeAll() }
                        .disabled(selectedCellIDs.isEmpty)
                    Spacer()
                    Button {
                        let candidates = collection.cells.filter { selectedCellIDs.contains($0.cellID) }
                        onPrepare(candidates)
                    } label: {
                            Label(areaID == nil ? "Prepare \(selectedCellIDs.count) cell\(selectedCellIDs.count == 1 ? "" : "s") offline" : "Show \(selectedCellIDs.count) selected cells", systemImage: "map")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCellIDs.isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    @MainActor
    private func loadBackground() async {
        backgroundChart = nil
        backgroundStatus = ""
        overviewZoom = 1; overviewPan = .zero; overviewPanStart = .zero
        guard let cell = overviewCells.first(where: { $0.cellID == effectiveBackgroundID }) else {
            if let first = overviewCells.first { backgroundCellID = first.cellID }
            return
        }
        backgroundLoading = true
        do {
            let chart: OfflineENCChart
            if areaID != nil {
                chart = try await store.packageCell(cell, from: collection, viewport: cell.bounds, overview: true).chart
            } else if let cached = store.charts.first(where: { $0.sha256 == collection.sha256 && $0.metadata.cellID == cell.cellID }) {
                chart = cached
            } else {
                chart = try await store.importCell(cell, from: collection, select: false)
            }
            try Task.checkCancellation()
            backgroundChart = chart
            backgroundStatus = "\(chart.metadata.cellID) · simplified overview · update status unverified"
        } catch is CancellationError { return }
        catch { backgroundStatus = "Background unavailable: \(error.localizedDescription)" }
        backgroundLoading = false
    }

    private func toggle(_ cell: OfflineENCZip.CellCandidate) {
        if selectedCellIDs.contains(cell.cellID) { selectedCellIDs.remove(cell.cellID) }
        else { selectedCellIDs.insert(cell.cellID) }
    }

    private func legendDot(_ color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    private func projectedRect(_ chart: OfflineENCBounds, in extent: OfflineENCBounds, size: CGSize,
                               zoom: CGFloat = 1, pan: CGSize = .zero) -> CGRect? {
        let projector = ENCProjector(bounds: extent, size: size, zoom: zoom, pan: pan)
        let topLeft = projector.screen(ChartCoordinate(longitude: chart.west, latitude: chart.north))
        let bottomRight = projector.screen(ChartCoordinate(longitude: chart.east, latitude: chart.south))
        let rect = CGRect(x: topLeft.x, y: topLeft.y,
                          width: max(1, bottomRight.x - topLeft.x), height: max(1, bottomRight.y - topLeft.y))
        return rect.intersects(CGRect(origin: .zero, size: size)) ? rect : nil
    }

    private func focus(_ cell: OfflineENCBounds, in extent: OfflineENCBounds, size: CGSize) {
        func mercatorY(_ latitude: Double) -> Double {
            log(tan(.pi / 4 + min(85.0511, max(-85.0511, latitude)) * .pi / 360))
        }
        let west = extent.west * .pi / 180, east = extent.east * .pi / 180
        let north = mercatorY(extent.north), south = mercatorY(extent.south)
        let cellWest = cell.west * .pi / 180, cellEast = cell.east * .pi / 180
        let cellNorth = mercatorY(cell.north), cellSouth = mercatorY(cell.south)
        let baseScale = min(Double(size.width) / max(east - west, 1e-9),
                            Double(size.height) / max(north - south, 1e-9)) * 0.94
        let targetScale = min(Double(size.width) * 0.72 / max(cellEast - cellWest, 1e-9),
                             Double(size.height) * 0.72 / max(cellNorth - cellSouth, 1e-9))
        overviewZoom = min(18, max(1, targetScale / max(baseScale, 1e-9)))
        let centerX = (west + east) / 2, centerY = (north + south) / 2
        let targetX = (cellWest + cellEast) / 2, targetY = (cellNorth + cellSouth) / 2
        let scale = baseScale * Double(overviewZoom)
        overviewPan = CGSize(width: (centerX - targetX) * scale,
                             height: (targetY - centerY) * scale)
        overviewPanStart = overviewPan
    }
}

private extension OfflineJSONValue {
    var coordinate: ChartCoordinate? {
        switch self {
        case .position(let lon, let lat), .position3D(let lon, let lat, _):
            return ChartCoordinate(longitude: lon, latitude: lat)
        default: break
        }
        guard case .array(let values) = self, values.count >= 2,
              case .number(let lon) = values[0], case .number(let lat) = values[1] else { return nil }
        return ChartCoordinate(longitude: lon, latitude: lat)
    }
    var coordinateList: [ChartCoordinate] {
        guard case .array(let values) = self else { return [] }
        return values.compactMap(\.coordinate)
    }
    var rings: [[ChartCoordinate]] {
        guard case .array(let values) = self else { return [] }
        return values.map(\.coordinateList)
    }
}

private func drawBackground(_ chart: OfflineENCChart, in context: inout GraphicsContext, projector: ENCProjector) {
        // Deliberately omit soundings, hazards and aids from this coverage selector.
        for objectClass in [42, 71, 30] {
            for feature in chart.features where feature.objectClass == objectClass {
                guard let coordinates = feature.coordinates else { continue }
                func path(_ points: [ChartCoordinate], closed: Bool) -> Path {
                    var result = Path()
                    guard let first = points.first else { return result }
                    result.move(to: projector.screen(first))
                    for point in points.dropFirst() { result.addLine(to: projector.screen(point)) }
                    if closed { result.closeSubpath() }
                    return result
                }
                func polygon(_ rings: [[ChartCoordinate]]) {
                    var shape = Path()
                    for ring in rings { shape.addPath(path(ring, closed: true)) }
                    let color = objectClass == 71 ? Color(red: 0.88, green: 0.84, blue: 0.69) : Color(red: 0.68, green: 0.82, blue: 0.84)
                    context.fill(shape, with: .color(color), style: FillStyle(eoFill: true))
                    if objectClass == 71 || objectClass == 30 {
                        context.stroke(shape, with: .color(.black.opacity(0.65)), lineWidth: 0.7)
                    }
                }
                switch feature.geometryType {
                case "Polygon": polygon(coordinates.rings)
                case "MultiPolygon":
                    if case .array(let polygons) = coordinates { for item in polygons { polygon(item.rings) } }
                case "LineString": context.stroke(path(coordinates.coordinateList, closed: false), with: .color(.black.opacity(0.7)), lineWidth: 0.8)
                case "MultiLineString":
                    for line in coordinates.rings { context.stroke(path(line, closed: false), with: .color(.black.opacity(0.7)), lineWidth: 0.8) }
                default: break
                }
            }
        }
    }


/// Raster-only LRU. It never retains chart models, render closures or ImageRenderer
/// instances. The vector working set remains separately bounded by the session.
@MainActor
final class OfflineENCTileCache: ObservableObject {
    struct Key: Hashable {
        let namespace: String
        let scene: String
        let address: OfflineENCTileAddress
    }
    struct Entry {
        let key: Key
        let image: CGImage
        var access: UInt64
        var bytes: Int { image.bytesPerRow * image.height }
    }
    private(set) var entries: [Key: Entry] = [:]
    @Published private(set) var displayedEntries: [Entry] = []
    private(set) var displayDomain = ""
    private(set) var overviewBackdrop: [Entry] = []
    private var displayedIsOverview = false
    private var generation = UUID()
    // The displayed frame retains at most one additional cache-sized set of images.
    var displayedByteCount: Int { (overviewBackdrop + displayedEntries).reduce(0) { $0 + $1.bytes } }
    @Published private(set) var status = "Preparing chart images…"
    private(set) var renderCount = 0
    private(set) var hitCount = 0
    private(set) var maximumRenderMilliseconds = 0.0
    private var clock: UInt64 = 0
    let byteLimit: Int
    var byteCount: Int { entries.values.reduce(0) { $0 + $1.bytes } }
    init(byteLimit: Int = 32 * 1024 * 1024) { self.byteLimit = byteLimit }

    func insert(_ image: CGImage, for key: Key, protecting protected: Set<Key> = []) {
        let bytes = image.bytesPerRow * image.height
        guard bytes <= byteLimit else { return }
        entries.removeValue(forKey: key)
        while byteCount + bytes > byteLimit {
            let victim = entries.values.filter { !protected.contains($0.key) }.min { $0.access < $1.access }
                ?? entries.values.min { $0.access < $1.access }
            guard let victim else { break }
            entries.removeValue(forKey: victim.key)
        }
        clock &+= 1
        entries[key] = Entry(key: key, image: image, access: clock)
    }

    func prepare(keys: [Key], displayDomain: String = "", isOverview: Bool = false, render: (OfflineENCTileAddress) async -> CGImage?) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        generation = request
        let protected = Set(keys)
        var failed = false
        for key in keys {
            guard !Task.isCancelled, generation == request else { return }
            if var entry = entries[key] {
                clock &+= 1; entry.access = clock; entries[key] = entry; hitCount += 1
                continue
            }
            status = "Preparing chart images…"
            let started = Date()
            let image = await render(key.address)
            maximumRenderMilliseconds = max(maximumRenderMilliseconds, Date().timeIntervalSince(started) * 1000)
            guard !Task.isCancelled, generation == request else { return }
            if let image { insert(image, for: key, protecting: protected); renderCount += 1 }
            else { failed = true }
            // Yield between raster jobs so controls and cancellation get serviced.
            await Task.yield()
        }
        guard !Task.isCancelled, generation == request else { return }
        let complete = keys.compactMap { entries[$0] }
        if !failed, !keys.isEmpty, complete.count == keys.count,
           complete.reduce(0, { $0 + $1.bytes }) <= byteLimit {
            // Keep a complete regional background for newly exposed edges when zooming out.
            // Both retained layers together share the same fixed display budget.
            let previous = self.displayDomain == displayDomain ? (displayedIsOverview ? displayedEntries : overviewBackdrop) : []
            let backdrop = isOverview ? [] : previous
            let completeBytes = complete.reduce(0) { $0 + $1.bytes }
            overviewBackdrop = backdrop.reduce(0, { $0 + $1.bytes }) + completeBytes <= byteLimit ? backdrop : []
            self.displayDomain = displayDomain
            displayedEntries = complete
            displayedIsOverview = isOverview
        } else {
            failed = true // Never replace a complete view with a partial or oversized batch.
        }
        status = failed ? "Some chart images could not be prepared." : "Chart images ready"
        print("ENC tiles: \(entries.count), bytes=\(byteCount), rendered=\(renderCount), hits=\(hitCount), maxTileMs=\(Int(maximumRenderMilliseconds))")
        fflush(stdout)
    }

    func clear() {
        generation = UUID()
        entries.removeAll(); overviewBackdrop.removeAll(); displayedEntries.removeAll(); displayedIsOverview = false; displayDomain = ""
        status = "Preparing chart images…"
    }
}

/// Only value snapshots cross the worker boundary. Projected geometry is tile-local,
/// never written to disk or used for feature inspection / boat positioning.
enum OfflineENCTilePreparation {
    static func prepare(cells: [OfflineENCChart], featureBounds: [String: [String: OfflineENCBounds]],
                        projector: ENCProjector, overview: Bool) async throws -> [OfflineENCChart] {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let screen = CGRect(origin: .zero, size: projector.clippingSize)
            return try cells.map { cell in
                let features = try cell.features.compactMap { feature -> OfflineENCFeature? in
                    try Task.checkCancellation()
                    let coverage = feature.objectClass == 302
                    let units = feature.objectClass == 311
                    guard coverage || units || feature.isPortrayed else { return nil }
                    if !coverage && !units {
                        if overview && !OfflineENCPackagePolicy.showsInOverview(objectClass: feature.objectClass) { return nil }
                        if let box = featureBounds[cell.id]?[feature.id],
                           !projector.rect(box).insetBy(dx: -96, dy: -96).intersects(screen) { return nil }
                    }
                    return OfflineENCFeature(geometryType: feature.geometryType,
                        coordinates: try feature.coordinates.map { try project($0, using: projector) },
                        attributes: feature.attributes, soundingDepths: feature.soundingDepths)
                }
                return OfflineENCChart(sourceName: cell.sourceName, originalFilename: cell.originalFilename,
                    sha256: cell.sha256, importedAt: cell.importedAt, metadata: cell.metadata, features: features)
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    static func project(_ value: OfflineJSONValue, using projector: ENCProjector) throws -> OfflineJSONValue {
        try Task.checkCancellation()
        switch value {
        case .position(let x, let y):
            let p = projector.screen(ChartCoordinate(longitude: x, latitude: y))
            return .position(p.x, p.y)
        case .position3D(let x, let y, let z):
            let p = projector.screen(ChartCoordinate(longitude: x, latitude: y))
            return .position3D(p.x, p.y, z)
        case .array(let values):
            if values.count >= 2, case .number(let x) = values[0], case .number(let y) = values[1] {
                let p = projector.screen(ChartCoordinate(longitude: x, latitude: y))
                return .array([.number(p.x), .number(p.y)] + values.dropFirst(2))
            }
            return .array(try values.map { try project($0, using: projector) })
        case .object(let values): return .object(try values.mapValues { try project($0, using: projector) })
        default: return value
        }
    }
}

/// Small LRU used by text layouts and origin-centred aid paths. No chart models retained.
struct OfflineENCBoundedCache<Key: Hashable, Value> {
    let limit: Int
    private var clock: UInt64 = 0
    private var entries: [Key: (value: Value, access: UInt64)] = [:]
    private(set) var hits = 0
    var count: Int { entries.count }
    mutating func value(for key: Key, make: () -> Value) -> Value {
        clock &+= 1
        if let entry = entries[key] {
            entries[key] = (entry.value, clock); hits += 1; return entry.value
        }
        let value = make()
        guard limit > 0 else { return value }
        if entries.count >= limit, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = (value, clock)
        return value
    }
    mutating func clear() { entries.removeAll() }
}

@MainActor
final class OfflineENCPortrayalCache: ObservableObject {
    struct TextKey: Hashable { let text: String; let style: String; let color: Color }
    private var texts = OfflineENCBoundedCache<TextKey, GraphicsContext.ResolvedText>(limit: 512)
    private var symbols = OfflineENCBoundedCache<String, Path>(limit: 128)
    func text(_ key: TextKey, make: () -> GraphicsContext.ResolvedText) -> GraphicsContext.ResolvedText {
        guard key.text.utf8.count <= 256 else { return make() }
        return texts.value(for: key, make: make)
    }
    func symbol(_ key: String, make: () -> Path) -> Path { symbols.value(for: key, make: make) }
    func clear() { texts.clear(); symbols.clear() }
}

/// Separate from raster tiles: only visible stations create controls, using the chart's live projection.
struct OfflineCurrentStationMarker: Identifiable {
    let station: CurrentStation
    let point: CGPoint
    var id: String { station.provider.rawValue + ":" + station.id }

    static func visible(_ stations: [CurrentStation], projector: ENCProjector) -> [Self] {
        let viewport = CGRect(origin: .zero, size: projector.size).insetBy(dx: -14, dy: -14)
        var seen = Set<String>()
        return stations.compactMap { station in
            guard CLLocationCoordinate2DIsValid(station.coordinate) else { return nil }
            let point = projector.screen(.init(longitude: station.lng, latitude: station.lat))
            let marker = Self(station: station, point: point)
            guard point.x.isFinite, point.y.isFinite, viewport.contains(point), seen.insert(marker.id).inserted else { return nil }
            return marker
        }
    }
}

/// Retain the existing scrolling table across chart refreshes; cancel requests on dismissal.
private struct OfflineCurrentStationPopup: UIViewRepresentable {
    let station: CurrentStation
    let onClose: () -> Void
    final class Coordinator {
        var task: Task<Void, Never>?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> CurrentStationCalloutView {
        let view = CurrentStationCalloutView()
        view.onClose = onClose
        var saved = CurrentService.cachedSnapshot(for: station)
        saved?.fromCache = true
        view.show(station: station, snapshot: saved, loading: true)
        context.coordinator.task = Task { @MainActor [weak view] in
            do {
                let snapshot = try await CurrentService.snapshot(for: station)
                guard !Task.isCancelled else { return }
                view?.show(station: station, snapshot: snapshot, loading: false)
            } catch {
                guard !Task.isCancelled else { return }
                view?.show(station: station, snapshot: nil, loading: false, error: "Current predictions unavailable. " + error.localizedDescription)
            }
        }
        return view
    }
    func updateUIView(_ view: CurrentStationCalloutView, context: Context) {
        view.onClose = onClose
    }
    static func dismantleUIView(_ view: CurrentStationCalloutView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        view.onClose = nil
    }
}

enum OfflineStationSymbol {
    /// Four-point overview dots grow smoothly to readable close-up symbols.
    static func diameter(metresAcross: Double) -> CGFloat {
        let distance = max(1, metresAcross)
        let fraction = min(1, max(0, log(80_000 / distance) / log(80)))
        return CGFloat(4 + 24 * fraction)
    }
}

struct OfflineTideStationMarker: Identifiable {
    let station: TideStation
    let point: CGPoint
    var id: String { station.source + ":" + station.id }
    static func visible(_ stations: [TideStation], projector: ENCProjector) -> [Self] {
        let viewport = CGRect(origin: .zero, size: projector.size).insetBy(dx: -14, dy: -14)
        var seen = Set<String>()
        return stations.compactMap { station in
            guard CLLocationCoordinate2DIsValid(station.coordinate) else { return nil }
            let marker = Self(station: station, point: projector.screen(.init(longitude: station.lng, latitude: station.lat)))
            guard marker.point.x.isFinite, marker.point.y.isFinite, viewport.contains(marker.point), seen.insert(marker.id).inserted else { return nil }
            return marker
        }
    }
}

private struct OfflineTideStationPopup: UIViewRepresentable {
    let station: TideStation
    let units: Units
    let onClose: () -> Void
    final class Coordinator { var task: Task<Void, Never>? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> TideStationCalloutView {
        let view = TideStationCalloutView()
        view.onClose = onClose
        context.coordinator.task = Task { @MainActor [weak view] in
            var snapshot = TideService.cachedSnapshot(for: station)
            let forecast = station.source == TideStation.noaa || station.forecastSeriesCode != nil
            view?.show(station: station, snapshot: snapshot, loading: true, units: units, ofsLoading: forecast)
            var tideError: String?
            do { snapshot = try await TideService.snapshot(for: station).snapshot }
            catch { tideError = error.localizedDescription }
            guard !Task.isCancelled else { return }
            view?.show(station: station, snapshot: snapshot, loading: false, units: units,
                       error: tideError, ofsLoading: forecast, preserveScroll: true)
            guard forecast else { return }
            do {
                let result = station.source == TideStation.noaa
                    ? try await TideService.ofsWaterLevel(for: station)
                    : try await TideService.chsWaterLevelForecast(for: station)
                guard !Task.isCancelled else { return }
                view?.show(station: station, snapshot: snapshot, loading: false, units: units,
                           error: tideError, ofsForecast: result.series, ofsFromCache: result.fromCache, preserveScroll: true)
            } catch {
                guard !Task.isCancelled else { return }
                view?.show(station: station, snapshot: snapshot, loading: false, units: units,
                           error: tideError, ofsError: error.localizedDescription, preserveScroll: true)
            }
        }
        return view
    }
    func updateUIView(_ view: TideStationCalloutView, context: Context) { view.onClose = onClose }
    static func dismantleUIView(_ view: TideStationCalloutView, coordinator: Coordinator) {
        coordinator.task?.cancel(); view.onClose = nil
    }
}

/// Geographic-scale sizing; applies only to labels and anchored symbols, never chart geometry.
struct OfflineENCMarkerSizing {
    let ordinary: CGFloat
    let important: CGFloat
    let text: CGFloat
    init(metresAcross: Double) {
        let distance = metresAcross.isFinite ? max(1, metresAcross) : 6_000
        let progress = min(1, max(0, log(distance / 1_000) / log(6)))
        ordinary = CGFloat(1 - 0.45 * progress)
        important = CGFloat(1 - 0.20 * progress)
        text = CGFloat(1 - 0.25 * progress)
    }
}

/// Local to one drawing pass; no retained per-pan cache or changes to feature geometry.
/// Priority controls optional text only. Protected symbols are always drawn.
final class OfflineENCLabelLayout {
    private struct Label {
        let rect: CGRect
        let priority: Int
        let draw: () -> Void
    }
    private var landNames: [String: [CGPoint]] = [:]
    func claimLandName(_ name: String, at point: CGPoint) -> Bool {
        let key = name.lowercased()
        guard !(landNames[key] ?? []).contains(where: { hypot($0.x - point.x, $0.y - point.y) < 240 }) else { return false }
        landNames[key, default: []].append(point)
        return true
    }
    private var protected: [CGRect] = []
    private var labels: [Label] = []
    func protect(_ rect: CGRect) { protected.append(rect.insetBy(dx: -2, dy: -2)) }
    func add(rect: CGRect, priority: Int, draw: @escaping () -> Void) {
        labels.append(Label(rect: rect, priority: priority, draw: draw))
    }
    func draw() {
        var occupied = OfflineENCLabelOccupancy()
        for rect in protected { occupied.reserve(rect) }
        // Stable ordering avoids label flicker when priorities match.
        for index in labels.indices.sorted(by: {
            labels[$0].priority == labels[$1].priority ? $0 < $1 : labels[$0].priority > labels[$1].priority
        }) {
            let label = labels[index]
            if occupied.claim(label.rect.insetBy(dx: -2, dy: -2)) { label.draw() }
        }
    }
}

/// Spatial bins keep collision work local rather than comparing every pair of labels.
struct OfflineENCLabelOccupancy {
    private var bins: [String: [CGRect]] = [:]
    private func keys(_ rect: CGRect) -> [String] {
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return [] }
        let left = Int(floor(rect.minX / 32)), right = Int(floor(rect.maxX / 32))
        let top = Int(floor(rect.minY / 32)), bottom = Int(floor(rect.maxY / 32))
        return (left...right).flatMap { x in (top...bottom).map { y in "\(x):\(y)" } }
    }
    mutating func reserve(_ rect: CGRect) {
        for key in keys(rect) { bins[key, default: []].append(rect) }
    }
    mutating func claim(_ rect: CGRect) -> Bool {
        let cells = keys(rect)
        guard !cells.isEmpty, !cells.contains(where: { key in bins[key, default: []].contains(where: { $0.intersects(rect) }) }) else { return false }
        reserve(rect)
        return true
    }
}

/// Compact crowded point symbols in place. No feature is hidden or displaced.
struct OfflineENCSymbolDensity {
    private var bins: [String: [CGPoint]] = [:]
    init(points: [CGPoint]) {
        for point in points where point.x.isFinite && point.y.isFinite {
            bins[Self.key(Int(floor(point.x / 24)), Int(floor(point.y / 24))), default: []].append(point)
        }
    }
    private static func key(_ x: Int, _ y: Int) -> String { "\(x):\(y)" }
    func scale(at point: CGPoint, base: CGFloat, important: Bool) -> CGFloat {
        guard point.x.isFinite, point.y.isFinite else { return base }
        let x = Int(floor(point.x / 24)), y = Int(floor(point.y / 24))
        var count = 0
        for dx in -1...1 {
            for dy in -1...1 {
                for other in bins[Self.key(x + dx, y + dy), default: []] {
                    if hypot(other.x - point.x, other.y - point.y) < 24 { count += 1 }
                }
            }
        }
        guard count > 1 else { return base }
        let factor = max(0.65, 1 - CGFloat(count - 1) * 0.10)
        // Critical symbols have a larger floor; hit targets remain 44 points across.
        return min(base, max(important ? 0.70 : 0.45, base * factor))
    }
}

/// Presentation groups only: preserve every candidate and its existing distance order.
enum OfflineENCNearbyGroup {
    case aidsAndHazards, soundings, other
    static func group(for objectClass: Int) -> Self {
        if OfflineENCFeature.aidClasses.contains(objectClass) ||
            [21, 27, 58, 86, 112, 153, 156, 159, 160].contains(objectClass) {
            return .aidsAndHazards
        }
        return objectClass == 129 ? .soundings : .other
    }
}

/// Bounded sampling keeps labels inside visible land, including concave shores and holes.
enum OfflineENCLandLabel {
    static func safeViewport(_ viewport: CGRect, labelSize: CGSize) -> CGRect {
        guard viewport.width > labelSize.width + 16, viewport.height > labelSize.height + 16 else { return .null }
        return viewport.insetBy(dx: labelSize.width / 2 + 8, dy: labelSize.height / 2 + 8)
    }
    static func position(in polygon: Path, viewport: CGRect) -> CGPoint? {
        let bounds = polygon.boundingRect.intersection(viewport)
        guard !bounds.isNull, bounds.width >= 24, bounds.height >= 18 else { return nil }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var best: CGPoint?
        var bestScore = -Double.infinity
        for row in 0..<9 {
            for column in 0..<9 {
                let point = CGPoint(x: bounds.minX + bounds.width * CGFloat(column + 1) / 10,
                                    y: bounds.minY + bounds.height * CGFloat(row + 1) / 10)
                guard polygon.contains(point, eoFill: true) else { continue }
                var clearance: CGFloat = 0
                for radius: CGFloat in [4, 8, 16, 24, 40] {
                    if [CGPoint(x: point.x-radius, y: point.y), CGPoint(x: point.x+radius, y: point.y),
                        CGPoint(x: point.x, y: point.y-radius), CGPoint(x: point.x, y: point.y+radius)]
                        .allSatisfy({ polygon.contains($0, eoFill: true) && viewport.contains($0) }) { clearance = radius } else { break }
                }
                let score = Double(clearance) - Double(hypot(point.x-center.x, point.y-center.y)) * 0.01
                if score > bestScore { best = point; bestScore = score }
            }
        }
        return best
    }
}

/// Union of data-coverage polygons, minus this cell's explicit no-data areas.
/// An absent coverage mask never means unlimited station coverage.
struct OfflineStationCoverage {
    let included: [Path]
    let excluded: [Path]
    func contains(_ point: CGPoint) -> Bool {
        included.contains { $0.contains(point, eoFill: true) } && !excluded.contains { $0.contains(point, eoFill: true) }
    }
}
