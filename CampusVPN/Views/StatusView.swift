import SwiftUI

struct StatusView: View {
    @ObservedObject var vpnState: VPNState
    @StateObject private var runtime = ContainerRuntime.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("连接状态") {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("VPN 状态", value: vpnState.connectionStatus.rawValue,
                              color: vpnState.statusColor)
                    statusRow("代理模式", value: vpnState.proxyMode.rawValue)
                    statusRow("网络环境", value: vpnState.networkEnvironment.rawValue)
                }
                .padding(4)
            }

            GroupBox("网络信息") {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("Wi-Fi", value: networkMonitor.currentSSID ?? "未连接")
                    statusRow("校园网", value: vpnState.isCampusNetwork ? "是" : "否")
                    statusRow("网络接口", value: networkMonitor.interfaceName ?? "N/A")
                    if vpnState.connectionStatus == .connected {
                        statusRow("SOCKS5 代理",
                                  value: "127.0.0.1:\(AppSettings.shared.socksPort)")
                        statusRow("代理可用",
                                  value: vpnState.proxyReachable ? "是" : "否",
                                  color: vpnState.proxyReachable ? .green : .red)
                    }
                }
                .padding(4)
            }

            GroupBox("运行环境") {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("容器运行时", value: runtime.detectedRuntime.rawValue)
                    statusRow("运行时就绪", value: runtime.isReady ? "是" : "否",
                              color: runtime.isReady ? .green : .red)
                    statusRow("容器运行中", value: vpnState.containerRunning ? "是" : "否")
                    if !runtime.setupProgress.isEmpty {
                        statusRow("进度", value: runtime.setupProgress)
                    }
                }
                .padding(4)
            }

            if let error = vpnState.lastError {
                GroupBox("错误") {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(4)
                }
            }
        }
        .padding()
    }

    private func statusRow(_ label: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .foregroundColor(color)
                .fontWeight(.medium)
            Spacer()
        }
    }
}
