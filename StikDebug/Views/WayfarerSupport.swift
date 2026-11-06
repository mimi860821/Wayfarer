//
//  WayfarerSupport.swift
//  Wayfarer
//
//  Travel modes, multi-stop route building and the mode/speed control bar.
//

import SwiftUI
import MapKit
import CoreLocation

/// How the simulated traveller moves. Cycling reuses pedestrian routing because
/// MapKit has no dedicated bicycle transport type.
enum TravelMode: String, CaseIterable, Identifiable {
    case walking
    case running
    case cycling
    case driving

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walking: return "Walk"
        case .running: return "Run"
        case .cycling: return "Bike"
        case .driving: return "Drive"
        }
    }

    var defaultSpeedKmh: Double {
        switch self {
        case .walking: return 5
        case .running: return 9
        case .cycling: return 18
        case .driving: return 40
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .driving: return .automobile
        default: return .walking
        }
    }
}

enum WayfarerSpeed {
    static func metersPerSecond(fromKmh kmh: Double) -> CLLocationSpeed {
        max(kmh, 0.5) / 3.6
    }
}

struct RouteStop: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

struct WayfarerBuiltRoute {
    let coordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    /// Number of legs where MapKit found no route and a straight line was used.
    let straightLegCount: Int
}

enum WayfarerRouteBuilder {
    static func polylineCoordinates(_ polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }

    static func straightDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Builds one continuous path through all stops, using MapKit directions for each leg.
    static func build(
        stops: [CLLocationCoordinate2D],
        loop: Bool,
        mode: TravelMode
    ) async throws -> WayfarerBuiltRoute {
        var points = stops
        if loop, let first = stops.first, stops.count > 1 {
            points.append(first)
        }
        guard points.count >= 2 else {
            throw NSError(
                domain: "Wayfarer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Add at least two stops."]
            )
        }

        var allCoordinates: [CLLocationCoordinate2D] = []
        var totalDistance: CLLocationDistance = 0
        var straightLegs = 0

        for (index, pair) in zip(points, points.dropFirst()).enumerated() {
            try Task.checkCancellation()
            let (start, end) = pair

            if index > 0 {
                // Stay well below MapKit's directions rate limit.
                try await Task.sleep(for: .milliseconds(400))
            }

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
            request.transportType = mode.transportType
            request.requestsAlternateRoutes = false

            var legCoordinates: [CLLocationCoordinate2D]
            var legDistance: CLLocationDistance
            do {
                let response = try await MKDirections(request: request).calculate()
                if let route = response.routes.first {
                    legCoordinates = polylineCoordinates(route.polyline)
                    legDistance = route.distance
                } else {
                    legCoordinates = [start, end]
                    legDistance = straightDistance(start, end)
                    straightLegs += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                legCoordinates = [start, end]
                legDistance = straightDistance(start, end)
                straightLegs += 1
            }

            if allCoordinates.isEmpty {
                allCoordinates.append(contentsOf: legCoordinates)
            } else {
                allCoordinates.append(contentsOf: legCoordinates.dropFirst())
            }
            totalDistance += legDistance
        }

        return WayfarerBuiltRoute(
            coordinates: allCoordinates,
            distance: totalDistance,
            straightLegCount: straightLegs
        )
    }
}

/// Mode picker plus speed stepper, shown above the route controls.
struct TravelModeSpeedBar: View {
    @Binding var modeRaw: String
    @Binding var speedKmh: Double
    var modeLocked: Bool

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $modeRaw) {
                ForEach(TravelMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(modeLocked)

            Stepper(value: $speedKmh, in: 1...120, step: 1) {
                Text("Speed \(Int(speedKmh)) km/h")
                    .font(.footnote.monospacedDigit())
            }
        }
    }
}
