//
//  FavoritesView.swift
//  Wayfarer
//
//  Favorite coordinates (with categories) and favorite routes.
//

import SwiftUI
import CoreLocation

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
}

struct FavoritesData: Codable {
    var categories: [FavoriteCategory] = []
    var coordinates: [CoordinateFavorite] = []
    var routes: [RouteFavorite] = []
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

    func categoryName(for id: UUID?) -> String {
        guard let id, let category = data.categories.first(where: { $0.id == id }) else {
            return "未分類"
        }
        return category.name
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

private enum FavoriteFilter: Hashable {
    case all
    case uncategorized
    case category(UUID)
}

struct FavoritesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FavoritesStore.shared

    @State private var section = 0
    @State private var filter: FavoriteFilter = .all
    @State private var showCategoryManager = false
    @State private var showRename = false
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
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("管理分類") { showCategoryManager = true }
                        .disabled(section != 0)
                }
            }
            .sheet(isPresented: $showCategoryManager) {
                CategoryManagerSheet()
            }
            .alert("重新命名", isPresented: $showRename) {
                TextField("名稱", text: $renameText)
                Button("儲存") { applyRename() }
                Button("取消", role: .cancel) { }
            }
        }
        .presentationDetents([.large])
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
                    ForEach(filteredCoordinates) { favorite in
                        coordinateRow(favorite)
                    }
                    Section {
                        EmptyView()
                    } footer: {
                        Text("點一下放置圖釘；向右滑可直接瞬移，向左滑刪除；長按可重新命名或移動分類。")
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func coordinateRow(_ favorite: CoordinateFavorite) -> some View {
        Button {
            onPickCoordinate(favorite)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.name)
                    .foregroundStyle(.primary)
                Text("\(store.categoryName(for: favorite.categoryID)) · "
                     + String(format: "%.5f, %.5f", favorite.latitude, favorite.longitude))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                onTeleportCoordinate(favorite)
                dismiss()
            } label: {
                Label("瞬移", systemImage: "location.fill")
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
                onTeleportCoordinate(favorite)
                dismiss()
            } label: {
                Label("直接瞬移", systemImage: "location.fill")
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
        let mode = TravelMode(rawValue: route.modeRaw)?.title ?? "走路"
        let shape = RouteShape(rawValue: route.shapeRaw)?.title ?? "單程"
        let roads = route.followRoads ? "導航" : "直線"
        return "\(route.stops.count) 個點 · \(mode) \(String(format: "%g", route.speedKmh)) 公里/小時 · \(roads) · \(shape)"
    }

    private var routesContent: some View {
        Group {
            if store.data.routes.isEmpty {
                ContentUnavailableView(
                    "沒有收藏的路線",
                    systemImage: "star.slash",
                    description: Text("建立路線後，按「收藏路線」即可儲存。")
                )
            } else {
                List {
                    ForEach(store.data.routes) { route in
                        Button {
                            onPickRoute(route)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.name)
                                    .foregroundStyle(.primary)
                                Text(routeSubtitle(route))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                    Section {
                        EmptyView()
                    } footer: {
                        Text("點一下載入並建立路線；向左滑刪除；長按可重新命名。")
                    }
                }
                .listStyle(.plain)
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
                Section {
                    EmptyView()
                } footer: {
                    Text("點分類可重新命名；向左滑刪除（裡面的座標會變成「未分類」，不會被刪掉）。")
                }
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
        dismiss()
    }
}
