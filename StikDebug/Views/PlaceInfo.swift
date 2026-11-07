//
//  PlaceInfo.swift
//  Wayfarer
//
//  Reverse geocoding (place name, country, time zone), time zone formatting,
//  and the live place/time card shown on the map.
//

import SwiftUI
import CoreLocation

struct PlaceInfo {
    var countryCode: String?
    var timeZoneID: String?
    var locality: String?
    var countryName: String?

    /// "Tokyo，日本"; nil when the place has no name (open ocean).
    var title: String? {
        let parts = [locality, countryName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }
}

/// A place name and time zone that can be shown without a network lookup.
struct KnownPlace: Codable {
    var title: String
    var timeZoneID: String?
}

/// Remembers looked-up place names on the phone (about 1 km resolution), so the
/// map card still works offline for areas seen before.
enum PlaceCache {
    private static let key = "wayfarer.placeCache"
    private static let maxEntries = 400

    private static func cellKey(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    private static func load() -> [String: KnownPlace] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: KnownPlace].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func lookup(_ coordinate: CLLocationCoordinate2D) -> KnownPlace? {
        load()[cellKey(coordinate)]
    }

    static func store(_ coordinate: CLLocationCoordinate2D, title: String?, timeZoneID: String?) {
        guard let title else { return }
        var entries = load()
        if entries.count >= maxEntries {
            for staleKey in entries.keys.prefix(maxEntries / 4) {
                entries.removeValue(forKey: staleKey)
            }
        }
        entries[cellKey(coordinate)] = KnownPlace(title: title, timeZoneID: timeZoneID)
        if let encoded = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}

enum TimeZoneFormat {
    /// Accepts normal identifiers ("Asia/Tokyo") and fixed offsets ("GMT+9", "UTC-3:30").
    static func timeZone(from id: String) -> TimeZone? {
        if let zone = TimeZone(identifier: id) { return zone }

        let pattern = #"^(?:GMT|UTC)([+-])(\d{1,2})(?::?(\d{2}))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: id).map { String(id[$0]) }
        }
        guard let sign = group(1), let hours = Int(group(2) ?? "") else { return nil }
        let minutes = Int(group(3) ?? "0") ?? 0
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// Rough zone from longitude, used until a real one is known.
    static func approximate(longitude: Double) -> TimeZone {
        let hours = Int((longitude / 15).rounded())
        return TimeZone(secondsFromGMT: hours * 3600) ?? .current
    }

    static func offsetLabel(_ zone: TimeZone, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if minutes == 0 {
            return "UTC\(sign)\(hours)"
        }
        return "UTC\(sign)\(hours):" + String(format: "%02d", minutes)
    }

    /// "+9", "-3", "+5:30"
    static func shortOffsetLabel(_ zone: TimeZone, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if minutes == 0 {
            return "\(sign)\(hours)"
        }
        return "\(sign)\(hours):" + String(format: "%02d", minutes)
    }

    static func offsetSeconds(id: String?) -> Int? {
        guard let id, let zone = timeZone(from: id) else { return nil }
        return zone.secondsFromGMT()
    }

    static func countryName(code: String?) -> String? {
        guard let code else { return nil }
        return Locale(identifier: "zh_TW").localizedString(forRegionCode: code)
    }

    /// "日本 · +9", or a waiting message while it is unknown.
    static func describe(countryCode: String?, timeZoneID: String?) -> String {
        var parts: [String] = []
        if let name = countryName(code: countryCode) {
            parts.append(name)
        }
        if let id = timeZoneID, let zone = timeZone(from: id) {
            parts.append(shortOffsetLabel(zone))
        }
        return parts.isEmpty ? "國家與時區：查詢中…" : parts.joined(separator: " · ")
    }
}

enum PlaceInfoResolver {
    /// Returns nil only when the lookup itself failed (offline, throttled).
    static func resolve(_ coordinate: CLLocationCoordinate2D) async -> PlaceInfo? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else {
                // Open ocean and similar: no place, but still give a usable zone.
                let zone = TimeZoneFormat.approximate(longitude: coordinate.longitude)
                return PlaceInfo(countryCode: nil, timeZoneID: zone.identifier, locality: nil, countryName: nil)
            }
            let zoneID = placemark.timeZone?.identifier
                ?? TimeZoneFormat.approximate(longitude: coordinate.longitude).identifier
            return PlaceInfo(
                countryCode: placemark.isoCountryCode,
                timeZoneID: zoneID,
                locality: placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea ?? placemark.name,
                countryName: placemark.country ?? placemark.ocean
            )
        } catch {
            return nil
        }
    }
}

/// Place name and time zone of the position currently shown on the map.
@MainActor
final class LocationInfoModel: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var timeZone: TimeZone = .current

    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastDate = Date.distantPast
    private var inFlight = false

    func update(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else {
            title = ""
            lastCoordinate = nil
            return
        }

        // Names saved with favorites or remembered earlier need no network.
        if let known = FavoritesStore.shared.knownPlace(near: coordinate) ?? PlaceCache.lookup(coordinate) {
            show(known)
            lastCoordinate = coordinate
            return
        }

        let moved = lastCoordinate.map { WayfarerRouteBuilder.straightDistance($0, coordinate) } ?? .infinity
        // Geocoder requests are rate limited: skip small moves and frequent repeats.
        if moved < 2000 && Date().timeIntervalSince(lastDate) < 30 { return }
        if inFlight { return }

        if moved > 100_000 {
            timeZone = TimeZoneFormat.approximate(longitude: coordinate.longitude)
            title = String(format: "%.2f, %.2f", coordinate.latitude, coordinate.longitude)
        }

        inFlight = true
        lastCoordinate = coordinate
        lastDate = Date()

        Task {
            let info = await PlaceInfoResolver.resolve(coordinate)
            inFlight = false
            guard let info else { return }
            PlaceCache.store(coordinate, title: info.title, timeZoneID: info.timeZoneID)
            if let id = info.timeZoneID, let zone = TimeZoneFormat.timeZone(from: id) {
                timeZone = zone
            }
            title = info.title ?? String(format: "%.2f, %.2f", coordinate.latitude, coordinate.longitude)
        }
    }

    private func show(_ place: KnownPlace) {
        if title != place.title {
            title = place.title
        }
        if let id = place.timeZoneID, let zone = TimeZoneFormat.timeZone(from: id), zone != timeZone {
            timeZone = zone
        }
    }
}

struct LocationInfoCard: View {
    @ObservedObject var model: LocationInfoModel

    private static func format(_ pattern: String, _ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title.isEmpty ? "定位中…" : model.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.format("HH:mm:ss", context.date, model.timeZone))
                        .font(.title3.monospacedDigit().weight(.medium))
                    Text("\(Self.format("M/d EEE", context.date, model.timeZone)) · \(TimeZoneFormat.offsetLabel(model.timeZone, at: context.date))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: 220, alignment: .leading)
    }
}

/// Compass for the top right of the map; tapping it turns the map back to north.
struct WayfarerCompassButton: View {
    let heading: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.regularMaterial)
                Image(systemName: "location.north.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.red)
                    .rotationEffect(.degrees(-heading))
            }
            .frame(width: 44, height: 44)
            .overlay(Circle().stroke(Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("指北針，點一下把地圖轉回正北")
    }
}
