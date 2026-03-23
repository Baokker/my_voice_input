import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var hotkeyMonitor: HotkeyMonitor!
    private var recorder: AudioRecorder!
    private var transcriber: VolcanoTranscriber!
    private let state = AppState.shared
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化菜单栏
        statusBarController = StatusBarController(onOpenSettings: { [weak self] in
            self?.showSettingsWindow()
        })

        // 初始化核心服务
        recorder = AudioRecorder()
        transcriber = VolcanoTranscriber()
        hotkeyMonitor = HotkeyMonitor()

        // 设置热键回调
        hotkeyMonitor.onRecordingStart = { [weak self] smartMode in
            self?.handleRecordingStart(smartMode: smartMode)
        }
        hotkeyMonitor.onRecordingStop = { [weak self] smartMode in
            self?.handleRecordingStop(smartMode: smartMode)
        }

        // 请求辅助功能权限
        _ = PermissionChecker.isAccessibilityTrusted(prompt: true)

        // 启动热键监听
        hotkeyMonitor.start()

        // 预热 WebSocket
        transcriber.warmup()

        // 首次运行（无 API Key）自动打开设置
        if !state.hasVolcConfig {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showSettingsWindow()
            }
        }

        print("PressTalk 已启动")
        print("  【右 Option】按住说话，松开 → 转录并输入")
        if state.hasDeepSeekConfig {
            print("  【右 Command】按住说话，松开 → 转录 + 智能整理")
        }
    }

    // MARK: - 设置窗口

    func showSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "PressTalk 设置"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.settingsWindow = window
    }

    // MARK: - 热键处理

    private func handleRecordingStart(smartMode: Bool) {
        DispatchQueue.main.async { self.state.currentState = .recording }
        recorder.start()
    }

    private func handleRecordingStop(smartMode: Bool) {
        let pcmData = recorder.stop()

        Task.detached { [weak self] in
            guard let self else { return }
            await MainActor.run { self.state.currentState = .transcribing }

            do {
                print("[转录中...]")
                var text = try await self.transcriber.transcribe(pcmData: pcmData)

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print("[未识别到有效语音]")
                    await MainActor.run { self.state.currentState = .idle }
                    self.hotkeyMonitor.markProcessingDone()
                    return
                }

                // 智能整理模式
                if smartMode && self.state.smartModeEnabled && self.state.hasDeepSeekConfig {
                    let preview = String(text.prefix(80))
                    print("[原文] \(preview)\(text.count > 80 ? "..." : "")")
                    print("[整理中...]")
                    text = try await DeepSeekFormatter.formatSmart(text: text)
                    let result = String(text.prefix(80))
                    print("[整理后] \(result)\(text.count > 80 ? "..." : "")")
                } else {
                    let result = String(text.prefix(80))
                    print("[识别结果] \(result)\(text.count > 80 ? "..." : "")")
                }

                TextInjector.inject(text: text)

                await MainActor.run {
                    self.state.currentState = .done
                    self.state.transcriptionCount += 1
                }

                // 0.8 秒后恢复 idle
                try? await Task.sleep(nanoseconds: 800_000_000)
                await MainActor.run { self.state.currentState = .idle }

            } catch {
                print("[错误] \(error.localizedDescription)")
                await MainActor.run { self.state.currentState = .idle }
            }

            self.hotkeyMonitor.markProcessingDone()
        }
    }
}
