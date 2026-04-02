import Foundation

@MainActor
final class NetworkPolicyEngine: ObservableObject {
    static let shared = NetworkPolicyEngine()

    private let vpnState: VPNState
    private let networkMonitor: NetworkMonitor
    private let easyConnect: EasyConnectService
    private let proxyManager: ProxyManager
    private let runtime: ContainerRuntime
    private let settings: AppSettings
    private let logger: AppLogger

    @Published var isActive: Bool = false

    private var reconnectTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private let maxReconnectAttempts = 10

    private init() {
        self.vpnState = VPNState()
        self.networkMonitor = NetworkMonitor.shared
        self.easyConnect = EasyConnectService.shared
        self.proxyManager = ProxyManager.shared
        self.runtime = ContainerRuntime.shared
        self.settings = AppSettings.shared
        self.logger = AppLogger.shared
    }

    func initialize(with state: VPNState) {
        let _ = state
    }

    var sharedState: VPNState { vpnState }

    func start(with state: VPNState) async {
        isActive = true

        state.connectionStatus = .runtimeSetup
        logger.info("正在初始化运行环境...")

        let runtimeOK = await runtime.ensureReady()
        state.runtimeReady = runtimeOK

        if !runtimeOK {
            state.connectionStatus = .error
            state.lastError = "容器运行环境初始化失败"
            logger.error("运行环境初始化失败，请检查 Docker/Colima")
            return
        }

        let imageOK = await runtime.pullImageIfNeeded("hagb/docker-easyconnect:cli")
        if !imageOK {
            state.connectionStatus = .error
            state.lastError = "EasyConnect 镜像拉取失败"
            return
        }

        state.connectionStatus = .disconnected
        logger.info("运行环境就绪，启动网络监控...")

        networkMonitor.onNetworkChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.evaluatePolicy(for: state)
            }
        }
        networkMonitor.startMonitoring()

        await evaluatePolicy(for: state)
        startHealthLoop(for: state)
    }

    func stop(for state: VPNState) async {
        isActive = false
        reconnectTask?.cancel()
        healthTask?.cancel()
        networkMonitor.stopMonitoring()

        if state.connectionStatus == .connected || state.connectionStatus == .connecting {
            await disconnect(for: state)
        }
    }

    func evaluatePolicy(for state: VPNState) async {
        guard isActive else { return }

        if state.manualOverrideActive {
            logger.debug("手动模式激活，跳过自动策略")
            return
        }

        state.currentSSID = networkMonitor.currentSSID
        state.isCampusNetwork = networkMonitor.isCampusNetwork

        if !networkMonitor.isConnectedToNetwork {
            state.networkEnvironment = .disconnected
            logger.info("网络断开，等待重连...")
            return
        }

        if networkMonitor.isCampusNetwork {
            state.networkEnvironment = .campus
            logger.info("检测到校园网 (\(networkMonitor.currentSSID ?? ""))，使用直连模式")
            await disconnect(for: state)
            return
        }

        state.networkEnvironment = .external
        if settings.autoConnect && state.connectionStatus != .connected && state.connectionStatus != .connecting {
            logger.info("外部网络，自动连接 VPN...")
            await connect(for: state)
        }
    }

    func connect(for state: VPNState) async {
        guard state.connectionStatus != .connecting else { return }

        state.connectionStatus = .connecting
        state.lastError = nil
        reconnectAttempt = 0

        let success = await easyConnect.start()
        if success {
            state.connectionStatus = .connected
            state.proxyReachable = true
            state.containerRunning = true
            reconnectAttempt = 0

            if state.proxyMode == .systemWide {
                await proxyManager.enableSystemProxy(port: settings.socksPort)
            }

            logger.info("VPN 连接成功")
        } else {
            state.connectionStatus = .error
            state.lastError = "VPN 连接失败"
            logger.error("VPN 连接失败")

            if settings.autoReconnect && !state.manualOverrideActive {
                scheduleReconnect(for: state)
            }
        }
    }

    func disconnect(for state: VPNState) async {
        state.connectionStatus = .disconnecting
        reconnectTask?.cancel()

        await proxyManager.disableSystemProxy()
        await easyConnect.stop()

        state.connectionStatus = .disconnected
        state.proxyReachable = false
        state.containerRunning = false
    }

    func manualConnect(for state: VPNState) async {
        state.manualOverrideActive = true
        await connect(for: state)
    }

    func manualDisconnect(for state: VPNState) async {
        state.manualOverrideActive = true
        await disconnect(for: state)
    }

    func resumeAutoMode(for state: VPNState) async {
        state.manualOverrideActive = false
        await evaluatePolicy(for: state)
    }

    func switchMode(to mode: ProxyMode, for state: VPNState) async {
        let wasConnected = state.connectionStatus == .connected
        state.proxyMode = mode

        if wasConnected {
            if mode == .systemWide {
                await proxyManager.enableSystemProxy(port: settings.socksPort)
            } else {
                await proxyManager.disableSystemProxy()
            }
        }

        logger.info("模式切换为: \(mode.rawValue)")
    }

    private func scheduleReconnect(for state: VPNState) {
        reconnectTask?.cancel()
        reconnectTask = Task {
            while reconnectAttempt < maxReconnectAttempts && !Task.isCancelled && isActive {
                reconnectAttempt += 1
                state.reconnectAttempt = reconnectAttempt
                let delay = min(UInt64(pow(2.0, Double(reconnectAttempt))) * 1_000_000_000, 60_000_000_000)
                logger.info("将在 \(delay / 1_000_000_000) 秒后重试 (\(reconnectAttempt)/\(maxReconnectAttempts))...")

                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }

                if networkMonitor.isCampusNetwork || !networkMonitor.isConnectedToNetwork {
                    logger.info("网络环境变化，取消重连")
                    return
                }

                logger.info("正在重连... 第 \(reconnectAttempt) 次")
                let success = await easyConnect.start()
                if success {
                    state.connectionStatus = .connected
                    state.proxyReachable = true
                    state.containerRunning = true
                    reconnectAttempt = 0
                    state.reconnectAttempt = 0

                    if state.proxyMode == .systemWide {
                        await proxyManager.enableSystemProxy(port: settings.socksPort)
                    }
                    logger.info("重连成功")
                    return
                }
            }

            if reconnectAttempt >= maxReconnectAttempts {
                logger.error("已达最大重试次数，停止自动重连")
                state.lastError = "重连失败，已达最大尝试次数"
            }
        }
    }

    private func startHealthLoop(for state: VPNState) {
        healthTask?.cancel()
        healthTask = Task {
            while !Task.isCancelled && isActive {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }

                await easyConnect.checkStatus()
                state.containerRunning = easyConnect.isRunning
                state.proxyReachable = easyConnect.proxyReachable

                if state.connectionStatus == .connected && !easyConnect.proxyReachable {
                    logger.warn("检测到代理不可用，标记异常")
                    state.connectionStatus = .error
                    state.lastError = "代理端口不可达"

                    if settings.autoReconnect && !state.manualOverrideActive {
                        scheduleReconnect(for: state)
                    }
                }
            }
        }
    }
}
