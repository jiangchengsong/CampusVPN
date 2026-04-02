import Foundation
import os

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published var entries: [LogEntry] = []
    private let maxEntries = 500
    private let osLog = Logger(subsystem: "com.campusvpn.CampusVPN", category: "app")

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String

        enum Level: String {
            case info = "INFO"
            case warn = "WARN"
            case error = "ERROR"
            case debug = "DEBUG"
        }

        var formatted: String {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            return "[\(df.string(from: timestamp))] [\(level.rawValue)] \(message)"
        }
    }

    private init() {}

    func info(_ message: String) {
        append(.init(timestamp: Date(), level: .info, message: message))
        osLog.info("\(message)")
    }

    func warn(_ message: String) {
        append(.init(timestamp: Date(), level: .warn, message: message))
        osLog.warning("\(message)")
    }

    func error(_ message: String) {
        append(.init(timestamp: Date(), level: .error, message: message))
        osLog.error("\(message)")
    }

    func debug(_ message: String) {
        append(.init(timestamp: Date(), level: .debug, message: message))
        osLog.debug("\(message)")
    }

    func clear() {
        entries.removeAll()
    }

    private func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}
