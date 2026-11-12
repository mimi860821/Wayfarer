//
//  WayfarerMapView.swift
//  iKiwi
//
//  The map used by the location simulator. It wraps MKMapView (instead of the
//  SwiftUI Map) because only MKMapView can show map tiles from other sources,
//  such as OpenStreetMap.
//

import SwiftUI
import MapKit
import UIKit

// MARK: - Map sources

enum MapSource: String, CaseIterable, Identifiable {
    case appleStandard
    case appleSatellite
    case osm
    case topo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleStandard: return "Apple 地圖"
        case .appleSatellite: return "Apple 衛星"
        case .osm: return "OpenStreetMap"
        case .topo: return "地形圖（等高線、步道）"
        }
    }

    /// Raster tile URL, nil for the Apple maps.
    var tileTemplate: String? {
        switch self {
        case .osm: return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        case .topo: return "https://tile.opentopomap.org/{z}/{x}/{y}.png"
        default: return nil
        }
    }

    var maximumZoom: Int {
        self == .topo ? 17 : 19
    }

    /// Credit that must stay visible while the source is shown.
    var attribution: String? {
        switch self {
        case .osm: return "© OpenStreetMap contributors"
        case .topo: return "© OpenStreetMap contributors, SRTM · 樣式 © OpenTopoMap (CC-BY-SA)"
        default: return nil
        }
    }
}

/// Tile overlay that identifies the app to the tile server and keeps a larger
/// disk cache, so the same tiles are not downloaded again and again.
final class WayfarerTileOverlay: MKTileOverlay {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 300 * 1024 * 1024
        )
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpAdditionalHeaders = [
            "User-Agent": "iKiwi/1.0 (personal iOS app; https://github.com/mimi860821/iKiwi)"
        ]
        return URLSession(configuration: configuration)
    }()

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let request = URLRequest(url: url(forTilePath: path))
        Self.session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result(nil, URLError(.badServerResponse))
                return
            }
            result(data, error)
        }.resume()
    }
}

// MARK: - Camera and commands

struct WayfarerCamera: Equatable {
    var centerCoordinate: CLLocationCoordinate2D
    var distance: CLLocationDistance
    var heading: Double
    var pitch: Double

    static func == (lhs: WayfarerCamera, rhs: WayfarerCamera) -> Bool {
        lhs.centerCoordinate.latitude == rhs.centerCoordinate.latitude
            && lhs.centerCoordinate.longitude == rhs.centerCoordinate.longitude
            && lhs.distance == rhs.distance
            && lhs.heading == rhs.heading
            && lhs.pitch == rhs.pitch
    }
}

/// A one-off instruction for the map ("show this area"). Every value has its own
/// identity, so setting the same area twice moves the map twice.
struct MapPosition: Equatable {
    enum Kind {
        case user
        case rect(MKMapRect)
        case camera(WayfarerCamera)
        case region(MKCoordinateRegion)
    }

    let id = UUID()
    let kind: Kind

    static var user: MapPosition { MapPosition(kind: .user) }
    static func rect(_ rect: MKMapRect) -> MapPosition { MapPosition(kind: .rect(rect)) }
    static func camera(_ camera: WayfarerCamera) -> MapPosition { MapPosition(kind: .camera(camera)) }
    static func region(_ region: MKCoordinateRegion) -> MapPosition { MapPosition(kind: .region(region)) }

    static func == (lhs: MapPosition, rhs: MapPosition) -> Bool {
        lhs.id == rhs.id
    }
}

struct WayfarerMapMarker: Equatable {
    enum Kind: Equatable {
        case pin
        case start
        case end
        case current
        case stop
    }

    let id: String
    let latitude: Double
    let longitude: Double
    let label: String
    let kind: Kind

