//
//  UpdateChecker.swift
//  iKiwi
//
//  Looks for a newer build on GitHub and hands the download to SideStore.
//  (An app cannot replace itself on iOS; installing needs SideStore's signing.)
//

import SwiftUI
import UIKit

struct AppUpdateInfo: Identifiable {
    let build: Int
    let tag: String
    let ipaURL: URL
    let pageURL: URL

    var id: Int { build }
}

enum UpdateCheckResult {
    case available(AppUpdateInfo)
    case upToDate
    case failed(String)
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    let tag_name: String
    let html_url: String
    let draft: Bool
    let assets: [Asset]
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repository = "mimi860821/iKiwi"
    static let sourceURL = "https://github.com/\(repository)/releases/latest/download/source.json"
    private static let skippedKey = "wayfarer.skippedUpdateBuild"

    /// Set when a newer build is found; the main screen asks about it.
    @Published var available: AppUpdateInfo?
    @Published private(set) var isChecking = false

    private var didCheckAtLaunch = false

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    func checkAtLaunch() {
        guard !didCheckAtLaunch else { return }
        didCheckAtLaunch = true
        Task { _ = await check(manual: false) }
    }

    /// `manual` checks ignore "skip this version" and always report back.
    @discardableResult
    func check(manual: Bool) async -> UpdateCheckResult {
        isChecking = true
        defer { isChecking = false }

        do {
            guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=1") else {
                return .failed("網址格式錯誤。")
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed("GitHub 暫時沒有回應，請稍後再試。")
            }

            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            guard let latest = releases.first(where: { !$0.draft }),
                  let build = Int(latest.tag_name.replacingOccurrences(of: "build-", with: "")),
                  let asset = latest.assets.first(where: { $0.name.hasSuffix(".ipa") }),
                  let ipaURL = URL(string: asset.browser_download_url),
                  let pageURL = URL(string: latest.html_url) else {
                return .failed("讀不到版本資訊。")
            }

            guard build > currentBuild else { return .upToDate }

            let info = AppUpdateInfo(build: build, tag: latest.tag_name, ipaURL: ipaURL, pageURL: pageURL)
            let skipped = UserDefaults.standard.integer(forKey: Self.skippedKey)
            if manual || skipped != build {
                available = info
            }
            return .available(info)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .failed("目前沒有網路。")
            default:
                return .failed("網路錯誤（\(error.code.rawValue)）。")
            }
        } catch {
            return .failed("檢查更新失敗。")
        }
    }

    func skip(_ info: AppUpdateInfo) {
        UserDefaults.standard.set(info.build, forKey: Self.skippedKey)
    }

    /// Opens SideStore with the IPA link; falls back to the release page.
    func install(_ info: AppUpdateInfo) {
        let encoded = info.ipaURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? info.ipaURL.absoluteString
        guard let sideStoreURL = URL(string: "sidestore://install?url=\(encoded)") else {
            UIApplication.shared.open(info.pageURL)
            return
        }
        UIApplication.shared.open(sideStoreURL) { opened in
            if !opened {
                DispatchQueue.main.async {
                    UIApplication.shared.open(info.pageURL)
                }
            }
        }
    }
}
