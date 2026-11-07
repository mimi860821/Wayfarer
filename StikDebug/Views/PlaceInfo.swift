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

    static func offsetSeconds(id: String?) -> Int? {
        guard let id, let zone = timeZone(from: id) else { return nil }
        return zone.secondsFromGMT()
    }

    static func countryName(code: String?) -> String? {
        guard let code else { return nil }
        return Locale(identifier: "zh_TW").localizedString(forRegionCode: code)
    }

    /// "日本 · UTC+9 · Asia/Tokyo", or a waiting message while it is unknown.
    static func describe(countryCode: String?, timeZoneID: String?) -> String {
        var parts: [String] = []
        if let name = countryName(code: countryCode) {
            parts.append(name)
        }
        if let id = timeZoneID, let zone = timeZone(from: id) {
            parts.append(offsetLabel(zone))
            if zone.identifier.contains("/") {
                parts.append(zone.identifier)
            }
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
            if let id = info.timeZoneID, let zone = TimeZoneFormat.timeZone(from: id) {
                timeZone = zone
            }
            let parts = [info.locality, info.countryName].compactMap { $0 }
            title = parts.isEmpty
                ? String(format: "%.2f, %.2f", coordinate.latitude, coordinate.longitude)
                : parts.joined(separator: "，")
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
