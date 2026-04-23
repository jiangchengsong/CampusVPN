import Foundation
import Network
import CoreWLAN
import CoreLocation
import AppKit

@MainActor
final class NetworkMonitor: NSObject, ObservableObject {
    static let shared = NetworkMonitor()

    @Published var currentSSID: String?
    @Published var isConnectedToNetwork: Bool = false
    @Published var isCampusNetwork: Bool = false
    @Published var interfaceName: String?
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var locationAuthorized: Bool = false

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.campusvpn.networkmonitor")
    private let wifiClient = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private let logger = AppLogger.shared
    private let settings = AppSettings.shared
    private var ssidPollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    var onNetworkChanged: (() -> Void)?

    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        updateLocationAuthorizationStatus()
    }

    var locationPermissionDescription: String {
        switch locationAuthorizationStatus {
        case .notDetermined:
            return "尚未申请"
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            return "已授权"
        case .denied:
            return "已拒绝"
        case .restricted:
            return "受系统限制"
        @unknown default:
            return "未知状态"
        }
    }

    var canRequestLocationPermission: Bool {
        locationAuthorizationStatus == .notDetermined
    }

    var needsManualLocationSettings: Bool {
        switch locationAuthorizationStatus {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }

    func startMonitoring() {
        requestLocationPermission()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.applyNetworkStatus(path.status)
            }
        }
        pathMonitor.start(queue: monitorQueue)

        startWakeObserver()
        stopSSIDPollingFallback()
        do {
            try wifiClient.startMonitoringEvent(with: .ssidDidChange)
            wifiClient.delegate = self
            logger.info("Wi-Fi SSID 监听已启动")
        } catch {
            logger.warn("CoreWLAN 事件监听失败，使用 30 秒轮询兜底: \(error.localizedDescription)")
            startSSIDPollingFallback()
        }

        applyNetworkStatus(pathMonitor.currentPath.status)
    }

    func stopMonitoring() {
        pathMonitor.cancel()
        stopSSIDPollingFallback()
        stopWakeObserver()
        try? wifiClient.stopMonitoringAllEvents()
    }

    func requestLocationPermission() {
        updateLocationAuthorizationStatus()

        guard CLLocationManager.locationServicesEnabled() else {
            locationAuthorized = false
            logger.warn("系统定位服务未开启，无法读取 Wi-Fi 名称")
            return
        }

        let status = locationAuthorizationStatus
        switch status {
        case .notDetermined:
            logger.info("请求位置权限以读取 Wi-Fi SSID...")
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            locationAuthorized = true
            logger.info("位置权限已授权")
            updateWiFiInfo()
            locationManager.stopUpdatingLocation()
        case .denied:
            locationAuthorized = false
            logger.warn("位置权限被拒绝，无法自动识别 Wi-Fi 名称。请在系统设置 > 隐私与安全性 > 定位服务中允许 CampusVPN")
            updateWiFiInfo()
        case .restricted:
            locationAuthorized = false
            logger.warn("位置权限受系统限制，无法自动识别 Wi-Fi 名称")
            updateWiFiInfo()
        @unknown default:
            locationAuthorized = false
        }
    }

    func openLocationPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func refreshLocationPermissionStatus() {
        updateLocationAuthorizationStatus()
        updateWiFiInfo()
    }

    private func updateLocationAuthorizationStatus() {
        let status = locationManager.authorizationStatus
        locationAuthorizationStatus = status
        switch status {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            locationAuthorized = true
        default:
            locationAuthorized = false
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
                // 不在日志中记录 SSID，避免位置/环境指纹泄露
                logger.info("Wi-Fi 已切换（\(isCampusNetwork ? "校园网" : "外部网络")）")
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

    private func applyNetworkStatus(_ status: NWPath.Status) {
        let wasConnected = isConnectedToNetwork
        isConnectedToNetwork = status == .satisfied
        updateWiFiInfo()

        if wasConnected != isConnectedToNetwork {
            logger.info("网络状态变化: \(isConnectedToNetwork ? "已连接" : "已断开")")
            onNetworkChanged?()
        }
    }

    private func startSSIDPollingFallback() {
        guard ssidPollTimer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateWiFiInfo()
            }
        }
        timer.tolerance = 5
        ssidPollTimer = timer
        logger.info("已启用低频 Wi-Fi SSID 兜底轮询")
    }

    private func stopSSIDPollingFallback() {
        ssidPollTimer?.invalidate()
        ssidPollTimer = nil
    }

    private func startWakeObserver() {
        guard wakeObserver == nil else { return }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWake()
            }
        }
    }

    private func stopWakeObserver() {
        guard let wakeObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        self.wakeObserver = nil
    }

    private func handleSystemWake() {
        logger.info("系统唤醒，刷新网络状态")
        applyNetworkStatus(pathMonitor.currentPath.status)
    }
}

// MARK: - CLLocationManagerDelegate

extension NetworkMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.updateLocationAuthorizationStatus()
            switch self.locationAuthorizationStatus {
            case .authorized, .authorizedAlways, .authorizedWhenInUse:
                self.locationAuthorized = true
                self.logger.info("位置权限已授权，现在可以读取 Wi-Fi 名称")
                self.updateWiFiInfo()
                manager.stopUpdatingLocation()
            case .denied:
                self.locationAuthorized = false
                self.logger.warn("位置权限被拒绝")
                self.updateWiFiInfo()
                manager.stopUpdatingLocation()
            case .restricted:
                self.locationAuthorized = false
                self.logger.warn("位置权限受系统限制")
                self.updateWiFiInfo()
                manager.stopUpdatingLocation()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            manager.stopUpdatingLocation()
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
