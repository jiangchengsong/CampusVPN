import Foundation

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: "username") }
    }
    @Published var socksPort: Int {
        didSet { UserDefaults.standard.set(socksPort, forKey: "socksPort") }
    }
    @Published var campusKeyword: String {
        didSet { UserDefaults.standard.set(campusKeyword, forKey: "campusKeyword") }
    }
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }
    @Published var autoReconnect: Bool {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }
    @Published var defaultMode: ProxyMode {
        didSet { UserDefaults.standard.set(defaultMode.rawValue, forKey: "defaultMode") }
    }
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    @Published var easyConnectVersion: String {
        didSet { UserDefaults.standard.set(easyConnectVersion, forKey: "easyConnectVersion") }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    @Published var gpuRefreshInterval: TimeInterval {
        didSet { UserDefaults.standard.set(gpuRefreshInterval, forKey: "gpuRefreshInterval") }
    }
    @Published var gpuServers: [GPUServer] {
        didSet { saveGPUServers() }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.serverURL = defaults.string(forKey: "serverURL") ?? ""
        self.username = defaults.string(forKey: "username") ?? ""
        self.socksPort = defaults.integer(forKey: "socksPort").nonZero ?? 1080
        self.campusKeyword = defaults.string(forKey: "campusKeyword") ?? "xjtu"
        self.autoConnect = defaults.object(forKey: "autoConnect") as? Bool ?? true
        self.autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.easyConnectVersion = defaults.string(forKey: "easyConnectVersion") ?? "7.6.7"
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        self.gpuRefreshInterval = defaults.double(forKey: "gpuRefreshInterval").nonZeroD ?? 60

        if let modeRaw = defaults.string(forKey: "defaultMode"),
           let mode = ProxyMode(rawValue: modeRaw) {
            self.defaultMode = mode
        } else {
            self.defaultMode = .socks5
        }

        if let data = defaults.data(forKey: "gpuServers"),
           let servers = try? JSONDecoder().decode([GPUServer].self, from: data) {
            self.gpuServers = servers
        } else {
            self.gpuServers = GPUServer.defaultServers
        }
    }

    private func saveGPUServers() {
        if let data = try? JSONEncoder().encode(gpuServers) {
            UserDefaults.standard.set(data, forKey: "gpuServers")
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

private extension Double {
    var nonZeroD: Double? { self == 0 ? nil : self }
}
