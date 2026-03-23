import Foundation

enum FormatterError: LocalizedError {
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return "DeepSeek API 错误: \(msg)"
        case .invalidResponse: return "DeepSeek 返回了无效的响应"
        }
    }
}

enum DeepSeekFormatter {
    private static let baseURL = "https://api.deepseek.com/chat/completions"

    private static let smartPrompt = """
    你是一个语音转录后处理助手，风格极度保守。你的工作是最小化整理：

    规则：
    1. 删除口头禅和停顿词（嗯、啊、那个、就是、然后然后、好吧好吧 等），直接删除，不替换
    2. 处理自我纠正：当说话者中途改口（"不是，我是说…"），保留最终说法，删除被推翻的部分
    3. 仅当说话者明确列举了多个点（如"第一…第二…"或"有三件事"），才整理为对应的有序/无序列表；否则输出连续段落
    4. 不解释、不演绎、不补充、不改写——原文说什么你就输出什么（去掉口头禅后）
    5. 如果原文是问句，输出也必须是问句；如果是陈述，输出也必须是陈述

    直接输出整理后的文本，不要任何说明或注释。
    """

    /// 智能整理文本
    static func formatSmart(text: String) async throws -> String {
        let state = AppState.shared
        guard state.hasDeepSeekConfig else { return text }

        let body: [String: Any] = [
            "model": state.deepseekModel,
            "messages": [
                ["role": "system", "content": smartPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.3,
        ]

        guard let url = URL(string: baseURL) else {
            throw FormatterError.requestFailed("无效的 URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(state.deepseekApiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw FormatterError.requestFailed("HTTP \(statusCode): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw FormatterError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
