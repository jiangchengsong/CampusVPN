import Foundation

@MainActor
final class GPUMonitorService: ObservableObject {
    static let shared = GPUMonitorService()

    @Published var serverStatuses: [ServerGPUStatus] = []
    @Published var isRefreshing: Bool = false
    @Published var lastRefreshTime: Date?

    var totalFree: Int { serverStatuses.reduce(0) { $0 + $1.freeCount } }
    var totalGPUs: Int { serverStatuses.reduce(0) { $0 + $1.totalCount } }

    private let logger = AppLogger.shared
    private let settings = AppSettings.shared
    private let menuRefreshStaleness: TimeInterval = 30
    private var menuRefreshTask: Task<Void, Never>?

    private init() {}

    func menuDidAppear() {
        guard shouldRefreshOnMenuAppear else { return }

        menuRefreshTask?.cancel()
        menuRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            await MainActor.run {
                self.menuRefreshTask = nil
            }
        }
    }

    func menuDidDisappear() {
        menuRefreshTask?.cancel()
        menuRefreshTask = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        let servers = settings.gpuServers
        guard !servers.isEmpty else {
            isRefreshing = false
            lastRefreshTime = Date()
            return
        }

        let useProxy = shouldUseProxy()

        if useProxy {
            logger.debug("GPU 查询使用 SOCKS5 代理 (127.0.0.1:\(settings.socksPort))")
        } else {
            logger.debug("GPU 查询使用直连")
        }

        let statuses = await withTaskGroup(of: ServerGPUStatus.self, returning: [ServerGPUStatus].self) { group in
            for server in servers {
                group.addTask {
                    await self.queryServer(server, useProxy: useProxy)
                }
            }
            var results: [ServerGPUStatus] = []
            for await status in group {
                results.append(status)
            }
            return results
        }

        serverStatuses = servers.map { server in
            statuses.first(where: { $0.server == server }) ??
                ServerGPUStatus(id: server.alias, server: server, gpus: [], reachable: false, errorMessage: "未查询")
        }

        isRefreshing = false
        lastRefreshTime = Date()
    }

    private var shouldRefreshOnMenuAppear: Bool {
        guard !isRefreshing else { return false }
        guard let lastRefreshTime else { return true }
        return Date().timeIntervalSince(lastRefreshTime) >= menuRefreshStaleness
    }

    private func queryServer(_ server: GPUServer, useProxy: Bool) async -> ServerGPUStatus {
        let nvidiaCmd = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.free,memory.total --format=csv,noheader,nounits"
        var args = [
            "-n",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1",
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "LogLevel=ERROR"
        ]

        if useProxy {
            args += ["-o", "ProxyCommand=/usr/bin/nc -x 127.0.0.1:\(settings.socksPort) %h %p"]
        }

        args += ["-p", "\(server.port)", server.sshTarget, nvidiaCmd]

        logger.debug("开始 GPU 查询 [\(server.alias)] \(useProxy ? "代理" : "直连")")

        let result = await ShellExecutor.runExecutable(
            "/usr/bin/ssh",
            arguments: args,
            timeout: 20
        )

        guard result.succeeded, !result.stdout.isEmpty else {
            let errDetail: String
            if !result.stderr.isEmpty {
                errDetail = result.stderr.components(separatedBy: "\n").first ?? result.stderr
            } else if result.exitCode == 255 {
                errDetail = "SSH 连接失败（网络不可达或认证失败）"
            } else {
                errDetail = "退出码 \(result.exitCode)"
            }
            logger.warn("GPU 查询失败 [\(server.alias)] \(server.host): \(errDetail)")
            return ServerGPUStatus(
                id: server.alias, server: server, gpus: [], reachable: false,
                errorMessage: errDetail
            )
        }

        let gpus = parseNvidiaSmiOutput(result.stdout, serverAlias: server.alias)
        return ServerGPUStatus(id: server.alias, server: server, gpus: gpus, reachable: true)
    }

    private func parseNvidiaSmiOutput(_ output: String, serverAlias: String) -> [GPUInfo] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning") && !$0.hasPrefix("Error") && !$0.hasPrefix("[Warning") }
            .compactMap { line -> GPUInfo? in
                let parts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 5,
                      let idx = Int(parts[0]),
                      let util = Int(parts[2]),
                      let memFree = Int(parts[3]),
                      let memTotal = Int(parts[4])
                else { return nil }

                var name = parts[1]
                    .replacingOccurrences(of: "NVIDIA ", with: "")
                    .replacingOccurrences(of: "GeForce ", with: "")
                if let dashIdx = name.firstIndex(of: "-") {
                    name = String(name[..<dashIdx])
                }

                return GPUInfo(
                    id: "\(serverAlias)-\(idx)",
                    index: idx,
                    name: name.trimmingCharacters(in: .whitespaces),
                    utilization: util,
                    memoryFree: memFree,
                    memoryTotal: memTotal
                )
            }
    }

    /// 判断本次 GPU 查询是否应该走 SOCKS 代理。
    /// 校园网直连；外部网络且 VPN 已连接、代理端口可达时走代理。
    private func shouldUseProxy() -> Bool {
        if NetworkMonitor.shared.isCampusNetwork { return false }
        let vpnState = VPNState.shared
        return vpnState.connectionStatus == .connected && vpnState.proxyReachable
    }

    func openSSH(to server: GPUServer) {
        let proxyAvailable = shouldUseProxy()
        let socksPort = settings.socksPort

        var script = "tell application \"Terminal\"\n  activate\n  do script \""
        if proxyAvailable {
            script += "ssh -o ProxyCommand='nc -x 127.0.0.1:\(socksPort) %h %p' -p \(server.port) \(server.sshTarget)"
        } else {
            script += "ssh -p \(server.port) \(server.sshTarget)"
        }
        script += "\"\nend tell"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}
