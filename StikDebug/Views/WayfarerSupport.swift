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
    case cycling
    case driving
    /// Very fast travel along roads, with fewer route points.
    case detect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walking: return "走路"
        case .cycling: return "騎車"
        case .driving: return "開車"
        case .detect: return "偵測"
        }
    }

    var defaultSpeedKmh: Double {
        switch self {
        case .walking: return 5
        case .cycling: return 19.5
        case .driving: return 40
        case .detect: return 600
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .driving, .detect: return .automobile
        default: return .walking
        }
    }
}

enum WayfarerTab: String, CaseIterable, Identifiable {
    case teleport
    case navigate
    case multi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teleport: return "瞬移"
        case .navigate: return "導航"
        case .multi: return "多點路徑"
        }
    }
}

/// How a multi-stop route is travelled.
enum RouteShape: String, CaseIterable, Identifiable {
    case oneWay
    case roundTrip
    case circuit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneWay: return "單程"
        case .roundTrip: return "來回"
        case .circuit: return "繞圈"
        }
    }
}

enum WayfarerSpeed {
    static let maxKmh: Double = 3000

    static func metersPerSecond(fromKmh kmh: Double) -> CLLocationSpeed {
        max(kmh, 0.5) / 3.6
    }

    static let updateIntervalKey = "wayfarer.updateInterval"
    static let defaultUpdateInterval: Double = 0.5

    /// Seconds between location updates while a route plays (user adjustable).
    static var updateInterval: Double {
        let stored = UserDefaults.standard.double(forKey: updateIntervalKey)
        return stored > 0 ? min(max(stored, 0.1), 5) : defaultUpdateInterval
    }

    /// Spacing between route points: never denser than 10 m, wider at high speed.
    static func pathSpacing(forSpeed metersPerSecond: CLLocationSpeed) -> CLLocationDistance {
        max(10, metersPerSecond * updateInterval)
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
        shape: RouteShape,
        mode: TravelMode,
        followRoads: Bool
    ) async throws -> WayfarerBuiltRoute {
        var points = stops
        if shape == .circuit, let first = stops.first, stops.count > 1 {
            points.append(first)
        }
        guard points.count >= 2 else {
            throw NSError(
                domain: "Wayfarer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "請至少加入兩個站點。"]
            )
        }

        if !followRoads {
            var total: CLLocationDistance = 0
            for (a, b) in zip(points, points.dropFirst()) {
                total += straightDistance(a, b)
            }
            var path = points
            if shape == .roundTrip {
                path.append(contentsOf: points.reversed().dropFirst())
                total *= 2
            }
            return WayfarerBuiltRoute(coordinates: path, distance: total, straightLegCount: 0)
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

        if shape == .roundTrip {
            allCoordinates.append(contentsOf: allCoordinates.reversed().dropFirst())
            totalDistance *= 2
        }

        return WayfarerBuiltRoute(
            coordinates: allCoordinates,
            distance: totalDistance,
            straightLegCount: straightLegs
        )
    }
}

/// Mode picker plus a speed field (type a value or use the stepper).
struct TravelModeSpeedBar: View {
    @Binding var modeRaw: String
    @Binding var speedKmh: Double
    @Binding var updateInterval: Double
    var modeLocked: Bool
    @FocusState private var speedFieldFocused: Bool
    @FocusState private var intervalFieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Picker("移動模式", selection: $modeRaw) {
                ForEach(TravelMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(modeLocked)

            HStack(spacing: 8) {
                Text("速度")
                    .font(.subheadline)
                TextField("速度", value: $speedKmh, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($speedFieldFocused)
                Text("公里/小時")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper("", value: $speedKmh, in: 1...3000, step: 1)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Text("更新間隔")
                    .font(.subheadline)
                TextField("秒", value: $updateInterval, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($intervalFieldFocused)
                Text("秒/次")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper("", value: $updateInterval, in: 0.1...5, step: 0.1)
                    .labelsHidden()
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        speedFieldFocused = false
                        intervalFieldFocused = false
                    }
                }
            }
        }
    }
}

/// Seconds to stay at each stop in point-to-point (hop) mode.
struct DwellField: View {
    @Binding var seconds: Double
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("到點停留")
                .font(.subheadline)
            TextField("秒", value: $seconds, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .focused($focused)
            Text("秒")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Stepper("", value: $seconds, in: 0...3600, step: 1)
                .labelsHidden()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focused = false }
            }
        }
    }
}
