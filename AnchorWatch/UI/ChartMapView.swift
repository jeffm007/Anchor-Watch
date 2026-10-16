import MapKit
import SwiftUI

final class AnchorAnnotation: MKPointAnnotation {}
final class BoatAnnotation: MKPointAnnotation {}
final class CircleLabelAnnotation: MKPointAnnotation {}
/// Where the swing fit puts the anchor.
final class EstimateAnnotation: MKPointAnnotation {}
/// A marked rock, shoal, dock or boat.
final class HazardAnnotation: MKPointAnnotation {
    var hazard: Hazard?
}

/// Faded anchor at the original drop spot once the anchor has been moved from it.
final class OriginalAnchorAnnotation: MKPointAnnotation {}
/// Labels on the lines from the boat to the new anchor spot and to the original one.
final class MeasureAnnotation: MKPointAnnotation {
    var color = UIColor.systemYellow
    /// Where the label normally sits relative to its point on the line (screen points).
    var baseOffset = CGPoint.zero
    /// How far it has been dragged from that point, metres east and north, so it stays put relative to its line.
    var shift = AnchorEstimate.Point(x: 0, y: 0)
    /// The point on the line it's measured from, and whether the finger has it now.
    var linePoint = CLLocationCoordinate2D()
    var isBeingDragged = false
}
final class StationAnnotation: MKPointAnnotation {}
final class WindAnnotation: MKPointAnnotation {
    var speed = 0.0
    var from = 0.0
}

/// Keep transient SwiftUI layout proposals away from MapKit's Metal drawable.
/// In particular, navigation and animated panel changes can briefly propose zero bounds.
@MainActor
final class ChartMapContainer: UIView {
    let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(map)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, let size = Self.drawableSize(bounds.size, scale: window?.screen.scale ?? 1),
              map.frame.size != size else { return }
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            map.frame = CGRect(origin: .zero, size: size)
            map.layoutIfNeeded()
            CATransaction.commit()
        }
    }

    static func drawableSize(_ size: CGSize, scale: CGFloat) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              scale.isFinite, scale > 0 else { return nil }
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }
}

/// UIKit map wrapped for SwiftUI because SwiftUI's Map can't host tile overlays.
struct ChartMapView: UIViewRepresentable {
    @ObservedObject var engine: AnchorWatchEngine

    func makeCoordinator() -> Coordinator { Coordinator(engine) }

    func makeUIView(context: Context) -> ChartMapContainer {
        let container = ChartMapContainer(frame: .zero)
        let map = container.map
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isRotateEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        // Long-press on the swing estimate moves the anchor there. On the map rather than the marker, where
        // MapKit's own selection and pan gestures would take the touch first.
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.5
        press.delegate = context.coordinator
        map.addGestureRecognizer(press)
        return container
    }

    func updateUIView(_ container: ChartMapContainer, context: Context) {
        context.coordinator.sync(container.map)
    }

