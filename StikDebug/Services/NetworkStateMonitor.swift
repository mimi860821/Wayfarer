//
//  NetworkStateMonitor.swift
//  Wayfarer
//
//  Tracks whether the phone is on Wi-Fi, cellular only, or offline, so the app
//  can explain why the on-device connection fails in the cellular-only state.
//

import Foundation
import Network

final class NetworkStateMonitor: ObservableObject {
    static let shared = NetworkStateMonitor()

    @Published private(set) var isWiFi = false
    @Published private(set) var isCellular = false
    @Published private(set) var isOffline = true

    /// Cellular data is the active connection and Wi-Fi is not: the state in which
    /// the device's pairing service refuses the loopback tunnel.
    var isCellularOnly: Bool {
        isCellular && !isWiFi
    }

    private let monitor = NWPathMonitor()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            let cellular = path.usesInterfaceType(.cellular)
            let offline = path.status != .satisfied
            DispatchQueue.main.async {
                self?.isWiFi = wifi
                self?.isCellular = cellular
                self?.isOffline = offline
            }
        }
        monitor.start(queue: DispatchQueue(label: "wayfarer.networkstate"))
    }
}
