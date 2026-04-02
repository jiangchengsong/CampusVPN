import AppKit

/// 在窗口关闭时执行回调（用于恢复 LSUIElement 激活策略等）。
final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    var onWindowWillClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onWindowWillClose?()
        onWindowWillClose = nil
    }
}
