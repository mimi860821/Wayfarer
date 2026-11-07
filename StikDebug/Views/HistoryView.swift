//
//  HistoryView.swift
//  Wayfarer
//
//  The last few teleports and played routes.
//

import SwiftUI
import CoreLocation

struct HistoryEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var isRoute: Bool
    /// Teleport target, or the first stop of a route.
    var latitude: Double
    var longitude: Double
    var route: RouteFavorite?
    var countryCode: String?
    var timeZoneID: String?
    var placeName: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension RouteFavorite {
    /// "5 個點 · 走路 5 公里/小時 · 直線 · 單程"
    var subtitleText: String {
        let shape = RouteShape(rawValue: shapeRaw)?.title ?? "單程"
        if hop == true {
            return "\(stops.count) 個點 · 點對點飛 · 停留 \(String(format: "%g", dwellSeconds ?? 0)) 秒 · \(shape)"
        }
        let mode = TravelMode(rawValue: modeRaw)?.title ?? "走路"
        let roads = followRoads ? "導航" : "直線"
        return "\(stops.count) 個點 · \(mode) \(String(format: "%g", speedKmh)) 公里/小時 · \(roads) · \(shape)"
    }
}

/// Keeps the 10 most recent entries in a small JSON file. Use from the main thread.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let maxEntries = 10
    private static let maxRoutePoints = 500

    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL
    private var isFillingPlaceInfo = false

    private init() {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wayfarer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")

        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: raw) {
            entries = decoded
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(entries) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    func addTeleport(_ coordinate: CLLocationCoordinate2D) {
        insert(HistoryEntry(
            isRoute: false,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ))
    }

    func addRoute(_ route: RouteFavorite) {
        guard let first = route.stops.first else { return }
        var trimmed = route

        // Very long imported tracks are thinned out so the history stays small.
        if trimmed.stops.count > Self.maxRoutePoints {
            let step = Int(ceil(Double(trimmed.stops.count) / Double(Self.maxRoutePoints)))
            var thinned = stride(from: 0, to: trimmed.stops.count, by: step).map { trimmed.stops[$0] }
            if let last = trimmed.stops.last {
                thinned.append(last)
            }
            trimmed.stops = thinned
        }

        insert(HistoryEntry(
            isRoute: true,
            latitude: first.latitude,
            longitude: first.longitude,
            route: trimmed
        ))
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func insert(_ newEntry: HistoryEntry) {
        var entry = newEntry
        if let known = PlaceCache.lookup(entry.coordinate) ?? FavoritesStore.shared.knownPlace(near: entry.coordinate) {
            entry.placeName = known.title
            entry.timeZoneID = known.timeZoneID
            entry.countryCode = known.countryCode
        }

        entries.removeAll { isDuplicate($0, entry) }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()

        Task { await self.fillMissingPlaceInfo() }
    }

    private func isDuplicate(_ a: HistoryEntry, _ b: HistoryEntry) -> Bool {
        guard a.isRoute == b.isRoute else { return false }
        if !a.isRoute {
            return WayfarerRouteBuilder.straightDistance(a.coordinate, b.coordinate) < 50
        }
        guard let ra = a.route, let rb = b.route,
              ra.stops.count == rb.stops.count,
              let af = ra.stops.first, let al = ra.stops.last,
              let bf = rb.stops.first, let bl = rb.stops.last else {
            return false
        }
        let tolerance = 0.000_001
        return abs(af.latitude - bf.latitude) < tolerance
            && abs(af.longitude - bf.longitude) < tolerance
            && abs(al.latitude - bl.latitude) < tolerance
            && abs(al.longitude - bl.longitude) < tolerance
    }

    /// Looks up the place name, country and time zone for entries that lack them.
    @MainActor
    func fillMissingPlaceInfo() async {
        guard !isFillingPlaceInfo else { return }
        isFillingPlaceInfo = true
        defer { isFillingPlaceInfo = false }

        for id in entries.filter({ $0.timeZoneID == nil || $0.placeName == nil }).map({ $0.id }) {
            guard let entry = entries.first(where: { $0.id == id }) else { continue }
            guard let info = await PlaceInfoResolver.resolve(entry.coordinate) else { return }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].countryCode = info.countryCode
                entries[index].timeZoneID = info.timeZoneID
                entries[index].placeName = info.title ?? ""
                save()
            }
            PlaceCache.store(entry.coordinate, title: info.title, timeZoneID: info.timeZoneID, countryCode: info.countryCode)
            try? await Task.sleep(for: .milliseconds(1200))
        }
    }
}

