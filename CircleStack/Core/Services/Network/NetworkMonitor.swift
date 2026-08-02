//
//  NetworkMonitor.swift
//  CircleStack
//
//  Created by Moein on 29/07/2026.
//

import Foundation
import Network
import Combine

class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")

    @Published var isConnected: Bool = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let connected = (path.status == .satisfied)
                if self?.isConnected != connected {
                    self?.isConnected = connected
                    Logger.shared.i("NetworkMonitor", "Network status changed: \(connected ? "Online" : "Offline")")
                }
            }
        }
        monitor.start(queue: queue)
    }
}
