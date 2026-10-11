import MapKit
import SwiftUI

final class AnchorAnnotation: MKPointAnnotation {}
final class BoatAnnotation: MKPointAnnotation {}
final class CircleLabelAnnotation: MKPointAnnotation {}
/// Where the swing fit puts the anchor.
final class EstimateAnnotation: MKPointAnnotation {}
final class StationAnnotation: MKPointAnnotation {}
final class WindAnnotation: MKPointAnnotation {
    var speed = 0.0
    var from = 0.0
}

/// UIKit map wrapped for SwiftUI because SwiftUI's Map can't host tile overlays.
struct ChartMapView: UIViewRepresentable {
    @ObservedObject var engine: AnchorWatchEngine

    func makeCoordinator() -> Coordinator { Coordinator(engine) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
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
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.sync(map)
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
        /// The swing estimate: a marker and its error ellipse.
        private let estimatePin = EstimateAnnotation()
        private var estimateEllipse: MKPolygon?
        private var estimateKey: [Double] = []
        /// Red arrow showing which way, and how far, the anchor has moved.
        private var driftArrow: MKPolyline?
        private var driftKey: [Double] = []
        private var trackLine: MKPolyline?
        private var trackCount = 0
        private var tether: MKPolyline?
        private var lastRecenter = 0
        private var lastZoomTick = 0
        private var framedOnce = false
        private var dragging = false
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
            boatPin.title = "Nereus"
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
                syncCircleLabel(map, anchor: anchor)
            } else {
                map.removeAnnotation(anchorPin)
                map.removeAnnotation(labelPin)
                // The track may still be recording under way; syncTrack removes it once it's empty.
                syncEstimate(map)
                syncDrift(map)
                for o in [circle, uncertainty, tether] as [MKOverlay?] { if let o { map.removeOverlay(o) } }
                circle = nil; uncertainty = nil; tether = nil; circleKey = []; uncertaintyKey = []
            }
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

            let grid = engine.windGrid.map { "\($0.coordinate.latitude),\($0.coordinate.longitude),\($0.fetched.timeIntervalSince1970)" }.joined()
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

        private func installLayer(_ map: MKMapView) {
            tiles.forEach(map.removeOverlay)
            layer = engine.mapLayer
            map.mapType = engine.mapLayer.mapType
            tiles = engine.mapLayer.makeOverlays()
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
            engine.alarm == nil ? CircleLabel.safe(engine.units.format(engine.radius)) : CircleLabel.alarm
        }

        /// Small caption centred just below the south edge of the alarm circle.
        private func syncCircleLabel(_ map: MKMapView, anchor: CLLocationCoordinate2D) {
            labelPin.coordinate = Geo.destination(from: anchor, bearing: 180, meters: engine.radius)
            if !map.annotations.contains(where: { $0 === labelPin }) { map.addAnnotation(labelPin) }
            let text = circleText
            if text != labelText, let view = map.view(for: labelPin) {
                labelText = text
                view.image = CircleLabel.image(text, alarm: engine.alarm != nil)
            }
        }

        private func syncCircle(_ map: MKMapView, anchor: CLLocationCoordinate2D) {
            let key = [anchor.latitude, anchor.longitude, engine.radius, engine.alarm == nil ? 0 : 1]
            guard key != circleKey else { return }
            circleKey = key
            if let circle { map.removeOverlay(circle) }
            let new = MKCircle(center: anchor, radius: engine.radius)
            circle = new
            map.addOverlay(new, level: .aboveLabels)
        }

        private func syncUncertainty(_ map: MKMapView, anchor: CLLocationCoordinate2D) {
            let key = engine.anchorUncertainty.map { [anchor.latitude, anchor.longitude, $0] } ?? []
            guard key != uncertaintyKey else { return }
            uncertaintyKey = key
            if let uncertainty { map.removeOverlay(uncertainty) }
            uncertainty = nil
            guard let meters = engine.anchorUncertainty, meters > 0 else { return }
            let new = MKCircle(center: anchor, radius: meters)
            new.title = "uncertainty"
            uncertainty = new
            map.addOverlay(new, level: .aboveLabels)
        }

