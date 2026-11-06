//
//  ConnectionDiagnosticsView.swift
//  Wayfarer
//
//  Read-only checks that show why the on-device connection may fail
//  (for example with Wi-Fi off and cellular data on).
//

import SwiftUI
import Network
import Darwin

struct ConnectionDiagnosticsView: View {
    @State private var lines: [String] = []
    @State private var isRunning = false

    var body: some View {
        List {
            Section {
                Button {
                    run()
                } label: {
                    Label(isRunning ? "診斷中…" : "開始診斷", systemImage: "stethoscope")
                }
                .disabled(isRunning)
            } footer: {
                Text("請在「出問題的狀態」下按（例如：LocalDevVPN 已連線、Wi-Fi 關閉、行動數據開啟）。這個功能只檢查網路，不會更改任何設定。完成後按「複製結果」或截圖。")
            }

            if !lines.isEmpty {
                Section("結果") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Button("複製結果") {
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                    }
                }
            }
        }
        .navigationTitle("連線診斷")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func append(_ text: String) {
        lines.append(text)
    }

    private func run() {
        guard !isRunning else { return }
        lines = []
        isRunning = true
        let host = DeviceConnectionContext.targetIPAddress

        Task.detached {
            let report: (String) -> Void = { text in
                Task { @MainActor in append(text) }
            }

            report("== 1. 網路狀態 ==")
            for line in await DiagnosticsProbe.pathSummary() {
                report(line)
            }

            report("")
            report("== 2. 網路介面 ==")
            let interfaces = DiagnosticsProbe.interfaceList()
            for item in interfaces {
                report("\(item.name)  \(item.address)  \(item.isUp ? "UP" : "down")")
            }

            report("")
            report("== 3. 遠端配對服務（Bonjour）==")
            for line in await DiagnosticsProbe.browseRemotePairing(seconds: 4) {
                report(line)
            }
            let discovered = RemotePairingPortResolver.discover(timeout: 4)
            report("App 採用：連接埠 \(discovered.port)（\(discovered.source)）")

            report("")
            report("== 4. 連線測試（目標 \(host)）==")
            var ports: [UInt16] = [discovered.port]
            if !ports.contains(RemotePairingPortResolver.fallback) {
                ports.append(RemotePairingPortResolver.fallback)
            }

            // Interface that owns the tunnel address (the VPN's utun).
            let tunnelInterface = interfaces.first { $0.address.hasPrefix("10.7.") && $0.name.hasPrefix("utun") }
            if let tunnelInterface {
                report("找到 VPN 通道介面：\(tunnelInterface.name)（\(tunnelInterface.address)）")
            } else {
                report("沒有找到 VPN 通道介面（10.7.x.x）。LocalDevVPN 可能沒有連線。")
            }

            for port in ports {
                report("-- 連接埠 \(port) --")
                report("一般連線：" + DiagnosticsProbe.tcpProbe(host: host, port: port, boundInterface: nil))
                if let tunnelInterface {
                    report("強制走 \(tunnelInterface.name)：" + DiagnosticsProbe.tcpProbe(host: host, port: port, boundInterface: tunnelInterface.name))
                }
            }

            report("")
            report("== 5. 直接連本機位址（不經過 VPN 轉換）==")
            var localHosts: [(String, String)] = [("本機迴路", "127.0.0.1")]
            var seen: Set<String> = ["127.0.0.1"]
            for item in interfaces where !seen.contains(item.address) {
                seen.insert(item.address)
                localHosts.append((item.name, item.address))
            }
            for (label, address) in localHosts {
                for port in ports {
                    report("\(label) \(address):\(port) → " + DiagnosticsProbe.tcpProbe(host: address, port: port, boundInterface: nil))
                }
            }

            report("")
            report("診斷完成。")
            await MainActor.run { isRunning = false }
        }
    }
}

struct DiagnosticsInterface {
    let name: String
    let address: String
    let isUp: Bool
}

