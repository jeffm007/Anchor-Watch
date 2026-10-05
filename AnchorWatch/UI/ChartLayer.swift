import MapKit

/// Free map sources. Tile servers ask for an identifying User-Agent and
/// reasonable use; tiles are cached on disk so a visited anchorage works offline.
enum ChartLayer: String, CaseIterable, Identifiable {
    case seaMap = "OpenSeaMap"
    case noaa = "NOAA Charts (US)"
    case apple = "Apple Maps"
    case satellite = "Satellite + Seamarks"
    var id: String { rawValue }

    /// Overlays to install, bottom to top.
    func makeOverlays() -> [MKTileOverlay] {
        let osm = ChartTileOverlay(template: "https://tile.openstreetmap.org/{z}/{x}/{y}.png", maxZoom: 19, replacesMap: true)
        let seamarks = ChartTileOverlay(template: "https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png", maxZoom: 18, replacesMap: false)
        switch self {
        case .seaMap: return [osm, seamarks]
        case .noaa: return [ChartTileOverlay.noaa()]
        case .apple: return []
        case .satellite: return [seamarks]
        }
    }

    var mapType: MKMapType { self == .satellite ? .satellite : .standard }
}

final class ChartTileOverlay: MKTileOverlay {
    fileprivate static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 1 << 30)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["User-Agent": "AnchorWatch/0.1 (iOS; personal boat project)"]
        return URLSession(configuration: config)
    }()

    private let urlBuilder: ((MKTileOverlayPath) -> URL)?

    init(template: String, maxZoom: Int, replacesMap: Bool, urlBuilder: ((MKTileOverlayPath) -> URL)? = nil) {
        self.urlBuilder = urlBuilder
        super.init(urlTemplate: template)
        maximumZ = maxZoom
        canReplaceMapContent = replacesMap
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        urlBuilder?(path) ?? super.url(forTilePath: path)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        fetch(url(forTilePath: path), result)
    }

    final func fetch(_ url: URL, _ result: @escaping (Data?, Error?) -> Void) {
        Self.session.dataTask(with: url) { data, _, error in
            result(data, error)
        }.resume()
    }
}

extension ChartTileOverlay {
    /// NOAA's official ENC chart rendering (depth soundings, channels, aids to navigation).
    /// The service has no pre-cut tiles, so each tile is an export request for that tile's
    /// Web Mercator bounding box. Covers US waters only; elsewhere tiles are blank.
    static func noaa() -> ChartTileOverlay {
        let endpoint = "https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/MapServer/export"
        return ChartTileOverlay(template: "https://gis.charttools.noaa.gov/{z}/{x}/{y}", maxZoom: 20, replacesMap: true) { path in
            let world = 2 * 20_037_508.342789244
            let size = world / Double(1 << path.z)
            let minX = -world / 2 + Double(path.x) * size
            let maxY = world / 2 - Double(path.y) * size
            let bbox = "\(minX),\(maxY - size),\(minX + size),\(maxY)"
            return URL(string: "\(endpoint)?bbox=\(bbox)&bboxSR=3857&imageSR=3857&size=256,256&format=png32&transparent=true&f=image")!
        }
    }
}
