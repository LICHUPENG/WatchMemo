import Foundation

struct AIMessage: Codable, Hashable {
    var role: String       // "user" / "assistant"
    var content: String
}

enum AIError: LocalizedError {
    case disabled
    case notConfigured(String)
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .disabled: return "云端 AI 已关闭（设置 → AI）"
        case .notConfigured(let what): return "AI 未配置：\(what)"
        case .http(let code, let body): return "AI 请求失败（HTTP \(code)）：\(body)"
        case .badResponse(let s): return "AI 返回无法解析：\(s)"
        }
    }
}

/// 统一的模型接口：OpenAI 兼容（DeepSeek / 千问 / Kimi / 智谱 / OpenAI / 自定义）与 Anthropic。
/// iPhone 直连服务商，不经过任何自建服务器；只发送文字，不发送音频。
struct AIClient {
    let provider: AIProvider
    let baseURL: URL
    let model: String
    let apiKey: String

    var host: String { baseURL.host ?? baseURL.absoluteString }
    var displayName: String { "\(provider.title) · \(model)" }

    static func current() throws -> AIClient {
        guard Prefs.aiEnabled else { throw AIError.disabled }
        let provider = Prefs.aiProvider
        guard let url = URL(string: Prefs.aiBaseURL), url.scheme?.hasPrefix("http") == true else {
            throw AIError.notConfigured("接口地址无效")
        }
        let model = Prefs.aiModel
        guard !model.isEmpty else { throw AIError.notConfigured("未填写模型名") }
        guard let key = Keychain.apiKey(for: provider) else { throw AIError.notConfigured("未填写 API Key") }
        return AIClient(provider: provider, baseURL: url, model: model, apiKey: key)
    }

    /// 当前配置的目标主机（用于发送前的告知），未配置时返回 nil。
    static var currentHost: String? { try? current().host }

    func chat(system: String, messages: [AIMessage], json: Bool, maxTokens: Int = 4096) async throws -> String {
        if provider.isAnthropic {
            return try await anthropic(system: system, messages: messages, maxTokens: maxTokens)
        }
        do {
            return try await openAI(system: system, messages: messages, json: json, maxTokens: maxTokens)
        } catch AIError.http(let code, let body) where json && code == 400 {
            // 部分兼容接口不支持 response_format，去掉后重试一次
            EventLog.shared.warn("AI 接口不支持 JSON 模式（\(body.prefix(80))），改用普通模式重试")
            return try await openAI(system: system, messages: messages, json: false, maxTokens: maxTokens)
        }
    }

    // MARK: - OpenAI 兼容

    private func openAI(system: String, messages: [AIMessage], json: Bool, maxTokens: Int) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system]] + messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let obj = try await send(&req, body: body)
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.badResponse(String(describing: obj).prefix(200).description)
        }
        return content
    }

    // MARK: - Anthropic

    private func anthropic(system: String, messages: [AIMessage], maxTokens: Int) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("messages"))
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let obj = try await send(&req, body: body)
        guard let blocks = obj["content"] as? [[String: Any]] else {
            throw AIError.badResponse(String(describing: obj).prefix(200).description)
        }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw AIError.badResponse("没有文本内容") }
        return text
    }

    // MARK: - HTTP

    private func send(_ req: inout URLRequest, body: [String: Any]) async throws -> [String: Any] {
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(code, String(text.prefix(300)))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse(String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return obj
    }

    // MARK: - 工具

    /// 从模型输出中取出 JSON 对象（兼容 ```json 代码块和前后多余文字）。
    static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func strings(_ any: Any?) -> [String] {
        guard let arr = any as? [Any] else {
            if let s = any as? String, !s.isEmpty { return [s] }
            return []
        }
        return arr.compactMap { item in
            if let s = item as? String { return s }
            if let d = item as? [String: Any] { return (d["text"] ?? d["content"] ?? d["title"]) as? String }
            return nil
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
