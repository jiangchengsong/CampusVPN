import AppKit

/// LSUIElement 应用默认是 `.accessory`，独立窗口往往无法成为键盘第一响应者，TextField 会无法输入。
/// 在需要键盘的窗口显示期间将策略切为 `.regular`，全部关闭后再恢复 `.accessory`。
@MainActor
enum ActivationPolicyManager {
    private static var auxiliaryWindowDepth = 0

    static func beginAuxiliaryWindow() {
        if auxiliaryWindowDepth == 0 {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        auxiliaryWindowDepth += 1
    }

    static func endAuxiliaryWindow() {
        auxiliaryWindowDepth -= 1
        if auxiliaryWindowDepth <= 0 {
            auxiliaryWindowDepth = 0
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
