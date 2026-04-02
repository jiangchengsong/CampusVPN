import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var password: String = KeychainService.savedPassword ?? ""

    var body: some View {
        TabView {
            connectionTab
                .tabItem { Label("连接", systemImage: "network") }

            serversTab
                .tabItem { Label("服务器", systemImage: "server.rack") }

            behaviorTab
                .tabItem { Label("行为", systemImage: "gearshape") }

            advancedTab
                .tabItem { Label("高级", systemImage: "wrench") }
        }
        .frame(width: 500, height: 440)
        .padding()
    }

    // MARK: - Connection

    private var connectionTab: some View {
        Form {
            Section("VPN 服务器") {
                TextField("服务器地址", text: $settings.serverURL)
                    .textFieldStyle(.roundedBorder)
            }
            Section("账号信息") {
                TextField("用户名（学号）", text: $settings.username)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: password) {
                        KeychainService.savedPassword = password
                    }
            }
            Section("代理端口") {
                HStack {
                    Text("SOCKS5 端口")
                    TextField("", value: $settings.socksPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Servers (GPU)

    private var serversTab: some View {
        VStack(spacing: 0) {
            List {
                ForEach($settings.gpuServers) { $server in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("别名", text: $server.alias)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            TextField("用户名", text: $server.user)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            TextField("主机", text: $server.host)
                                .textFieldStyle(.roundedBorder)
                            TextField("端口", value: $server.port, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { indexSet in
                    settings.gpuServers.remove(atOffsets: indexSet)
                }
            }

            Divider()
            HStack {
                Button {
                    settings.gpuServers.append(
                        GPUServer(alias: "新服务器", user: "root", host: "", port: 22)
                    )
                } label: {
                    Label("添加", systemImage: "plus")
                }

                Spacer()

                Button("恢复默认") {
                    settings.gpuServers = GPUServer.defaultServers
                }

                Spacer()

                HStack {
                    Text("刷新间隔")
                    TextField("", value: $settings.gpuRefreshInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Text("秒")
                }
                .font(.caption)
            }
            .padding(8)
        }
    }

    // MARK: - Behavior

    private var behaviorTab: some View {
        Form {
            Section("自动策略") {
                Toggle("非校园网自动连接 VPN", isOn: $settings.autoConnect)
                Toggle("断线自动重连", isOn: $settings.autoReconnect)
                Toggle("登录时自动启动", isOn: $settings.launchAtLogin)

                HStack {
                    Text("校园网关键词")
                    TextField("", text: $settings.campusKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                Text("Wi-Fi 名称包含此关键词时视为校园网，使用直连模式")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("默认模式") {
                Picker("代理模式", selection: $settings.defaultMode) {
                    ForEach(ProxyMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("SOCKS5：仅本地代理端口，适合终端/SSH 使用\n系统全局代理：全部流量通过代理，适合浏览器访问")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        Form {
            Section("EasyConnect") {
                HStack {
                    Text("版本号")
                    TextField("", text: $settings.easyConnectVersion)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                Text("对应 docker-easyconnect 使用的 EC_VER 参数")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("运行环境") {
                HStack {
                    Text("容器运行时")
                    Text(ContainerRuntime.shared.detectedRuntime.rawValue)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                HStack {
                    Text("运行时状态")
                    Circle()
                        .fill(ContainerRuntime.shared.isReady ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(ContainerRuntime.shared.isReady ? "就绪" : "未就绪")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            Section("诊断") {
                Button("打开日志窗口") {
                    WindowManager.shared.showLogWindow()
                }
                Button("重新运行初始设置...") {
                    settings.hasCompletedOnboarding = false
                    if let d = NSApp.delegate as? AppDelegate { d.showOnboardingWindow() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
