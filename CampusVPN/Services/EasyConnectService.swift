import Foundation

@MainActor
final class EasyConnectService: ObservableObject {
    static let shared = EasyConnectService()

    private let containerName = "easyconnect"
    private let imageName = "hagb/docker-easyconnect:cli"
    private let runtime = ContainerRuntime.shared
    private let logger = AppLogger.shared
    private let settings = AppSettings.shared

    @Published var isRunning: Bool = false
    @Published var proxyReachable: Bool = false

    private var healthCheckTask: Task<Void, Never>?

    private init() {}

    func start() async -> Bool {
        guard runtime.isReady else {
            logger.error("容器运行时未就绪")
            return false
        }

        guard let password = KeychainService.savedPassword, !password.isEmpty else {
            logger.error("未配置 VPN 密码，请在设置中填写")
            return false
        }

        let username = settings.username
        let server = settings.serverURL
        let port = settings.socksPort
        let ecVersion = settings.easyConnectVersion

        guard !username.isEmpty else {
            logger.error("未配置用户名，请在设置中填写")
            return false
        }

        let existingCheck = await runtime.runDocker("ps --format '{{.Names}}' --filter name=^\(containerName)$")
        if existingCheck.stdout.contains(containerName) {
            logger.info("EasyConnect 容器已在运行")
            isRunning = true
            return await waitForProxy()
        }

        _ = await runtime.runDocker("rm -f \(containerName) 2>/dev/null")

        logger.info("启动 EasyConnect 容器...")
        let runCmd = """
            run -d \
            --name \(containerName) \
            --device /dev/net/tun \
            --cap-add NET_ADMIN \
            -e EC_VER=\(ecVersion) \
            -e CLI_OPTS="-d \(server) -u \(username) -p \(password)" \
            -p \(port):1080 \
            \(imageName)
            """
        let result = await runtime.runDocker(runCmd)

        if !result.succeeded {
            logger.error("容器启动失败: \(result.stderr)")
            return false
        }

        isRunning = true
        logger.info("容器已启动，等待代理就绪...")
        return await waitForProxy()
    }

    func stop() async {
        logger.info("停止 EasyConnect 容器...")
        healthCheckTask?.cancel()
        _ = await runtime.runDocker("stop \(containerName) 2>/dev/null")
        _ = await runtime.runDocker("rm \(containerName) 2>/dev/null")
        isRunning = false
        proxyReachable = false
        logger.info("EasyConnect 已停止")
    }

    func restart() async -> Bool {
        await stop()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return await start()
    }

    func checkStatus() async {
        let result = await runtime.runDocker("ps --format '{{.Names}}' --filter name=^\(containerName)$")
        isRunning = result.stdout.contains(containerName)

        if isRunning {
            proxyReachable = await checkProxyPort()
        } else {
            proxyReachable = false
        }
    }

    func getLogs(tail: Int = 100) async -> String {
        await runtime.dockerLogs(containerName, tail: tail)
    }

    func startHealthMonitor() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await checkStatus()
            }
        }
    }

    func stopHealthMonitor() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    private func waitForProxy() async -> Bool {
        let port = settings.socksPort
        for attempt in 1...20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await checkProxyPort() {
                proxyReachable = true
                logger.info("SOCKS5 代理就绪 (127.0.0.1:\(port))")
                return true
            }
            logger.debug("等待代理就绪... (\(attempt)/20)")
        }

        logger.error("代理连接超时")
        let logs = await getLogs(tail: 15)
        logger.error("容器日志:\n\(logs)")
        return false
    }

    private func checkProxyPort() async -> Bool {
        let port = settings.socksPort
        let result = await ShellExecutor.run("nc -z 127.0.0.1 \(port) 2>/dev/null")
        return result.succeeded
    }
}
