import SwiftUI

struct LogView: View {
    @StateObject private var logger = AppLogger.shared
    @State private var filterLevel: AppLogger.LogEntry.Level?
    @State private var autoScroll = true
    @State private var showDebug = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logContent
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    private var toolbar: some View {
        HStack {
            Text("日志")
                .font(.headline)

            Spacer()

            Picker("级别", selection: $filterLevel) {
                Text("常规").tag(Optional<AppLogger.LogEntry.Level>.none)
                Text("INFO").tag(Optional<AppLogger.LogEntry.Level>.some(.info))
                Text("WARN").tag(Optional<AppLogger.LogEntry.Level>.some(.warn))
                Text("ERROR").tag(Optional<AppLogger.LogEntry.Level>.some(.error))
                Text("DEBUG").tag(Optional<AppLogger.LogEntry.Level>.some(.debug))
            }
            .frame(width: 120)

            Toggle("显示调试", isOn: $showDebug)

            Toggle("自动滚动", isOn: $autoScroll)

            Button("清除") {
                logger.clear()
            }
        }
        .padding(8)
    }

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredEntries) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: logger.entries.count) {
                if autoScroll, let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var filteredEntries: [AppLogger.LogEntry] {
        if let level = filterLevel {
            return logger.entries.filter { $0.level == level }
        }
        return showDebug ? logger.entries : logger.entries.filter { $0.level != .debug }
    }

    private func logRow(_ entry: AppLogger.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.formatted)
                .foregroundColor(logColor(for: entry.level))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func logColor(for level: AppLogger.LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        case .debug: return .secondary
        }
    }
}
