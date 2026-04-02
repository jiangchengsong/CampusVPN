import Foundation

enum RuntimeType: String {
    case dockerDesktop = "Docker Desktop"
    case orbStack = "OrbStack"
    case colima = "Colima"
    case none = "未检测到"
}

@MainActor
final class ContainerRuntime: ObservableObject {
    static let shared = ContainerRuntime()

    @Published var detectedRuntime: RuntimeType = .none
    @Published var isReady: Bool = false
    @Published var setupProgress: String = ""

    private let logger = AppLogger.shared
    private let appSupportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CampusVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    func detectRuntime() async -> RuntimeType {
        let dockerCheck = await ShellExecutor.run("docker info 2>/dev/null")
        if dockerCheck.succeeded {
            if dockerCheck.stdout.contains("orbstack") || dockerCheck.stdout.contains("OrbStack") {
                detectedRuntime = .orbStack
            } else if dockerCheck.stdout.contains("Docker Desktop") || dockerCheck.stdout.contains("desktop") {
                detectedRuntime = .dockerDesktop
            } else {
                let colimaCheck = await ShellExecutor.run("colima status 2>/dev/null")
                detectedRuntime = colimaCheck.succeeded ? .colima : .dockerDesktop
            }
            isReady = true
            logger.info("检测到容器运行时: \(detectedRuntime.rawValue)")
            return detectedRuntime
        }

        let colimaExists = await ShellExecutor.run("which colima")
        if colimaExists.succeeded {
            detectedRuntime = .colima
            logger.info("检测到 Colima，但未运行，正在启动...")
            return await startColima() ? .colima : .none
        }

        detectedRuntime = .none
        return .none
    }

    func ensureReady() async -> Bool {
        let runtime = await detectRuntime()
        if runtime != .none && isReady { return true }

        if runtime == .none {
            logger.info("未检测到容器运行时，开始自动安装...")
            return await installAndSetupRuntime()
        }

        return isReady
    }

    private func installAndSetupRuntime() async -> Bool {
        setupProgress = "检查 Homebrew..."
        let brewCheck = await ShellExecutor.run("which brew")
        if !brewCheck.succeeded {
            setupProgress = "正在安装 Homebrew..."
            logger.info("正在安装 Homebrew...")
            let installBrew = await ShellExecutor.run(
                "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
            if !installBrew.succeeded {
                logger.error("Homebrew 安装失败: \(installBrew.stderr)")
                setupProgress = "Homebrew 安装失败"
                return false
            }
        }

        setupProgress = "正在安装 Docker CLI..."
        logger.info("正在安装 Docker CLI...")
        let dockerInstall = await ShellExecutor.run("brew install docker")
        if !dockerInstall.succeeded {
            logger.error("Docker CLI 安装失败: \(dockerInstall.stderr)")
            setupProgress = "Docker CLI 安装失败"
            return false
        }

        setupProgress = "正在安装 Colima..."
        logger.info("正在安装 Colima...")
        let colimaInstall = await ShellExecutor.run("brew install colima")
        if !colimaInstall.succeeded {
            logger.error("Colima 安装失败: \(colimaInstall.stderr)")
            setupProgress = "Colima 安装失败"
            return false
        }

        return await startColima()
    }

    private func startColima() async -> Bool {
        setupProgress = "正在启动 Colima 虚拟机..."
        logger.info("正在启动 Colima...")
        let start = await ShellExecutor.run(
            "colima start --cpu 2 --memory 2 --disk 10 --profile campusvpn 2>&1")
        if start.succeeded {
            isReady = true
            detectedRuntime = .colima
            setupProgress = "运行环境就绪"
            logger.info("Colima 启动成功")
            return true
        }

        logger.error("Colima 启动失败: \(start.stderr)")
        setupProgress = "Colima 启动失败"
        return false
    }

    func stopRuntime() async {
        if detectedRuntime == .colima {
            logger.info("正在停止 Colima...")
            _ = await ShellExecutor.run("colima stop --profile campusvpn 2>/dev/null")
        }
        isReady = false
    }

    func runDocker(_ args: String) async -> ShellResult {
        var envOverride: [String: String]? = nil
        if detectedRuntime == .colima {
            let socketPath = "\(NSHomeDirectory())/.colima/campusvpn/docker.sock"
            envOverride = ["DOCKER_HOST": "unix://\(socketPath)"]
        }
        return await ShellExecutor.run("docker \(args)", environment: envOverride)
    }

    func dockerLogs(_ container: String, tail: Int = 50) async -> String {
        let result = await runDocker("logs --tail \(tail) \(container) 2>&1")
        return result.stdout
    }

    func pullImageIfNeeded(_ image: String) async -> Bool {
        setupProgress = "检查镜像 \(image)..."
        let check = await runDocker("image inspect \(image) 2>/dev/null")
        if check.succeeded {
            logger.info("镜像已存在: \(image)")
            return true
        }

        setupProgress = "正在拉取镜像 \(image)..."
        logger.info("拉取镜像: \(image)")
        let pull = await runDocker("pull \(image)")
        if pull.succeeded {
            logger.info("镜像拉取完成: \(image)")
            setupProgress = "镜像就绪"
            return true
        }

        logger.error("镜像拉取失败: \(pull.stderr)")
        setupProgress = "镜像拉取失败"
        return false
    }
}