    static func dismantleUIView(_ container: ChartMapContainer, coordinator: Coordinator) {
        container.map.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        let engine: AnchorWatchEngine
        init(_ engine: AnchorWatchEngine) { self.engine = engine }

        private var layer: ChartLayer?
        private var tiles: [MKTileOverlay] = []
        private let anchorPin = AnchorAnnotation()
        private let boatPin = BoatAnnotation()
        private let labelPin = CircleLabelAnnotation()
        private var labelText = ""
        private var pinsAdded = false

        private var circle: MKCircle?
        private var circleKey: [Double] = []
        /// Dotted circle round the anchor: how far off the drop point may be from GPS error.
        private var uncertainty: MKCircle?
        private var uncertaintyKey: [Double] = []
        /// Predicted swing: how far the stern can reach, and the arc the boat should lie in over the next 24 h.
        private var swingCircle: MKCircle?
        private var swingArc: MKPolyline?
        private var swingKey: [Double] = []
        /// The swing estimate: a marker and its error ellipse.
        private let estimatePin = EstimateAnnotation()
        private var estimateEllipse: MKPolygon?
        private var estimateKey: [Double] = []
        /// Set once the current estimate has been brought into view, so the chart only zooms out for it once.
        private var estimateShown = false
        /// Red arrow showing which way, and how far, the anchor has moved.
        private var driftArrow: MKPolyline?
        private var driftKey: [Double] = []
        private var trackLine: MKPolyline?
        private var trackRevision = -1
        private var tether: MKPolyline?
        private var lastRecenter = 0
        private var lastZoomTick = 0
        private var framedOnce = false
        private var dragging = false
        /// From dragging the anchor pin: a yellow line from the boat to the new anchor spot (distance and bearing from
        /// the boat), and a white line from the original drop mark to it (how far it moved). They stay up, following
        /// the boat, until one of the labels is long-pressed.
        private let measurePin = MeasureAnnotation()
        private let originalPin: MeasureAnnotation = {
            let pin = MeasureAnnotation()
            pin.color = .white
            pin.baseOffset = CGPoint(x: 0, y: -18)      // just above its white line
            return pin
        }()
        private let originalMark = OriginalAnchorAnnotation()
        private var measureLine: MKPolyline?
        private var movedLine: MKPolyline?
        /// Each line and its label can be put away on its own (long-press its label); the next drag shows both again.
        private var showBoatLine = false
        private var showMovedLine = false
        private var measureVisible: Bool { showBoatLine || showMovedLine }
        /// Marked hazards: an icon each, and a red circle for how far around it to keep off.
        private var hazardPins: [HazardAnnotation] = []
        private var hazardCircles: [MKCircle] = []
        private var hazardKey: [Hazard] = []
        /// A hazard being dragged, and the one the measuring lines are about (nil: they're about the anchor).
        private var draggedHazard: HazardAnnotation?
        private var measuredHazard: (id: UUID, origin: CLLocationCoordinate2D)?
        /// The anchor's view while it's being dragged: MapKit only updates the pin's coordinate on release, so the
        /// live position is read from where the view is drawn.
        /// The app's own anchor drag (MapKit's annotation drag gets cancelled whenever anything on the chart changes):
        /// how far the anchor's tip sits from the finger, so it doesn't jump to it.
        private var grab = CGPoint.zero
        /// On-screen length of the boat icon, true to scale but never smaller than `minBoatPoints`.
        private var boatPoints: CGFloat = BoatIcon.minPoints
        private var lastHeading = 0.0

        private var windKey = ""
        private var stationKey = ""
        private var stationPins: [StationAnnotation] = []
        private var lastFitTick = 0
        private var windPins: [WindAnnotation] = []
        private var windWasOn = false
        private var windMapHeading = 0.0

        func sync(_ map: MKMapView) {
            if layer != engine.mapLayer { installLayer(map) }
            if !pinsAdded { map.addAnnotations([anchorPin, boatPin]); pinsAdded = true }

            // Boat
            if let fix = engine.fix { boatPin.coordinate = fix.coordinate }
            boatPin.title = engine.boat.name
            updateBoatView(map)

            // Anchor + alarm circle
            if let anchor = engine.anchor {
                if !dragging { anchorPin.coordinate = anchor }
                anchorPin.title = "Anchor"
                if !map.annotations.contains(where: { $0 === anchorPin }) { map.addAnnotation(anchorPin) }
                syncCircle(map, anchor: anchor)
                syncUncertainty(map, anchor: anchor)
                syncEstimate(map)
                syncDrift(map)
                syncTether(map, anchor: anchor)
                syncSwing(map, anchor: anchor)
                syncCircleLabel(map, anchor: anchor)
                syncOriginalMark(map, anchor: anchor)
                // Dev aid: `-showMeasure` shows the measuring lines, for screenshots.
                if ProcessInfo.processInfo.arguments.contains("-showMeasure") && !measureVisible { showBoatLine = true; showMovedLine = true }
                if measureVisible && !dragging && draggedHazard == nil { updateMeasure(map) }
            } else {
                map.removeAnnotation(anchorPin)
                map.removeAnnotation(labelPin)
                map.removeAnnotation(originalMark)
                if measureVisible {
                    if measuredHazard != nil && draggedHazard == nil { updateMeasure(map) } else if measuredHazard == nil { clearMeasure(map) }
                }
                // The track may still be recording under way; syncTrack removes it once it's empty.
                syncEstimate(map)
                syncDrift(map)
                for o in [circle, uncertainty, tether, swingCircle, swingArc] as [MKOverlay?] { if let o { map.removeOverlay(o) } }
                circle = nil; uncertainty = nil; tether = nil; circleKey = []; uncertaintyKey = []
                swingCircle = nil; swingArc = nil; swingKey = []
            }
            syncHazards(map)
            syncTrack(map)
            frame(map)
            applyZoomCommand(map)
            syncWind(map)
            syncStations(map)
        }

        /// Blue badges for the observation stations, shown with the wind overlay.
        private func syncStations(_ map: MKMapView) {
            let key = "\(engine.windOverlayOn)-" + engine.observations.map { "\($0.id)\($0.time.timeIntervalSince1970)" }.joined()
            if key != stationKey {
                stationKey = key
                map.removeAnnotations(stationPins)
                stationPins = []
                if engine.windOverlayOn {
                    stationPins = engine.observations.map { obs in
                        let pin = StationAnnotation()
                        pin.coordinate = obs.coordinate
                        pin.title = StationName.short(obs.name)
                        pin.subtitle = obs.summary()
                        return pin
                    }
                    map.addAnnotations(stationPins)
                }
            }
            fitStationsIfRequested(map)
        }

        private func fitStationsIfRequested(_ map: MKMapView) {
            guard engine.fitStationsTick != lastFitTick else { return }
            lastFitTick = engine.fitStationsTick
            var coordinates = engine.observations.map(\.coordinate)
            if let here = engine.anchor ?? engine.fix?.coordinate { coordinates.append(here) }
            let points = coordinates.map(MKMapPoint.init)
            guard let first = points.first else { return }
            let rect = points.dropFirst().reduce(MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))) {
                $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0)))
            }
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 260, left: 60, bottom: 260, right: 100), animated: true)
        }

        /// Wind arrows for the forecast hour chosen on the slider; rebuilt only when something changed.
        private func syncWind(_ map: MKMapView) {
            if engine.windOverlayOn && !windWasOn { engine.requestWindGrid(for: map.region) }
            windWasOn = engine.windOverlayOn

            let grid = engine.windGrid.map { "\($0.coordinate.latitude),\($0.coordinate.longitude),\($0.fetched.timeIntervalSince1970),\($0.sample(atHour: engine.windHour)?.time.timeIntervalSince1970 ?? -1)" }.joined()
            let key = "\(engine.windOverlayOn)-\(Int(engine.windHour))-\(grid.hashValue)"
            guard key != windKey else { return }
            windKey = key

            map.removeAnnotations(windPins)
            windPins = []
            guard engine.windOverlayOn else { return }
            windPins = engine.windGrid.compactMap { series in
                guard let sample = series.sample(atHour: engine.windHour) else { return nil }
                let pin = WindAnnotation()
                pin.coordinate = series.coordinate
                pin.speed = sample.speed
                pin.from = sample.direction
                pin.title = String(format: "%.0f kt from %@", sample.speed, Compass.name(sample.direction))
                pin.subtitle = String(format: "gusts %.0f kt", sample.gust)
                return pin
            }
            map.addAnnotations(windPins)
        }

        private func applyZoomCommand(_ map: MKMapView) {
            guard engine.zoomTick != lastZoomTick else { return }
            lastZoomTick = engine.zoomTick
            scaleVisibleRect(map, by: engine.zoomFactor)
        }

        /// Current zoom level in tile terms (256-point tiles).
        private func zoomLevel(_ map: MKMapView) -> Double {
            let pointsPerMapPoint = Double(map.bounds.width) / map.visibleMapRect.size.width
            return log2(pointsPerMapPoint * MKMapSize.world.width / 256)
        }

        /// Zooms about the view's centre. factor < 1 zooms in, > 1 zooms out.
        private func scaleVisibleRect(_ map: MKMapView, by factor: Double) {
            let r = map.visibleMapRect
            let w = r.size.width * factor, h = r.size.height * factor
            let rect = MKMapRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
            map.setVisibleMapRect(rect, animated: true)
        }

        /// MapKit stops requesting tiles once the view is zoomed past a map-replacing overlay's
        /// max zoom, which leaves a blank grid. Pull back to the layer's max zoom when that happens.
        func clampZoom(_ map: MKMapView) {
            guard let maxZ = tiles.filter(\.canReplaceMapContent).map(\.maximumZ).min(), map.bounds.width > 0 else { return }
            let excess = zoomLevel(map) - (Double(maxZ) - 0.6)
            guard excess.isFinite, excess > 0.02 else { return }
            scaleVisibleRect(map, by: pow(2, excess))
        }

        /// Metres on the ground per screen point at the boat's latitude.
        private func metersPerPoint(_ map: MKMapView) -> Double {
            guard map.bounds.width > 0 else { return 1 }
            return MKMetersPerMapPointAtLatitude(boatPin.coordinate.latitude) * map.visibleMapRect.size.width / Double(map.bounds.width)
        }

        /// Sizes the icon to the boat's real length at this zoom, points the bow at the anchor
        /// (or along the GPS course), and keeps the anchor line starting at the bow.
        private func updateBoatView(_ map: MKMapView) {
            let length = (engine.scope.boatLength / metersPerPoint(map)).rounded()
            boatPoints = min(max(CGFloat(length), BoatIcon.minPoints), 600)
            if let view = map.view(for: boatPin) {
                view.image = BoatIcon.image(height: boatPoints)
                view.alpha = engine.hasFreshPosition ? 1 : 0.35
                view.isAccessibilityElement = true
                view.accessibilityLabel = engine.boat.name + (engine.hasFreshPosition ? " position" : " last known position")
                if let heading = engine.heading { lastHeading = heading }
                view.transform = CGAffineTransform(rotationAngle: (lastHeading - map.camera.heading).radians)
            }
            if let anchor = engine.anchor { syncTether(map, anchor: anchor) }
        }

        func mapViewDidChangeVisibleRegion(_ map: MKMapView) {
            updateBoatView(map)
            // Arrows point with the wind, so they must turn when the map is rotated.
            if abs(map.camera.heading - windMapHeading) > 0.5 {
                windMapHeading = map.camera.heading
                for pin in windPins { (map.view(for: pin) as? WindAnnotationView)?.setMapHeading(windMapHeading) }
            }
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            clampZoom(map)
            if engine.windOverlayOn { engine.requestWindGrid(for: map.region) }
        }

        private var tileGeneration = UUID()
        private var failedTiles: Set<URL> = []
        private func installLayer(_ map: MKMapView) {
            tileGeneration = UUID()
            let generation = tileGeneration
            failedTiles.removeAll()
            DispatchQueue.main.async { [weak self] in self?.engine.chartStatus = nil }
            tiles.forEach(map.removeOverlay)
            layer = engine.mapLayer
            map.mapType = engine.mapLayer.mapType
            tiles = engine.mapLayer.makeOverlays()
            for case let tile as ChartTileOverlay in tiles {
                tile.onTileResult = { [weak self] url, error in
                    DispatchQueue.main.async {
                        guard let self, self.tileGeneration == generation else { return }
                        if error != nil { self.failedTiles.insert(url) } else { self.failedTiles.remove(url) }
                        self.engine.chartStatus = self.failedTiles.isEmpty ? nil : "Some chart tiles are unavailable. Check your connection or choose another map source."
                    }
                }
            }
            // Tiles go under everything else; re-add vector overlays on top afterwards.
            var vectors: [MKOverlay] = []
            if let circle { vectors.append(circle) }
            if let uncertainty { vectors.append(uncertainty) }
            if let estimateEllipse { vectors.append(estimateEllipse) }
            if let driftArrow { vectors.append(driftArrow) }
            if let trackLine { vectors.append(trackLine) }
            if let tether { vectors.append(tether) }
            vectors.forEach(map.removeOverlay)
            tiles.forEach { map.addOverlay($0, level: .aboveLabels) }
            vectors.forEach { map.addOverlay($0, level: .aboveLabels) }
            clampZoom(map)
        }

        private var circleText: String {
            engine.alarm != nil ? engine.monitoring.title + " · " + engine.units.format(engine.radius) : (engine.circleMonitoringAvailable ? "Circle alarm ON · " : "Circle alarm OFF · ") + engine.units.format(engine.radius)
        }

        /// Small caption centred just below the south edge of the alarm circle.
        private func syncCircleLabel(_ map: MKMapView, anchor: CLLocationCoordinate2D) {
            labelPin.coordinate = Geo.destination(from: anchor, bearing: 180, meters: engine.radius)
            if !map.annotations.contains(where: { $0 === labelPin }) { map.addAnnotation(labelPin) }
            let text = circleText
            let appearanceKey = text + engine.monitoring.tone.rawValue
            if appearanceKey != labelText, let view = map.view(for: labelPin) {
                labelText = appearanceKey
                view.image = CircleLabel.image(text, alarm: engine.alarm != nil, caution: engine.monitoring.tone != .green)
            }
        }

        private func syncCircle(_ map: MKMapView, anchor: CLLocationCoordinate2D) {
            let key = [anchor.latitude, anchor.longitude, engine.radius, Double(engine.monitoring.tone == .green ? 0 : engine.monitoring.tone == .red ? 2 : 1), engine.circleMonitoringAvailable ? 1 : 0]
            guard key != circleKey else { return }
            circleKey = key
            if let circle { map.removeOverlay(circle) }
            let new = MKCircle(center: anchor, radius: engine.radius)
            circle = new
            map.addOverlay(new, level: .aboveLabels)
        }

        private func syncUncertainty(_ map: MKMapView, anchor: CLLocationCoordinate2D) {
            // Once the swing confirms the mark, the uncertainty ring has done its job.
            let meters = engine.anchorAgreesWithSwing ? nil : engine.anchorUncertainty
            let key = meters.map { [anchor.latitude, anchor.longitude, $0] } ?? []
            guard key != uncertaintyKey else { return }
            uncertaintyKey = key
            if let uncertainty { map.removeOverlay(uncertainty) }
            uncertainty = nil
            guard let meters, meters > 0 else { return }
            let new = MKCircle(center: anchor, radius: meters)
            new.title = "uncertainty"
            uncertainty = new
            map.addOverlay(new, level: .aboveLabels)
        }

        private func syncSwing(_ map: MKMapView, anchor: CLLocationCoordinate2D) {
            let radius = engine.swingRadius
            let arc = engine.predictedSwingArc
            let key = [anchor.latitude, anchor.longitude, radius.rounded(), arc?.from.rounded() ?? -1, arc?.width.rounded() ?? -1]
            guard key != swingKey else { return }
            swingKey = key
            for o in [swingCircle, swingArc] as [MKOverlay?] { if let o { map.removeOverlay(o) } }
            swingCircle = nil; swingArc = nil
            guard radius > 0 else { return }

            let circle = MKCircle(center: anchor, radius: radius)
            circle.title = "swing"
            swingCircle = circle
            map.addOverlay(circle, level: .aboveLabels)

            if let arc, arc.width > 0 {
                let steps = max(2, Int(arc.width / 3))
                var coords = (0...steps).map { i in
                    Geo.destination(from: anchor, bearing: arc.from + arc.width * Double(i) / Double(steps), meters: radius)
                }
                let line = MKPolyline(coordinates: &coords, count: coords.count)
                line.title = "swingArc"
                swingArc = line
                map.addOverlay(line, level: .aboveLabels)
            }
        }

        private func syncEstimate(_ map: MKMapView) {
            // Shown only while it disagrees with the mark; once the anchor is moved there, just the anchor shows.
            let estimate = engine.anchor == nil || engine.anchorAgreesWithSwing ? nil : engine.anchorEstimate
            let key = estimate.map { [$0.center.latitude, $0.center.longitude, $0.semiMajor, $0.semiMinor, $0.majorBearing] } ?? []
            guard key != estimateKey else { return }
            estimateKey = key
            if let estimateEllipse { map.removeOverlay(estimateEllipse) }
            estimateEllipse = nil
            guard let estimate else { map.removeAnnotation(estimatePin); estimateShown = false; return }
            // The first time an estimate appears off the visible chart, zoom out once to show it.
            if !estimateShown {
                estimateShown = true
                if !map.visibleMapRect.contains(MKMapPoint(estimate.center)) {
                    DispatchQueue.main.async { [engine] in engine.recenter() }   // not during the view update
                }
            }

            estimatePin.coordinate = estimate.center
            estimatePin.title = "Anchor by swing"
            estimatePin.subtitle = "±\(engine.units.format(estimate.semiMajor)) · \(Int(estimate.minutes)) min of swing · long-press or tap Move to set the anchor here"
            if !map.annotations.contains(where: { $0 === estimatePin }) { map.addAnnotation(estimatePin) }

            // Error ellipse as a polygon: long axis along majorBearing.
            var coords = (0..<72).map { i -> CLLocationCoordinate2D in
                let t = Double(i) / 72 * 2 * .pi
                let along = estimate.semiMajor * cos(t), across = estimate.semiMinor * sin(t)
                let b = estimate.majorBearing.radians
                let east = along * sin(b) + across * cos(b), north = along * cos(b) - across * sin(b)
                return AnchorEstimate.coordinate(AnchorEstimate.Point(x: east, y: north), from: estimate.center)
            }
            let polygon = MKPolygon(coordinates: &coords, count: coords.count)
            polygon.title = "estimate"
            estimateEllipse = polygon
            map.addOverlay(polygon, level: .aboveLabels)
        }

        private func syncDrift(_ map: MKMapView) {
            let drift = engine.anchor == nil ? nil : engine.anchorDrift
            let key = drift.map { [$0.from.latitude, $0.from.longitude, $0.to.latitude, $0.to.longitude] } ?? []
            guard key != driftKey else { return }
            driftKey = key
            if let driftArrow { map.removeOverlay(driftArrow) }
            driftArrow = nil
            guard let drift else { return }
            // Shaft from where the anchor was to where it is now, then a head drawn back over the tip.
            let head = max(3, drift.distance * 0.3)
            let back = (drift.bearing + 180).truncatingRemainder(dividingBy: 360)
            var coords = [drift.from, drift.to,
                          Geo.destination(from: drift.to, bearing: back - 30, meters: head), drift.to,
                          Geo.destination(from: drift.to, bearing: back + 30, meters: head)]
            let line = MKPolyline(coordinates: &coords, count: coords.count)
            line.title = "drift"
            driftArrow = line
            map.addOverlay(line, level: .aboveLabels)
        }

        private func syncTrack(_ map: MKMapView) {
            guard engine.trackRevision != trackRevision else { return }
            trackRevision = engine.trackRevision
            if let trackLine { map.removeOverlay(trackLine) }
            guard engine.track.count > 1 else { trackLine = nil; return }
            var coords = engine.track.map(\.coordinate)
            let line = MKPolyline(coordinates: &coords, count: coords.count)
            trackLine = line
            map.addOverlay(line, level: .aboveLabels)
        }

        /// Dashed line from the anchor to the boat's bow (the tip of the icon), not the phone's position.
        private func syncTether(_ map: MKMapView, anchor: CLLocationCoordinate2D) {
            if let tether { map.removeOverlay(tether) }
            guard let fix = engine.fix else { tether = nil; return }
            let toAnchor = Geo.bearing(from: fix.coordinate, to: anchor)
            let gap = Geo.distance(fix.coordinate, anchor)
            let bowOffset = min(Double(boatPoints) / 2 * metersPerPoint(map), gap)
            let bow = Geo.destination(from: fix.coordinate, bearing: toAnchor, meters: bowOffset)
            var coords = [anchor, bow]
            let line = MKPolyline(coordinates: &coords, count: 2)
            line.title = "tether"
            tether = line
            map.addOverlay(line, level: .aboveLabels)
        }

        private func frame(_ map: MKMapView) {
            let wantsRecenter = engine.recenterTick != lastRecenter
            lastRecenter = engine.recenterTick
            guard wantsRecenter || !framedOnce else { return }
            let center = engine.anchor ?? engine.fix?.coordinate
            guard let center else { return }
            framedOnce = true
            // Wide enough for the circle, the boat and the swing estimate, which can sit a rode-length from a poor mark.
            let reach = [engine.fix?.coordinate, engine.anchorEstimate?.center].compactMap { $0 }
                .map { Geo.distance(center, $0) }.max() ?? 0
            let swing = engine.anchor == nil ? 0 : engine.swingRadius * 2.8
            let span = max(engine.anchor == nil ? 300 : engine.radius * 3.5, reach * 2.6 + 40, swing, 150)
            map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span), animated: true)
        }

        // MARK: Interaction

        /// Lets our tap run alongside the map's own gestures (annotation selection, double-tap zoom).
        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Long-press within reach of the purple swing marker moves the anchor there.
        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            if draggedHazard != nil {
                dragHazard(map, gesture.state, finger: point)
                return
            }
            if dragging {
                dragAnchor(map, gesture.state, finger: point)
                return
            }
            guard gesture.state == .began else { return }
            // A press on or near the anchor starts dragging it.
            if engine.anchor != nil, let view = map.view(for: anchorPin), view.frame.insetBy(dx: -20, dy: -20).contains(point) {
                let tip = map.convert(anchorPin.coordinate, toPointTo: map)
                grab = CGPoint(x: tip.x - point.x, y: tip.y - point.y)
                dragAnchor(map, .began, finger: point)
                return
            }
            // A press on a label is for moving the label: it shouldn't close, delete or move anything else.
            if pressedMeasureLabel(map, at: point) != nil { return }
            // Long-pressing the faded original-drop mark deletes it (with the moved line that measures from it) and makes
            // the current anchor spot the official one for the next move.
            if map.annotations.contains(where: { $0 === originalMark }),
               map.view(for: originalMark)?.frame.insetBy(dx: -8, dy: -8).contains(gesture.location(in: map)) == true {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                engine.clearOriginalAnchor()
                clearMovedLine(map)
                map.removeAnnotation(originalMark)
                return
            }
            if engine.anchor != nil, let estimate = engine.anchorEstimate, !engine.anchorAgreesWithSwing {
                let marker = map.convert(estimate.center, toPointTo: map)
                if hypot(marker.x - point.x, marker.y - point.y) <= 36 { moveToEstimate(map); return }
            }
            // On a hazard: drag it, as for the anchor.
            if let pin = hazardPins.first(where: { map.view(for: $0)?.frame.insetBy(dx: -12, dy: -12).contains(point) == true }) {
                let tip = map.convert(pin.coordinate, toPointTo: map)
                grab = CGPoint(x: tip.x - point.x, y: tip.y - point.y)
                draggedHazard = pin
                dragHazard(map, .began, finger: point)
                return
            }
            // Anywhere else: mark a hazard here.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            engine.pendingHazard = .init(coordinate: map.convert(point, toCoordinateFrom: map))
        }

        func mapView(_ map: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if view.annotation is EstimateAnnotation { moveToEstimate(map) }
            if let pin = view.annotation as? HazardAnnotation, let id = pin.hazard?.id {
                map.deselectAnnotation(pin, animated: true)
                if control === view.leftCalloutAccessoryView { engine.editHazard(id) } else { engine.removeHazard(id) }
            }
        }

        private func moveToEstimate(_ map: MKMapView) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            map.deselectAnnotation(estimatePin, animated: true)
            engine.moveAnchorToEstimate()
            engine.pokeControls()
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            engine.pokeControls()
            if let map = gesture.view as? MKMapView, let pin = pressedMeasureLabel(map, at: gesture.location(in: map)),
               let view = map.view(for: pin), gesture.location(in: view).x >= view.bounds.width - MeasureLabel.closeWidth - 8 {
                // The ✕ at the end of a label closes that label and its line.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if pin === measurePin { clearBoatLine(map) } else { clearMovedLine(map) }
                return
            }
            guard engine.placingAnchor, let map = gesture.view as? MKMapView,
                  pressedMeasureLabel(map, at: gesture.location(in: map)) == nil else { return }   // a tap on a label is the label's
            engine.moveAnchor(to: map.convert(gesture.location(in: map), toCoordinateFrom: map))
        }

        /// Moves the anchor pin with the finger. The chart holds still meanwhile, and nothing else on it can cancel
        /// the drag; letting go moves the anchor there.
        private func dragAnchor(_ map: MKMapView, _ state: UIGestureRecognizer.State, finger: CGPoint) {
            switch state {
            case .began:
                measuredHazard = nil            // the lines are about the anchor now
                engine.beginAnchorDrag()
                dragging = true
                showBoatLine = true
                showMovedLine = true
                map.isScrollEnabled = false
                map.isZoomEnabled = false
                engine.showNudgePad = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                updateMeasure(map)
            case .changed:
                let tip = CGPoint(x: finger.x + grab.x, y: finger.y + grab.y)
                UIView.performWithoutAnimation { anchorPin.coordinate = map.convert(tip, toCoordinateFrom: map) }
                updateMeasure(map)
            case .ended:
                finishDrag(map)
                engine.moveAnchor(to: anchorPin.coordinate)
                updateMeasure(map)          // stays up, following the boat, until its ✕ is tapped
            default:
                finishDrag(map)
                if let anchor = engine.anchor { anchorPin.coordinate = anchor }
                updateMeasure(map)
            }
        }

        /// Moves a hazard with the finger, its keep-off circle with it, measured from the boat and from where it was.
        private func dragHazard(_ map: MKMapView, _ state: UIGestureRecognizer.State, finger: CGPoint) {
            guard let pin = draggedHazard, let hazard = pin.hazard else { return }
            switch state {
            case .began:
                measuredHazard = (hazard.id, pin.coordinate)
                showBoatLine = true
                showMovedLine = true
                map.isScrollEnabled = false
                map.isZoomEnabled = false
                map.deselectAnnotation(pin, animated: false)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                updateMeasure(map)
            case .changed:
                let tip = CGPoint(x: finger.x + grab.x, y: finger.y + grab.y)
                UIView.performWithoutAnimation { pin.coordinate = map.convert(tip, toCoordinateFrom: map) }
                if let i = hazardPins.firstIndex(where: { $0 === pin }) {
                    map.removeOverlay(hazardCircles[i])
                    let circle = MKCircle(center: pin.coordinate, radius: hazard.radius)
                    circle.title = "hazard"
                    hazardCircles[i] = circle
                    map.addOverlay(circle, level: .aboveLabels)
                }
                updateMeasure(map)
            case .ended:
                draggedHazard = nil
                map.isScrollEnabled = true
                map.isZoomEnabled = true
                engine.moveHazard(hazard.id, to: pin.coordinate)
                updateMeasure(map)
            default:
                draggedHazard = nil
                map.isScrollEnabled = true
                map.isZoomEnabled = true
                pin.coordinate = hazard.coordinate
                hazardKey = []                  // redraw from the saved hazards
                syncHazards(map)
                updateMeasure(map)
            }
        }

        private func finishDrag(_ map: MKMapView) {
            dragging = false
            map.isScrollEnabled = true
            map.isZoomEnabled = true
        }

        private func syncHazards(_ map: MKMapView) {
            guard engine.hazards != hazardKey else { return }
            hazardKey = engine.hazards
            if let measured = measuredHazard, !hazardKey.contains(where: { $0.id == measured.id }) {
                clearMeasure(map)
                measuredHazard = nil
            }
            if let dragged = draggedHazard?.hazard, !hazardKey.contains(where: { $0.id == dragged.id }) {
                draggedHazard = nil
                map.isScrollEnabled = true
                map.isZoomEnabled = true
            }
            map.removeAnnotations(hazardPins)
            map.removeOverlays(hazardCircles)
            hazardPins = engine.hazards.map { hazard in
                let pin = HazardAnnotation()
                pin.hazard = hazard
                pin.coordinate = hazard.coordinate
                pin.title = hazard.label
                pin.subtitle = "Keep \(engine.units.format(hazard.radius)) off"
                return pin
            }
            hazardCircles = engine.hazards.map { hazard in
                let circle = MKCircle(center: hazard.coordinate, radius: hazard.radius)
                circle.title = "hazard"
                return circle
            }
            map.addAnnotations(hazardPins)
            map.addOverlays(hazardCircles, level: .aboveLabels)
        }

        /// The faded mark at the original drop spot, shown once the anchor has moved from it.
        private func syncOriginalMark(_ map: MKMapView, anchor: CLLocationCoordinate2D) {
            if let original = engine.originalAnchor, Geo.distance(original, anchor) > 1 {
                originalMark.coordinate = original
                originalMark.title = "Original drop (long-press to remove)"
                if !map.annotations.contains(where: { $0 === originalMark }) { map.addAnnotation(originalMark) }
            } else {
                map.removeAnnotation(originalMark)
            }
        }

        private func updateMeasure(_ map: MKMapView) {
            if let measured = measuredHazard {
                guard let hazard = engine.hazards.first(where: { $0.id == measured.id }) else { clearMeasure(map); measuredHazard = nil; return }
                let at = draggedHazard?.coordinate ?? hazard.coordinate
                if showBoatLine, let boat = engine.fix?.coordinate {
                    measureLine = replaceLine(map, measureLine, from: boat, to: at, title: "measure")
                    place(map, measurePin, at: midpoint(boat, at), text: hazard.label + " " + fromBoat(boat, to: at))
                }
                guard showMovedLine else { return }
                if Geo.distance(measured.origin, at) >= 0.5 {
                    movedLine = replaceLine(map, movedLine, from: measured.origin, to: at, title: "moved")
                    place(map, originalPin, at: midpoint(measured.origin, at), text: engine.units.format(Geo.distance(measured.origin, at)))
                } else {
                    if let movedLine { map.removeOverlay(movedLine) }
                    movedLine = nil
                    map.removeAnnotation(originalPin)
                }
                return
            }
            let anchor = dragging ? anchorPin.coordinate : (engine.anchor ?? anchorPin.coordinate)
            if showBoatLine, let boat = engine.fix?.coordinate {
                measureLine = replaceLine(map, measureLine, from: boat, to: anchor, title: "measure")
                place(map, measurePin, at: midpoint(boat, anchor), text: "New " + fromBoat(boat, to: anchor))
            }
            guard showMovedLine else { return }
            if let original = engine.originalAnchor, Geo.distance(original, anchor) >= 0.5 {
                // White line from the original drop mark to the new spot, labelled just above with how far it moved.
                movedLine = replaceLine(map, movedLine, from: original, to: anchor, title: "moved")
                place(map, originalPin, at: midpoint(original, anchor), text: engine.units.format(Geo.distance(original, anchor)))
            } else {
                if let movedLine { map.removeOverlay(movedLine) }
                movedLine = nil
                map.removeAnnotation(originalPin)
            }
        }

        /// "228 ft · NE 053°": distance and true bearing from the boat.
        private func fromBoat(_ boat: CLLocationCoordinate2D, to point: CLLocationCoordinate2D) -> String {
            let bearing = Geo.bearing(from: boat, to: point)
            return "\(engine.units.format(Geo.distance(boat, point))) · \(Compass.name(bearing)) \(String(format: "%03.0f°", bearing))"
        }

        private func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
            Geo.destination(from: a, bearing: Geo.bearing(from: a, to: b), meters: Geo.distance(a, b) / 2)
        }

        private func replaceLine(_ map: MKMapView, _ old: MKPolyline?, from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D,
                                 title: String) -> MKPolyline {
            if let old { map.removeOverlay(old) }
            var coords = [a, b]
            let line = MKPolyline(coordinates: &coords, count: 2)
            line.title = title
            map.addOverlay(line, level: .aboveLabels)
            return line
        }

        private func place(_ map: MKMapView, _ pin: MeasureAnnotation, at point: CLLocationCoordinate2D, text: String) {
            pin.linePoint = point
            if !pin.isBeingDragged { pin.coordinate = AnchorEstimate.coordinate(pin.shift, from: point) }
            if !map.annotations.contains(where: { $0 === pin }) { map.addAnnotation(pin) }
            if pin.title != text {
                pin.title = text
                (map.view(for: pin) as? MeasureLabelView)?.show(MeasureLabel.image(text, color: pin.color))
            }
        }

        private func clearMeasure(_ map: MKMapView) {
            clearBoatLine(map)
            clearMovedLine(map)
        }

        /// Slides a measuring label with the finger, holding the chart still; where it's left is kept relative to its line.
        @objc func labelSlid(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? MKAnnotationView, let pin = view.annotation as? MeasureAnnotation else { return }
            var ancestor = view.superview
            while let v = ancestor, !(v is MKMapView) { ancestor = v.superview }
            guard let map = ancestor as? MKMapView else { return }
            switch gesture.state {
            case .began:
                pin.isBeingDragged = true
                map.isScrollEnabled = false
            case .changed:
                let t = gesture.translation(in: map)
                let p = map.convert(pin.coordinate, toPointTo: map)
                pin.coordinate = map.convert(CGPoint(x: p.x + t.x, y: p.y + t.y), toCoordinateFrom: map)
                gesture.setTranslation(.zero, in: map)
            default:
                pin.isBeingDragged = false
                map.isScrollEnabled = true
                let o = GPSQuality.offset(pin.coordinate, from: pin.linePoint)
                pin.shift = AnchorEstimate.Point(x: o.east, y: o.north)
            }
        }

        /// The yellow boat-to-anchor line and its label.
        private func clearBoatLine(_ map: MKMapView) {
            showBoatLine = false
            if let measureLine { map.removeOverlay(measureLine) }
            measureLine = nil
            map.removeAnnotation(measurePin)
            measurePin.title = nil
            measurePin.shift = AnchorEstimate.Point(x: 0, y: 0)
        }

        /// The white original-to-new line and its distance.
        private func clearMovedLine(_ map: MKMapView) {
            showMovedLine = false
            if let movedLine { map.removeOverlay(movedLine) }
            movedLine = nil
            map.removeAnnotation(originalPin)
            originalPin.title = nil
            originalPin.shift = AnchorEstimate.Point(x: 0, y: 0)
        }

        /// The measuring label a long-press landed on, if any.
        private func pressedMeasureLabel(_ map: MKMapView, at point: CGPoint) -> MeasureAnnotation? {
            [measurePin, originalPin].first { pin in
                map.annotations.contains { $0 === pin } && (map.view(for: pin)?.frame.insetBy(dx: -8, dy: -8).contains(point) ?? false)
            }
        }

        // MARK: Rendering

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is AnchorAnnotation:
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "anchor")
                view.image = AnchorIcon.image
                view.isAccessibilityElement = true
                view.accessibilityLabel = "Anchor position"
                view.accessibilityHint = "Use Move Anchor or Fine-tune on the Anchor tab to adjust"
                // The tip at the bottom of the icon sits exactly on the anchor's coordinate.
                view.centerOffset = CGPoint(x: 0, y: -AnchorIcon.size.height / 2)
                view.canShowCallout = true
                view.zPriority = .max
                view.displayPriority = .required
                view.collisionMode = .none
                return view
            case let pin as HazardAnnotation:
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "hazard")
                view.image = HazardIcon.image(pin.hazard?.kind ?? .other)
                view.isAccessibilityElement = true
                view.accessibilityLabel = "Hazard: " + (pin.hazard?.label ?? "marked hazard")
                view.canShowCallout = true
                let remove = UIButton(type: .system)
                remove.setTitle("Remove", for: .normal)
                remove.setTitleColor(.systemRed, for: .normal)
                remove.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                remove.sizeToFit()
                view.rightCalloutAccessoryView = remove
                let edit = UIButton(type: .system)
                edit.setTitle("Edit", for: .normal)
                edit.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                edit.sizeToFit()
                view.leftCalloutAccessoryView = edit
                view.displayPriority = .required
                view.collisionMode = .none
                return view
            case is OriginalAnchorAnnotation:
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "original")
                view.image = AnchorIcon.image
                view.alpha = 0.45
                view.centerOffset = CGPoint(x: 0, y: -AnchorIcon.size.height / 2)
                view.canShowCallout = true
                view.displayPriority = .required
                view.collisionMode = .none
                return view
            case let pin as MeasureAnnotation:
                let view = MeasureLabelView(annotation: annotation, reuseIdentifier: "measure")
                view.show(MeasureLabel.image(pin.title ?? "", color: pin.color))
                view.centerOffset = pin.baseOffset
                // Slide the label to move it; the ✕ is handled by the map's tap.
                view.isUserInteractionEnabled = true
                view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(labelSlid(_:))))
                view.zPriority = .max
                view.displayPriority = .required
                view.collisionMode = .none
                return view
            case is EstimateAnnotation:
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "estimate")
                view.image = EstimateIcon.image
                view.canShowCallout = true
                // A button in the callout does the same as long-pressing the marker.
                let move = UIButton(type: .system)
                move.setTitle("Move anchor here", for: .normal)
                move.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
                move.sizeToFit()
                view.rightCalloutAccessoryView = move
                view.displayPriority = .required
                view.collisionMode = .none
                return view
            case let pin as StationAnnotation:
                let view = MKAnnotationView(annotation: pin, reuseIdentifier: "station")
                let speed = engine.observations.first { StationName.short($0.name) == pin.title }?.windSpeed
                view.image = StationIcon.image(speed: speed)
                view.canShowCallout = true
                view.displayPriority = .defaultHigh
                view.collisionMode = .circle
                return view
            case let pin as WindAnnotation:
                let view = (map.dequeueReusableAnnotationView(withIdentifier: "wind") as? WindAnnotationView)
                    ?? WindAnnotationView(annotation: pin, reuseIdentifier: "wind")
                view.annotation = pin
                view.configure(speed: pin.speed, from: pin.from, mapHeading: map.camera.heading)
                return view
            case is CircleLabelAnnotation:
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "circleLabel")
                labelText = circleText
                view.image = CircleLabel.image(labelText, alarm: engine.alarm != nil, caution: engine.monitoring.tone != .green)
                view.centerOffset = CGPoint(x: 0, y: (view.image?.size.height ?? 0) / 2 + 4)   // hang below the circle edge
                view.canShowCallout = false
                view.isUserInteractionEnabled = false
                view.displayPriority = .required
                view.collisionMode = .none
                return view
            case is BoatAnnotation:
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "boat")
                view.image = BoatIcon.image(height: boatPoints)
                view.alpha = engine.hasFreshPosition ? 1 : 0.35
                view.isAccessibilityElement = true
                view.accessibilityLabel = engine.boat.name + (engine.hasFreshPosition ? " position" : " last known position")
                view.displayPriority = .required
                view.canShowCallout = true
                view.zPriority = .defaultSelected
                return view
            default:
                return nil
            }
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let tile as MKTileOverlay:
                return MKTileOverlayRenderer(tileOverlay: tile)
            case let circle as MKCircle where circle.title == "hazard":
                let r = MKCircleRenderer(circle: circle)
                r.strokeColor = UIColor.systemRed.withAlphaComponent(0.8)
                r.fillColor = UIColor.systemRed.withAlphaComponent(0.18)
                r.lineWidth = 1.5
                return r
            case let circle as MKCircle where circle.title == "swing":
                let r = MKCircleRenderer(circle: circle)
                r.strokeColor = UIColor.systemCyan.withAlphaComponent(0.7)
                r.lineWidth = 1.5
                r.lineDashPattern = [8, 6]
                return r
            case let circle as MKCircle where circle.title == "uncertainty":
                let r = MKCircleRenderer(circle: circle)
                r.strokeColor = UIColor.systemOrange
                r.fillColor = UIColor.systemOrange.withAlphaComponent(0.1)
                r.lineWidth = 2
                r.lineDashPattern = [2, 5]
                return r
            case let circle as MKCircle:
                let r = MKCircleRenderer(circle: circle)
                let color = UIColor(engine.monitoring.color)
                if !engine.circleMonitoringAvailable { r.lineDashPattern = [6, 5] }
                r.strokeColor = color
                r.fillColor = color.withAlphaComponent(0.15)
                r.lineWidth = 3
                return r
            case let polygon as MKPolygon where polygon.title == "estimate":
                let r = MKPolygonRenderer(polygon: polygon)
                r.strokeColor = UIColor.systemPurple
                r.fillColor = UIColor.systemPurple.withAlphaComponent(0.12)
                r.lineWidth = 2
                r.lineDashPattern = [6, 4]
                return r
            case let line as MKPolyline:
                let r = MKPolylineRenderer(polyline: line)
                if line.title == "drift" {
                    r.strokeColor = .systemRed
                    r.lineWidth = 4
                    r.lineCap = .round
                    r.lineJoin = .round
                } else if line.title == "measure" {
                    r.strokeColor = .systemYellow
                    r.lineWidth = 3
                    r.lineCap = .round
                } else if line.title == "moved" {
                    r.strokeColor = .white
                    r.lineWidth = 2.5
                    r.lineDashPattern = [6, 5]
                } else if line.title == "swingArc" {
                    r.strokeColor = UIColor.systemCyan.withAlphaComponent(0.55)
                    r.lineWidth = 7
                    r.lineCap = .round
                } else if line.title == "tether" {
                    r.strokeColor = UIColor.systemOrange.withAlphaComponent(0.8)
                    r.lineWidth = 1.5
                    r.lineDashPattern = [4, 4]
                } else {
                    r.strokeColor = .systemPurple
                    r.lineWidth = 3
                }
                return r
            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }
    }
}

