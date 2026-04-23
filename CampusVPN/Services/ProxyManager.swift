import Foundation

@MainActor
final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var systemProxyEnabled: Bool = false
    private let logger = AppLogger.shared

    /// 启用前保存每个网络服务的旧代理状态，关闭时恢复（避免覆盖 Clash 等已有设置）。
    private var savedProxyState: [String: [String: String]] = [:]

    private let pacDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CampusVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    /// 通过 PAC 自动代理让浏览器走 SOCKS5（解决纯系统 SOCKS 代理 DNS 不走隧道的问题）。
    /// 校园网域名（根据 campusKeyword 自动推导 + 手动配置的绕过域名）走 DIRECT。
    /// 同时保存并暂停 Clash 等已有的 HTTP/SOCKS 代理设置，关闭时恢复。
    func enableSystemProxy(port: Int) async {
        let services = await getNetworkServices()

        for service in services {
            savedProxyState[service] = await captureProxyState(service: service)
        }

        let settings = AppSettings.shared
        var bypassConditions: [String] = []

        let keyword = settings.campusKeyword.trimmingCharacters(in: .whitespaces).lowercased()
        if !keyword.isEmpty {
            bypassConditions.append("shExpMatch(host, \"*.\(keyword).edu.cn\")")
            bypassConditions.append("shExpMatch(host, \"\(keyword).edu.cn\")")
        }

        let customDomains = settings.proxyBypassDomains
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for domain in customDomains {
            if domain.hasPrefix("*.") || domain.contains("*") {
                bypassConditions.append("shExpMatch(host, \"\(domain)\")")
            } else {
                bypassConditions.append("dnsDomainIs(host, \"\(domain)\")")
                bypassConditions.append("shExpMatch(host, \"*.\(domain)\")")
            }
        }

        let extraChecks = bypassConditions.isEmpty
            ? ""
            : bypassConditions.map { "                \($0)" }.joined(separator: " ||\n") + " ||\n"

        let pacPath = pacDir.appendingPathComponent("proxy.pac")
        let pacContent = """
        function FindProxyForURL(url, host) {
            if (isPlainHostName(host) ||
                host === "127.0.0.1" ||
                host === "localhost" ||
                shExpMatch(host, "*.local") ||
                isInNet(host, "169.254.0.0", "255.255.0.0") ||
                isInNet(host, "10.0.0.0", "255.0.0.0") ||
                isInNet(host, "172.16.0.0", "255.240.0.0") ||
                isInNet(host, "192.168.0.0", "255.255.0.0") ||
        \(extraChecks)        false) {
                return "DIRECT";
            }
            return "SOCKS5 127.0.0.1:\(port); SOCKS 127.0.0.1:\(port); DIRECT";
        }
        """
        try? pacContent.write(to: pacPath, atomically: true, encoding: .utf8)
        let pacURL = pacPath.absoluteString

        for service in services {
            _ = await ShellExecutor.run(
                "networksetup -setsocksfirewallproxystate \"\(service)\" off")
            _ = await ShellExecutor.run(
                "networksetup -setwebproxystate \"\(service)\" off")
            _ = await ShellExecutor.run(
                "networksetup -setsecurewebproxystate \"\(service)\" off")
            _ = await ShellExecutor.run(
                "networksetup -setautoproxyurl \"\(service)\" \"\(pacURL)\"")
        }

        systemProxyEnabled = true
        logger.info("系统代理已开启（PAC → SOCKS5 127.0.0.1:\(port)），浏览器与系统应用均生效")
    }

    /// 关闭 PAC 代理并恢复启用前的代理设置（Clash 等）。
    func disableSystemProxy() async {
        let services = await getNetworkServices()
        for service in services {
            _ = await ShellExecutor.run(
                "networksetup -setautoproxystate \"\(service)\" off")

            if let saved = savedProxyState[service] {
                await restoreProxyState(service: service, state: saved)
            }
        }
        savedProxyState.removeAll()
        systemProxyEnabled = false
        logger.info("系统代理已关闭，已恢复先前代理设置")
    }

    func checkSystemProxyStatus() async -> Bool {
        let result = await ShellExecutor.run(
            "networksetup -getautoproxyurl Wi-Fi 2>/dev/null")
        let enabled = result.stdout.contains("Enabled: Yes") && result.stdout.contains("proxy.pac")
        systemProxyEnabled = enabled
        return enabled
    }

    // MARK: - Save / Restore

    private func captureProxyState(service: String) async -> [String: String] {
        var state: [String: String] = [:]
        let socks = await ShellExecutor.run("networksetup -getsocksfirewallproxy \"\(service)\" 2>/dev/null")
        state["socks"] = socks.stdout
        let web = await ShellExecutor.run("networksetup -getwebproxy \"\(service)\" 2>/dev/null")
        state["web"] = web.stdout
        let secureWeb = await ShellExecutor.run("networksetup -getsecurewebproxy \"\(service)\" 2>/dev/null")
        state["secureweb"] = secureWeb.stdout
        let auto = await ShellExecutor.run("networksetup -getautoproxyurl \"\(service)\" 2>/dev/null")
        state["auto"] = auto.stdout
        return state
    }

    private func restoreProxyState(service: String, state: [String: String]) async {
        if let socks = state["socks"] {
            let enabled = socks.contains("Enabled: Yes")
            if enabled, let server = parseField(socks, "Server"), let port = parseField(socks, "Port") {
                _ = await ShellExecutor.run(
                    "networksetup -setsocksfirewallproxy \"\(service)\" \(server) \(port)")
                _ = await ShellExecutor.run(
                    "networksetup -setsocksfirewallproxystate \"\(service)\" on")
            } else {
                _ = await ShellExecutor.run(
                    "networksetup -setsocksfirewallproxystate \"\(service)\" off")
            }
        }
        if let web = state["web"] {
            let enabled = web.contains("Enabled: Yes")
            if enabled, let server = parseField(web, "Server"), let port = parseField(web, "Port") {
                _ = await ShellExecutor.run(
                    "networksetup -setwebproxy \"\(service)\" \(server) \(port)")
                _ = await ShellExecutor.run(
                    "networksetup -setwebproxystate \"\(service)\" on")
            } else {
                _ = await ShellExecutor.run(
                    "networksetup -setwebproxystate \"\(service)\" off")
            }
        }
        if let sw = state["secureweb"] {
            let enabled = sw.contains("Enabled: Yes")
            if enabled, let server = parseField(sw, "Server"), let port = parseField(sw, "Port") {
                _ = await ShellExecutor.run(
                    "networksetup -setsecurewebproxy \"\(service)\" \(server) \(port)")
                _ = await ShellExecutor.run(
                    "networksetup -setsecurewebproxystate \"\(service)\" on")
            } else {
                _ = await ShellExecutor.run(
                    "networksetup -setsecurewebproxystate \"\(service)\" off")
            }
        }
        if let auto = state["auto"] {
            let enabled = auto.contains("Enabled: Yes")
            if enabled, let url = parseField(auto, "URL") {
                _ = await ShellExecutor.run(
                    "networksetup -setautoproxyurl \"\(service)\" \"\(url)\"")
            } else {
                _ = await ShellExecutor.run(
                    "networksetup -setautoproxystate \"\(service)\" off")
            }
        }
    }

    private func parseField(_ output: String, _ field: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ": ")
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == field {
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                return val.isEmpty || val == "(null)" ? nil : val
            }
        }
        return nil
    }

    private func getNetworkServices() async -> [String] {
        let result = await ShellExecutor.run("networksetup -listallnetworkservices | tail -n +2")
        guard result.succeeded else { return ["Wi-Fi"] }
        return result.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }
}
