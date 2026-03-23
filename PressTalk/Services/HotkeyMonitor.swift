import CoreGraphics
import Foundation

/// 全局热键监听器：右 Option(61) → 普通转录，右 Command(54) → 智能整理
final class HotkeyMonitor {
    // 右 Option = keyCode 61, 右 Command = keyCode 54
    private let rightOptionKeyCode: CGKeyCode = 61
    private let rightCommandKeyCode: CGKeyCode = 54

    var onRecordingStart: ((_ smartMode: Bool) -> Void)?
    var onRecordingStop: ((_ smartMode: Bool) -> Void)?

    private var activeKeyCode: CGKeyCode? = nil
    private var isProcessing = false
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitorThread: Thread?

    /// 在后台线程启动 CGEventTap 监听
    func start() {
        let thread = Thread { [weak self] in
            self?.setupEventTap()
            CFRunLoopRun()
        }
        thread.name = "HotkeyMonitor"
        thread.qualityOfService = .userInteractive
        thread.start()
        monitorThread = thread
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// 标记处理完成（由外部调用）
    func markProcessingDone() {
        lock.lock()
        isProcessing = false
        lock.unlock()
    }

    private func setupEventTap() {
        // 需要监听 flagsChanged（修饰键按下/释放）
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        // 使用 Unmanaged 传递 self
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleFlagsChanged(event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            print("[错误] 无法创建 CGEventTap，请确认已授予辅助功能权限")
            return
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        guard keyCode == rightOptionKeyCode || keyCode == rightCommandKeyCode else {
            return
        }

        // 判断是按下还是释放：检查对应的修饰键标志是否存在
        let isKeyDown: Bool
        if keyCode == rightOptionKeyCode {
            isKeyDown = flags.contains(.maskAlternate)
        } else {
            isKeyDown = flags.contains(.maskCommand)
        }

        if isKeyDown {
            handleKeyDown(keyCode: keyCode)
        } else {
            handleKeyUp(keyCode: keyCode)
        }
    }

    private func handleKeyDown(keyCode: CGKeyCode) {
        lock.lock()
        defer { lock.unlock() }

        // 已有活跃键或正在处理中，忽略
        guard activeKeyCode == nil, !isProcessing else { return }
        activeKeyCode = keyCode

        let smartMode = (keyCode == rightCommandKeyCode)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.onRecordingStart?(smartMode)
        }
    }

    private func handleKeyUp(keyCode: CGKeyCode) {
        lock.lock()
        guard activeKeyCode == keyCode else {
            lock.unlock()
            return
        }
        let smartMode = (keyCode == rightCommandKeyCode)
        activeKeyCode = nil
        isProcessing = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.onRecordingStop?(smartMode)
        }
    }
}