/// Top-down trawler silhouette, bow pointing up (north), so it can be rotated to the boat's heading.
enum BoatIcon {
    /// Smallest on-screen length, so the boat stays visible when zoomed far out.
    static let minPoints: CGFloat = 30

    private static var cache: [Int: UIImage] = [:]

    /// The icon scaled to `height` points long, with a width in the same proportion as the artwork.
    static func image(height: CGFloat) -> UIImage {
        let key = Int(height)
        if let cached = cache[key] { return cached }
        let size = CGSize(width: height * artworkSize.width / artworkSize.height, height: height)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in
            artwork.draw(in: CGRect(origin: .zero, size: size))
        }
        cache[key] = scaled
        return scaled
    }

    private static let artworkSize = CGSize(width: 26, height: 62)

    private static let artwork: UIImage = {
        let size = artworkSize
        return UIGraphicsImageRenderer(size: size).image { _ in            let w = size.width, h = size.height
            let inset: CGFloat = 1.5

            // Hull: sharp bow, full-bodied midships, square transom with rounded corners.
            let hull = UIBezierPath()
            hull.move(to: CGPoint(x: w / 2, y: inset))
            hull.addCurve(to: CGPoint(x: w - inset, y: h * 0.42),
                          controlPoint1: CGPoint(x: w * 0.62, y: h * 0.12),
                          controlPoint2: CGPoint(x: w - inset, y: h * 0.26))
            hull.addLine(to: CGPoint(x: w - inset, y: h - 7))
            hull.addQuadCurve(to: CGPoint(x: w - 6, y: h - inset), controlPoint: CGPoint(x: w - inset, y: h - inset))
            hull.addLine(to: CGPoint(x: 6, y: h - inset))
            hull.addQuadCurve(to: CGPoint(x: inset, y: h - 7), controlPoint: CGPoint(x: inset, y: h - inset))
            hull.addLine(to: CGPoint(x: inset, y: h * 0.42))
            hull.addCurve(to: CGPoint(x: w / 2, y: inset),
                          controlPoint1: CGPoint(x: inset, y: h * 0.26),
                          controlPoint2: CGPoint(x: w * 0.38, y: h * 0.12))
            hull.close()
            UIColor.systemBlue.setFill(); hull.fill()
            UIColor.white.setStroke(); hull.lineWidth = 2; hull.stroke()

            // Pilothouse and aft cabin roofs.
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 5, y: h * 0.40, width: w - 10, height: h * 0.20), cornerRadius: 3).fill()
            UIBezierPath(roundedRect: CGRect(x: 7, y: h * 0.63, width: w - 14, height: h * 0.20), cornerRadius: 3).fill()
            // Windscreen line across the front of the pilothouse.
            UIColor.systemBlue.setStroke()
            let glass = UIBezierPath()
            glass.move(to: CGPoint(x: 7, y: h * 0.44)); glass.addLine(to: CGPoint(x: w - 7, y: h * 0.44))
            glass.lineWidth = 1.5; glass.stroke()
            // Centre-line mark on the foredeck.
            let fore = UIBezierPath()
            fore.move(to: CGPoint(x: w / 2, y: h * 0.14)); fore.addLine(to: CGPoint(x: w / 2, y: h * 0.34))
            UIColor.white.withAlphaComponent(0.7).setStroke(); fore.lineWidth = 1.5; fore.stroke()
        }
    }()
}

