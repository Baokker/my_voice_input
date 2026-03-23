import Network
import SwiftUI

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}

private struct PermissionSnapshot: Equatable {
    let accessibility: PermissionStatus
    let inputMonitoring: PermissionStatus
    let microphone: PermissionStatus
}

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @State private var accessibilityStatus = PermissionChecker.accessibilityStatus
    @State private var inputMonitoringStatus = PermissionChecker.inputMonitoringStatus
    @State private var microphoneStatus = PermissionChecker.microphoneStatus
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var permissionHint: String?
    @State private var permissionPollingTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("1. 火山引擎配置") {
                TextField("App ID", text: $state.volcAppId)
                    .textFieldStyle(.roundedBorder)
                SecureField("Access Key", text: $state.volcAccessKey)
                    .textFieldStyle(.roundedBorder)
                Link("前往控制台获取 →",
                     destination: URL(string: "https://console.volcengine.com/speech/service/10038")!)
                    .font(.caption)
            }

            Section("2. DeepSeek 配置（可选）") {
                SecureField("API Key", text: $state.deepseekApiKey)
                    .textFieldStyle(.roundedBorder)
                Link("获取 API Key →",
                     destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                    .font(.caption)
            }

            Section("3. 授予系统权限") {
                permissionRow("辅助功能", status: accessibilityStatus,
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                permissionRow("输入监控", status: inputMonitoringStatus,
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                permissionRow("麦克风", status: microphoneStatus,
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

                Button("刷新权限状态") {
                    refreshPermissions()
                }

                Text("如果你是从旧版 VoiceInput 升级，PressTalk 会被系统视为新的 App，需要重新授予辅助功能和输入监控权限。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let permissionHint {
                    Text(permissionHint)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section("4. 使用说明") {
                Text("打开 PressTalk 后，先填写 API Key，再授予权限。")
                    .foregroundColor(.secondary)
                Text("右 Option：按住说话，松开后转录并输入文字。")
                    .foregroundColor(.secondary)
                Text("右 Command：同上，转录后再由 DeepSeek 智能整理。")
                    .foregroundColor(.secondary)
            }

            Section("5. 诊断") {
                HStack {
                    Button(isTesting ? "连接中…" : "测试连接") {
                        testConnection()
                    }
                    .disabled(isTesting)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("成功") ? .green : .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .onAppear {
            refreshPermissions()
        }
        .onDisappear {
            stopPermissionPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshPermissions()
        }
    }

    private func permissionRow(_ name: String, status: PermissionStatus, url: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(status.rawValue)
                .foregroundColor(statusColor(status))
            Button("前往设置") {
                let baseline = currentSnapshot()
                permissionHint = nil
                PermissionChecker.openSystemSettings(url: url)
                startPermissionPolling(from: baseline)
            }
            .font(.caption)
        }
    }

    private func statusColor(_ status: PermissionStatus) -> Color {
        switch status {
        case .authorized: return .green
        case .denied: return .red
        case .undetermined, .unknown: return .orange
        }
    }

    @discardableResult
    private func refreshPermissions() -> PermissionSnapshot {
        let snapshot = PermissionSnapshot(
            accessibility: PermissionChecker.accessibilityStatus,
            inputMonitoring: PermissionChecker.inputMonitoringStatus,
            microphone: PermissionChecker.microphoneStatus
        )
        accessibilityStatus = snapshot.accessibility
        inputMonitoringStatus = snapshot.inputMonitoring
        microphoneStatus = snapshot.microphone
        return snapshot
    }

    private func currentSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibility: accessibilityStatus,
            inputMonitoring: inputMonitoringStatus,
            microphone: microphoneStatus
        )
    }

    private func startPermissionPolling(from baseline: PermissionSnapshot) {
        stopPermissionPolling()
        permissionPollingTask = Task { @MainActor in
            for _ in 0..<18 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }

                let latest = refreshPermissions()
                if latest != baseline {
                    permissionHint = nil
                    permissionPollingTask = nil
                    return
                }
            }

            permissionHint = "如果系统里已完成授权但这里仍未更新，请退出并重新打开 PressTalk。"
            permissionPollingTask = nil
        }
    }

    private func stopPermissionPolling() {
        permissionPollingTask?.cancel()
        permissionPollingTask = nil
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task.detached {
            do {
                let success = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Bool, Error>) in
                    let queue = DispatchQueue(label: "test.connection")
                    let gate = ContinuationGate()
                    let conn = NWConnection(
                        host: "openspeech.bytedance.com",
                        port: 443,
                        using: .tls
                    )
                    conn.stateUpdateHandler = { st in
                        switch st {
                        case .ready:
                            guard gate.tryResume() else { return }
                            conn.cancel()
                            continuation.resume(returning: true)
                        case .failed(let error):
                            guard gate.tryResume() else { return }
                            conn.cancel()
                            continuation.resume(throwing: error)
                        default:
                            break
                        }
                    }
                    conn.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 5) {
                        guard gate.tryResume() else { return }
                        conn.cancel()
                        continuation.resume(returning: false)
                    }
                }

                await MainActor.run {
                    testResult = success ? "连接成功！" : "连接超时"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "连接失败: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
