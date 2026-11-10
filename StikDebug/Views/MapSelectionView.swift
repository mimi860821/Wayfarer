//
//  MapSelectionView.swift
//  StikDebug
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

private struct CoordinateSnapshot: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct RouteSearchSelection {
    let title: String
    let coordinate: CLLocationCoordinate2D
}

private enum RouteSearchField {
    case start
    case end
}

private struct RouteSimulationPlan {
    let displayCoordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
}

private enum RouteSimulationDefaults {
    static let pathSamplingDistance: CLLocationDistance = 10
    static let playbackTickInterval: TimeInterval = 0.5
    static let minimumSpeedMetersPerSecond: CLLocationSpeed = 1.0
    static let importedRouteFallbackSpeedMetersPerSecond: CLLocationSpeed = 13.4
}

private struct RoutePlaybackSample {
    let coordinate: CLLocationCoordinate2D
    let delayFromPrevious: TimeInterval
    /// Index in the route the sample was built from (where the walk has got to).
    var baseIndex: Int = 0
}

private struct OpenStreetMapWay {
    let geometry: [CLLocationCoordinate2D]
    let speedLimitMetersPerSecond: CLLocationSpeed
}

private enum OpenStreetMapSpeedLimitService {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let copyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let boundingBoxPaddingDegrees = 0.0015
    static let nearestWayThreshold: CLLocationDistance = 40
}

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let tags: [String: String]?
        let geometry: [Coordinate]?
    }

    struct Coordinate: Decodable {
        let lat: Double
        let lon: Double
    }
}

private extension MKPolyline {
    var coordinateArray: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private func interpolateCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    fraction: Double
) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: start.latitude + ((end.latitude - start.latitude) * fraction),
        longitude: start.longitude + ((end.longitude - start.longitude) * fraction)
    )
}

private func sampledRouteCoordinates(
    from coordinates: [CLLocationCoordinate2D],
    targetDistance: CLLocationDistance
) -> [CLLocationCoordinate2D] {
    guard coordinates.count > 1 else { return coordinates }

    var sampled = [coordinates[0]]
    for (start, end) in zip(coordinates, coordinates.dropFirst()) {
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let segmentCount = max(1, Int(ceil(distance / targetDistance)))
        for index in 1...segmentCount {
            let point = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentCount)
            )
            if sampled.last.map(CoordinateSnapshot.init) != CoordinateSnapshot(point) {
                sampled.append(point)
            }
        }
    }

    return sampled
}

private func midpointCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) -> CLLocationCoordinate2D {
    interpolateCoordinate(from: start, to: end, fraction: 0.5)
}

private func distanceAlong(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
        total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
    }
}

private func distanceFromPoint(
    _ point: MKMapPoint,
    toSegmentFrom start: MKMapPoint,
    to end: MKMapPoint
) -> CLLocationDistance {
    let dx = end.x - start.x
    let dy = end.y - start.y

    guard dx != 0 || dy != 0 else {
        return point.distance(to: start)
    }

    let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / ((dx * dx) + (dy * dy))))
    let projectedPoint = MKMapPoint(
        x: start.x + (dx * projection),
        y: start.y + (dy * projection)
    )
    return point.distance(to: projectedPoint)
}

private func parseSpeedLimitMetersPerSecond(from rawValue: String) -> CLLocationSpeed? {
    let normalized = rawValue
        .lowercased()
        .split(separator: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !normalized.isEmpty else { return nil }
    guard normalized != "none",
          normalized != "signals",
          normalized != "implicit",
          normalized != "walk" else {
        return nil
    }

    let scanner = Scanner(string: normalized)
    guard let numericValue = scanner.scanDouble() else { return nil }

    if normalized.contains("mph") {
        return numericValue * 0.44704
    }
    if normalized.contains("knot") {
        return numericValue * 0.514444
    }

    return numericValue / 3.6
}

private func speedLimitMetersPerSecond(from tags: [String: String]) -> CLLocationSpeed? {
    if let maxspeed = tags["maxspeed"],
       let parsed = parseSpeedLimitMetersPerSecond(from: maxspeed) {
        return parsed
    }

    let directionalValues = [
        tags["maxspeed:forward"],
        tags["maxspeed:backward"]
    ]
        .compactMap { $0 }
        .compactMap(parseSpeedLimitMetersPerSecond(from:))

    guard !directionalValues.isEmpty else { return nil }
    return directionalValues.min()
}

private func overpassQuery(for coordinates: [CLLocationCoordinate2D]) -> String? {
    guard let first = coordinates.first else { return nil }

    var minLatitude = first.latitude
    var maxLatitude = first.latitude
    var minLongitude = first.longitude
    var maxLongitude = first.longitude

    for coordinate in coordinates.dropFirst() {
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, coordinate.longitude)
        maxLongitude = max(maxLongitude, coordinate.longitude)
    }

    let padding = OpenStreetMapSpeedLimitService.boundingBoxPaddingDegrees
    let south = minLatitude - padding
    let west = minLongitude - padding
    let north = maxLatitude + padding
    let east = maxLongitude + padding

    let bbox = String(format: "%.6f,%.6f,%.6f,%.6f", south, west, north, east)

    return """
    [out:json][timeout:20];
    (
      way(\(bbox))[highway][maxspeed];
      way(\(bbox))[highway]["maxspeed:forward"];
      way(\(bbox))[highway]["maxspeed:backward"];
    );
    out tags geom;
    """
}

private func fetchOpenStreetMapWays(for coordinates: [CLLocationCoordinate2D]) async throws -> [OpenStreetMapWay] {
    guard let query = overpassQuery(for: coordinates) else { return [] }

    var components = URLComponents(url: OpenStreetMapSpeedLimitService.endpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "data", value: query)]
    guard let url = components?.url else { return [] }

    let (data, response) = try await URLSession.shared.data(from: url)

    if let httpResponse = response as? HTTPURLResponse,
       !(200...299).contains(httpResponse.statusCode) {
        throw NSError(
            domain: "OpenStreetMapSpeedLimits",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Overpass returned HTTP \(httpResponse.statusCode)."]
        )
    }

    let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
    return decoded.elements.compactMap { element in
        guard let tags = element.tags,
              let speedLimit = speedLimitMetersPerSecond(from: tags),
              let geometry = element.geometry?.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              geometry.count > 1 else {
            return nil
        }

        return OpenStreetMapWay(
            geometry: geometry,
            speedLimitMetersPerSecond: speedLimit
        )
    }
}

private func nearestSpeedLimit(
    forSegmentFrom start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    using ways: [OpenStreetMapWay]
) -> CLLocationSpeed? {
    let midpoint = MKMapPoint(midpointCoordinate(from: start, to: end))
    var bestMatch: (speed: CLLocationSpeed, distance: CLLocationDistance)?

    for way in ways {
        for (wayStart, wayEnd) in zip(way.geometry, way.geometry.dropFirst()) {
            let candidateDistance = distanceFromPoint(
                midpoint,
                toSegmentFrom: MKMapPoint(wayStart),
                to: MKMapPoint(wayEnd)
            )

            if bestMatch == nil || candidateDistance < bestMatch!.distance {
                bestMatch = (way.speedLimitMetersPerSecond, candidateDistance)
            }
        }
    }

    guard let bestMatch,
          bestMatch.distance <= OpenStreetMapSpeedLimitService.nearestWayThreshold else {
        return nil
    }

    return bestMatch.speed
}

/// At high speed, keep a point only once the path has moved far enough since the
/// last kept point, so location updates follow the chosen interval. Each kept point
/// remembers its index in the original path.
private func decimatedForPlayback(
    _ coordinates: [CLLocationCoordinate2D],
    speed: CLLocationSpeed
) -> [(coordinate: CLLocationCoordinate2D, index: Int)] {
    let all = coordinates.enumerated().map { (coordinate: $0.element, index: $0.offset) }
    let spacing = WayfarerSpeed.pathSpacing(forSpeed: speed)
    guard spacing > RouteSimulationDefaults.pathSamplingDistance,
          all.count > 2,
          let first = all.first,
          let last = all.last else {
        return all
    }

    var result = [first]
    var lastKept = first
    for item in all.dropFirst() {
        let distance = CLLocation(latitude: lastKept.coordinate.latitude, longitude: lastKept.coordinate.longitude)
            .distance(from: CLLocation(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude))
        if distance >= spacing {
            result.append(item)
            lastKept = item
        }
    }
    if lastKept.index != last.index {
        result.append(last)
    }
    return result
}

private func buildPlaybackSamples(
    from sourceCoordinates: [CLLocationCoordinate2D],
    speedWays: [OpenStreetMapWay],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) -> [RoutePlaybackSample] {
    let points = decimatedForPlayback(sourceCoordinates, speed: fallbackSpeedMetersPerSecond)
    guard let firstPoint = points.first else { return [] }

    var samples = [
        RoutePlaybackSample(coordinate: firstPoint.coordinate, delayFromPrevious: 0, baseIndex: firstPoint.index)
    ]

    for (startPoint, endPoint) in zip(points, points.dropFirst()) {
        let start = startPoint.coordinate
        let end = endPoint.coordinate
        let segmentDistance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        guard segmentDistance > 0 else { continue }

        let speedLimit = nearestSpeedLimit(forSegmentFrom: start, to: end, using: speedWays) ?? fallbackSpeedMetersPerSecond
        let clampedSpeed = max(speedLimit, RouteSimulationDefaults.minimumSpeedMetersPerSecond)
        let segmentTravelTime = segmentDistance / clampedSpeed
        let segmentStepCount = max(1, Int(ceil(segmentTravelTime / WayfarerSpeed.updateInterval)))
        let stepDelay = segmentTravelTime / Double(segmentStepCount)

        for index in 1...segmentStepCount {
            let coordinate = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentStepCount)
            )
            if samples.last.map({ CoordinateSnapshot($0.coordinate) }) != CoordinateSnapshot(coordinate) {
                samples.append(RoutePlaybackSample(
                    coordinate: coordinate,
                    delayFromPrevious: stepDelay,
                    baseIndex: index == segmentStepCount ? endPoint.index : startPoint.index
                ))
            }
        }
    }

    return samples
}

private func prefetchRoutePlaybackSamples(
    displayCoordinates: [CLLocationCoordinate2D],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) async -> [RoutePlaybackSample] {
    let speedWays = (try? await fetchOpenStreetMapWays(for: displayCoordinates)) ?? []
    return buildPlaybackSamples(
        from: displayCoordinates,
        speedWays: speedWays,
        fallbackSpeedMetersPerSecond: fallbackSpeedMetersPerSecond
    )
}

