//
//  OfflineGuideView.swift
//  Wayfarer
//
//  Explains how to use Wayfarer without Wi-Fi.
//

import SwiftUI

struct OfflineGuideView: View {
    @ObservedObject private var network = NetworkStateMonitor.shared

    private var statusText: String {
        if network.isWiFi {
            return "目前已連上 Wi-Fi，不需要任何特別步驟。"
        }
        if network.isCellularOnly {
            return "目前是「Wi-Fi 關閉、行動數據開啟」。這個狀態下手機的服務會拒絕連線，請照下面的步驟操作。"
        }
        if network.isOffline {
            return "目前沒有網路（可能是飛航模式）。如果 LocalDevVPN 已連線，現在可以直接在 Wayfarer 瞬移或播放路線。"
        }
        return "目前的網路狀態不明。"
    }

    var body: some View {
        List {
            Section("目前狀態") {
                Label("Wi-Fi：\(network.isWiFi ? "已連線" : "未連線")", systemImage: "wifi")
                Label("行動數據：\(network.isCellular ? "使用中" : "未使用")", systemImage: "antenna.radiowaves.left.and.right")
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("為什麼需要這些步驟") {
                Text("手機上的配對服務，在「行動數據開啟、Wi-Fi 關閉」時會拒絕連線；但在「已連上 Wi-Fi」或「沒有任何網路（飛航模式）」時可以。連線建立之後，就算行動數據回來，位置和路線播放都會繼續。")
                    .font(.subheadline)
            }

            Section("沒有 Wi-Fi 時的使用步驟") {
                step(1, "關閉 Wi-Fi，保持行動數據開啟。")
                step(2, "開啟 LocalDevVPN 並連線。這一步需要有網路，所以要在開飛航模式之前完成。")
                step(3, "開啟飛航模式（Wi-Fi 保持關閉）。")
                step(4, "回到 Wayfarer，瞬移或播放路線，讓連線建立。")
                step(5, "關閉飛航模式。行動數據恢復，位置和路線會繼續。")
            }

            Section("注意事項") {
                note("不要把 Wayfarer 從 App 切換畫面上滑關掉，設定裡的「背景保持運作」請保持開啟。")
                note("連線可能因為長時間背景、重新開機、LocalDevVPN 斷線而中斷，中斷後位置會恢復成真實位置。這時請重做上面的步驟。")
                note("飛航模式下沒有網路，無法向地圖查詢道路。要用「導航」連線方式，請在步驟 3 之前先規劃好路線；「直線」連線方式不需要網路。")
                note("有連上任何 Wi-Fi（即使那個 Wi-Fi 不能上網）時，不需要這些步驟。")
            }
        }
        .navigationTitle("沒有 Wi-Fi 時怎麼使用")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private func note(_ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: "info.circle")
        }
    }
}