/// Anchor with a long pointed tip at the bottom. The tip's end is the point that marks where the
/// anchor was dropped, so the image's bottom-centre must be placed on the coordinate.
/// Swing-estimate marker: a purple ring with an anchor in it, centred on the estimate.
enum EstimateIcon {
    static let image: UIImage = {
        let size = CGSize(width: 26, height: 26)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let ring = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 22, height: 22))
            UIColor.white.withAlphaComponent(0.85).setFill(); ring.fill()
            UIColor.systemPurple.setStroke(); ring.lineWidth = 2.5; ring.stroke()
            let glyph = NSAttributedString(string: anchorGlyph, attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: UIColor.systemPurple])
            let g = glyph.size()
            glyph.draw(at: CGPoint(x: (size.width - g.width) / 2, y: (size.height - g.height) / 2))
        }
    }()
}

enum AnchorIcon {
    /// On-screen size in points. The artwork is drawn at 40x56 and scaled down to this.
    static let size = CGSize(width: 20, height: 28)

    static let image: UIImage = {
        UIGraphicsImageRenderer(size: size).image { _ in
            artwork.draw(in: CGRect(origin: .zero, size: size))
        }
    }()

    private static let artworkSize = CGSize(width: 40, height: 56)

    private static let artwork: UIImage = {
        let size = artworkSize
        return UIGraphicsImageRenderer(size: size).image { _ in
            let navy = UIColor(red: 0.05, green: 0.17, blue: 0.37, alpha: 1)
            let cx = size.width / 2

            let ring = UIBezierPath(arcCenter: CGPoint(x: cx, y: 7), radius: 4.5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            let stock = UIBezierPath(); stock.move(to: CGPoint(x: cx - 10, y: 17)); stock.addLine(to: CGPoint(x: cx + 10, y: 17))
            let shank = UIBezierPath(); shank.move(to: CGPoint(x: cx, y: 11.5)); shank.addLine(to: CGPoint(x: cx, y: 42))
            let arms = UIBezierPath()
            arms.move(to: CGPoint(x: 5, y: 29))
            arms.addCurve(to: CGPoint(x: cx, y: 43), controlPoint1: CGPoint(x: 6, y: 40), controlPoint2: CGPoint(x: 13, y: 43))
            arms.addCurve(to: CGPoint(x: size.width - 5, y: 29), controlPoint1: CGPoint(x: 27, y: 43), controlPoint2: CGPoint(x: size.width - 6, y: 40))
            // Fluke points at the ends of the arms.
            let flukes = UIBezierPath()
            flukes.move(to: CGPoint(x: 1, y: 27)); flukes.addLine(to: CGPoint(x: 10, y: 28)); flukes.addLine(to: CGPoint(x: 5, y: 35)); flukes.close()
            flukes.move(to: CGPoint(x: size.width - 1, y: 27)); flukes.addLine(to: CGPoint(x: size.width - 10, y: 28)); flukes.addLine(to: CGPoint(x: size.width - 5, y: 35)); flukes.close()
            // The pronounced drop-point tip.
            let tip = UIBezierPath()
            tip.move(to: CGPoint(x: cx - 5, y: 40)); tip.addLine(to: CGPoint(x: cx + 5, y: 40)); tip.addLine(to: CGPoint(x: cx, y: size.height - 1)); tip.close()

            func draw(_ stroke: UIColor, extra: CGFloat, fill: UIColor?) {
                stroke.setStroke()
                for (path, width) in [(ring, 3.0), (stock, 3.5), (shank, 3.5), (arms, 3.5)] as [(UIBezierPath, CGFloat)] {
                    path.lineWidth = width + extra; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
                }
                flukes.lineWidth = extra; flukes.lineJoinStyle = .round
                tip.lineWidth = extra; tip.lineJoinStyle = .round
                if let fill { fill.setFill(); flukes.fill(); }
                if extra > 0 { flukes.stroke(); tip.stroke() }
            }
            draw(.white, extra: 3, fill: .white)       // outline so it reads on any chart colour
            draw(navy, extra: 0, fill: navy)
            UIColor.systemRed.setFill(); tip.fill()
        }
    }()
}

/// Distance and direction pill on the measuring line.
/// Shows a measuring label's picture in its own image view. Setting MKAnnotationView.image cross-fades, which
/// left the previous figures ghosting under the new ones as they updated every second.
final class MeasureLabelView: MKAnnotationView {
    private let picture = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        addSubview(picture)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ image: UIImage) {
        UIView.performWithoutAnimation {
            picture.image = image
            picture.frame = CGRect(origin: .zero, size: image.size)
            frame.size = image.size
        }
    }
}