        private func syncEstimate(_ map: MKMapView) {
            let estimate = engine.anchor == nil ? nil : engine.anchorEstimate
            let key = estimate.map { [$0.center.latitude, $0.center.longitude, $0.semiMajor, $0.semiMinor, $0.majorBearing] } ?? []
            guard key != estimateKey else { return }
            estimateKey = key
            if let estimateEllipse { map.removeOverlay(estimateEllipse) }
            estimateEllipse = nil
            guard let estimate else { map.removeAnnotation(estimatePin); return }

            estimatePin.coordinate = estimate.center
            estimatePin.title = "Anchor by swing"
            estimatePin.subtitle = "±\(engine.units.format(estimate.semiMajor)) · \(Int(estimate.minutes)) min of swing"
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
            guard engine.track.count != trackCount else { return }
            trackCount = engine.track.count
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
            let span = max(engine.anchor == nil ? 300 : engine.radius * 3.5, 150)
            map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span), animated: true)
        }

        // MARK: Interaction

        /// Lets our tap run alongside the map's own gestures (annotation selection, double-tap zoom).
        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            engine.pokeControls()
            guard engine.placingAnchor, let map = gesture.view as? MKMapView else { return }
            engine.moveAnchor(to: map.convert(gesture.location(in: map), toCoordinateFrom: map))
        }

        func mapView(_ map: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState: MKAnnotationView.DragState) {
            switch newState {
            case .starting, .dragging:
                dragging = true
            case .ending, .canceling:
                dragging = false
                view.dragState = .none
                if newState == .ending, let pin = view.annotation { engine.moveAnchor(to: pin.coordinate) }
            default: break
            }
        }

        // MARK: Rendering

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is AnchorAnnotation:
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "anchor")
                view.image = AnchorIcon.image
                // The tip at the bottom of the icon sits exactly on the anchor's coordinate.
                view.centerOffset = CGPoint(x: 0, y: -AnchorIcon.size.height / 2)
                view.isDraggable = true
                view.canShowCallout = true
                view.zPriority = .max
                view.displayPriority = .required
                view.collisionMode = .none
                return view
            case is EstimateAnnotation:
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "estimate")
                view.image = EstimateIcon.image
                view.canShowCallout = true
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
                view.image = CircleLabel.image(labelText, alarm: engine.alarm != nil)
                view.centerOffset = CGPoint(x: 0, y: (view.image?.size.height ?? 0) / 2 + 4)   // hang below the circle edge
                view.canShowCallout = false
                view.isUserInteractionEnabled = false
                view.displayPriority = .required
                view.collisionMode = .none
                return view
            case is BoatAnnotation:
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "boat")
                view.image = BoatIcon.image(height: boatPoints)
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
            case let circle as MKCircle where circle.title == "uncertainty":
                let r = MKCircleRenderer(circle: circle)
                r.strokeColor = UIColor.systemOrange
                r.fillColor = UIColor.systemOrange.withAlphaComponent(0.1)
                r.lineWidth = 2
                r.lineDashPattern = [2, 5]
                return r
            case let circle as MKCircle:
                let r = MKCircleRenderer(circle: circle)
                let color: UIColor = engine.alarm == nil ? .systemGreen : .systemRed
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

/// Caption under the alarm circle.
enum CircleLabel {
    static func safe(_ radius: String) -> String { "Alarm Radius = \(radius)" }
    static let alarm = "Nereus is on the move!"

    static func image(_ text: String, alarm: Bool) -> UIImage {
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let color: UIColor = alarm ? .white : UIColor(red: 0.05, green: 0.35, blue: 0.15, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let size = CGSize(width: ceil(textSize.width) + 14, height: ceil(textSize.height) + 6)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let pill = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            (alarm ? UIColor.systemRed : UIColor.white.withAlphaComponent(0.88)).setFill()
            pill.fill()
            (alarm ? UIColor.white : UIColor.systemGreen).setStroke()
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
