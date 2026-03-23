import Foundation
import SwiftUI

enum InputState: String {
    case idle, recording, transcribing, done
}

/// 全局共享状态
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var currentState: InputState = .idle
    @Published var transcriptionCount: Int = 0

    // 设置项，持久化到 UserDefaults
    @AppStorage("volcAppId") var volcAppId: String = ""
    @AppStorage("volcAccessKey") var volcAccessKey: String = ""
    @AppStorage("deepseekApiKey") var deepseekApiKey: String = ""
    @AppStorage("deepseekModel") var deepseekModel: String = "deepseek-chat"
    @AppStorage("smartModeEnabled") var smartModeEnabled: Bool = true

    var hasVolcConfig: Bool {
        !volcAppId.isEmpty && !volcAccessKey.isEmpty
    }

    var hasDeepSeekConfig: Bool {
        !deepseekApiKey.isEmpty
    }

    private init() {}
}
