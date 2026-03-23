import AppKit
import CoreGraphics

enum TextInjector {

    /// 将文字注入到当前光标位置（剪贴板 + 模拟 Cmd+V）
    static func inject(text: String) {
        guard !text.isEmpty else { return }

        // 1. 写入剪贴板
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 2. 等待剪贴板就绪
        usleep(100_000) // 100ms

        // 3. 模拟 Cmd+V
        simulateCmdV()
    }

    private static func simulateCmdV() {
        let vKeyCode: CGKeyCode = 0x09 // kVK_ANSI_V

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else {
            print("[错误] 无法创建 CGEvent，请检查辅助功能权限")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
