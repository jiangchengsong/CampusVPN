import Foundation

@MainActor
final class NetworkPolicyEngine: ObservableObject {
    static let shared = NetworkPolicyEngine()

    private let networkMonitor: NetworkMonitor
    private let easyConnect: EasyConnectService
    private let proxyManager: ProxyManager
    private let runtime: ContainerRuntime
    private let settings: AppSettings
    private let logger: AppLogger

    @Published var isActive: Bool = false

    private var reconnectTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var runtimePreparationTask: Task<Bool, Never>?
    private var connectTask: Task<Bool, Never>?
    private var startupInProgress = false
    private var pendingPolicyEvaluation = false
    private var reconnectAttempt: Int = 0
    private let maxReconnectAttempts = 10

    private init() {
        self.networkMonitor = NetworkMonitor.shared
        self.easyConnect = EasyConnectService.shared
        self.proxyManager = ProxyManager.shared
        self.runtime = ContainerRuntime.shared
        self.settings = AppSettings.shared
        self.logger = AppLogger.shared
    }

    func start(with state: VPNState) async {
        if isActive {
            await evaluatePolicy(for: state)
            return
        }

        isActive = true
        startupInProgress = true
        state.proxyMode = settings.defaultMode

        networkMonitor.onNetworkChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleNetworkChanged(for: state)
            }
        }
        networkMonitor.startMonitoring()

        try? await Task.sleep(nanoseconds: 300_000_000)

        state.currentSSID = networkMonitor.currentSSID
        state.isCampusNetwork = networkMonitor.isCampusNetwork
        startupInProgress = false
        pendingPolicyEvaluation = false

        await evaluatePolicy(for: state)
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

    private func handleNetworkChanged(for state: VPNState) async {
        if startupInProgress {
            pendingPolicyEvaluation = true
            return
        }

        await evaluatePolicy(for: state)
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
            let changed = state.networkEnvironment != .disconnected
            state.networkEnvironment = .disconnected
            if changed {
                logger.info("网络断开，等待重连")
            }
            return
        }

        if networkMonitor.isCampusNetwork {
            let changed = state.networkEnvironment != .campus
            state.networkEnvironment = .campus
            if changed {
                logger.info("检测到校园网，使用直连模式")
            }
            if state.connectionStatus == .connected || state.connectionStatus == .connecting {
                await disconnect(for: state)
            }
            return
        }

        state.networkEnvironment = .external
        if settings.autoConnect && state.connectionStatus != .connected && state.connectionStatus != .connecting {
            if !state.runtimeReady {
                let ready = await prepareRuntimeIfNeeded(for: state)
                if !ready {
                    return
                }
            }
            logger.info("外部网络，自动连接 VPN...")
            await connect(for: state)
        }
    }

    private func prepareRuntimeIfNeeded(for state: VPNState) async -> Bool {
        if state.runtimeReady { return true }

        if let task = runtimePreparationTask {
            let ready = await task.value
            state.runtimeReady = ready
            return ready
        }

        state.connectionStatus = .runtimeSetup
        state.lastError = nil
        logger.info("初始化运行环境...")

        let task = Task { @MainActor in
            let runtimeOK = await runtime.ensureReady()
            guard runtimeOK else { return false }
            return await runtime.pullImageIfNeeded("hagb/docker-easyconnect:cli")
        }
        runtimePreparationTask = task

        let ready = await task.value
        runtimePreparationTask = nil
        state.runtimeReady = ready

        if ready {
            state.connectionStatus = .disconnected
            logger.info("运行环境就绪")
        } else {
            state.connectionStatus = .error
            state.lastError = "容器运行环境初始化失败"
            logger.error("运行环境初始化失败，请检查 Docker/Colima")
        }

        return ready
    }

    func connect(for state: VPNState) async {
        await connect(for: state, scheduleOnFailure: true, resetReconnectCounter: true)
    }

    private func connect(
        for state: VPNState,
        scheduleOnFailure: Bool,
        resetReconnectCounter: Bool
    ) async {
        if let task = connectTask {
            _ = await task.value
            return
        }

        guard state.connectionStatus != .connecting else { return }

        state.connectionStatus = .connecting
        state.lastError = nil
        if resetReconnectCounter {
            reconnectAttempt = 0
            state.reconnectAttempt = 0
        }

        let task = Task { @MainActor in
            await self.easyConnect.start()
        }
        connectTask = task

        let success = await task.value
        connectTask = nil

        if success {
            state.connectionStatus = .connected
            state.proxyReachable = true
            state.containerRunning = true
            reconnectAttempt = 0

            if state.proxyMode == .systemWide {
                await proxyManager.enableSystemProxy(port: settings.socksPort)
            }

            logger.info("VPN 连接成功")
            startHealthLoop(for: state)
        } else {
            state.connectionStatus = .error
            state.lastError = "VPN 连接失败"
            logger.error("VPN 连接失败")

            if scheduleOnFailure && settings.autoReconnect && !state.manualOverrideActive {
                scheduleReconnect(for: state)
            }
        }
    }

    func disconnect(for state: VPNState) async {
        state.connectionStatus = .disconnecting
        reconnectTask?.cancel()
        healthTask?.cancel()
        connectTask?.cancel()
        connectTask = nil

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
                await connect(for: state, scheduleOnFailure: false, resetReconnectCounter: false)
                if state.connectionStatus == .connected {
                    state.reconnectAttempt = 0
                    return
                }
            }

            if reconnectAttempt >= maxReconnectAttempts {
                logger.error("已达最大重试次数，停止自动重连")
                state.lastError = "重连失败，已达最大尝试次数"
            }
        }
    }

    /// 健康检查仅在 VPN 已连接（非校园网直连）时执行。
    private func startHealthLoop(for state: VPNState) {
        healthTask?.cancel()
        healthTask = Task {
            while !Task.isCancelled && isActive {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }

                guard state.connectionStatus == .connected else { continue }

                await easyConnect.checkStatus()
                state.containerRunning = easyConnect.isRunning
                state.proxyReachable = easyConnect.proxyReachable

                if !easyConnect.proxyReachable {
                    logger.warn("检测到代理不可用，标记异常")
                    state.connectionStatus = .error
                    state.lastError = "代理端口不可达"

                    if settings.autoReconnect && !state.manualOverrideActive {
                        scheduleReconnect(for: state)
                    }
                    return
                }
            }
        }
    }
}
