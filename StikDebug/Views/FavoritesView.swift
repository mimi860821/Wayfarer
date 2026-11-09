//
//  FavoritesView.swift
//  Wayfarer
//
//  Favorite coordinates (with categories) and favorite routes.
//

import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

// MARK: - Models

struct FavoriteCategory: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
}

struct CoordinateFavorite: Identifiable, Codable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var categoryID: UUID?
    var countryCode: String?
    var timeZoneID: String?
    /// Place name saved with the favorite so it can be shown offline.
    var placeName: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct StopPoint: Codable {
    var latitude: Double
    var longitude: Double
}

struct RouteFavorite: Identifiable, Codable {
    var id = UUID()
    var name: String
    var stops: [StopPoint]
    var modeRaw: String
    var speedKmh: Double
    var shapeRaw: String
    var followRoads: Bool
    var createdAt = Date()
    /// Point-to-point mode: jump to each stop and wait `dwellSeconds`.
    var hop: Bool?
    var dwellSeconds: Double?
    var countryCode: String?
    var timeZoneID: String?
    var placeName: String?
}

struct FavoritesData: Codable {
    var categories: [FavoriteCategory] = []
    var coordinates: [CoordinateFavorite] = []
    var routes: [RouteFavorite] = []
}

// MARK: - Bookmark file import (LocWarp format)

private struct LocWarpCategory: Decodable {
    let id: String
    let name: String
    let sort_order: Int?
}

private struct LocWarpBookmark: Decodable {
    let name: String?
    let lat: Double?
    let lng: Double?
    let category_id: String?
    let created_at: String?
    let country_code: String?
}

private struct LocWarpFile: Decodable {
    let categories: [LocWarpCategory]?
    let bookmarks: [LocWarpBookmark]
}

struct BookmarkImportSummary {
    var added = 0
    var skipped = 0
    var categoriesAdded = 0
}

// MARK: - Store

