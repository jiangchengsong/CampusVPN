import Foundation
import Darwin

struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
}

enum ShellExecutor {

    static func run(_ command: String, environment: [String: String]? = nil, timeout: TimeInterval? = nil) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runSync(command, environment: environment, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }

    static func runSync(_ command: String, environment: [String: String]? = nil, timeout: TimeInterval? = nil) -> ShellResult {
        runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", command],
            environment: environment,
            timeout: timeout
        )
    }

    static func runExecutable(
        _ executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runProcess(
                    executableURL: URL(fileURLWithPath: executablePath),
                    arguments: arguments,
                    environment: environment,
                    timeout: timeout
                )
                continuation.resume(returning: result)
            }
        }
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) -> ShellResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.environment = makeEnvironment(overrides: environment)

        var stdoutData = Data()
        var stderrData = Data()
        let outputGroup = DispatchGroup()

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        let lock = NSLock()
        var timedOut = false
        var timeoutWorkItem: DispatchWorkItem?

        do {
            try process.run()
        } catch {
            return ShellResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        if let timeout {
            let item = DispatchWorkItem {
                lock.lock()
                timedOut = process.isRunning
                if timedOut {
                    process.terminate()
                }
                lock.unlock()

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
            timeoutWorkItem = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
        }

        process.waitUntilExit()
        timeoutWorkItem?.cancel()
        outputGroup.wait()

        lock.lock()
        let didTimeOut = timedOut
        lock.unlock()

        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if didTimeOut {
            let seconds = timeout.map { String(format: "%.0f", $0) } ?? ""
            let timeoutMessage = seconds.isEmpty ? "命令超时" : "命令超时（\(seconds) 秒）"
            stderr = stderr.isEmpty ? timeoutMessage : "\(stderr)\n\(timeoutMessage)"
        }

        return ShellResult(
            exitCode: didTimeOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func makeEnvironment(overrides: [String: String]? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")

        if (env["SSH_AUTH_SOCK"] ?? "").isEmpty, let socket = discoverSSHAuthSocket() {
            env["SSH_AUTH_SOCK"] = socket
        }

        if let extra = overrides {
            for (k, v) in extra { env[k] = v }
        }

        return env
    }

    private static func discoverSSHAuthSocket() -> String? {
        let fileManager = FileManager.default
        let currentUID = NSNumber(value: getuid())

        for basePath in ["/var/run", "/private/tmp"] {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: basePath) else {
                continue
            }

            for entry in entries where entry.hasPrefix("com.apple.launchd.") {
                let socketPath = "\(basePath)/\(entry)/Listeners"
                guard fileManager.fileExists(atPath: socketPath),
                      let attributes = try? fileManager.attributesOfItem(atPath: socketPath),
                      let owner = attributes[.ownerAccountID] as? NSNumber,
                      owner == currentUID
                else {
                    continue
                }
                return socketPath
            }
        }

        return nil
    }

    static func stream(_ command: String, onOutput: @escaping (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = pipe

                process.environment = makeEnvironment()

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                    onOutput(line)
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    onOutput("Error: \(error.localizedDescription)")
                    continuation.resume(returning: -1)
                    return
                }

                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }
}