private struct SaveTarget: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = HistoryStore.shared

    let onTeleport: (CLLocationCoordinate2D) -> Void
    let onRoute: (RouteFavorite) -> Void

    @State private var savingCoordinate: SaveTarget?
    @State private var showClearConfirm = false
    @State private var showSavedMessage = false

    private static let recordedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.entries.isEmpty {
                    ContentUnavailableView(
                        "還沒有歷史記錄",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("瞬移或播放路線之後，最近 10 筆會出現在這裡。")
                    )
                } else {
                    List {
                        ForEach(store.entries) { entry in
                            row(entry)
                        }
                    }
                    .listStyle(.plain)

                    HintFooter(text: "點一下重新執行；向右滑加入收藏，向左滑刪除。最多保留最近 10 筆。")
                }
            }
            .navigationTitle("歷史記錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清除") { showClearConfirm = true }
                        .disabled(store.entries.isEmpty)
                }
            }
            .task {
                await store.fillMissingPlaceInfo()
            }
            .sheet(item: $savingCoordinate) { target in
                SaveCoordinateSheet(coordinate: target.coordinate)
            }
            .alert("清除全部歷史記錄？", isPresented: $showClearConfirm) {
                Button("清除", role: .destructive) { store.clear() }
                Button("取消", role: .cancel) { }
            }
            .alert("已加入收藏", isPresented: $showSavedMessage) {
                Button("好", role: .cancel) { }
            }
        }
        .presentationDetents([.large])
    }

    private func title(_ entry: HistoryEntry) -> String {
        let place: String
        if let name = entry.placeName, !name.isEmpty {
            place = name
        } else {
            place = String(format: "%.4f, %.4f", entry.latitude, entry.longitude)
        }
        return entry.isRoute ? "路線 · \(place)" : place
    }

    private func detail(_ entry: HistoryEntry) -> String {
        let recorded = Self.recordedFormatter.string(from: entry.date)
        if entry.isRoute, let route = entry.route {
            return "\(recorded) · \(route.subtitleText)"
        }
        return "\(recorded) · " + String(format: "%.5f, %.5f", entry.latitude, entry.longitude)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        Button {
            if entry.isRoute, let route = entry.route {
                onRoute(route)
            } else {
                onTeleport(entry.coordinate)
            }
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.isRoute ? "point.topleft.down.curvedto.point.bottomright.up" : "mappin.circle.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(entry))
                        .foregroundStyle(.primary)
                    TimelineView(.everyMinute) { context in
                        Text(TimeZoneFormat.describe(
                            countryCode: entry.countryCode,
                            timeZoneID: entry.timeZoneID,
                            at: context.date
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text(detail(entry))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                saveToFavorites(entry)
            } label: {
                Label("收藏", systemImage: "star")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.remove(entry.id)
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    private func saveToFavorites(_ entry: HistoryEntry) {
        if entry.isRoute, var route = entry.route {
            route.id = UUID()
            route.name = "\(entry.placeName?.isEmpty == false ? entry.placeName! : "路線") · \(Self.recordedFormatter.string(from: entry.date))"
            route.countryCode = entry.countryCode
            route.timeZoneID = entry.timeZoneID
            route.placeName = entry.placeName
            FavoritesStore.shared.addRoute(route)
            Task { await FavoritesStore.shared.fillMissingPlaceInfo() }
            showSavedMessage = true
        } else {
            savingCoordinate = SaveTarget(coordinate: entry.coordinate)
        }
    }
}