/// Persists favorites as a JSON file in Application Support. Use from the main thread.
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var data = FavoritesData()
    private let fileURL: URL

    private init() {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wayfarer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("favorites.json")

        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(FavoritesData.self, from: raw) {
            data = decoded
        } else if let legacyData = UserDefaults.standard.data(forKey: "locationBookmarks"),
                  let legacy = try? JSONDecoder().decode([LocationBookmark].self, from: legacyData) {
            // Bring over bookmarks saved by the original app.
            data.coordinates = legacy.map {
                CoordinateFavorite(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, categoryID: nil)
            }
            save()
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    private var isFillingPlaceInfo = false

    /// Looks up country and time zone for favorites that do not have them yet
    /// (a route uses its first stop). One request at a time to respect rate limits.
    @MainActor
    func fillMissingPlaceInfo() async {
        guard !isFillingPlaceInfo else { return }
        isFillingPlaceInfo = true
        defer { isFillingPlaceInfo = false }

        for id in data.coordinates.filter({ $0.timeZoneID == nil || $0.placeName == nil }).map({ $0.id }) {
            guard let item = data.coordinates.first(where: { $0.id == id }) else { continue }
            guard let info = await PlaceInfoResolver.resolve(item.coordinate) else { return }
            if let index = data.coordinates.firstIndex(where: { $0.id == id }) {
                data.coordinates[index].countryCode = info.countryCode
                data.coordinates[index].timeZoneID = info.timeZoneID
                data.coordinates[index].placeName = info.title ?? ""
                save()
            }
            PlaceCache.store(item.coordinate, title: info.title, timeZoneID: info.timeZoneID, countryCode: info.countryCode)
            try? await Task.sleep(for: .milliseconds(1200))
        }

        for id in data.routes.filter({ $0.timeZoneID == nil || $0.placeName == nil }).map({ $0.id }) {
            guard let route = data.routes.first(where: { $0.id == id }),
                  let first = route.stops.first else { continue }
            let start = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
            guard let info = await PlaceInfoResolver.resolve(start) else { return }
            if let index = data.routes.firstIndex(where: { $0.id == id }) {
                data.routes[index].countryCode = info.countryCode
                data.routes[index].timeZoneID = info.timeZoneID
                data.routes[index].placeName = info.title ?? ""
                save()
            }
            PlaceCache.store(start, title: info.title, timeZoneID: info.timeZoneID, countryCode: info.countryCode)
            try? await Task.sleep(for: .milliseconds(1200))
        }
    }

    /// A saved favorite within 500 m whose name is stored (works offline).
    func knownPlace(near coordinate: CLLocationCoordinate2D) -> KnownPlace? {
        for favorite in data.coordinates {
            guard let name = favorite.placeName, !name.isEmpty else { continue }
            if WayfarerRouteBuilder.straightDistance(favorite.coordinate, coordinate) < 500 {
                return KnownPlace(title: name, timeZoneID: favorite.timeZoneID, countryCode: favorite.countryCode)
            }
        }
        return nil
    }

    func categoryName(for id: UUID?) -> String {
        guard let id, let category = data.categories.first(where: { $0.id == id }) else {
            return "未分類"
        }
        return category.name
    }

    /// Imports a bookmarks file exported by LocWarp (categories plus bookmarks).
    /// Already present favorites (same name and coordinate) are skipped.
    func importLocWarpBookmarks(_ raw: Data) throws -> BookmarkImportSummary {
        let file = try JSONDecoder().decode(LocWarpFile.self, from: raw)
        var summary = BookmarkImportSummary()

        var categoryMap: [String: UUID] = [:]
        let categories = (file.categories ?? []).sorted { ($0.sort_order ?? 0) < ($1.sort_order ?? 0) }
        for category in categories {
            let before = data.categories.count
            if let id = addCategory(category.name) {
                categoryMap[category.id] = id
                if data.categories.count > before {
                    summary.categoriesAdded += 1
                }
            }
        }

        // Oldest first, so the "added" order matches the original file.
        let bookmarks = file.bookmarks.sorted { ($0.created_at ?? "") < ($1.created_at ?? "") }
        for bookmark in bookmarks {
            guard let latitude = bookmark.lat, let longitude = bookmark.lng,
                  abs(latitude) <= 90, abs(longitude) <= 180 else {
                summary.skipped += 1
                continue
            }

            let name = (bookmark.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = name.isEmpty ? String(format: "%.4f, %.4f", latitude, longitude) : name
            let exists = data.coordinates.contains {
                abs($0.latitude - latitude) < 0.000_001
                    && abs($0.longitude - longitude) < 0.000_001
                    && $0.name == finalName
            }
            if exists {
                summary.skipped += 1
                continue
            }

            var favorite = CoordinateFavorite(
                name: finalName,
                latitude: latitude,
                longitude: longitude,
                categoryID: bookmark.category_id.flatMap { categoryMap[$0] }
            )
            let code = (bookmark.country_code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                favorite.countryCode = code.uppercased()
            }
            data.coordinates.append(favorite)
            summary.added += 1
        }

        save()
        return summary
    }

    // Categories

    @discardableResult
    func addCategory(_ name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = data.categories.first(where: { $0.name == trimmed }) {
            return existing.id
        }
        let category = FavoriteCategory(name: trimmed)
        data.categories.append(category)
        save()
        return category.id
    }

    func renameCategory(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = data.categories.firstIndex(where: { $0.id == id }) else { return }
        data.categories[index].name = trimmed
        save()
    }

    func deleteCategory(_ id: UUID) {
        data.categories.removeAll { $0.id == id }
        for index in data.coordinates.indices where data.coordinates[index].categoryID == id {
            data.coordinates[index].categoryID = nil
        }
        save()
    }

    // Coordinates

    func addCoordinate(name: String, coordinate: CLLocationCoordinate2D, categoryID: UUID?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
            ? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
            : trimmed
        data.coordinates.append(
            CoordinateFavorite(
                name: finalName,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                categoryID: categoryID
            )
        )
        save()
    }

    func renameCoordinate(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = data.coordinates.firstIndex(where: { $0.id == id }) else { return }
        data.coordinates[index].name = trimmed
        save()
    }

    func moveCoordinate(_ id: UUID, to categoryID: UUID?) {
        guard let index = data.coordinates.firstIndex(where: { $0.id == id }) else { return }
        data.coordinates[index].categoryID = categoryID
        save()
    }

    func moveCoordinates(_ ids: Set<UUID>, to categoryID: UUID?) {
        for index in data.coordinates.indices where ids.contains(data.coordinates[index].id) {
            data.coordinates[index].categoryID = categoryID
        }
        save()
    }

    func deleteCoordinate(_ id: UUID) {
        data.coordinates.removeAll { $0.id == id }
        save()
    }

    // Routes

    func addRoute(_ route: RouteFavorite) {
        data.routes.append(route)
        save()
    }

    func renameRoute(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = data.routes.firstIndex(where: { $0.id == id }) else { return }
        data.routes[index].name = trimmed
        save()
    }

    func deleteRoute(_ id: UUID) {
        data.routes.removeAll { $0.id == id }
        save()
    }
}

// MARK: - Favorites list

private enum FavoriteSort: String, CaseIterable, Identifiable {
    case addedNewest
    case addedOldest
    case nameAscending
    case nameDescending
    case zoneEastToWest
    case zoneWestToEast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addedNewest: return "加入時間（新→舊）"
        case .addedOldest: return "加入時間（舊→新）"
        case .nameAscending: return "名稱（A→Z）"
        case .nameDescending: return "名稱（Z→A）"
        case .zoneEastToWest: return "時區（東→西）"
        case .zoneWestToEast: return "時區（西→東）"
        }
    }

    /// Sorts items given in the order they were added.
    func sorted<T>(_ items: [T], name: (T) -> String, zoneID: (T) -> String?) -> [T] {
        switch self {
        case .addedOldest:
            return items
        case .addedNewest:
            return Array(items.reversed())
        case .nameAscending:
            return items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case .nameDescending:
            return items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedDescending }
        case .zoneEastToWest:
            return items.sorted { lhs, rhs in
                let a = TimeZoneFormat.offsetSeconds(id: zoneID(lhs)) ?? Int.min
                let b = TimeZoneFormat.offsetSeconds(id: zoneID(rhs)) ?? Int.min
                if a != b { return a > b }
                return name(lhs).localizedStandardCompare(name(rhs)) == .orderedAscending
            }
        case .zoneWestToEast:
            return items.sorted { lhs, rhs in
                let a = TimeZoneFormat.offsetSeconds(id: zoneID(lhs)) ?? Int.max
                let b = TimeZoneFormat.offsetSeconds(id: zoneID(rhs)) ?? Int.max
                if a != b { return a < b }
                return name(lhs).localizedStandardCompare(name(rhs)) == .orderedAscending
            }
        }
    }
}