/// Round red badge with a symbol for the kind of hazard.
enum HazardIcon {
    private static var cache: [Hazard.Kind: UIImage] = [:]

    static func image(_ kind: Hazard.Kind) -> UIImage {
        if let cached = cache[kind] { return cached }
        let symbol = switch kind {
        case .rock: "exclamationmark.triangle.fill"
        case .shoal: "water.waves"
        case .dock: "rectangle.split.3x1.fill"
        case .boat: "sailboat.fill"
        case .other: "exclamationmark"
        }
        let size = CGSize(width: 28, height: 28)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            UIColor.systemRed.setFill(); UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 24, height: 24)).fill()
            let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            glyph?.draw(in: CGRect(x: 7, y: 7, width: 14, height: 14))
        }
        cache[kind] = image
        return image
    }
}

/// Distance and bearing pill on a measuring line, with an ✕ at the right end that closes it.
enum MeasureLabel {
    /// Width of the ✕ end of the pill; a tap there closes the label, anywhere else drags it.
    static let closeWidth: CGFloat = 30

    static func image(_ text: String, color: UIColor = .systemYellow) -> UIImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold),
                                                    .foregroundColor: UIColor.black]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let height = max(ceil(textSize.height) + 10, 28)
        let size = CGSize(width: ceil(textSize.width) + 12 + closeWidth, height: height)
        return UIGraphicsImageRenderer(size: size).image { context in
            let pill = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            color.setFill()
            pill.fill()
            (text as NSString).draw(at: CGPoint(x: 10, y: (height - textSize.height) / 2), withAttributes: attrs)
            // Divider, then the ✕.
            let x = size.width - closeWidth
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.black.withAlphaComponent(0.25).cgColor)
            cg.setLineWidth(1)
            cg.move(to: CGPoint(x: x, y: 6)); cg.addLine(to: CGPoint(x: x, y: height - 6)); cg.strokePath()
            let c = CGPoint(x: x + closeWidth / 2 - 1, y: height / 2), r: CGFloat = 4.5
            cg.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor)
            cg.setLineWidth(2)
            cg.setLineCap(.round)
            cg.move(to: CGPoint(x: c.x - r, y: c.y - r)); cg.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
            cg.move(to: CGPoint(x: c.x + r, y: c.y - r)); cg.addLine(to: CGPoint(x: c.x - r, y: c.y + r))
            cg.strokePath()
        }
    }
}

