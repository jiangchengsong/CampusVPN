import SwiftUI

struct MenuBarView: View {
    @ObservedObject var vpnState: VPNState
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var gpuMonitor = GPUMonitorService.shared

    private let engine = NetworkPolicyEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            vpnSection
            Divider().padding(.vertical, 4)
            bottomBar
            Divider().padding(.vertical, 4)
            gpuSection
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            gpuMonitor.menuDidAppear()
        }
        .onDisappear {
            gpuMonitor.menuDidDisappear()
        }
    }

    // MARK: - GPU (底部，减少误触 popover)

    private var gpuSection: some View {
        VStack(spacing: 4) {
            HStack {
                Text("GPU 监控")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                if gpuMonitor.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else if let t = gpuMonitor.lastRefreshTime {
                    Text(t, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button {
                    Task { await gpuMonitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(gpuMonitor.isRefreshing)
            }

            if gpuMonitor.serverStatuses.isEmpty && !gpuMonitor.isRefreshing {
                Text("暂无数据")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            } else {
                ForEach(gpuMonitor.serverStatuses) { status in
                    ServerRow(status: status, gpuMonitor: gpuMonitor)
                }
            }
        }
    }

    // MARK: - VPN

    private var vpnSection: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(vpnState.statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 0) {
                    Text(vpnState.statusSummary)
                        .font(.caption).fontWeight(.medium)
                    if let error = vpnState.lastError {
                        Text(error).font(.caption2).foregroundColor(.red).lineLimit(1)
                    }
                }

                Spacer()
                connectionButton
            }

            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: "wifi").frame(width: 11)
                    Text(networkMonitor.currentSSID ?? "无")
                    if vpnState.isCampusNetwork {
                        Text("校园网")
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                Spacer()
                modeMenu
            }
            .font(.caption2).foregroundColor(.secondary)

            if vpnState.connectionStatus == .connected {
                HStack {
                    Text("SOCKS5 127.0.0.1:\(settings.socksPort)")
                    Spacer()
                    Circle().fill(vpnState.proxyReachable ? .green : .red).frame(width: 6, height: 6)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
            }

            if vpnState.reconnectAttempt > 0 {
                Text("重连中... 第 \(vpnState.reconnectAttempt) 次")
                    .font(.caption2).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch vpnState.connectionStatus {
        case .disconnected, .error:
            Button { Task { await engine.manualConnect(for: vpnState) } } label: {
                Image(systemName: "power").font(.caption)
            }.buttonStyle(.plain).foregroundColor(.green)
        case .connected:
            Button { Task { await engine.manualDisconnect(for: vpnState) } } label: {
                Image(systemName: "power").font(.caption)
            }.buttonStyle(.plain).foregroundColor(.red)
        case .connecting, .runtimeSetup, .disconnecting:
            ProgressView().controlSize(.mini)
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(ProxyMode.allCases, id: \.self) { mode in
                Button {
                    Task { await engine.switchMode(to: mode, for: vpnState) }
                } label: {
                    if mode == vpnState.proxyMode { Label(mode.rawValue, systemImage: "checkmark") }
                    else { Text(mode.rawValue) }
                }
            }
            Divider()
            if vpnState.manualOverrideActive {
                Button("恢复自动模式") {
                    Task { await engine.resumeAutoMode(for: vpnState) }
                }
            }
            if vpnState.connectionStatus == .connected {
                Button("重新连接") {
                    Task {
                        await engine.disconnect(for: vpnState)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await engine.connect(for: vpnState)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: vpnState.manualOverrideActive ? "hand.raised" : "arrow.triangle.2.circlepath")
                    .frame(width: 11)
                Text(vpnState.proxyMode == .socks5 ? "SOCKS5" : "全局")
            }
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.quaternary).cornerRadius(3)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack {
            Button("日志") { WindowManager.shared.showLogWindow() }
            Spacer()
            Button("设置...") { WindowManager.shared.showSettingsWindow() }
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
        }
        .font(.caption)
    }
}

// MARK: - Server Row with Popover

private struct ServerRow: View {
    let status: ServerGPUStatus
    let gpuMonitor: GPUMonitorService
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 10)
                .rotationEffect(.degrees(isHovering ? 90 : 0))

            Text(status.server.alias)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)

            if status.reachable {
                Text("(\(status.freeCount)/\(status.totalCount))")
                    .font(.caption2)
                    .foregroundColor(status.freeCount > 0 ? .green : .red)
            } else {
                Text("离线").font(.caption2).foregroundColor(.red)
            }

            Spacer()

            Button {
                gpuMonitor.openSSH(to: status.server)
            } label: {
                Image(systemName: "terminal").font(.caption2)
            }
            .buttonStyle(.plain)
            .help("SSH 连接到 \(status.server.alias)")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $isHovering, arrowEdge: .trailing) {
            gpuDetailPopover
        }
    }

    private var gpuDetailPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.server.alias)
                .font(.caption)
                .fontWeight(.bold)
                .padding(.bottom, 2)

            if status.reachable {
                ForEach(status.gpus) { gpu in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(gpu.isFree ? .green : .red)
                            .frame(width: 7, height: 7)
                        Text("[\(gpu.index)]")
                        Text(gpu.name)
                        Spacer(minLength: 10)
                        Text("\(gpu.memoryFree)M/\(gpu.memoryTotal)M")
                        Text("\(gpu.utilization)%")
                            .foregroundColor(gpu.utilization < 5 ? .green : .red)
                    }
                    .font(.system(.caption2, design: .monospaced))
                }
            } else {
                Text("连接失败")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(10)
        .frame(minWidth: 280)
    }
}
