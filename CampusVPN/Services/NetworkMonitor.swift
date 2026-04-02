import Foundation
import Network
import CoreWLAN
import CoreLocation

@MainActor
final class NetworkMonitor: NSObject, ObservableObject {
    static let shared = NetworkMonitor()

    @Published var currentSSID: String?
    @Published var isConnectedToNetwork: Bool = false
    @Published var isCampusNetwork: Bool = false
    @Published var interfaceName: String?

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.campusvpn.networkmonitor")
    private let wifiClient = CWWiFiClient.shared()
    private let logger = AppLogger.shared
    private let settings = AppSettings.shared
    private var ssidPollTimer: Timer?

    var onNetworkChanged: (() -> Void)?

    override private init() {
        super.init()
    }

    func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasConnected = self.isConnectedToNetwork
                self.isConnectedToNetwork = path.status == .satisfied
                self.updateWiFiInfo()

                if wasConnected != self.isConnectedToNetwork {
                    self.logger.info("网络状态变化: \(self.isConnectedToNetwork ? "已连接" : "已断开")")
                    self.onNetworkChanged?()
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)

        do {
            try wifiClient.startMonitoringEvent(with: .ssidDidChange)
            wifiClient.delegate = self
            logger.info("Wi-Fi SSID 监听已启动")
        } catch {
            logger.warn("CoreWLAN 事件监听失败，使用轮询模式: \(error.localizedDescription)")
        }

        ssidPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateWiFiInfo()
            }
        }

        updateWiFiInfo()
    }

    func stopMonitoring() {
        pathMonitor.cancel()
        ssidPollTimer?.invalidate()
        ssidPollTimer = nil
        try? wifiClient.stopMonitoringAllEvents()
    }

    func updateWiFiInfo() {
        guard let iface = wifiClient.interface() else {
            currentSSID = nil
            isCampusNetwork = false
            interfaceName = nil
            return
        }

        interfaceName = iface.interfaceName

        if let ssid = iface.ssid() {
            let previousSSID = currentSSID
            currentSSID = ssid

            let keyword = settings.campusKeyword.lowercased()
            isCampusNetwork = ssid.lowercased().contains(keyword)

            if previousSSID != ssid {
                logger.info("Wi-Fi 切换: \(previousSSID ?? "无") -> \(ssid) (\(isCampusNetwork ? "校园网" : "外部网络"))")
                onNetworkChanged?()
            }
        } else {
            if currentSSID != nil {
                logger.info("Wi-Fi 断开")
                onNetworkChanged?()
            }
            currentSSID = nil
            isCampusNetwork = false
        }
    }
}

extension NetworkMonitor: CWEventDelegate {
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in
            self.updateWiFiInfo()
        }
    }
}