/// Caption under the alarm circle.
enum CircleLabel {
    static func safe(_ radius: String) -> String { "Alarm Radius = \(radius)" }
    static let alarm = "Nereus is on the move!"

    static func image(_ text: String, alarm: Bool, caution: Bool = false) -> UIImage {
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let color: UIColor = alarm ? .white : caution ? .systemOrange : UIColor(red: 0.05, green: 0.35, blue: 0.15, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let size = CGSize(width: ceil(textSize.width) + 14, height: ceil(textSize.height) + 6)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let pill = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            (alarm ? UIColor.systemRed : UIColor.white.withAlphaComponent(0.88)).setFill()
            pill.fill()
            (alarm ? UIColor.white : caution ? UIColor.systemOrange : UIColor.systemGreen).setStroke()
            pill.lineWidth = 1.5
            pill.stroke()
            (text as NSString).draw(at: CGPoint(x: 7, y: 3), withAttributes: attrs)
        }
    }
}

/// Arrow showing where the wind is blowing TO, centred on the forecast point, with the speed in knots just past its tip.
final class WindAnnotationView: MKAnnotationView {
    private let arrow = UIImageView()
    private let label = UILabel()
    private var from = 0.0
    private static let side = 84.0
    /// Centre of the speed label from the centre of the arrow: half its length plus a small gap.
    private static let labelDistance = WindIcon.length / 2 + 10

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        arrow.frame = CGRect(x: (Self.side - WindIcon.width) / 2, y: (Self.side - WindIcon.length) / 2,
                             width: WindIcon.width, height: WindIcon.length)
        // A faint halo keeps the thin arrow visible over dark satellite water.
        arrow.layer.shadowColor = UIColor.white.cgColor
        arrow.layer.shadowOpacity = 0.7
        arrow.layer.shadowRadius = 1
        arrow.layer.shadowOffset = .zero
        // The speed sits on a small white pill so it stays readable over dark satellite water as well as pale charts.
        label.bounds = CGRect(x: 0, y: 0, width: 24, height: 14)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textAlignment = .center
        label.textColor = .black
        label.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        label.layer.cornerRadius = 7
        label.layer.masksToBounds = true
        addSubview(arrow)
        addSubview(label)
        canShowCallout = true
        displayPriority = .defaultLow
        collisionMode = .none
        zPriority = .min
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(speed: Double, from: Double, mapHeading: Double) {
        self.from = from
        arrow.image = WindIcon.arrow(speed: speed)
        label.text = String(format: "%.0f", speed)
        setMapHeading(mapHeading)
    }

