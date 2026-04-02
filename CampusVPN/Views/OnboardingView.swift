import SwiftUI

struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var runtime = ContainerRuntime.shared
    @State private var password: String = ""
    @State private var currentStep: Int = 0
    @State private var isSettingUp = false
    @State private var setupError: String?

    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 24)
                .padding(.bottom, 12)

            Divider()

            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: credentialsStep
                case 2: runtimeStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.slide)
            .animation(.easeInOut(duration: 0.25), value: currentStep)

            Divider()
            navigationFooter
                .padding(16)
        }
        .frame(width: 520, height: 480)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<4) { step in
                Circle()
                    .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)
                if step < 3 {
                    Rectangle()
                        .fill(step < currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                        .frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 100)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "shield.checkered")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("欢迎使用 CampusVPN")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("自动管理校园 VPN 连接\n校园网自动直连，外部网络自动开启 VPN")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                featureRow("wifi", "Wi-Fi 智能识别", "自动检测校园网环境")
                featureRow("arrow.triangle.2.circlepath", "自动重连", "断线后指数退避重试")
                featureRow("network", "双模式", "SOCKS5 代理或系统全局代理")
                featureRow("hand.raised", "手动控制", "随时可切换为手动模式")
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)

            Spacer()
        }
    }

    private var credentialsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "person.badge.key")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("配置 VPN 账号")
                .font(.title)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("服务器地址").font(.callout).foregroundColor(.secondary)
                    TextField("https://vpn.example.edu.cn", text: $settings.serverURL)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("用户名（学号）").font(.callout).foregroundColor(.secondary)
                    TextField("请输入学号", text: $settings.username)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("密码").font(.callout).foregroundColor(.secondary)
                    SecureField("请输入密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(width: 320)

            HStack(spacing: 4) {
                Image(systemName: "lock.shield")
                    .foregroundColor(.green)
                Text("凭据将安全存储在系统钥匙串中，不会明文保存")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var runtimeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("配置运行环境")
                .font(.title)
                .fontWeight(.bold)

            if isSettingUp {
                ProgressView()
                    .controlSize(.large)
                    .padding(.top, 8)
                Text(runtime.setupProgress)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            } else if runtime.isReady {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                    .padding(.top, 8)
                Text("运行环境已就绪")
                    .font(.headline)
                Text(runtime.detectedRuntime.rawValue)
                    .foregroundColor(.secondary)
            } else if let error = setupError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.red)
                    .padding(.top, 8)
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("重试") {
                    Task { await setupRuntime() }
                }
                .controlSize(.large)
                .padding(.top, 4)
            } else {
                Text("CampusVPN 需要容器运行环境来运行 EasyConnect。\n点击「下一步」开始自动配置。")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
        .task(id: currentStep) {
            if currentStep == 2 && !runtime.isReady && !isSettingUp {
                await setupRuntime()
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("设置完成")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("CampusVPN 已准备就绪\n它将常驻菜单栏，自动管理你的 VPN 连接")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - Navigation

    private var navigationFooter: some View {
        HStack {
            if currentStep > 0 {
                Button("上一步") {
                    withAnimation { currentStep -= 1 }
                }
                .controlSize(.large)
            }

            Spacer()

            if currentStep < 3 {
                Button("下一步") {
                    handleNext()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(currentStep == 1 && (settings.username.isEmpty || password.isEmpty))
                .disabled(currentStep == 2 && isSettingUp)
            } else {
                Button("开始使用") {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Helpers

    private func featureRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 24)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func handleNext() {
        if currentStep == 1 {
            KeychainService.savedPassword = password
        }
        withAnimation { currentStep += 1 }
    }

    private func setupRuntime() async {
        isSettingUp = true
        setupError = nil
        let ok = await runtime.ensureReady()
        isSettingUp = false
        if !ok {
            setupError = "运行环境配置失败\n请确保已安装 Docker Desktop、OrbStack 或 Homebrew"
        }
    }

    private func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        onFinish()
    }
}
