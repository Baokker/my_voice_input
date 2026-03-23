import AppKit
import Foundation
import AVFoundation
import ApplicationServices
import IOKit

enum PermissionStatus: String {
    case authorized = "✓ 已授权"
    case denied     = "✗ 未授权"
    case undetermined = "? 未确定"
    case unknown    = "? 检测失败"
}

enum PermissionChecker {

    // MARK: - 辅助功能

    static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    static var accessibilityStatus: PermissionStatus {
        AXIsProcessTrusted() ? .authorized : .denied
    }

    // MARK: - 输入监控

    static var inputMonitoringStatus: PermissionStatus {
        // IOHIDCheckAccess(1) — 1 = kIOHIDRequestTypeListenEvent
        typealias IOHIDCheckAccessFunc = @convention(c) (Int32) -> UInt32
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let sym = dlsym(handle, "IOHIDCheckAccess") else {
            return .unknown
        }
        let fn = unsafeBitCast(sym, to: IOHIDCheckAccessFunc.self)
        let status = fn(1)
        switch status {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .undetermined
        default: return .unknown
        }
    }

    // MARK: - 麦克风

    static var microphoneStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .unknown
        }
    }

    static func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    // MARK: - 深链接

    static let permissionURLs: [(name: String, url: String)] = [
        ("辅助功能", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
        ("输入监控", "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
        ("麦克风",   "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
    ]

    static func openSystemSettings(url: String) {
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}
