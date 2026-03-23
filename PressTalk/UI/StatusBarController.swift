import AppKit
import Combine

final class StatusBarController {
    private let statusItem: NSStatusItem
    private let state = AppState.shared
    private var cancellables = Set<AnyCancellable>()
    private var countItem: NSMenuItem!
    private var smartItem: NSMenuItem!
    private let onOpenSettings: () -> Void

    private let icons: [InputState: String] = [
        .idle: "●",
        .recording: "◉",
        .transcribing: "◌",
        .done: "✓",
    ]

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = icons[.idle]!
        statusItem.button?.font = NSFont.systemFont(ofSize: 14)

        buildMenu()
        observeState()
    }

    private func buildMenu() {
        let menu = NSMenu()

        countItem = NSMenuItem(title: "今日转录：0 次", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        menu.addItem(countItem)

        menu.addItem(.separator())

        smartItem = NSMenuItem(title: "智能整理（右 Command）",
                               action: #selector(toggleSmart(_:)),
                               keyEquivalent: "")
        smartItem.target = self
        smartItem.state = state.smartModeEnabled && state.hasDeepSeekConfig ? .on : .off
        menu.addItem(smartItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…",
                                       action: #selector(openSettings),
                                       keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func observeState() {
        state.$currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self else { return }
                self.statusItem.button?.title = self.icons[newState] ?? "●"
            }
            .store(in: &cancellables)

        state.$transcriptionCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.countItem.title = "今日转录：\(count) 次"
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    @objc private func toggleSmart(_ sender: NSMenuItem) {
        if !state.hasDeepSeekConfig {
            let alert = NSAlert()
            alert.messageText = "未配置 DeepSeek API Key"
            alert.informativeText = "请打开「设置」填写 DEEPSEEK_API_KEY。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }
        state.smartModeEnabled.toggle()
        sender.state = state.smartModeEnabled ? .on : .off
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