    func setMapHeading(_ heading: Double) {
        let angle = (from + 180 - heading).radians       // clockwise from straight up
        arrow.transform = CGAffineTransform(rotationAngle: angle)
        // The label stays upright, moved out along the arrow to sit past its tip.
        label.center = CGPoint(x: Self.side / 2 + Self.labelDistance * sin(angle),
                               y: Self.side / 2 - Self.labelDistance * cos(angle))
    }
}

enum WindIcon {
    private static var cache: [Int: UIImage] = [:]
    static let width = 10.0, length = 36.0

    private static let bands: [(upTo: Double, color: UIColor)] = [
        (5, UIColor(white: 0.55, alpha: 1)),                       // light
        (10, .systemGreen),
        (15, UIColor(red: 0.93, green: 0.72, blue: 0, alpha: 1)),  // yellow
        (20, .systemOrange),
        (25, .systemRed),
        (.infinity, .systemPurple),
    ]

    static func arrow(speed: Double) -> UIImage {
        let band = bands.firstIndex { speed < $0.upTo } ?? bands.count - 1
        if let cached = cache[band] { return cached }
        // A long thin shaft that fades in from the tail, under a small swept arrowhead. Drawn pointing up.
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: length)).image { context in
            let color = bands[band].color
            let cg = context.cgContext
            let headBase = 8.0
            cg.saveGState()
            cg.clip(to: CGRect(x: width / 2 - 0.9, y: headBase - 1, width: 1.8, height: length - headBase))
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [color.withAlphaComponent(0).cgColor, color.cgColor] as CFArray,
                                      locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: length), end: CGPoint(x: 0, y: headBase), options: [])
            cg.restoreGState()

            let head = UIBezierPath()
            head.move(to: CGPoint(x: width / 2, y: 0.5))
            head.addLine(to: CGPoint(x: width - 0.5, y: headBase + 1.5))
            head.addLine(to: CGPoint(x: width / 2, y: headBase - 1))
            head.addLine(to: CGPoint(x: 0.5, y: headBase + 1.5))
            head.close()
            color.setFill(); head.fill()
        }
        cache[band] = image
        return image
    }
}

/// Round blue badge for an observation station, showing the measured wind in knots.
enum StationIcon {
    private static var cache: [String: UIImage] = [:]

    static func image(speed: Double?) -> UIImage {
        let text = speed.map { String(Int($0.rounded())) } ?? "–"
        if let cached = cache[text] { return cached }
        let size = CGSize(width: 34, height: 34)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 30, height: 30))
            UIColor.systemBlue.setFill(); circle.fill()
            UIColor.white.setStroke(); circle.lineWidth = 2.5; circle.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: UIColor.white]
            let textSize = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attrs)
        }
        cache[text] = image
        return image
    }
}
