import AppKit
import SwiftUI

@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var logWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private init() {}

    func showLogWindow() {
        if let w = logWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = makeWindow(
            title: "CampusVPN 日志",
            view: LogView(),
            size: NSSize(width: 650, height: 420),
            resizable: true
        )
        window.minSize = NSSize(width: 400, height: 250)
        logWindow = window
    }

    func showSettingsWindow() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = makeWindow(
            title: "CampusVPN 设置",
            view: SettingsView(),
            size: NSSize(width: 500, height: 440),
            resizable: false
        )
        settingsWindow = window
    }

    private func makeWindow<V: View>(title: String, view: V, size: NSSize, resizable: Bool) -> NSWindow {
        dismissMenuBarPanel()

        let controller = NSHostingController(rootView: view)
        var mask: NSWindow.StyleMask = [.titled, .closable]
        if resizable { mask.insert([.resizable, .miniaturizable]) }

        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = mask
        window.setContentSize(size)
        window.center()

        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.level = .floating
            NSApp.activate(ignoringOtherApps: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                window.level = .normal
            }
        }

        return window
    }

    private func dismissMenuBarPanel() {
        for window in NSApp.windows where window != logWindow && window != settingsWindow {
            if window is NSPanel {
                window.orderOut(nil)
            }
        }
    }
}
