import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?
    private var onboardingWindowCloseDelegate: WindowCloseDelegate?
    private var logWindow: NSWindow?
    private var logWindowCloseDelegate: WindowCloseDelegate?
    private var settingsWindow: NSWindow?
    private var settingsWindowCloseDelegate: WindowCloseDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.shared

        if settings.launchAtLogin {
            enableLoginItem()
        }

        if !settings.hasCompletedOnboarding {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            return
        }

        Task { @MainActor in
            await startServices()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            await ProxyManager.shared.disableSystemProxy()
            await EasyConnectService.shared.stop()
            GPUMonitorService.shared.stopPeriodicRefresh()
        }
    }

    @MainActor
    func startServices() async {
        let engine = NetworkPolicyEngine.shared
        await engine.start(with: VPNState.shared)
        GPUMonitorService.shared.startPeriodicRefresh(
            interval: AppSettings.shared.gpuRefreshInterval
        )
    }

    // MARK: - Window Management

    @MainActor
    func showOnboardingWindow() {
        if let existing = onboardingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView(onFinish: { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            Task { @MainActor in
                await self?.startServices()
            }
        })

        ActivationPolicyManager.beginAuxiliaryWindow()

        let controller = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: controller)
        window.title = "CampusVPN 初始设置"
        window.setContentSize(NSSize(width: 520, height: 480))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()

        let closeDel = WindowCloseDelegate()
        closeDel.onWindowWillClose = { [weak self] in
            ActivationPolicyManager.endAuxiliaryWindow()
            self?.onboardingWindowCloseDelegate = nil
        }
        window.delegate = closeDel
        onboardingWindowCloseDelegate = closeDel

        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window
    }

    @MainActor
    func showLogWindow() {
        if let existing = logWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        ActivationPolicyManager.beginAuxiliaryWindow()

        let controller = NSHostingController(rootView: LogView())
        let window = NSWindow(contentViewController: controller)
        window.title = "CampusVPN 日志"
        window.setContentSize(NSSize(width: 650, height: 420))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.minSize = NSSize(width: 400, height: 250)
        window.center()

        let closeDel = WindowCloseDelegate()
        closeDel.onWindowWillClose = { [weak self] in
            ActivationPolicyManager.endAuxiliaryWindow()
            self?.logWindowCloseDelegate = nil
        }
        window.delegate = closeDel
        logWindowCloseDelegate = closeDel

        window.makeKeyAndOrderFront(nil)

        self.logWindow = window
    }

    @MainActor
    func showSettingsWindow() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        ActivationPolicyManager.beginAuxiliaryWindow()

        let controller = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: controller)
        window.title = "CampusVPN 设置"
        window.setContentSize(NSSize(width: 500, height: 440))
        window.styleMask = [.titled, .closable]
        window.center()

        let closeDel = WindowCloseDelegate()
        closeDel.onWindowWillClose = { [weak self] in
            ActivationPolicyManager.endAuxiliaryWindow()
            self?.settingsWindowCloseDelegate = nil
        }
        window.delegate = closeDel
        settingsWindowCloseDelegate = closeDel

        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window
    }

    // MARK: - Login Item

    func enableLoginItem() {
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
    }

    func disableLoginItem() {
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.unregister()
        }
    }
}