    init(id: String, coordinate: CLLocationCoordinate2D, label: String, kind: Kind) {
        self.id = id
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.label = label
        self.kind = kind
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private final class WayfarerAnnotation: NSObject, MKAnnotation {
    var marker: WayfarerMapMarker
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?

    init(_ marker: WayfarerMapMarker) {
        self.marker = marker
        self.coordinate = marker.coordinate
        self.title = marker.label
    }
}

// MARK: - Map view

struct WayfarerMapView: UIViewRepresentable {
    var source: MapSource
    var position: MapPosition
    var routeLine: MKPolyline?
    var stopLine: [CLLocationCoordinate2D]
    var markers: [WayfarerMapMarker]
    var onTap: (CLLocationCoordinate2D) -> Void
    var onCameraChange: (WayfarerCamera) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.isRotateEnabled = true
        map.isPitchEnabled = true

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.ignoreTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        map.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        singleTap.delegate = context.coordinator
        singleTap.require(toFail: doubleTap)
        map.addGestureRecognizer(singleTap)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: WayfarerMapView

        private var lastPositionID: UUID?
        private var lastSource: MapSource?
        private var tileOverlay: MKTileOverlay?
        private var routeOverlay: MKPolyline?
        private var stopOverlay: MKPolyline?
        private var stopPoints: [CLLocationCoordinate2D] = []
        private var annotations: [String: WayfarerAnnotation] = [:]

        init(_ parent: WayfarerMapView) {
            self.parent = parent
        }

        // MARK: Updating

        func update(_ map: MKMapView) {
            applySource(map)
            applyRoute(map)
            applyStopLine(map)
            applyMarkers(map)
            applyPosition(map)
        }

        private func applySource(_ map: MKMapView) {
            let source = parent.source
            guard source != lastSource else { return }
            lastSource = source

            if let old = tileOverlay {
                map.removeOverlay(old)
                tileOverlay = nil
            }

            switch source {
            case .appleStandard:
                map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
            case .appleSatellite:
                map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
            case .osm, .topo:
                map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
            }

            if let template = source.tileTemplate {
                let overlay = WayfarerTileOverlay(urlTemplate: template)
                overlay.canReplaceMapContent = true
                overlay.maximumZ = source.maximumZoom
                // Index 0: below the route lines, which are added at the same level.
                map.insertOverlay(overlay, at: 0, level: .aboveLabels)
                tileOverlay = overlay
            }
        }

        private func samePolyline(_ a: MKPolyline?, _ b: MKPolyline?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            if a === b { return true }
            guard a.pointCount == b.pointCount, a.pointCount > 0 else { return false }
            let pa = a.points()
            let pb = b.points()
            let last = a.pointCount - 1
            return pa[0].x == pb[0].x && pa[0].y == pb[0].y
                && pa[last].x == pb[last].x && pa[last].y == pb[last].y
                && a.boundingMapRect.origin.x == b.boundingMapRect.origin.x
                && a.boundingMapRect.origin.y == b.boundingMapRect.origin.y
                && a.boundingMapRect.size.width == b.boundingMapRect.size.width
                && a.boundingMapRect.size.height == b.boundingMapRect.size.height
        }

        private func applyRoute(_ map: MKMapView) {
            if samePolyline(routeOverlay, parent.routeLine) { return }
            if let old = routeOverlay {
                map.removeOverlay(old)
            }
            routeOverlay = parent.routeLine
            if let new = routeOverlay {
                map.addOverlay(new, level: .aboveLabels)
            }
        }

        private func applyStopLine(_ map: MKMapView) {
            let wanted = parent.stopLine
            let unchanged = wanted.count == stopPoints.count
                && zip(wanted, stopPoints).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
            if unchanged { return }

            if let old = stopOverlay {
                map.removeOverlay(old)
                stopOverlay = nil
            }
            stopPoints = wanted
            if wanted.count >= 2 {
                let line = MKPolyline(coordinates: wanted, count: wanted.count)
                stopOverlay = line
                map.addOverlay(line, level: .aboveLabels)
            }
        }

        private func applyMarkers(_ map: MKMapView) {
            let wantedIDs = Set(parent.markers.map { $0.id })
            for (id, annotation) in annotations where !wantedIDs.contains(id) {
                map.removeAnnotation(annotation)
                annotations[id] = nil
            }

            for marker in parent.markers {
                if let existing = annotations[marker.id] {
                    if existing.marker.kind != marker.kind || existing.marker.label != marker.label {
                        map.removeAnnotation(existing)
                        let replacement = WayfarerAnnotation(marker)
                        annotations[marker.id] = replacement
                        map.addAnnotation(replacement)
                    } else if existing.marker != marker {
                        existing.marker = marker
                        existing.coordinate = marker.coordinate
                    }
                } else {
                    let annotation = WayfarerAnnotation(marker)
                    annotations[marker.id] = annotation
                    map.addAnnotation(annotation)
                }
            }
        }

        private func applyPosition(_ map: MKMapView) {
            let position = parent.position
            guard position.id != lastPositionID else { return }
            lastPositionID = position.id

            switch position.kind {
            case .user:
                map.setUserTrackingMode(.follow, animated: true)
            case .rect(let rect):
                map.setUserTrackingMode(.none, animated: false)
                map.setVisibleMapRect(
                    rect,
                    edgePadding: UIEdgeInsets(top: 110, left: 40, bottom: 340, right: 40),
                    animated: true
                )
            case .camera(let camera):
                map.setUserTrackingMode(.none, animated: false)
                map.setCamera(
                    MKMapCamera(
                        lookingAtCenter: camera.centerCoordinate,
                        fromDistance: camera.distance,
                        pitch: camera.pitch,
                        heading: camera.heading
                    ),
                    animated: true
                )
            case .region(let region):
                map.setUserTrackingMode(.none, animated: false)
                map.setRegion(region, animated: true)
            }
        }

        // MARK: Gestures

        @objc func ignoreTap(_ recognizer: UITapGestureRecognizer) {}

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: map)
            parent.onTap(map.convert(point, toCoordinateFrom: map))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is MKAnnotationView { return false }
                view = current.superview
            }
            return true
        }

        // MARK: MKMapViewDelegate

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let camera = mapView.camera
            let snapshot = WayfarerCamera(
                centerCoordinate: camera.centerCoordinate,
                distance: camera.centerCoordinateDistance,
                heading: camera.heading,
                pitch: camera.pitch
            )
            DispatchQueue.main.async { [weak self] in
                self?.parent.onCameraChange(snapshot)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                if line === stopOverlay {
                    renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.75)
                    renderer.lineWidth = 3
                    renderer.lineDashPattern = [6, 6]
                } else {
                    renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8)
                    renderer.lineWidth = 5
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                // Follow mode still works; the blue dot itself is not drawn.
                let hidden = MKAnnotationView(annotation: annotation, reuseIdentifier: "hidden-user")
                hidden.isEnabled = false
                hidden.canShowCallout = false
                return hidden
            }
            guard let item = annotation as? WayfarerAnnotation else { return nil }

            let identifier = "wayfarer-marker"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: item, reuseIdentifier: identifier)
            view.annotation = item
            view.canShowCallout = false
            view.titleVisibility = .adaptive
            view.displayPriority = .required

            switch item.marker.kind {
            case .pin:
                view.markerTintColor = .systemRed
                view.glyphText = nil
            case .start:
                view.markerTintColor = .systemGreen
                view.glyphText = nil
            case .end:
                view.markerTintColor = .systemRed
                view.glyphText = nil
            case .current:
                view.markerTintColor = .systemBlue
                view.glyphText = nil
            case .stop:
                view.markerTintColor = .systemOrange
                view.glyphText = item.marker.label
            }
            return view
        }
    }
}