enum DiagnosticsProbe {
    static func pathSummary() async -> [String] {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "wayfarer.diagnostics.path")
            var finished = false
            monitor.pathUpdateHandler = { path in
                guard !finished else { return }
                finished = true
                var result: [String] = []
                result.append("狀態：\(path.status)")
                result.append("可用介面：" + path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ", "))
                result.append("Wi-Fi：\(path.usesInterfaceType(.wifi))  行動網路：\(path.usesInterfaceType(.cellular))  其他(VPN等)：\(path.usesInterfaceType(.other))")
                result.append("昂貴連線：\(path.isExpensive)  受限：\(path.isConstrained)")
                monitor.cancel()
                continuation.resume(returning: result)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                guard !finished else { return }
                finished = true
                monitor.cancel()
                continuation.resume(returning: ["讀取網路狀態逾時"])
            }
        }
    }

    static func interfaceList() -> [DiagnosticsInterface] {
        var result: [DiagnosticsInterface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let interface = entry.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
                let name = String(cString: interface.ifa_name)
                let isUp = (interface.ifa_flags & UInt32(IFF_UP)) != 0
                result.append(DiagnosticsInterface(name: name, address: String(cString: buffer), isUp: isUp))
            }
            current = interface.ifa_next
        }
        return result
    }

    static func browseRemotePairing(seconds: Double) async -> [String] {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjour(type: "_remotepairing._tcp", domain: "local."),
                using: parameters
            )
            let queue = DispatchQueue(label: "wayfarer.diagnostics.browse")
            var results: [NWBrowser.Result] = []
            var found: [String] = []
            var connections: [NWConnection] = []
            var finished = false

            browser.browseResultsChangedHandler = { newResults, _ in
                results = Array(newResults)
            }
            browser.start(queue: queue)

            queue.asyncAfter(deadline: .now() + seconds) {
                browser.cancel()

                if results.isEmpty {
                    continuation.resume(returning: ["沒有找到任何服務"])
                    return
                }

                for (index, result) in results.prefix(4).enumerated() {
                    let interfaces = result.interfaces.map { $0.name }.joined(separator: ",")
                    found.append("服務 \(index + 1)：介面 \(interfaces.isEmpty ? "?" : interfaces)")
                    let connection = NWConnection(to: result.endpoint, using: parameters)
                    connections.append(connection)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready, .waiting, .failed:
                            let path = connection.currentPath
                            let remote = path?.remoteEndpoint.map { "\($0)" } ?? "?"
                            let local = path?.localEndpoint.map { "\($0)" } ?? "?"
                            let line = "  服務 \(index + 1) 狀態 \(state)；對方 \(remote)；本機 \(local)"
                            if !found.contains(line) {
                                found.append(line)
                            }
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }

                queue.asyncAfter(deadline: .now() + 2.5) {
                    guard !finished else { return }
                    finished = true
                    connections.forEach { $0.cancel() }
                    continuation.resume(returning: found)
                }
            }
        }
    }

    /// Plain TCP connect with a timeout. Closes the socket immediately and sends nothing.
    static func tcpProbe(host: String, port: UInt16, boundInterface: String?) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "無法建立 socket（\(String(cString: strerror(errno)))）" }
        defer { close(fd) }

        if let boundInterface {
            var index = if_nametoindex(boundInterface)
            if index == 0 { return "找不到介面 \(boundInterface)" }
            let status = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            if status != 0 { return "綁定介面失敗（\(String(cString: strerror(errno)))）" }
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return "位址格式錯誤" }

        let started = Date()
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 {
            return "成功（\(elapsed(since: started)) ms）"
        }
        if errno != EINPROGRESS {
            return "失敗：\(String(cString: strerror(errno)))（errno \(errno)）"
        }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&descriptor, 1, 3000)
        if pollResult == 0 {
            return "逾時（3 秒沒有回應）"
        }
        if pollResult < 0 {
            return "poll 失敗：\(String(cString: strerror(errno)))"
        }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
        if socketError == 0 {
            return "成功（\(elapsed(since: started)) ms）"
        }
        return "失敗：\(String(cString: strerror(socketError)))（errno \(socketError)，\(elapsed(since: started)) ms）"
    }

    private static func elapsed(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
