//
//  AppFeature.swift
//  StikDebug
//

import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable {
    case home
    case scripts
    case tools
    case console
    case deviceInfo = "deviceinfo"
    case profiles
    case processes
    case launchApps = "launchapps"
    case location
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .home:
            return "JIT"
        case .scripts:
            return "腳本"
        case .tools:
            return "工具"
        case .console:
            return "主控台"
        case .deviceInfo:
            return "裝置資訊"
        case .profiles:
            return "App 到期日"
        case .launchApps:
            return "啟動 App"
        case .processes:
            return "處理程序"
        case .location:
            return "定位"
        case .settings:
            return "設定"
        }
    }

    var detail: String {
        switch self {
        case .home:
            return "為已安裝的 App 啟用 JIT"
        case .scripts:
            return "管理並執行 JS 腳本"
        case .tools:
            return "更多工具"
        case .console:
            return "裝置即時記錄"
        case .deviceInfo:
            return "檢視裝置詳細資訊"
        case .profiles:
            return "查看 App 到期日"
        case .launchApps:
            return "不啟用 JIT 直接啟動已安裝的 App"
        case .processes:
            return "檢視執行中的 App"
        case .location:
            return "模擬 GPS 定位"
        case .settings:
            return "設定 iKiwi"
        }
    }

    var toolTitle: String {
        switch self {
        case .location:
            return "定位模擬"
        default:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "bolt.fill"
        case .scripts:
            return "scroll"
        case .tools:
            return "wrench.and.screwdriver"
        case .console:
            return "terminal"
        case .deviceInfo:
            return "iphone.and.arrow.forward"
        case .profiles:
            return "calendar.badge.clock"
        case .launchApps:
            return "square.grid.2x2"
        case .processes:
            return "rectangle.stack.person.crop"
        case .location:
            return "location"
        case .settings:
            return "gearshape.fill"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .home:
            HomeView()
        case .scripts:
            ScriptListView()
        case .tools:
            ToolsView()
        case .console:
            ConsoleLogsView()
        case .deviceInfo:
            DeviceInfoView()
        case .profiles:
            ProfileView()
        case .launchApps:
            InstalledAppsListView(onSelectApp: { _, _ in }, showDoneButton: false, mode: .launch)
        case .processes:
            ProcessInspectorView()
        case .location:
            LocationSimulationView()
        case .settings:
            SettingsView()
        }
    }
}

extension AppFeature {
    static let mainTabs: [AppFeature] = [.home, .tools, .settings]
    static let toolList: [AppFeature] = [.launchApps, .scripts, .console, .deviceInfo, .profiles, .processes, .location]
}
