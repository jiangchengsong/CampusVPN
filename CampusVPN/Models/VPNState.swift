import Foundation
import SwiftUI

enum ConnectionStatus: String {
    case disconnected = "未连接"
    case connecting = "连接中..."
    case connected = "已连接"
    case disconnecting = "断开中..."
    case error = "连接错误"
    case runtimeSetup = "运行环境初始化中..."
}

enum ProxyMode: String, CaseIterable, Codable {
    case socks5 = "SOCKS5 代理"
    case systemWide = "系统全局代理"
}

enum NetworkEnvironment: String {
    case campus = "校园网（直连）"
    case external = "外部网络"
    case disconnected = "无网络"
}

@MainActor
final class VPNState: ObservableObject {
    static let shared = VPNState()

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var proxyMode: ProxyMode = .socks5
    @Published var networkEnvironment: NetworkEnvironment = .disconnected
    @Published var currentSSID: String?
    @Published var isCampusNetwork: Bool = false
    @Published var socksPort: Int = 1080
    @Published var lastError: String?
    @Published var isAutoMode: Bool = true
    @Published var manualOverrideActive: Bool = false
    @Published var runtimeReady: Bool = false
    @Published var containerRunning: Bool = false
    @Published var proxyReachable: Bool = false
    @Published var reconnectAttempt: Int = 0

    var statusIcon: String {
        switch connectionStatus {
        case .connected:
            return isCampusNetwork ? "wifi" : "lock.shield.fill"
        case .connecting, .runtimeSetup:
            return "arrow.triangle.2.circlepath"
        case .disconnecting:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        case .disconnected:
            return "shield.slash"
        }
    }

    var statusColor: Color {
        switch connectionStatus {
        case .connected: return .green
        case .connecting, .runtimeSetup, .disconnecting: return .orange
        case .error: return .red
        case .disconnected: return .secondary
        }
    }

    var statusSummary: String {
        if isCampusNetwork {
            return "校园网直连"
        }
        return connectionStatus.rawValue
    }
}
