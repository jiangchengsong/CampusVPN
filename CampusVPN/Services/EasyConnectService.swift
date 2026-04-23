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
    private var startTask: Task<Bool, Never>?

    private init() {}

    func start() async -> Bool {
        if let task = startTask {
            return await task.value
        }

        let task = Task { @MainActor in
            await self.startImpl()
        }
        startTask = task

        let success = await task.value
        startTask = nil
        return success
    }

    private func startImpl() async -> Bool {
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
        let ecVersion = settings.easyConnectVersion

        guard !username.isEmpty else {
            logger.error("未配置用户名，请在设置中填写")
            return false
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
            -p 1080:1080 \
            -p 2222:2222 \
            \(imageName)
            """
        let result = await runtime.runDocker(runCmd)

        if !result.succeeded {
            let safe = LogRedaction.redactEasyConnectCLI(result.stderr)
            logger.error("容器启动失败: \(safe)")
            return false
        }

        isRunning = true
        logger.info("容器已启动，等待代理就绪...")
        return await waitForProxy()
    }

    func stop() async {
        logger.info("停止 EasyConnect 容器...")
        startTask?.cancel()
        startTask = nil
        healthCheckTask?.cancel()
        let port = settings.socksPort
        _ = await ShellExecutor.run("pkill -f 'ssh.*-D \(port).*127.0.0.1' 2>/dev/null")
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
        let jumpHost = settings.jumpHost
        let jumpUser = settings.jumpUser

        // 检查 VPN 是否已登录
        let logs = await getLogs(tail: 20)
        let alreadyLoggedIn = logs.components(separatedBy: "\n").last(where: {
            $0.contains("login successfully") || $0.contains("login FAILED")
        })?.contains("login successfully") ?? false

        if !alreadyLoggedIn {
            // 等待 VPN 登录成功（最多 60 秒，EasyConnect 可能多次重试）
            logger.info("等待 VPN 登录完成（最多 60 秒）...")
            for attempt in 1...60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let logs = await getLogs(tail: 20)
                // 取最后一条登录结果判断
                let lastLogin = logs.components(separatedBy: "\n").last(where: {
                    $0.contains("login successfully") || $0.contains("login FAILED")
                })
                if lastLogin?.contains("login successfully") == true {
                    logger.info("VPN 登录成功，建立代理隧道...")
                    break
                }
                if attempt == 15 || attempt == 30 || attempt == 45 {
                    logger.debug("仍在等待 VPN 登录... (\(attempt)/60)")
                }
                if attempt == 60 {
                    logger.error("VPN 登录超时")
                    return false
                }
            }
        } else {
            logger.info("VPN 已登录，建立代理隧道...")
        }

        // 启动容器内 socat 转发（先杀旧进程）
        _ = await runtime.runDocker("exec \(containerName) sh -c \"pids=\\$(ps aux | grep 'socat TCP-LISTEN:2222' | grep -v grep | awk '{print \\$1}'); [ -n \\\"\\$pids\\\" ] && kill \\$pids 2>/dev/null; true\"")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let socat = await runtime.runDocker("exec -d \(containerName) socat TCP-LISTEN:2222,fork,reuseaddr TCP:\(jumpHost):22")
        if !socat.succeeded {
            logger.error("代理隧道转发启动失败: \(socat.stderr)")
            return false
        }

        // 等待 socat 就绪
        var tunnelPortReady = false
        for _ in 1...10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let r = await ShellExecutor.run("nc -z 127.0.0.1 2222 2>/dev/null")
            if r.succeeded {
                tunnelPortReady = true
                break
            }
        }
        if !tunnelPortReady {
            logger.error("代理隧道端口未就绪")
            return false
        }

        // 停止旧的 ssh -D 进程（如果有）
        _ = await ShellExecutor.run("pkill -f 'ssh.*-D \(port).*127.0.0.1' 2>/dev/null")
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 建立宿主机原生 SOCKS5（ssh -D）
        let ssh = await ShellExecutor.run(
            "ssh -o StrictHostKeyChecking=no -o BatchMode=yes -fN -D \(port) -p 2222 \(jumpUser)@127.0.0.1",
            timeout: 12
        )
        if !ssh.succeeded {
            let detail = ssh.stderr.isEmpty ? "退出码 \(ssh.exitCode)" : ssh.stderr
            logger.error("SOCKS5 代理进程启动失败: \(detail)")
            return false
        }

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if await checkProxyPort() {
            proxyReachable = true
            logger.info("SOCKS5 代理就绪 (127.0.0.1:\(port))")
            return true
        }

        logger.error("SOCKS5 代理建立失败")
        return false
    }

    private func checkProxyPort() async -> Bool {
        let port = settings.socksPort
        let result = await ShellExecutor.run("nc -z 127.0.0.1 \(port) 2>/dev/null")
        return result.succeeded
    }
}
