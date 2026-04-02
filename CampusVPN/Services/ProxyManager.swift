import Foundation

@MainActor
final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var systemProxyEnabled: Bool = false
    private let logger = AppLogger.shared

    private init() {}

    func enableSystemProxy(port: Int) async {
        let services = await getNetworkServices()
        for service in services {
            _ = await ShellExecutor.run(
                "networksetup -setsocksfirewallproxy \"\(service)\" 127.0.0.1 \(port)")
            _ = await ShellExecutor.run(
                "networksetup -setsocksfirewallproxystate \"\(service)\" on")
            _ = await ShellExecutor.run(
                "networksetup -setwebproxy \"\(service)\" 127.0.0.1 \(port)")
            _ = await ShellExecutor.run(
                "networksetup -setwebproxystate \"\(service)\" on")
            _ = await ShellExecutor.run(
                "networksetup -setsecurewebproxy \"\(service)\" 127.0.0.1 \(port)")
            _ = await ShellExecutor.run(
                "networksetup -setsecurewebproxystate \"\(service)\" on")
        }
        systemProxyEnabled = true
        logger.info("系统代理已开启 (SOCKS5 + HTTP/HTTPS -> 127.0.0.1:\(port))")
    }

    func disableSystemProxy() async {
        let services = await getNetworkServices()
        for service in services {
            _ = await ShellExecutor.run(
                "networksetup -setsocksfirewallproxystate \"\(service)\" off")
            _ = await ShellExecutor.run(
                "networksetup -setwebproxystate \"\(service)\" off")
            _ = await ShellExecutor.run(
                "networksetup -setsecurewebproxystate \"\(service)\" off")
        }
        systemProxyEnabled = false
        logger.info("系统代理已关闭")
    }

    func checkSystemProxyStatus() async -> Bool {
        let result = await ShellExecutor.run(
            "networksetup -getsocksfirewallproxy Wi-Fi 2>/dev/null")
        let enabled = result.stdout.contains("Enabled: Yes")
        systemProxyEnabled = enabled
        return enabled
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
