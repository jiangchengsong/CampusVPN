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
    @Published var locationAuthorized: Bool = false

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.campusvpn.networkmonitor")
    private let wifiClient = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private let logger = AppLogger.shared
    private let settings = AppSettings.shared
    private var ssidPollTimer: Timer?

    var onNetworkChanged: (() -> Void)?

    override private init() {
        super.init()
        locationManager.delegate = self
    }

    func startMonitoring() {
        requestLocationPermission()

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
            logger.warn("CoreWLAN 事件监听失败，使用轮询: \(error.localizedDescription)")
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

    func requestLocationPermission() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            logger.info("请求位置权限以读取 Wi-Fi SSID...")
            locationManager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            locationAuthorized = true
            logger.info("位置权限已授权")
        case .denied, .restricted:
            locationAuthorized = false
            logger.warn("位置权限被拒绝，无法自动识别 Wi-Fi 名称。请在系统设置 > 隐私与安全 > 定位服务中允许 CampusVPN")
        @unknown default:
            break
        }
    }

    func updateWiFiInfo() {
        let iface = wifiClient.interface()
        interfaceName = iface?.interfaceName

        let ssid = iface?.ssid()

        if let ssid, !ssid.isEmpty {
            let previousSSID = currentSSID
            currentSSID = ssid

            let keyword = settings.campusKeyword.lowercased()
            isCampusNetwork = ssid.lowercased().contains(keyword)

            if previousSSID != ssid {
                logger.info("Wi-Fi: \(previousSSID ?? "无") -> \(ssid) (\(isCampusNetwork ? "校园网" : "外部网络"))")
                onNetworkChanged?()
            }
        } else {
            if isConnectedToNetwork && !locationAuthorized {
                if currentSSID != "（需要位置权限）" {
                    currentSSID = "（需要位置权限）"
                    logger.warn("已连接 Wi-Fi 但无法读取名称，需要位置权限")
                }
                isCampusNetwork = false
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
}

// MARK: - CLLocationManagerDelegate

extension NetworkMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            switch status {
            case .authorized, .authorizedAlways:
                self.locationAuthorized = true
                self.logger.info("位置权限已授权，现在可以读取 Wi-Fi SSID")
                self.updateWiFiInfo()
            case .denied, .restricted:
                self.locationAuthorized = false
                self.logger.warn("位置权限被拒绝")
            default:
                break
            }
        }
    }
}

// MARK: - CWEventDelegate

extension NetworkMonitor: CWEventDelegate {
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in
            self.updateWiFiInfo()
        }
    }
}
