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
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    private init() {}

    func startPeriodicRefresh(interval: TimeInterval = 60) {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPeriodicRefresh() {
        timerTask?.cancel()
        timerTask = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        let servers = settings.gpuServers
        let proxyAvailable = await checkProxyAvailable()

        let statuses = await withTaskGroup(of: ServerGPUStatus.self, returning: [ServerGPUStatus].self) { group in
            for server in servers {
                group.addTask {
                    await self.queryServer(server, useProxy: proxyAvailable)
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

    private func queryServer(_ server: GPUServer, useProxy: Bool) async -> ServerGPUStatus {
        let sshOpts = "-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR"
        let proxyOpt = useProxy
            ? "-o ProxyCommand='nc -x 127.0.0.1:\(settings.socksPort) %h %p'"
            : ""
        let nvidiaCmd = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.free,memory.total --format=csv,noheader,nounits"
        let cmd = "/usr/bin/ssh \(sshOpts) \(proxyOpt) -p \(server.port) \(server.sshTarget) \"\(nvidiaCmd)\" 2>/dev/null"

        let result = await ShellExecutor.run(cmd)

        guard result.succeeded, !result.stdout.isEmpty else {
            return ServerGPUStatus(
                id: server.alias, server: server, gpus: [], reachable: false,
                errorMessage: "连接失败"
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

    private func checkProxyAvailable() async -> Bool {
        let port = settings.socksPort
        let result = await ShellExecutor.run("nc -z 127.0.0.1 \(port) 2>/dev/null")
        return result.succeeded
    }

    func openSSH(to server: GPUServer) {
        let proxyAvailable = EasyConnectService.shared.proxyReachable
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
