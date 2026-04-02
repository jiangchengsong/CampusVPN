import SwiftUI

@main
struct CampusVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var vpnState = VPNState.shared
    @ObservedObject private var gpuMonitor = GPUMonitorService.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(vpnState: vpnState)
        } label: {
            let free = gpuMonitor.totalFree
            let total = gpuMonitor.totalGPUs
            if total > 0 {
                Text("GPU: \(free)/\(total)")
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("GPU: --")
                    .font(.system(.body, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)
    }
}