/// Small usage hint shown under a list, styled differently from the list rows.
struct HintFooter: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.caption2)
        } icon: {
            Image(systemName: "lightbulb")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

private enum FavoriteFilter: Hashable {
    case all
    case uncategorized
    case category(UUID)
}

struct FavoritesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FavoritesStore.shared

    @AppStorage("wayfarer.favSort") private var sortRaw = FavoriteSort.addedNewest.rawValue
    @State private var section = 0
    @State private var filter: FavoriteFilter = .all
    @State private var showCategoryManager = false
    @State private var showRename = false
    @State private var showImporter = false
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var importMessage: String?
    @State private var renameText = ""
    @State private var renamingCoordinateID: UUID?
    @State private var renamingRouteID: UUID?

    let onPickCoordinate: (CoordinateFavorite) -> Void
    let onTeleportCoordinate: (CoordinateFavorite) -> Void
    let onPickRoute: (RouteFavorite) -> Void

    private var filteredCoordinates: [CoordinateFavorite] {
        switch filter {
        case .all:
            return store.data.coordinates
        case .uncategorized:
            return store.data.coordinates.filter { $0.categoryID == nil }
        case .category(let id):
            return store.data.coordinates.filter { $0.categoryID == id }
        }
    }

    private var sort: FavoriteSort {
        FavoriteSort(rawValue: sortRaw) ?? .addedNewest
    }

    private var sortedCoordinates: [CoordinateFavorite] {
        sort.sorted(filteredCoordinates, name: { $0.name }, zoneID: { $0.timeZoneID })
    }

    private var sortedRoutes: [RouteFavorite] {
        sort.sorted(store.data.routes, name: { $0.name }, zoneID: { $0.timeZoneID })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("類型", selection: $section) {
                    Text("座標").tag(0)
                    Text("路線").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if section == 0 {
                    coordinatesContent
                } else {
                    routesContent
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting && section == 0 {
                    selectionBar
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(selecting ? "完成" : "選取") {
                        selecting.toggle()
                        selectedIDs = []
                    }
                    .disabled(section != 0)

                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("匯入收藏檔")

                    Menu {
                        Picker("排序", selection: $sortRaw) {
                            ForEach(FavoriteSort.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                    } label: {
                        Label("排序", systemImage: "arrow.up.arrow.down")
                    }

                    Button("分類") { showCategoryManager = true }
                        .disabled(section != 0)
                }
            }
            .task {
                await store.fillMissingPlaceInfo()
            }
            .onChange(of: section) { _, _ in
                selecting = false
                selectedIDs = []
            }
            .onChange(of: filter) { _, _ in
                selectedIDs = []
            }
            .sheet(isPresented: $showCategoryManager) {
                CategoryManagerSheet()
            }
            .alert("重新命名", isPresented: $showRename) {
                TextField("名稱", text: $renameText)
                Button("儲存") { applyRename() }
                Button("取消", role: .cancel) { }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, .plainText, .data],
                allowsMultipleSelection: false
            ) { result in
                importBookmarkFile(result)
            }
            .alert(
                "匯入收藏",
                isPresented: Binding(
                    get: { importMessage != nil },
                    set: { if !$0 { importMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) { }
            } message: {
                Text(importMessage ?? "")
            }
        }
        .presentationDetents([.large])
    }

    private func importBookmarkFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                let summary = try store.importLocWarpBookmarks(data)
                section = 0
                filter = .all
                importMessage = "已匯入 \(summary.added) 筆座標、新增 \(summary.categoriesAdded) 個分類。"
                    + (summary.skipped > 0 ? "\n略過 \(summary.skipped) 筆（已存在或座標無效）。" : "")
                    + "\n地名、國家與時區會在背景補查，需要一點時間。"
                Task { await store.fillMissingPlaceInfo() }
            } catch {
                importMessage = "無法讀取這個檔案，請確認是收藏匯出的 JSON 檔。"
            }
        case .failure:
            importMessage = "無法開啟檔案。"
        }
    }

    private func applyRename() {
        if let id = renamingCoordinateID {
            store.renameCoordinate(id, to: renameText)
        } else if let id = renamingRouteID {
            store.renameRoute(id, to: renameText)
        }
        renamingCoordinateID = nil
        renamingRouteID = nil
    }

    // MARK: Coordinates

    private func chip(_ title: String, _ value: FavoriteFilter) -> some View {
        Button {
            filter = value
        } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(filter == value ? Color.accentColor : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(filter == value ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var coordinatesContent: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("全部", .all)
                    chip("未分類", .uncategorized)
                    ForEach(store.data.categories) { category in
                        chip(category.name, .category(category.id))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if filteredCoordinates.isEmpty {
                ContentUnavailableView(
                    "沒有收藏的座標",
                    systemImage: "star.slash",
                    description: Text("在地圖上放置圖釘，再按圖釘旁的書籤圖示即可收藏。")
                )
            } else {
                List {
                    ForEach(sortedCoordinates) { favorite in
                        coordinateRow(favorite)
                    }
                }
                .listStyle(.plain)

                HintFooter(text: selecting
                           ? "點一下勾選項目，再按下方「移動到分類」。"
                           : "點一下直接瞬移；向右滑只放置圖釘，向左滑刪除；長按可重新命名或移動分類。")
            }
        }
    }

    @ViewBuilder
    private func coordinateRow(_ favorite: CoordinateFavorite) -> some View {
        if selecting {
            selectableRow(favorite)
        } else {
            normalRow(favorite)
        }
    }

    private func rowText(_ favorite: CoordinateFavorite) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(favorite.name)
                .foregroundStyle(.primary)
            TimelineView(.everyMinute) { context in
                Text(TimeZoneFormat.describe(
                    countryCode: favorite.countryCode,
                    timeZoneID: favorite.timeZoneID,
                    at: context.date
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text("\(store.categoryName(for: favorite.categoryID)) · "
                 + String(format: "%.5f, %.5f", favorite.latitude, favorite.longitude))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func selectableRow(_ favorite: CoordinateFavorite) -> some View {
        let isSelected = selectedIDs.contains(favorite.id)
        return Button {
            if isSelected {
                selectedIDs.remove(favorite.id)
            } else {
                selectedIDs.insert(favorite.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                rowText(favorite)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var allSelected: Bool {
        !sortedCoordinates.isEmpty && sortedCoordinates.allSatisfy { selectedIDs.contains($0.id) }
    }

    private func toggleSelectAll() {
        if allSelected {
            selectedIDs = []
        } else {
            selectedIDs = Set(sortedCoordinates.map { $0.id })
        }
    }

    private func moveSelected(to categoryID: UUID?) {
        guard !selectedIDs.isEmpty else { return }
        store.moveCoordinates(selectedIDs, to: categoryID)
        selectedIDs = []
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button(allSelected ? "取消全選" : "全選") {
                toggleSelectAll()
            }

            Spacer()

            Text("已選 \(selectedIDs.count) 項")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Button("未分類") {
                    moveSelected(to: nil)
                }
                ForEach(store.data.categories) { category in
                    Button(category.name) {
                        moveSelected(to: category.id)
                    }
                }
            } label: {
                Label("移動到分類", systemImage: "folder")
            }
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func normalRow(_ favorite: CoordinateFavorite) -> some View {
        Button {
            onTeleportCoordinate(favorite)
            dismiss()
        } label: {
            rowText(favorite)
        }
        .swipeActions(edge: .leading) {
            Button {
                onPickCoordinate(favorite)
                dismiss()
            } label: {
                Label("放置圖釘", systemImage: "mappin")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.deleteCoordinate(favorite.id)
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                onPickCoordinate(favorite)
                dismiss()
            } label: {
                Label("只放置圖釘（不瞬移）", systemImage: "mappin")
            }

            Button {
                renamingRouteID = nil
                renamingCoordinateID = favorite.id
                renameText = favorite.name
                showRename = true
            } label: {
                Label("重新命名", systemImage: "pencil")
            }

            Menu {
                Button("未分類") {
                    store.moveCoordinate(favorite.id, to: nil)
                }
                ForEach(store.data.categories) { category in
                    Button(category.name) {
                        store.moveCoordinate(favorite.id, to: category.id)
                    }
                }
            } label: {
                Label("移動到分類", systemImage: "folder")
            }

            Button(role: .destructive) {
                store.deleteCoordinate(favorite.id)
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    // MARK: Routes

    private func routeSubtitle(_ route: RouteFavorite) -> String {
        let shape = RouteShape(rawValue: route.shapeRaw)?.title ?? "單程"
        if route.hop == true {
            return "\(route.stops.count) 個點 · 點對點飛 · 停留 \(String(format: "%g", route.dwellSeconds ?? 0)) 秒 · \(shape)"
        }
        let mode = TravelMode(rawValue: route.modeRaw)?.title ?? "走路"
        let roads = route.followRoads ? "導航" : "直線"
        return "\(route.stops.count) 個點 · \(mode) \(String(format: "%g", route.speedKmh)) 公里/小時 · \(roads) · \(shape)"
    }

    private var routesContent: some View {
        VStack(spacing: 0) {
            if store.data.routes.isEmpty {
                ContentUnavailableView(
                    "沒有收藏的路線",
                    systemImage: "star.slash",
                    description: Text("建立路線後，按「收藏路線」即可儲存。")
                )
            } else {
                List {
                    ForEach(sortedRoutes) { route in
                        Button {
                            onPickRoute(route)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.name)
                                    .foregroundStyle(.primary)
                                TimelineView(.everyMinute) { context in
                                    Text("起點：" + TimeZoneFormat.describe(
                                        countryCode: route.countryCode,
                                        timeZoneID: route.timeZoneID,
                                        at: context.date
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Text(routeSubtitle(route))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteRoute(route.id)
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                renamingCoordinateID = nil
                                renamingRouteID = route.id
                                renameText = route.name
                                showRename = true
                            } label: {
                                Label("重新命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.deleteRoute(route.id)
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)

                HintFooter(text: "點一下載入並建立路線；向左滑刪除；長按可重新命名。")
            }
        }
    }
}

// MARK: - Category manager

private struct CategoryManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FavoritesStore.shared

    @State private var showNameAlert = false
    @State private var nameText = ""
    @State private var editingID: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            List {
                if store.data.categories.isEmpty {
                    Text("還沒有分類，按右上角「新增」建立。")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.data.categories) { category in
                    Button {
                        editingID = category.id
                        nameText = category.name
                        showNameAlert = true
                    } label: {
                        HStack {
                            Text(category.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(store.data.coordinates.filter { $0.categoryID == category.id }.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.deleteCategory(category.id)
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                }
            }

            HintFooter(text: "點分類可重新命名；向左滑刪除（裡面的座標會變成「未分類」，不會被刪掉）。")
            }
            .navigationTitle("管理分類")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新增") {
                        editingID = nil
                        nameText = ""
                        showNameAlert = true
                    }
                }
            }
            .alert(editingID == nil ? "新增分類" : "重新命名分類", isPresented: $showNameAlert) {
                TextField("分類名稱", text: $nameText)
                Button("儲存") {
                    if let editingID {
                        store.renameCategory(editingID, to: nameText)
                    } else {
                        store.addCategory(nameText)
                    }
                    editingID = nil
                }
                Button("取消", role: .cancel) {
                    editingID = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Save coordinate

struct SaveCoordinateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FavoritesStore.shared

    let coordinate: CLLocationCoordinate2D

    @State private var name = ""
    @State private var categoryID: UUID?
    @State private var newCategory = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("座標") {
                    Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                        .font(.footnote.monospaced())
                }

                Section("名稱") {
                    TextField("例如：公園入口", text: $name)
                }

                Section("分類") {
                    Picker("分類", selection: $categoryID) {
                        Text("未分類").tag(UUID?.none)
                        ForEach(store.data.categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    TextField("或建立新分類（選填）", text: $newCategory)
                }
            }
            .navigationTitle("收藏座標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("儲存") { save() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        var finalCategory = categoryID
        if let created = store.addCategory(newCategory) {
            finalCategory = created
        }
        store.addCoordinate(name: name, coordinate: coordinate, categoryID: finalCategory)
        Task { await FavoritesStore.shared.fillMissingPlaceInfo() }
        dismiss()
    }
}