private enum CoordinateImportError: LocalizedError {
    case emptyFile
    case noCoordinates

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "選取的檔案是空的。"
        case .noCoordinates:
            return "找不到有效座標。支援 GPX、GeoJSON、JSON、CSV 或純文字（每行一組「緯度,經度」）。"
        }
    }
}

private enum CoordinateImportParser {
    static let supportedContentTypes: [UTType] = [
        .plainText,
        .commaSeparatedText,
        .json,
        .xml,
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "kml", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json
    ]

    private enum CoordinateOrder {
        case latitudeLongitude
        case longitudeLatitude
    }

    static func parse(url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CoordinateImportError.emptyFile }

        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "json" || fileExtension == "geojson" {
            if let coordinates = try? parseJSONCoordinates(from: data),
               !coordinates.isEmpty {
                return coordinates
            }
        }

        if fileExtension == "gpx" || fileExtension == "kml" || fileExtension == "xml" {
            let coordinates = parseXMLCoordinates(from: data)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let text = decodedText(from: data) {
            let coordinates = parseInline(text)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let coordinates = try? parseJSONCoordinates(from: data),
           !coordinates.isEmpty {
            return coordinates
        }

        let coordinates = parseXMLCoordinates(from: data)
        if !coordinates.isEmpty {
            return coordinates
        }

        throw CoordinateImportError.noCoordinates
    }

    static func parseInline(_ text: String) -> [CLLocationCoordinate2D] {
        sanitized(parseTextCoordinates(from: text))
    }

    private static func decodedText(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }

    private static func sanitized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            if result.last.map(CoordinateSnapshot.init) == CoordinateSnapshot(coordinate) {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func coordinate(
        first: Double,
        second: Double,
        order: CoordinateOrder
    ) -> CLLocationCoordinate2D? {
        let preferred: CLLocationCoordinate2D
        let fallback: CLLocationCoordinate2D

        switch order {
        case .latitudeLongitude:
            preferred = CLLocationCoordinate2D(latitude: first, longitude: second)
            fallback = CLLocationCoordinate2D(latitude: second, longitude: first)
        case .longitudeLatitude:
            preferred = CLLocationCoordinate2D(latitude: second, longitude: first)
            fallback = CLLocationCoordinate2D(latitude: first, longitude: second)
        }

        if CLLocationCoordinate2DIsValid(preferred) {
            return preferred
        }
        if CLLocationCoordinate2DIsValid(fallback) {
            return fallback
        }
        return nil
    }

    private static func parseJSONCoordinates(from data: Data) throws -> [CLLocationCoordinate2D] {
        let object = try JSONSerialization.jsonObject(with: data)
        return sanitized(coordinates(fromJSONObject: object, order: .latitudeLongitude))
    }

    private static func coordinates(
        fromJSONObject object: Any,
        order: CoordinateOrder
    ) -> [CLLocationCoordinate2D] {
        if let dictionary = object as? [String: Any] {
            if let latitude = numberValue(forAnyKey: ["latitude", "lat"], in: dictionary),
               let longitude = numberValue(forAnyKey: ["longitude", "lon", "lng"], in: dictionary),
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                return [coordinate]
            }

            if let geometry = dictionary["geometry"] {
                return coordinates(fromJSONObject: geometry, order: order)
            }

            if let type = dictionary["type"] as? String {
                let loweredType = type.lowercased()
                if loweredType == "featurecollection",
                   let features = dictionary["features"] as? [Any] {
                    return features.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if loweredType == "geometrycollection",
                   let geometries = dictionary["geometries"] as? [Any] {
                    return geometries.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if let coordinateObject = dictionary["coordinates"] {
                    return coordinates(fromJSONObject: coordinateObject, order: .longitudeLatitude)
                }
            }

            return dictionary.values.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        if let array = object as? [Any] {
            if array.count >= 2,
               let first = numericValue(array[0]),
               let second = numericValue(array[1]),
               let coordinate = coordinate(first: first, second: second, order: order) {
                return [coordinate]
            }

            return array.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        return []
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func numberValue(forAnyKey keys: [String], in dictionary: [String: Any]) -> Double? {
        let keyedValues = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = keyedValues[key],
               let number = numericValue(value) {
                return number
            }
        }
        return nil
    }

    private static func parseXMLCoordinates(from data: Data) -> [CLLocationCoordinate2D] {
        let collector = XMLCoordinateCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return sanitized(collector.coordinates)
    }

    private final class XMLCoordinateCollector: NSObject, XMLParserDelegate {
        var coordinates: [CLLocationCoordinate2D] = []
        private var isCollectingKMLCoordinates = false
        private var kmlCoordinateBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()
            if ["wpt", "trkpt", "rtept"].contains(name),
               let latitude = Double(attributeDict["lat"] ?? ""),
               let longitude = Double(attributeDict["lon"] ?? ""),
               let coordinate = CoordinateImportParser.coordinate(
                    first: latitude,
                    second: longitude,
                    order: .latitudeLongitude
               ) {
                coordinates.append(coordinate)
            } else if name == "coordinates" {
                isCollectingKMLCoordinates = true
                kmlCoordinateBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingKMLCoordinates {
                kmlCoordinateBuffer += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName.lowercased() == "coordinates" else { return }
            coordinates.append(contentsOf: CoordinateImportParser.parseKMLCoordinateText(kmlCoordinateBuffer))
            isCollectingKMLCoordinates = false
            kmlCoordinateBuffer = ""
        }
    }

    private static func parseKMLCoordinateText(_ text: String) -> [CLLocationCoordinate2D] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> CLLocationCoordinate2D? in
                let values = token
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard values.count >= 2 else { return nil }
                return coordinate(first: values[0], second: values[1], order: .longitudeLatitude)
            }
    }

    private static func parseTextCoordinates(from text: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var headerIndices: (latitude: Int, longitude: Int)?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = splitFields(trimmed)
            if headerIndices == nil,
               let detectedHeader = detectHeader(in: fields) {
                headerIndices = detectedHeader
                continue
            }

            if let headerIndices,
               fields.indices.contains(headerIndices.latitude),
               fields.indices.contains(headerIndices.longitude),
               let latitude = numbers(in: fields[headerIndices.latitude]).first,
               let longitude = numbers(in: fields[headerIndices.longitude]).first,
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                coordinates.append(coordinate)
                continue
            }

            let values = numbers(in: trimmed)
            if values.count >= 2,
               let coordinate = coordinate(first: values[0], second: values[1], order: .latitudeLongitude) {
                coordinates.append(coordinate)
            }
        }

        return coordinates
    }

    private static func splitFields(_ line: String) -> [String] {
        line
            .split { character in
                character == "," ||
                character == ";" ||
                character == "\t"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func detectHeader(in fields: [String]) -> (latitude: Int, longitude: Int)? {
        let lowered = fields.map { $0.lowercased() }
        guard let latitude = lowered.firstIndex(where: { $0 == "lat" || $0 == "latitude" }),
              let longitude = lowered.firstIndex(where: { $0 == "lon" || $0 == "lng" || $0 == "long" || $0 == "longitude" }) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

// MARK: - Bookmark Model

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct LocationSimulationView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var showConnectedStatus = true
    @State private var connectionErrorMessage: String?
    private var isDeviceConnected: Bool {
        tunnel.isConnected && !tunnel.isStarting && tunnel.lastError == nil && connectionErrorMessage == nil
    }
    @ObservedObject private var simulationSession = LocationSimulationSession.shared
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var routeLoadTask: Task<Void, Never>?
    @State private var routeSpeedPrefetchTask: Task<Void, Never>?
    @State private var routePlaybackTask: Task<Void, Never>?
    @State private var isBusy = false
    @State private var isLoadingRoute = false
    @State private var isPrefetchingRouteSpeeds = false
    @State private var isImportingCoordinates = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var searchText = ""
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @State private var showCoordinateImporter = false
    @State private var showRouteSearch = false
    @State private var routeStartSelection: RouteSearchSelection?
    @State private var routeEndSelection: RouteSearchSelection?
    @State private var routePlan: RouteSimulationPlan?
    @State private var routePolyline: MKPolyline?
    @State private var routePlaybackSamples: [RoutePlaybackSample] = []
    @State private var routePlaybackCoordinate: CLLocationCoordinate2D?
    @State private var simulatedCoordinate: CLLocationCoordinate2D?
    @State private var routeRequestID = UUID()

    // Wayfarer additions
    @AppStorage("wayfarer.travelMode") private var travelModeRaw = TravelMode.walking.rawValue
    @AppStorage("wayfarer.speedKmh") private var speedKmh: Double = 5
    @AppStorage("wayfarer.updateInterval") private var updateInterval: Double = 0.5
    @State private var panelTab: WayfarerTab = .teleport
    @State private var showCoordinateInput = false
    @State private var showStopListInput = false
    @AppStorage("wayfarer.followRoads") private var followRoads = false
    @State private var multiStops: [RouteStop] = []
    @AppStorage("wayfarer.pathShape") private var pathShapeRaw = RouteShape.oneWay.rawValue
    @AppStorage("wayfarer.repeatRoute") private var repeatRoute = false
    @State private var showSaveRoute = false
    @State private var routeFavoriteName = ""
    @State private var routeSourceStops: [CLLocationCoordinate2D] = []
    @State private var routeSourceFollowRoads = false
    @State private var routeSourceShape: RouteShape = .oneWay
    @State private var suppressModeSpeedReset = false
    @AppStorage("wayfarer.hopMode") private var hopMode = false
    @AppStorage("wayfarer.dwellSeconds") private var dwellSeconds: Double = 3
    @State private var routeIsHop = false
    @State private var showHistory = false
    @State private var showSharedList = false
    @State private var panelCollapsed = false
    @State private var copyToastText: String?
    @State private var playbackBaseOffset = 0
    @State private var routeWaypointIndices: [Int] = []
    @State private var routeLogical = LogicalPlan.empty
    @State private var routeFromMultiStop = false
    @State private var routeCycleDirty = false
    @State private var isReplanning = false
    @State private var hopRemaining: Double = 0
    @State private var mapCamera: MapCamera?
    @State private var mapHeading: Double = 0
    @StateObject private var locationInfo = LocationInfoModel()
    @State private var repeatPlayback = false
    @State private var isPlaybackPaused = false
    @State private var playbackCursor = 1
    @State private var playbackGeneration = 0

    private static let routeDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var routeStartCoordinate: CLLocationCoordinate2D? {
        routeStartSelection?.coordinate
    }

    private var routeEndCoordinate: CLLocationCoordinate2D? {
        routeEndSelection?.coordinate
    }

    private var hasActiveSimulation: Bool {
        simulationSession.isActive || simulatedCoordinate != nil || routePlaybackTask != nil
    }

    private var isRouteRunning: Bool {
        routePlaybackTask != nil || simulationSession.routeCoordinates != nil
    }

    private var hasRouteContext: Bool {
        routeStartSelection != nil ||
        routeEndSelection != nil ||
        routePlan != nil ||
        isLoadingRoute ||
        isPrefetchingRouteSpeeds ||
        routePlaybackCoordinate != nil ||
        simulationSession.routeCoordinates != nil
    }

    private var displayedRouteCoordinate: CLLocationCoordinate2D? {
        simulationSession.routeCoordinates == nil ? routePlaybackCoordinate : simulationSession.coordinate
    }

    private var routeSummaryText: String? {
        guard let routePlan else { return nil }
        let distanceText = Measurement(
            value: routePlan.distance / 1000,
            unit: UnitLength.kilometers
        ).formatted(.measurement(width: .abbreviated, usage: .road))
        let durationText = Self.routeDurationFormatter.string(from: routePlan.expectedTravelTime)
        if let durationText, !durationText.isEmpty {
            return "\(distanceText) • 約 \(durationText)"
        }
        return distanceText
    }

    private var routeStatusText: String {
        if simulationSession.routeCoordinates != nil {
            if isPlaybackPaused {
                return routeIsHop ? "已暫停（點對點飛）。" : "已暫停。"
            }
            if routeIsHop && hopRemaining > 0 {
                return "點對點飛：\(Int(ceil(hopRemaining))) 秒後飛往下一站。"
            }
            return "路線模擬中。"
        }
        if isLoadingRoute {
            return "正在計算路線…"
        }
        if isPrefetchingRouteSpeeds {
            return "正在取得道路速度…"
        }
        if routePlan != nil {
            return "路線已就緒，可以播放。"
        }
        if routeStartSelection != nil || routeEndSelection != nil {
            return "請設定起點與終點。"
        }
        return "請在下方選擇功能。"
    }

    private var routeAttributionLink: some View {
        Link(
            "Speed limit data © OpenStreetMap contributors (ODbL)",
            destination: OpenStreetMapSpeedLimitService.copyrightURL
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var searchResultsListBase: some View {
        List(searchCompleter.results.prefix(5), id: \.self) { result in
            Button {
                selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 350)
        .scrollDisabled(true)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if #available(iOS 26, *) {
            searchResultsListBase
                .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            searchResultsListBase
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $position) {
                    if hasRouteContext {
                        if let routePolyline {
                            MapPolyline(routePolyline)
                                .stroke(.blue.opacity(0.8), lineWidth: 5)
                        }
                        if let routeStartCoordinate, multiStops.isEmpty {
                            Marker("起點", coordinate: routeStartCoordinate)
                                .tint(.green)
                        }
                        if let routeEndCoordinate, multiStops.isEmpty {
                            Marker("終點", coordinate: routeEndCoordinate)
                                .tint(.red)
                        }
                        if let displayedRouteCoordinate {
                            Marker("目前位置", coordinate: displayedRouteCoordinate)
                                .tint(.blue)
                        }
                    } else if let coordinate {
                        Marker("圖釘", coordinate: coordinate)
                            .tint(.red)
                    }
                    if multiStops.count >= 2 && !hasRouteContext {
                        MapPolyline(coordinates: multiStops.map { $0.coordinate })
                            .stroke(.orange.opacity(0.75), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
                    }
                    if multiStops.count <= 100 {
                        ForEach(Array(multiStops.enumerated()), id: \.element.id) { index, stop in
                            Marker("\(index + 1)", coordinate: stop.coordinate)
                                .tint(.orange)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { point in
                    if let loc = proxy.convert(point, from: .local) {
                        if isMultiStopMode {
                            addStop(loc)
                        } else {
                            applySelection(loc)
                        }
                    }
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    mapHeading = context.camera.heading
                    mapCamera = context.camera
                }
            }
                .ignoresSafeArea()
                .onChange(of: coordinate.map(CoordinateSnapshot.init)) { _, new in
                    if let new {
                        position = .region(
                            MKCoordinateRegion(
                                center: new.coordinate,
                                latitudinalMeters: 1000,
                                longitudinalMeters: 1000
                            )
                        )
                    }
                }

            VStack(spacing: 0) {
                if !searchCompleter.results.isEmpty {
                    searchResultsList
                }

                Spacer()

                VStack(spacing: 12) {
                    if isRouteRunning && panelCollapsed {
                        collapsedBar
                    } else {
                        if isRouteRunning {
                            panelHandle
                        }

                        if isImportingCoordinates {
                            ProgressView("正在匯入座標…")
                                .font(.footnote)
                        }

                        if !hasRouteContext {
                            Picker("功能", selection: $panelTab) {
                                ForEach(WayfarerTab.allCases) { tab in
                                    Text(tab.title).tag(tab)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        if hasRouteContext {
                            routeControls
                        } else {
                            switch panelTab {
                            case .teleport:
                                pinControls
                            case .navigate:
                                navigateControls
                            case .multi:
                                multiStopControls
                            }
                        }
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24).onEnded { value in
                        handlePanelDrag(value.translation)
                    }
                )
            }
        }
        .overlay(alignment: .top) {
            topOverlay
        }
        .overlay(alignment: .top) {
            if let message = copyToastText {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.25)))
                    .padding(.top, 70)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top) {
            if !isDeviceConnected || showConnectedStatus {
                DeviceConnectionStatusView(errorMessage: connectionErrorMessage)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
            }
        }
        .task(id: isDeviceConnected) {
            showConnectedStatus = true
            guard isDeviceConnected else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                showConnectedStatus = false
            } catch {}
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    showBookmarks = true
                } label: {
                    Image(systemName: "bookmark.fill")
                }

                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("歷史記錄")

                Button {
                    showSharedList = true
                } label: {
                    Image(systemName: "person.2.fill")
                }
                .accessibilityLabel("共享清單")

                Button {
                    showCoordinateImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(isBusy || isRouteRunning || isImportingCoordinates)
                .accessibilityLabel("匯入座標檔")
            }
            ToolbarItem(placement: .topBarTrailing) {
                TextField("搜尋地點…", text: $searchText)
                    .padding(.leading, 6)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onChange(of: searchText) { _, newValue in
                        searchCompleter.update(query: newValue)
                    }
                    .onSubmit {
                        applyCoordinatesFromSearchText()
                    }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showSaveBookmark) {
            if let pinCoordinate = coordinate {
                SaveCoordinateSheet(coordinate: pinCoordinate)
            }
        }
        .alert("收藏路線", isPresented: $showSaveRoute) {
            TextField("路線名稱", text: $routeFavoriteName)
            Button("儲存") { saveRouteFavorite() }
            Button("取消", role: .cancel) { routeFavoriteName = "" }
        } message: {
            Text("為這條路線取個名稱。")
        }
        .sheet(isPresented: $showBookmarks) {
            FavoritesSheet(
                onPickCoordinate: { favorite in
                    panelTab = .teleport
                    applySelection(favorite.coordinate)
                },
                onTeleportCoordinate: { favorite in
                    panelTab = .teleport
                    applySelection(favorite.coordinate)
                    DispatchQueue.main.async { simulate() }
                },
                onPickRoute: { route in
                    applyRouteFavorite(route)
                }
            )
        }
        .sheet(isPresented: $showSharedList) {
            SharedListSheet(
                currentPin: coordinate,
                onPick: { item in
                    panelTab = .teleport
                    applySelection(item.coordinate)
                },
                onTeleport: { item in
                    panelTab = .teleport
                    applySelection(item.coordinate)
                    DispatchQueue.main.async { simulate() }
                }
            )
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(
                onTeleport: { target in
                    panelTab = .teleport
                    applySelection(target)
                    DispatchQueue.main.async { simulate() }
                },
                onRoute: { route in
                    applyRouteFavorite(route)
                }
            )
        }
        .sheet(isPresented: $showRouteSearch) {
            RouteSearchSheet(
                initialStart: routeStartSelection,
                initialEnd: routeEndSelection
            ) { startSelection, endSelection in
                routeStartSelection = startSelection
                routeEndSelection = endSelection
                refreshRoute()
            }
        }
        .fileImporter(
            isPresented: $showCoordinateImporter,
            allowedContentTypes: CoordinateImportParser.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importCoordinates(result)
        }
        .onAppear {
            if TravelMode(rawValue: travelModeRaw) == nil {
                travelModeRaw = TravelMode.walking.rawValue
            }
            locationInfo.update(infoCoordinate)
            loadBookmarks()
            if let routeCoordinates = simulationSession.routeCoordinates {
                coordinate = nil
                routePolyline = makeRoutePolyline(for: routeCoordinates)
                routeStartSelection = routeCoordinates.first.map {
                    RouteSearchSelection(title: "路線起點", coordinate: $0)
                }
                routeEndSelection = routeCoordinates.last.map {
                    RouteSearchSelection(title: "路線終點", coordinate: $0)
                }
                if let routePolyline {
                    position = .rect(routePolyline.boundingMapRect)
                }
            } else if let activeCoordinate = simulationSession.coordinate {
                coordinate = activeCoordinate
                simulatedCoordinate = activeCoordinate
            }
        }
        .onChange(of: panelTab) { _, _ in
            panelTabChanged()
        }
        .onChange(of: travelModeRaw) { _, _ in
            modeChanged()
        }
        .sheet(isPresented: $showCoordinateInput) {
            CoordinateInputSheet(
                onPlace: { target in
                    applySelection(target)
                },
                onTeleport: { target in
                    applySelection(target)
                    DispatchQueue.main.async { simulate() }
                }
            )
        }
        .sheet(isPresented: $showStopListInput) {
            StopListInputSheet { coordinates in
                multiStops = coordinates.map { RouteStop(coordinate: $0) }
                DispatchQueue.main.async { buildMultiStopRoute() }
            }
        }
        .onChange(of: speedKmh) { _, _ in
            applySpeedChange()
        }
        .onChange(of: updateInterval) { _, _ in
            intervalChanged()
        }
        .onChange(of: dwellSeconds) { _, _ in
            dwellChanged()
        }
        .onChange(of: isRouteRunning) { _, running in
            if !running {
                panelCollapsed = false
            }
        }
        .onChange(of: pathShapeRaw) { _, _ in
            replanIfPaused()
        }
        .onChange(of: followRoads) { _, _ in
            replanIfPaused()
        }
        .onChange(of: hopMode) { _, _ in
            replanIfPaused()
        }
        .onChange(of: repeatRoute) { _, _ in
            repeatToggled()
        }
        .onChange(of: infoCoordinate.map(CoordinateSnapshot.init)) { _, newValue in
            locationInfo.update(newValue?.coordinate)
        }
        .onDisappear {
            routeLoadTask?.cancel()
            routeLoadTask = nil
            routeSpeedPrefetchTask?.cancel()
            routeSpeedPrefetchTask = nil
            endBackgroundTask()
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "locationBookmarks")
        }
    }

    private func addBookmark() {
        guard let coord = coordinate else { return }
        let name = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        bookmarks.append(bookmark)
        saveBookmarks()
        newBookmarkName = ""
    }

    private func setRoutePlan(_ plan: RouteSimulationPlan?) {
        routePlan = plan
        routePolyline = plan.flatMap { makeRoutePolyline(for: $0.displayCoordinates) }
    }

    private func makeRoutePolyline(for coordinates: [CLLocationCoordinate2D]) -> MKPolyline? {
        guard coordinates.count > 1 else { return nil }
        return coordinates.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return MKPolyline(coordinates: baseAddress, count: buffer.count)
        }
    }

    // MARK: - Location

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        searchCompleter.results = []
        dismissKeyboard()

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            if let item = response?.mapItems.first {
                useSearchedPlace(item.placemark.coordinate)
            }
        }
    }

    private func applyCoordinatesFromSearchText() {
        let importedCoordinates = CoordinateImportParser.parseInline(searchText)
        guard !importedCoordinates.isEmpty else { return }

        searchText = ""
        searchCompleter.results = []
        dismissKeyboard()

        // A single pasted coordinate is used right away; several make a route.
        if importedCoordinates.count == 1, let only = importedCoordinates.first,
           CLLocationCoordinate2DIsValid(only) {
            useSearchedPlace(only)
        } else {
            applyImportedCoordinates(importedCoordinates, sourceName: "已匯入")
        }
    }

    private func importCoordinates(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let sourceName = url.deletingPathExtension().lastPathComponent
            isImportingCoordinates = true

            Task {
                do {
                    let coordinates = try await Task.detached(priority: .userInitiated) {
                        try CoordinateImportParser.parse(url: url)
                    }.value

                    await MainActor.run {
                        isImportingCoordinates = false
                        applyImportedCoordinates(
                            coordinates,
                            sourceName: sourceName.isEmpty ? "已匯入" : sourceName
                        )
                    }
                } catch {
                    await MainActor.run {
                        isImportingCoordinates = false
                        showImportError(error)
                    }
                }
            }
        case .failure(let error):
            showImportError(error)
        }
    }

    private func applyImportedCoordinates(
        _ importedCoordinates: [CLLocationCoordinate2D],
        sourceName: String
    ) {
        guard !isRouteRunning else { return }

        let coordinates = importedCoordinates.filter(CLLocationCoordinate2DIsValid)
        guard let firstCoordinate = coordinates.first else {
            showImportError(CoordinateImportError.noCoordinates)
            return
        }

        if coordinates.count == 1 {
            applySelection(firstCoordinate)
            return
        }

        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        coordinate = nil

        let displayCoordinates = sampledRouteCoordinates(
            from: coordinates,
            targetDistance: WayfarerSpeed.pathSpacing(
                forSpeed: WayfarerSpeed.metersPerSecond(fromKmh: speedKmh)
            )
        )

        guard displayCoordinates.count > 1,
              let lastCoordinate = displayCoordinates.last else {
            applySelection(firstCoordinate)
            return
        }

        let distance = distanceAlong(displayCoordinates)
        let fallbackSpeed = WayfarerSpeed.metersPerSecond(fromKmh: speedKmh)
        repeatPlayback = false
        routeSourceStops = coordinates
        routeSourceFollowRoads = false
        routeSourceShape = .oneWay
        routeIsHop = false
        routeFromMultiStop = false
        routeStartSelection = RouteSearchSelection(title: "\(sourceName) 起點", coordinate: firstCoordinate)
        routeEndSelection = RouteSearchSelection(title: "\(sourceName) 終點", coordinate: lastCoordinate)
        setRoutePlan(RouteSimulationPlan(
            displayCoordinates: displayCoordinates,
            distance: distance,
            expectedTravelTime: distance / fallbackSpeed
        ))

        if let routePolyline {
            position = .rect(routePolyline.boundingMapRect)
        }

        routeRequestID = UUID()
        isPrefetchingRouteSpeeds = false
        routePlaybackSamples = buildPlaybackSamples(
            from: displayCoordinates,
            speedWays: [],
            fallbackSpeedMetersPerSecond: fallbackSpeed
        )
    }

    private func showImportError(_ error: Error) {
        alertTitle = "匯入失敗"
        alertMessage = error.localizedDescription
        showAlert = true
    }

    private var pinControls: some View {
        VStack(spacing: 10) {
            if let coord = coordinate {
                HStack(spacing: 8) {
                    Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        copyCoordinate(coord)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("複製座標")
                }
            } else {
                Text("點選地圖放置圖釘，或按「輸入座標」")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("停止", action: clear)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!pairingExists || isBusy || !hasActiveSimulation)

                Button("瞬移", action: simulate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!pairingExists || isBusy || isLoadingRoute || coordinate == nil)

                Button {
                    showCoordinateInput = true
                } label: {
                    Label("輸入座標", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)

                Button {
                    showSaveBookmark = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(coordinate == nil || isRouteRunning)
            }
        }
    }

    private var routeControls: some View {
        VStack(spacing: 10) {
            Text(routeStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isLoadingRoute || isPrefetchingRouteSpeeds {
                ProgressView()
                    .controlSize(.small)
            } else if let routeSummaryText {
                Text(routeSummaryText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if routeIsHop {
                DwellField(seconds: $dwellSeconds)

                Text("點對點飛：依序瞬移到每個站點，每個站點停留設定的秒數；播放中也可以直接改停留秒數。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                TravelModeSpeedBar(
                    modeRaw: $travelModeRaw,
                    speedKmh: $speedKmh,
                    updateInterval: $updateInterval,
                    modeLocked: false
                )

                Text("切換模式只會調整速度，路線不變；播放中也可以直接改速度與更新間隔。間隔越短越平順，但手機要處理的更新越多，太短時實際速度可能跟不上。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    routeFavoriteName = ""
                    showSaveRoute = true
                } label: {
                    Label("收藏這條路線", systemImage: "star")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(routePlan == nil || routeSourceStops.count < 2)

                Button {
                    copyRouteStops()
                } label: {
                    Label("複製座標", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(routeSourceStops.isEmpty)
            }

            if routeFromMultiStop && isRouteRunning {
                pausedEditControls
            }

            HStack(spacing: 12) {
                Button("停止", action: clear)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!pairingExists || isBusy || !hasActiveSimulation)

                Button("播放路線", action: simulateRoute)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !pairingExists ||
                        isBusy ||
                        isLoadingRoute ||
                        isPrefetchingRouteSpeeds ||
                        routePlan == nil ||
                        routePlaybackSamples.isEmpty
                    )

                if isRouteRunning {
                    Button(isPlaybackPaused ? "繼續" : "暫停") {
                        isPlaybackPaused.toggle()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isReplanning)
                } else {
                    Button("重設", action: resetKeepingStops)
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                }
            }
        }
    }

    private func simulate() {
        guard pairingExists, let coord = coordinate, !isBusy else { return }
        runLocationCommand(
            errorTitle: "瞬移失敗",
            errorMessage: { code in
                "無法設定位置（錯誤 \(code)）。請確認 LocalDevVPN 已開啟、已連上 Wi-Fi，且配對檔有效。" + cellularOnlyHint
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
            HistoryStore.shared.addTeleport(coord)
            routePlaybackCoordinate = nil
            beginBackgroundTask()
            LocationSimulationSession.shared.clearRoute()
            startResendLoop(with: coord)
        }
    }

    private func simulateRoute() {
        guard pairingExists,
              let routePlan,
              let firstCoordinate = routePlaybackSamples.first?.coordinate,
              !isBusy else {
            return
        }
        stopResendLoop()
        cancelRoutePlayback(resetMarker: false)
        runLocationCommand(
            errorTitle: "路線模擬失敗",
            errorMessage: { code in
                "無法開始路線模擬（錯誤 \(code)）。請確認 LocalDevVPN 已開啟、已連上 Wi-Fi，且配對檔有效。" + cellularOnlyHint
            },
            operation: { locationUpdateCode(for: firstCoordinate) }
        ) {
            recordRouteHistory()
            beginBackgroundTask()
            let routeID = LocationSimulationSession.shared.startRoute(
                at: firstCoordinate,
                coordinates: routePlan.displayCoordinates
            )
            simulatedCoordinate = nil
            routePlaybackCoordinate = firstCoordinate
            startRoutePlayback(routeID: routeID)
        }
    }

    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        LocationSimulationCommandQueue.shared.async {
            let code = operation()
            DispatchQueue.main.async {
                isBusy = false
                if code == 0 {
                    connectionErrorMessage = nil
                    onSuccess()
                } else {
                    alertTitle = errorTitle
                    alertMessage = errorMessage(code)
                    connectionErrorMessage = "Code \(code): \(alertMessage)"
                    showAlert = true
                }
            }
        }
    }

    private func clear() {
        guard pairingExists, !isBusy else { return }
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        cancelRoutePlayback(resetMarker: true)
        stopResendLoop()
        LocationSimulationSession.shared.clearRoute()
        runLocationCommand(
            errorTitle: "停止失敗",
            errorMessage: { code in "無法停止模擬（錯誤 \(code)）。" },
            operation: clear_simulated_location
        ) {
            endBackgroundTask()
            LocationSimulationSession.shared.stop()
            withAnimation(.easeInOut(duration: 0.35)) {
                position = .userLocation(fallback: .automatic)
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        LocationSimulationSession.shared.startResending(at: coordinate) {
            LocationSimulationCommandQueue.shared.async {
                _ = locationUpdateCode(for: coordinate)
            }
        }
    }

    private func stopResendLoop() {
        LocationSimulationSession.shared.pauseResending()
        simulatedCoordinate = nil
    }

    private func cancelRoutePlayback(resetMarker: Bool) {
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        isPlaybackPaused = false
        if resetMarker {
            routePlaybackCoordinate = nil
        }
    }

    private func applySelection(_ coordinate: CLLocationCoordinate2D) {
        guard !isRouteRunning else { return }
        if hasRouteContext {
            resetRouteSelection()
        }
        multiStops = []
        self.coordinate = coordinate
    }

    /// Reset for a multi-stop route: clear the built route and playback, but keep the
    /// stops so the route is still there to edit or build again. Other routes are
    /// cleared completely, as before.
    private func resetKeepingStops() {
        guard routeFromMultiStop, routeSourceStops.count >= 2 else {
            resetRouteSelection()
            return
        }
        let stops = routeSourceStops
        resetRouteSelection()
        multiStops = stops.map { RouteStop(coordinate: $0) }
        panelTab = .multi
        if let outline = makeRoutePolyline(for: stops) {
            position = .rect(outline.boundingMapRect)
        }
    }

    private func resetRouteSelection() {
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routeStartSelection = nil
        routeEndSelection = nil
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        multiStops = []
        routeSourceStops = []
        routeIsHop = false
        routeFromMultiStop = false
        routeCycleDirty = false
        isReplanning = false
        hopRemaining = 0
        repeatPlayback = false
        isPlaybackPaused = false
    }

    private func refreshRoute() {
        routeLoadTask?.cancel()
        routeSpeedPrefetchTask?.cancel()
        setRoutePlan(nil)
        routePlaybackSamples = []

        guard let routeStart = routeStartSelection?.coordinate,
              let routeEnd = routeEndSelection?.coordinate else {
            isLoadingRoute = false
            isPrefetchingRouteSpeeds = false
            return
        }

        let requestID = UUID()
        routeRequestID = requestID
        isLoadingRoute = true
        isPrefetchingRouteSpeeds = false

        routeSourceStops = [routeStart, routeEnd]
        routeSourceFollowRoads = true
        routeSourceShape = .oneWay
        routeIsHop = false
        routeFromMultiStop = false

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: routeStart))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: routeEnd))
        request.requestsAlternateRoutes = false
        request.transportType = travelMode.transportType
        let speedMps = WayfarerSpeed.metersPerSecond(fromKmh: speedKmh)
        repeatPlayback = false

        routeLoadTask = Task {
            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled else { return }
                guard let route = response.routes.first else {
                    throw NSError(
                        domain: "RouteSimulation",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "找不到路線。"]
                    )
                }

                let displayCoordinates = sampledRouteCoordinates(
                    from: route.polyline.coordinateArray,
                    targetDistance: WayfarerSpeed.pathSpacing(forSpeed: speedMps)
                )
                let routePlan = RouteSimulationPlan(
                    displayCoordinates: displayCoordinates,
                    distance: route.distance,
                    expectedTravelTime: route.distance / speedMps
                )
                let playbackSamples = buildPlaybackSamples(
                    from: displayCoordinates,
                    speedWays: [],
                    fallbackSpeedMetersPerSecond: speedMps
                )

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    self.setRoutePlan(routePlan)
                    routePlaybackSamples = playbackSamples
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                    if let routePolyline {
                        position = .rect(routePolyline.boundingMapRect)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                }
            } catch {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                    alertTitle = "路線規劃失敗"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func startRoutePlayback(routeID: UUID) {
        isPlaybackPaused = false
        playbackCursor = 1
        playbackGeneration += 1
        routePlaybackTask = Task {
            var lastSuccessfulCoordinate = routePlaybackSamples.first?.coordinate
            // Point-to-point: after a pause, Resume jumps on to the next stop at once.
            var skipNextWait = false

            while !Task.isCancelled {
                // Paused: keep re-sending the current position so it does not expire.
                var pausedTicks = 0
                var pausedHere = false
                while isPlaybackPaused {
                    pausedHere = true
                    guard !Task.isCancelled,
                          LocationSimulationSession.shared.isCurrentRoute(routeID) else {
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                    pausedTicks += 1
                    if pausedTicks % 4 == 0, let keepCoordinate = lastSuccessfulCoordinate {
                        _ = await sendLocationUpdate(for: keepCoordinate)
                    }
                }
                if pausedHere && routeIsHop {
                    skipNextWait = true
                }
                guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }

                let samples = routePlaybackSamples
                let cursor = playbackCursor

                if cursor >= samples.count {
                    if repeatPlayback, samples.count > 1 {
                        if routeCycleDirty {
                            await rebuildCycleForRepeat()
                        } else {
                            await MainActor.run {
                                rebuildFullPlaybackSamples()
                                playbackCursor = 1
                                playbackGeneration += 1
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    break
                }

                let generation = playbackGeneration
                let sample = samples[cursor]

                // Wait in short slices so Pause takes effect at once; the position keeps
                // being refreshed while paused. Continuous moves keep the time already
                // waited; point-to-point skips the rest of the stay on Resume.
                var remainingWait = routeIsHop ? max(dwellSeconds, 0) : sample.delayFromPrevious
                if skipNextWait {
                    remainingWait = 0
                    skipNextWait = false
                }
                var pausedWaitTicks = 0
                var pausedDuringWait = false
                while remainingWait > 0 {
                    guard !Task.isCancelled,
                          LocationSimulationSession.shared.isCurrentRoute(routeID) else {
                        return
                    }
                    if generation != playbackGeneration { break }
                    if routeIsHop {
                        let shown = remainingWait
                        await MainActor.run { hopRemaining = shown }
                    }
                    let slice = min(remainingWait, 0.25)
                    try? await Task.sleep(for: .seconds(slice))
                    if isPlaybackPaused {
                        pausedDuringWait = true
                        pausedWaitTicks += 1
                        if pausedWaitTicks % 16 == 0, let keepCoordinate = lastSuccessfulCoordinate {
                            _ = await sendLocationUpdate(for: keepCoordinate)
                        }
                        continue
                    }
                    if pausedDuringWait && routeIsHop {
                        // Resumed after a pause: do not wait out the rest of the stay.
                        remainingWait = 0
                        break
                    }
                    remainingWait -= slice
                }
                if routeIsHop {
                    await MainActor.run { hopRemaining = 0 }
                }
                guard !Task.isCancelled,
                      LocationSimulationSession.shared.isCurrentRoute(routeID) else {
                    return
                }
                if isPlaybackPaused || generation != playbackGeneration { continue }

                let code = await sendLocationUpdate(for: sample.coordinate)
                guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                guard code == 0 else {
                    await MainActor.run {
                        routePlaybackTask = nil
                        routePlaybackCoordinate = lastSuccessfulCoordinate
                        LocationSimulationSession.shared.clearRoute()
                        if let lastSuccessfulCoordinate {
                            startResendLoop(with: lastSuccessfulCoordinate)
                        }
                        alertTitle = "路線模擬失敗"
                        alertMessage = "無法繼續路線模擬（錯誤 \(code)）。"
                        connectionErrorMessage = "錯誤 \(code)：無法繼續路線模擬。"
                        showAlert = true
                    }
                    return
                }

                lastSuccessfulCoordinate = sample.coordinate
                await MainActor.run {
                    if generation == playbackGeneration {
                        playbackCursor = cursor + 1
                    }
                    routePlaybackCoordinate = sample.coordinate
                    LocationSimulationSession.shared.updateCoordinate(sample.coordinate)
                }
            }

            await MainActor.run {
                guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                routePlaybackTask = nil
                // The route has ended; while it stays set, isRouteRunning keeps
                // map taps, search, bookmarks and Reset disabled.
                LocationSimulationSession.shared.clearRoute()
                if let lastSuccessfulCoordinate {
                    routePlaybackCoordinate = lastSuccessfulCoordinate
                    startResendLoop(with: lastSuccessfulCoordinate)
                }
            }
        }
    }

    private func sendLocationUpdate(for coordinate: CLLocationCoordinate2D) async -> Int32 {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: locationUpdateCode(for: coordinate))
            }
        }
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
    }
}

// MARK: - Wayfarer: modes, speed, multi-stop routes

extension LocationSimulationView {
    private var travelMode: TravelMode {
        TravelMode(rawValue: travelModeRaw) ?? .walking
    }

    private var cellularOnlyHint: String {
        NetworkStateMonitor.shared.isCellularOnly
            ? "\n\n偵測到 Wi-Fi 關閉、行動數據開啟，這個狀態下無法建立連線。請先開飛航模式再試，詳細步驟見「設定 → 說明 → 沒有 Wi-Fi 時怎麼使用」。"
            : ""
    }

    private var isMultiStopMode: Bool {
        panelTab == .multi && !hasRouteContext
    }

    private var navigateHint: String {
        if simulationSession.coordinate == nil {
            return "尚未設定目前位置。請先到「瞬移」設定起點，或按「設定起點與終點」。"
        }
        if coordinate == nil {
            return "在地圖上點選目的地，再按「從目前位置前往」。"
        }
        return "已選好目的地，按「從目前位置前往」規劃路線。"
    }

    private var navigateControls: some View {
        VStack(spacing: 10) {
            Text(navigateHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TravelModeSpeedBar(
                modeRaw: $travelModeRaw,
                speedKmh: $speedKmh,
                updateInterval: $updateInterval,
                modeLocked: false
            )

            HStack(spacing: 10) {
                Button {
                    showRouteSearch = true
                } label: {
                    Label("設定起點與終點", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                Button("從目前位置前往") {
                    navigateToPin()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !pairingExists || isBusy || isLoadingRoute ||
                    coordinate == nil || simulationSession.coordinate == nil
                )
            }
        }
    }

    private var pathShape: RouteShape {
        RouteShape(rawValue: pathShapeRaw) ?? .oneWay
    }

    private var multiStopControls: some View {
        VStack(spacing: 8) {
            Text(multiStops.isEmpty
                 ? "點選地圖加入站點，或貼上座標清單"
                 : "已加入 \(multiStops.count) 個站點，可繼續點地圖加入")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("點對點飛（逐點瞬移）", isOn: $hopMode)
                .font(.subheadline)

            if hopMode {
                DwellField(seconds: $dwellSeconds)
            } else {
                TravelModeSpeedBar(
                    modeRaw: $travelModeRaw,
                    speedKmh: $speedKmh,
                    updateInterval: $updateInterval,
                    modeLocked: false
                )

                HStack(spacing: 8) {
                    Text("連線方式")
                        .font(.subheadline)
                    Picker("連線方式", selection: $followRoads) {
                        Text("直線").tag(false)
                        Text("導航").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }

            HStack(spacing: 8) {
                Text("走法")
                    .font(.subheadline)
                Picker("走法", selection: $pathShapeRaw) {
                    ForEach(RouteShape.allCases) { shape in
                        Text(shape.title).tag(shape.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            if pathShape != .oneWay {
                Toggle("重複播放（直到按停止）", isOn: $repeatRoute)
                    .font(.subheadline)
            }

            HStack(spacing: 8) {
                Button("復原") {
                    if !multiStops.isEmpty { multiStops.removeLast() }
                }
                .buttonStyle(.bordered)
                .disabled(multiStops.isEmpty)

                Button("清除") {
                    multiStops.removeAll()
                }
                .buttonStyle(.bordered)
                .disabled(multiStops.isEmpty)

                Button {
                    showStopListInput = true
                } label: {
                    Label("貼上清單", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.bordered)

                Button("建立路線") {
                    buildMultiStopRoute()
                }
                .buttonStyle(.borderedProminent)
                .disabled(multiStops.count < 2 || isLoadingRoute)
            }
        }
    }

    private var infoCoordinate: CLLocationCoordinate2D? {
        displayedRouteCoordinate ?? simulationSession.coordinate ?? coordinate
    }

    /// Place/time card and compass; hidden while searching so they do not cover the results.
    @ViewBuilder
    private var topOverlay: some View {
        if searchText.isEmpty && searchCompleter.results.isEmpty {
            HStack(alignment: .top) {
                if infoCoordinate != nil {
                    LocationInfoCard(model: locationInfo, onCopy: { copyCurrentPosition() })
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    WayfarerCompassButton(heading: mapHeading) {
                        resetMapNorth()
                    }
                    if hasActiveSimulation {
                        realLocationButton
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    /// Stops the simulation so the phone reports its real position again.
    private var realLocationButton: some View {
        Button(action: clear) {
            Label("回到真實位置", systemImage: "location.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .disabled(!pairingExists || isBusy)
        .accessibilityLabel("回到手機的真實位置，停止模擬")
    }

    private func showCopied(_ message: String) {
        withAnimation { copyToastText = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copyToastText == message {
                withAnimation { copyToastText = nil }
            }
        }
    }

    private func copyCoordinate(_ target: CLLocationCoordinate2D) {
        CoordinateClipboard.copy(CoordinateClipboard.text(for: target))
        showCopied("已複製座標")
    }

    private func copyCurrentPosition() {
        guard let target = infoCoordinate else { return }
        copyCoordinate(target)
    }

    private func copyRouteStops() {
        guard !routeSourceStops.isEmpty else { return }
        CoordinateClipboard.copy(CoordinateClipboard.text(for: routeSourceStops))
        showCopied("已複製 \(routeSourceStops.count) 個座標")
    }

    private func resetMapNorth() {
        guard let camera = mapCamera else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            position = .camera(
                MapCamera(
                    centerCoordinate: camera.centerCoordinate,
                    distance: camera.distance,
                    heading: 0,
                    pitch: 0
                )
            )
        }
    }

    /// One sample per stop; the wait before each jump is the dwell time, read live.
    private func hopSamples(for path: [CLLocationCoordinate2D]) -> [RoutePlaybackSample] {
        let dwell = max(dwellSeconds, 0)
        return path.enumerated().map { index, point in
            RoutePlaybackSample(coordinate: point, delayFromPrevious: index == 0 ? 0 : dwell)
        }
    }

    private func buildHopRoute() {
        guard multiStops.count >= 2 else { return }
        routeLoadTask?.cancel()
        routeSpeedPrefetchTask?.cancel()

        let stops = multiStops.map(\.coordinate)
        let shape = pathShape
        var path = stops
        switch shape {
        case .oneWay:
            break
        case .roundTrip:
            path.append(contentsOf: stops.reversed().dropFirst())
        case .circuit:
            path.append(stops[0])
        }

        var distance: CLLocationDistance = 0
        for (a, b) in zip(path, path.dropFirst()) {
            distance += WayfarerRouteBuilder.straightDistance(a, b)
        }
        let dwell = max(dwellSeconds, 0)

        routeRequestID = UUID()
        routeSourceStops = stops
        routeSourceFollowRoads = false
        routeSourceShape = shape
        routeIsHop = true
        routeFromMultiStop = true
        routeCycleDirty = false
        routeLogical = LogicalPlan.initial(shape: shape, count: stops.count)
        routeWaypointIndices = Array(path.indices)
        playbackBaseOffset = 0

        routeStartSelection = RouteSearchSelection(title: "站點 1", coordinate: stops[0])
        let closed = shape != .oneWay
        routeEndSelection = RouteSearchSelection(
            title: closed ? "站點 1" : "站點 \(stops.count)",
            coordinate: closed ? stops[0] : stops[stops.count - 1]
        )
        coordinate = nil

        setRoutePlan(RouteSimulationPlan(
            displayCoordinates: path,
            distance: distance,
            expectedTravelTime: dwell * Double(max(path.count - 1, 0))
        ))
        routePlaybackSamples = hopSamples(for: path)
        repeatPlayback = repeatRoute && shape != .oneWay
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        if let routePolyline {
            position = .rect(routePolyline.boundingMapRect)
        }
    }

    private func recordRouteHistory() {
        guard routeSourceStops.count >= 2 else { return }
        let favorite = RouteFavorite(
            name: "",
            stops: routeSourceStops.map { StopPoint(latitude: $0.latitude, longitude: $0.longitude) },
            modeRaw: travelModeRaw,
            speedKmh: speedKmh,
            shapeRaw: routeSourceShape.rawValue,
            followRoads: routeSourceFollowRoads,
            hop: routeIsHop,
            dwellSeconds: dwellSeconds
        )
        HistoryStore.shared.addRoute(favorite)
    }

    /// Swipe down shrinks the panel to one row while a route runs; swipe up brings it back.
    private func handlePanelDrag(_ translation: CGSize) {
        guard isRouteRunning else { return }
        guard abs(translation.height) > abs(translation.width) * 1.5 else { return }
        if translation.height > 40 {
            withAnimation(.easeInOut(duration: 0.25)) { panelCollapsed = true }
        } else if translation.height < -40 {
            withAnimation(.easeInOut(duration: 0.25)) { panelCollapsed = false }
        }
    }

    private var panelHandle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { panelCollapsed = true }
        } label: {
            VStack(spacing: 3) {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 40, height: 5)
                Text("往下滑，縮小成一列")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("縮小設定面板")
    }

    /// "已到 2／5 站" for multi-stop routes.
    private var routeProgressText: String? {
        guard routeFromMultiStop, !routeLogical.sequence.isEmpty else { return nil }
        let total = routeLogical.sequence.count
        return "已到 \(min(passedWaypointCount(), total))／\(total) 站"
    }

    private var collapsedBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { panelCollapsed = false }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展開設定面板")

            VStack(alignment: .leading, spacing: 1) {
                Text(routeStatusText)
                    .font(.footnote)
                    .lineLimit(1)
                if let progress = routeProgressText {
                    Text(progress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button {
                isPlaybackPaused.toggle()
            } label: {
                Image(systemName: isPlaybackPaused ? "play.fill" : "pause.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.bordered)
            .disabled(isReplanning)
            .accessibilityLabel(isPlaybackPaused ? "繼續" : "暫停")

            Button(action: clear) {
                Image(systemName: "stop.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!pairingExists || isBusy)
            .accessibilityLabel("停止")
        }
    }

    private func repeatToggled() {
        guard isRouteRunning else { return }
        repeatPlayback = repeatRoute && routeSourceShape != .oneWay
    }

    /// Where the path of the current plan passes each waypoint (searched in order).
    private func computeWaypointIndices(
        path: [CLLocationCoordinate2D],
        waypoints: [CLLocationCoordinate2D]
    ) -> [Int] {
        var result: [Int] = []
        var cursor = 0
        let tolerance = 0.000_001
        for waypoint in waypoints {
            var found = cursor
            var index = cursor
            while index < path.count {
                if abs(path[index].latitude - waypoint.latitude) < tolerance
                    && abs(path[index].longitude - waypoint.longitude) < tolerance {
                    found = index
                    break
                }
                index += 1
            }
            result.append(found)
            cursor = found
        }
        return result
    }

    /// How many waypoints after the start have been reached so far.
    private func passedWaypointCount() -> Int {
        if routeIsHop {
            return max(playbackCursor - 1, 0)
        }
        let lastIndex = max(playbackCursor - 1, 0)
        guard routePlaybackSamples.indices.contains(lastIndex),
              routeWaypointIndices.count > 1 else {
            return 0
        }
        let absolute = playbackBaseOffset + routePlaybackSamples[lastIndex].baseIndex
        var passed = 0
        for index in 1..<routeWaypointIndices.count where routeWaypointIndices[index] <= absolute {
            passed += 1
        }
        return passed
    }

    private func hopPath(stops: [CLLocationCoordinate2D], shape: RouteShape) -> [CLLocationCoordinate2D] {
        var path = stops
        switch shape {
        case .oneWay:
            break
        case .roundTrip:
            path.append(contentsOf: stops.reversed().dropFirst())
        case .circuit:
            if let first = stops.first { path.append(first) }
        }
        return path
    }

    private func applyReplan(
        plan: RouteSimulationPlan,
        samples: [RoutePlaybackSample],
        indices: [Int],
        logical: LogicalPlan,
        shape: RouteShape,
        roads: Bool,
        hop: Bool
    ) {
        setRoutePlan(plan)
        routePlaybackSamples = samples
        playbackBaseOffset = 0
        routeWaypointIndices = indices
        routeLogical = logical
        routeSourceShape = shape
        routeSourceFollowRoads = roads
        routeIsHop = hop
        repeatPlayback = repeatRoute && shape != .oneWay
        routeCycleDirty = true
        playbackCursor = 1
        playbackGeneration += 1
        isReplanning = false
    }

    private func revertPausedSettings() {
        pathShapeRaw = routeSourceShape.rawValue
        followRoads = routeSourceFollowRoads
        hopMode = routeIsHop
    }

    /// While paused, changing the walk style re-plans the rest of the trip from here.
    private func replanIfPaused() {
        guard isRouteRunning, isPlaybackPaused, routeFromMultiStop, !isReplanning else { return }
        let stops = routeSourceStops
        guard stops.count >= 2, let current = routePlaybackCoordinate else { return }

        let newShape = pathShape
        let roads = followRoads
        let hop = hopMode
        if newShape == routeSourceShape && roads == routeSourceFollowRoads && hop == routeIsHop {
            return
        }

        guard let state = routeLogical.remaining(after: passedWaypointCount()) else {
            revertPausedSettings()
            alertTitle = "路線已走完"
            alertMessage = "已經走到最後，沒有後續路線可以調整。"
            showAlert = true
            return
        }

        let newLogical: LogicalPlan?
        if state.isReturning {
            newLogical = LogicalPlan.makeReturning(shape: newShape, next: state.next)
        } else {
            newLogical = LogicalPlan.make(shape: newShape, count: stops.count, nextOutbound: state.next)
        }
        guard let newLogical, !newLogical.sequence.isEmpty else {
            revertPausedSettings()
            alertTitle = "無法改成單程"
            alertMessage = "已經在回程中，無法改成單程。可以選「來回」繼續回程，或「繞圈」直接回到起點。"
            showAlert = true
            return
        }

        let waypoints = [current] + newLogical.sequence.map { stops[$0] }
        let mode = travelMode
        let speedMps = WayfarerSpeed.metersPerSecond(fromKmh: speedKmh)
        isReplanning = true

        if hop {
            var distance: CLLocationDistance = 0
            for (a, b) in zip(waypoints, waypoints.dropFirst()) {
                distance += WayfarerRouteBuilder.straightDistance(a, b)
            }
            let plan = RouteSimulationPlan(
                displayCoordinates: waypoints,
                distance: distance,
                expectedTravelTime: max(dwellSeconds, 0) * Double(max(waypoints.count - 1, 0))
            )
            applyReplan(
                plan: plan,
                samples: hopSamples(for: waypoints),
                indices: Array(waypoints.indices),
                logical: newLogical,
                shape: newShape,
                roads: roads,
                hop: true
            )
            return
        }

        Task {
            do {
                let built = try await WayfarerRouteBuilder.buildSequence(
                    points: waypoints,
                    mode: mode,
                    followRoads: roads
                )
                let displayCoordinates = sampledRouteCoordinates(
                    from: built.coordinates,
                    targetDistance: WayfarerSpeed.pathSpacing(forSpeed: speedMps)
                )
                let plan = RouteSimulationPlan(
                    displayCoordinates: displayCoordinates,
                    distance: built.distance,
                    expectedTravelTime: built.distance / speedMps
                )
                let samples = buildPlaybackSamples(
                    from: displayCoordinates,
                    speedWays: [],
                    fallbackSpeedMetersPerSecond: speedMps
                )
                let indices = computeWaypointIndices(
                    path: displayCoordinates,
                    waypoints: built.waypointCoordinates
                )
                await MainActor.run {
                    applyReplan(
                        plan: plan,
                        samples: samples,
                        indices: indices,
                        logical: newLogical,
                        shape: newShape,
                        roads: roads,
                        hop: false
                    )
                    if built.straightLegCount > 0 {
                        alertTitle = "部分路段改用直線"
                        alertMessage = "有 \(built.straightLegCount) 段找不到道路路線，已改用直線連接。"
                        showAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    isReplanning = false
                    revertPausedSettings()
                    alertTitle = "重新規劃失敗"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    /// After an edit mid-route, the next lap of a repeating route is built afresh
    /// from the stops with the current settings.
    private func rebuildCycleForRepeat() async {
        let stops = routeSourceStops
        let shape = routeSourceShape
        let roads = routeSourceFollowRoads
        let hop = routeIsHop
        let mode = travelMode
        let speedMps = WayfarerSpeed.metersPerSecond(fromKmh: speedKmh)
        guard stops.count >= 2 else { return }

        if hop {
            let path = hopPath(stops: stops, shape: shape)
            var distance: CLLocationDistance = 0
            for (a, b) in zip(path, path.dropFirst()) {
                distance += WayfarerRouteBuilder.straightDistance(a, b)
            }
            let plan = RouteSimulationPlan(
                displayCoordinates: path,
                distance: distance,
                expectedTravelTime: max(dwellSeconds, 0) * Double(max(path.count - 1, 0))
            )
            await MainActor.run {
                applyReplan(
                    plan: plan,
                    samples: hopSamples(for: path),
                    indices: Array(path.indices),
                    logical: LogicalPlan.initial(shape: shape, count: stops.count),
                    shape: shape,
                    roads: roads,
                    hop: true
                )
                routeCycleDirty = false
            }
            return
        }

        do {
            let built = try await WayfarerRouteBuilder.build(
                stops: stops,
                shape: shape,
                mode: mode,
                followRoads: roads
            )
            let displayCoordinates = sampledRouteCoordinates(
                from: built.coordinates,
                targetDistance: WayfarerSpeed.pathSpacing(forSpeed: speedMps)
            )
            let plan = RouteSimulationPlan(
                displayCoordinates: displayCoordinates,
                distance: built.distance,
                expectedTravelTime: built.distance / speedMps
            )
            let samples = buildPlaybackSamples(
                from: displayCoordinates,
                speedWays: [],
                fallbackSpeedMetersPerSecond: speedMps
            )
            let indices = computeWaypointIndices(path: displayCoordinates, waypoints: built.waypointCoordinates)
            await MainActor.run {
                applyReplan(
                    plan: plan,
                    samples: samples,
                    indices: indices,
                    logical: LogicalPlan.initial(shape: shape, count: stops.count),
                    shape: shape,
                    roads: roads,
                    hop: false
                )
                routeCycleDirty = false
            }
        } catch {
            await MainActor.run {
                rebuildFullPlaybackSamples()
                playbackCursor = 1
                playbackGeneration += 1
                routeCycleDirty = false
            }
        }
    }

    private var pausedEditControls: some View {
        VStack(spacing: 8) {
            Text(isPlaybackPaused
                 ? "暫停中：可以調整後續路線，調整完按「繼續」。"
                 : "想調整點對點飛、連線方式、走法？先按「暫停」。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("點對點飛（逐點瞬移）", isOn: $hopMode)
                .font(.subheadline)

            if !hopMode {
                HStack(spacing: 8) {
                    Text("連線方式")
                        .font(.subheadline)
                    Picker("連線方式", selection: $followRoads) {
                        Text("直線").tag(false)
                        Text("導航").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }

            HStack(spacing: 8) {
                Text("走法")
                    .font(.subheadline)
                Picker("走法", selection: $pathShapeRaw) {
                    ForEach(RouteShape.allCases) { shape in
                        Text(shape.title).tag(shape.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            if pathShape != .oneWay {
                Toggle("重複播放（直到按停止）", isOn: $repeatRoute)
                    .font(.subheadline)
            }

            if isReplanning {
                ProgressView("重新規劃中…")
                    .font(.footnote)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(!isPlaybackPaused || isReplanning)
    }

    private func dwellChanged() {
        let clamped = min(max(dwellSeconds, 0), 3600)
        if clamped != dwellSeconds {
            dwellSeconds = clamped
            return
        }
        guard routeIsHop, !isRouteRunning, let plan = routePlan else { return }
        setRoutePlan(RouteSimulationPlan(
            displayCoordinates: plan.displayCoordinates,
            distance: plan.distance,
            expectedTravelTime: clamped * Double(max(plan.displayCoordinates.count - 1, 0))
        ))
    }

    private func panelTabChanged() {
        if panelTab == .multi {
            coordinate = nil
        } else {
            multiStops = []
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    /// A place picked from the search results, or a coordinate typed in the search bar.
    /// On the Teleport tab it teleports there at once; on the other tabs it is still
    /// used as the destination (Navigate) or added as a stop (Multi-stop).
    private func useSearchedPlace(_ target: CLLocationCoordinate2D) {
        dismissKeyboard()
        switch panelTab {
        case .teleport:
            applySelection(target)
            DispatchQueue.main.async { simulate() }
        case .navigate:
            applySelection(target)
        case .multi:
            addStop(target)
            position = .region(
                MKCoordinateRegion(
                    center: target,
                    latitudinalMeters: 1000,
                    longitudinalMeters: 1000
                )
            )
        }
    }

    private func addStop(_ stopCoordinate: CLLocationCoordinate2D) {
        guard multiStops.count < 500 else {
            alertTitle = "站點太多"
            alertMessage = "一條路線最多 500 個站點。"
            showAlert = true
            return
        }
        multiStops.append(RouteStop(coordinate: stopCoordinate))
    }

    private func navigateToPin() {
        guard let destination = coordinate,
              let start = simulationSession.coordinate else { return }
        routeStartSelection = RouteSearchSelection(title: "目前位置", coordinate: start)
        routeEndSelection = RouteSearchSelection(title: "目的地", coordinate: destination)
        coordinate = nil
        refreshRoute()
    }

    private func buildMultiStopRoute() {
        guard multiStops.count >= 2 else { return }
        if hopMode {
            buildHopRoute()
            return
        }
        if followRoads && multiStops.count > 25 {
            alertTitle = "站點太多"
            alertMessage = "沿道路規劃最多支援 25 個站點。請關閉「沿道路規劃」改用直線連接，或減少站點。"
            showAlert = true
            return
        }

        routeLoadTask?.cancel()
        routeSpeedPrefetchTask?.cancel()
        setRoutePlan(nil)
        routePlaybackSamples = []

        let requestID = UUID()
        routeRequestID = requestID
        isLoadingRoute = true
        isPrefetchingRouteSpeeds = false
        coordinate = nil

        let stopCoordinates = multiStops.map(\.coordinate)
        let shape = pathShape
        let shouldRepeat = repeatRoute && shape != .oneWay
        let mode = travelMode
        let roads = followRoads
        let speedMps = WayfarerSpeed.metersPerSecond(fromKmh: speedKmh)

        routeSourceStops = stopCoordinates
        routeSourceFollowRoads = roads
        routeSourceShape = shape
        routeIsHop = false
        routeFromMultiStop = false

        routeStartSelection = RouteSearchSelection(title: "站點 1", coordinate: stopCoordinates[0])
        let closed = shape != .oneWay
        let lastStop = closed ? stopCoordinates[0] : stopCoordinates[stopCoordinates.count - 1]
        routeEndSelection = RouteSearchSelection(
            title: closed ? "站點 1" : "站點 \(stopCoordinates.count)",
            coordinate: lastStop
        )

        routeLoadTask = Task {
            do {
                let built = try await WayfarerRouteBuilder.build(
                    stops: stopCoordinates,
                    shape: shape,
                    mode: mode,
                    followRoads: roads
                )
                guard !Task.isCancelled else { return }

                let displayCoordinates = sampledRouteCoordinates(
                    from: built.coordinates,
                    targetDistance: WayfarerSpeed.pathSpacing(forSpeed: speedMps)
                )
                let plan = RouteSimulationPlan(
                    displayCoordinates: displayCoordinates,
                    distance: built.distance,
                    expectedTravelTime: built.distance / speedMps
                )
                let samples = buildPlaybackSamples(
                    from: displayCoordinates,
                    speedWays: [],
                    fallbackSpeedMetersPerSecond: speedMps
                )

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    setRoutePlan(plan)
                    routePlaybackSamples = samples
                    repeatPlayback = shouldRepeat
                    routeLogical = LogicalPlan.initial(shape: shape, count: stopCoordinates.count)
                    routeWaypointIndices = computeWaypointIndices(
                        path: displayCoordinates,
                        waypoints: built.waypointCoordinates
                    )
                    playbackBaseOffset = 0
                    routeFromMultiStop = true
                    routeCycleDirty = false
                    isLoadingRoute = false
                    if let routePolyline {
                        position = .rect(routePolyline.boundingMapRect)
                    }
                    if built.straightLegCount > 0 {
                        alertTitle = "部分路段改用直線"
                        alertMessage = "有 \(built.straightLegCount) 段找不到道路路線，已改用直線連接。"
                        showAlert = true
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                }
            } catch {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    alertTitle = "路線規劃失敗"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    /// Switching mode only changes the speed (to that mode's default); the route
    /// and the current position are left alone.
    private func modeChanged() {
        if suppressModeSpeedReset {
            suppressModeSpeedReset = false
            return
        }
        speedKmh = travelMode.defaultSpeedKmh
    }

    private func saveRouteFavorite() {
        guard routeSourceStops.count >= 2 else { return }
        let trimmed = routeFavoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = FavoritesStore.shared.data.routes.count + 1
        let favorite = RouteFavorite(
            name: trimmed.isEmpty ? "路線 \(count)" : trimmed,
            stops: routeSourceStops.map { StopPoint(latitude: $0.latitude, longitude: $0.longitude) },
            modeRaw: travelModeRaw,
            speedKmh: speedKmh,
            shapeRaw: routeSourceShape.rawValue,
            followRoads: routeSourceFollowRoads,
            hop: routeIsHop,
            dwellSeconds: dwellSeconds
        )
        FavoritesStore.shared.addRoute(favorite)
        Task { await FavoritesStore.shared.fillMissingPlaceInfo() }
        routeFavoriteName = ""
    }

    /// Loads a favorite route into the multi-stop tab and builds it.
    private func applyRouteFavorite(_ favorite: RouteFavorite) {
        guard !isRouteRunning else { return }
        resetRouteSelection()
        coordinate = nil

        let savedMode = (TravelMode(rawValue: favorite.modeRaw) ?? .walking).rawValue
        if travelModeRaw != savedMode {
            suppressModeSpeedReset = true
            travelModeRaw = savedMode
        }
        speedKmh = favorite.speedKmh
        followRoads = favorite.followRoads
        hopMode = favorite.hop ?? false
        dwellSeconds = favorite.dwellSeconds ?? 3
        pathShapeRaw = favorite.shapeRaw
        panelTab = .multi
        multiStops = favorite.stops.map {
            RouteStop(coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
        DispatchQueue.main.async { buildMultiStopRoute() }
    }

    private func intervalChanged() {
        let clamped = min(max(updateInterval, 0.1), 5)
        if clamped != updateInterval {
            updateInterval = clamped
            return
        }
        applySpeedChange()
    }

    private func rebuildFullPlaybackSamples() {
        guard let plan = routePlan else { return }
        playbackBaseOffset = 0
        if routeIsHop {
            routePlaybackSamples = hopSamples(for: plan.displayCoordinates)
            return
        }
        routePlaybackSamples = buildPlaybackSamples(
            from: plan.displayCoordinates,
            speedWays: [],
            fallbackSpeedMetersPerSecond: WayfarerSpeed.metersPerSecond(fromKmh: speedKmh)
        )
    }

    /// Re-times the route for the current speed. While a route is playing, only the
    /// part still ahead of the current position is rebuilt.
    private func applySpeedChange() {
        let clamped = min(max(speedKmh, 1), WayfarerSpeed.maxKmh)
        if clamped != speedKmh {
            speedKmh = clamped
            return
        }
        guard !routeIsHop else { return }
        guard let plan = routePlan else { return }
        let speedMps = WayfarerSpeed.metersPerSecond(fromKmh: speedKmh)
        let base = plan.displayCoordinates
        guard base.count > 1 else { return }

        if routePlaybackTask != nil, let current = routePlaybackCoordinate {
            // Continue from where the walk really is (the nearest point would be wrong on
            // a round trip, where the way back passes the same places as the way out).
            let lastIndex = max(playbackCursor - 1, 0)
            let localIndex = routePlaybackSamples.indices.contains(lastIndex)
                ? routePlaybackSamples[lastIndex].baseIndex
                : 0
            let absoluteIndex = min(playbackBaseOffset + localIndex, base.count - 1)
            let remaining = [current] + Array(base.dropFirst(min(absoluteIndex + 1, base.count)))
            let samples = buildPlaybackSamples(
                from: remaining,
                speedWays: [],
                fallbackSpeedMetersPerSecond: speedMps
            )
            routePlaybackSamples = samples
            playbackBaseOffset = absoluteIndex
            playbackGeneration += 1
            playbackCursor = 1
        } else if !isRouteRunning {
            rebuildFullPlaybackSamples()
            setRoutePlan(RouteSimulationPlan(
                displayCoordinates: base,
                distance: plan.distance,
                expectedTravelTime: plan.distance / speedMps
            ))
        }
    }
}

// MARK: - Wayfarer: coordinate input sheets

private struct CoordinateInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    let onPlace: (CLLocationCoordinate2D) -> Void
    let onTeleport: (CLLocationCoordinate2D) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("輸入「緯度,經度」，例如 25.0330,121.5654")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("緯度,經度", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)

                Button("貼上剪貼簿") {
                    if let pasted = UIPasteboard.general.string {
                        text = pasted
                    }
                }
                .buttonStyle(.bordered)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button("只放置圖釘") { submit(teleport: false) }
                        .buttonStyle(.bordered)
                    Button("直接瞬移") { submit(teleport: true) }
                        .buttonStyle(.borderedProminent)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("輸入座標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { fieldFocused = false }
                }
            }
            .onAppear { fieldFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit(teleport: Bool) {
        guard let first = CoordinateImportParser.parseInline(text).first else {
            errorMessage = "格式不正確，請輸入「緯度,經度」。"
            return
        }
        dismiss()
        if teleport {
            onTeleport(first)
        } else {
            onPlace(first)
        }
    }
}

private struct StopListInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var editorFocused: Bool

    let onApply: ([CLLocationCoordinate2D]) -> Void

    private var parsed: [CLLocationCoordinate2D] {
        CoordinateImportParser.parseInline(text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("每行一組「緯度,經度」，例如：")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("-22.712348,-43.312467\n-22.711237,-43.312910")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .focused($editorFocused)
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.4))
                    )

                Text("已讀到 \(parsed.count) 個點")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("貼上剪貼簿") {
                        if let pasted = UIPasteboard.general.string {
                            text = pasted
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("清空") { text = "" }
                        .buttonStyle(.bordered)
                        .disabled(text.isEmpty)

                    Spacer()

                    Button("套用並建立路線") {
                        let coordinates = parsed
                        dismiss()
                        onApply(coordinates)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsed.count < 2)
                }
            }
            .padding()
            .navigationTitle("座標清單")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { editorFocused = false }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct RouteSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialStart: RouteSearchSelection?
    let initialEnd: RouteSearchSelection?
    let onApply: (RouteSearchSelection, RouteSearchSelection) -> Void

    @StateObject private var startCompleter = LocationSearchCompleter()
    @StateObject private var endCompleter = LocationSearchCompleter()
    @State private var startQuery: String
    @State private var endQuery: String
    @State private var startSelection: RouteSearchSelection?
    @State private var endSelection: RouteSearchSelection?
    @State private var isResolvingSelection = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: RouteSearchField?

    init(
        initialStart: RouteSearchSelection?,
        initialEnd: RouteSearchSelection?,
        onApply: @escaping (RouteSearchSelection, RouteSearchSelection) -> Void
    ) {
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.onApply = onApply
        _startQuery = State(initialValue: initialStart?.title ?? "")
        _endQuery = State(initialValue: initialEnd?.title ?? "")
        _startSelection = State(initialValue: initialStart)
        _endSelection = State(initialValue: initialEnd)
    }

    private var activeResults: [MKLocalSearchCompletion] {
        switch focusedField {
        case .start:
            return startCompleter.results
        case .end:
            return endCompleter.results
        case .none:
            return []
        }
    }

    private var canApply: Bool {
        startSelection != nil && endSelection != nil && !isResolvingSelection
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                routeField(
                    title: "起點",
                    icon: "circle.fill",
                    tint: .green,
                    text: $startQuery,
                    selection: startSelection,
                    field: .start
                )

                routeField(
                    title: "終點",
                    icon: "flag.checkered.circle.fill",
                    tint: .red,
                    text: $endQuery,
                    selection: endSelection,
                    field: .end
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if isResolvingSelection {
                    ProgressView("正在解析地點…")
                        .font(.footnote)
                } else if !activeResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(activeResults.enumerated()), id: \.element) { index, result in
                                Button {
                                    resolve(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if !result.subtitle.isEmpty {
                                            Text(result.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                }
                                .buttonStyle(.plain)

                                if index < activeResults.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                } else {
                    Text("請搜尋起點與終點以建立路線。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("設定路線")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("使用此路線") {
                        guard let startSelection, let endSelection else { return }
                        onApply(startSelection, endSelection)
                        dismiss()
                    }
                    .disabled(!canApply)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if startSelection == nil {
                focusedField = .start
            } else if endSelection == nil {
                focusedField = .end
            }
        }
    }

    private func routeField(
        title: String,
        icon: String,
        tint: Color,
        text: Binding<String>,
        selection: RouteSearchSelection?,
        field: RouteSearchField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)

                TextField(title, text: text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: field)
                    .submitLabel(field == .start ? .next : .done)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        errorMessage = nil
                        update(query: newValue, for: field)
                    }
                    .onSubmit {
                        if field == .start {
                            focusedField = .end
                        } else {
                            focusedField = nil
                        }
                    }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)

            if let selection {
                Text(String(format: "%.5f, %.5f", selection.coordinate.latitude, selection.coordinate.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func update(query: String, for field: RouteSearchField) {
        switch field {
        case .start:
            if query != startSelection?.title {
                startSelection = nil
            }
            startCompleter.update(query: query)
        case .end:
            if query != endSelection?.title {
                endSelection = nil
            }
            endCompleter.update(query: query)
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        let field = focusedField ?? .start
        let request = MKLocalSearch.Request(completion: completion)
        isResolvingSelection = true
        errorMessage = nil

        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                isResolvingSelection = false

                guard let item = response?.mapItems.first else {
                    errorMessage = error?.localizedDescription ?? "無法解析這個地點。"
                    return
                }

                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = name.isEmpty ? completion.title : name
                let selection = RouteSearchSelection(title: title, coordinate: item.placemark.coordinate)

                switch field {
                case .start:
                    startSelection = selection
                    startQuery = title
                    startCompleter.results = []
                    focusedField = .end
                case .end:
                    endSelection = selection
                    endQuery = title
                    endCompleter.results = []
                    focusedField = nil
                }
            }
        }
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    let onSelect: (LocationBookmark) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "沒有書籤",
                        systemImage: "bookmark.slash",
                        description: Text("在地圖上放置圖釘，再點書籤圖示即可儲存地點。")
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.name)
                                        .foregroundStyle(.primary)
                                    Text(String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: onDelete)
                    }
                }
            }
            .navigationTitle("書籤")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !bookmarks.isEmpty {
                    EditButton()
                }
            }
        }
    }
}
