import Foundation

struct GPUServer: Identifiable, Codable, Equatable {
    var id: String { alias }
    var alias: String
    var user: String
    var host: String
    var port: Int

    var sshTarget: String { "\(user)@\(host)" }
}

struct GPUInfo: Identifiable {
    let id: String
    let index: Int
    let name: String
    let utilization: Int
    let memoryFree: Int
    let memoryTotal: Int

    var isFree: Bool { utilization < 5 && memoryFree > 4000 }
    var memoryUsed: Int { memoryTotal - memoryFree }
}

struct ServerGPUStatus: Identifiable {
    let id: String
    let server: GPUServer
    var gpus: [GPUInfo]
    var reachable: Bool
    var errorMessage: String?

    var freeCount: Int { gpus.filter(\.isFree).count }
    var totalCount: Int { gpus.count }
}

extension GPUServer {
    static let defaultServers: [GPUServer] = [
        GPUServer(alias: "server1", user: "user", host: "192.168.1.100", port: 22),
    ]
}
