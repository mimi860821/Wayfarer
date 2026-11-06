//
//  TunnelManager.swift
//  StikDebug
//

import Foundation
import UIKit

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false

    @Published private(set) var isStarting = false
    @Published private(set) var lastError: NSError?
    private var restartPending = false

    private init() {}

    func markDisconnected() {
        runOnMain {
            self.isConnected = false
        }
    }

    func restart() {
        runOnMain {
            self.isConnected = false
            if self.isStarting {
                self.restartPending = true
            } else {
                self.start()
            }
        }
    }

    func start(showErrorUI: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.start(showErrorUI: showErrorUI)
            }
            return
        }

        let pairingFileURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            isConnected = false
            lastError = NSError(domain: "StikDebug", code: -17, userInfo: [NSLocalizedDescriptionKey: "Pairing file not found."])
            return
        }

        guard !isStarting else {
            return
        }

        lastError = nil
        isConnected = false
        isStarting = true

        DispatchQueue.global(qos: .userInteractive).async { [showErrorUI] in
            let result: Result<Void, NSError>
            do {
                try JITEnableContext.shared.startTunnel()
                result = .success(())
            } catch {
                result = .failure(error as NSError)
            }

            DispatchQueue.main.async {
                self.finishStart(result, showErrorUI: showErrorUI)
            }
        }
    }

    private func finishStart(_ result: Result<Void, NSError>, showErrorUI: Bool) {
        isStarting = false
        if restartPending {
            restartPending = false
            start()
            return
        }

        switch result {
        case .success:
            lastError = nil
            isConnected = true
            LogManager.shared.addInfoLog("Tunnel connected successfully")
            mountDeveloperDiskImageIfNeeded()
        case .failure(let error):
            lastError = error
            isConnected = false
            handleStartFailure(error, showErrorUI: showErrorUI)
        }
    }

    private func mountDeveloperDiskImageIfNeeded() {
        guard DeveloperDiskImageService.filesAreReady else { return }
        MountingProgress.shared.pubMount()
    }

    private func handleStartFailure(_ error: NSError, showErrorUI: Bool) {
        LogManager.shared.addErrorLog(tunnelConnectionLogMessage(for: error))
        guard showErrorUI else {
            return
        }

        if error.code == -9 {
            handleInvalidPairingFile()
            return
        }

        showAlert(
            title: "連線失敗",
            message: tunnelConnectionAlertMessage(for: error),
            showOk: false,
            showTryAgain: true
        ) { shouldTryAgain in
            if shouldTryAgain {
                startTunnelInBackground()
            }
        }
    }

    private func handleInvalidPairingFile() {
        LogManager.shared.addInfoLog("Pairing file reported invalid; keeping existing file")

        showAlert(
            title: "Invalid Pairing File",
            message: "The pairing file may be invalid or expired. You can import a new pairing file to replace it.\n\n\(connectionDiagnosticDetails())",
            showOk: true,
            showTryAgain: false,
            primaryButtonText: "Select New File"
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    TunnelManager.shared.start(showErrorUI: showErrorUI)
}

func markTunnelDisconnected() {
    TunnelManager.shared.markDisconnected()
}

private func tunnelConnectionLogMessage(for error: NSError) -> String {
    let target = RemotePairingPortResolver.lastAttemptDescription
    return "Tunnel connection failed for \(target): \(error.localizedDescription) (Domain: \(error.domain), Code: \(error.code), Raw: \(String(describing: error)))"
}

private func tunnelConnectionAlertMessage(for error: NSError) -> String {
    var hint = ""
    if NetworkStateMonitor.shared.isCellularOnly {
        hint = """
        偵測到：Wi-Fi 關閉、行動數據開啟。這個狀態下手機的服務會拒絕連線。

        處理方式：先開 LocalDevVPN 並連線，再開飛航模式，回到 Wayfarer 重試；成功後可以關掉飛航模式。
        詳細步驟在「設定 → 說明 → 沒有 Wi-Fi 時怎麼使用」。


        """
    }

    return """
    錯誤 \(error.code)：\(error.localizedDescription)

    \(hint)排除方式：
    1. 確認已連上 Wi-Fi（不需要有網路），或已進入飛航模式，並且 LocalDevVPN 已連線。
    2. 重新啟動 iPhone，重新連線 LocalDevVPN 後再試。
    3. 確認配對檔有效（不要重新按 idevice_pair 的 Create）。

    嘗試連線：\(RemotePairingPortResolver.lastAttemptDescription)

    \(connectionDiagnosticDetails())
    """
}

func connectionDiagnosticDetails() -> String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    var systemInfo = utsname()
    uname(&systemInfo)
    let model = withUnsafePointer(to: &systemInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }

    return """
    \(version)
    \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
    \(DeviceModelName.name(for: model))
    """
}
