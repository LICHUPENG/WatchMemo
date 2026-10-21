import Foundation
import Security

/// 用户设置（UserDefaults）。界面用 @AppStorage 读写同名 key，服务层用这里的静态属性读取。
enum Prefs {
    enum Key {
        static let autoTranscribe = "autoTranscribe"
        static let preferOnDevice = "preferOnDevice"
        static let speechLocale = "speechLocale"
        static let skipSilence = "skipSilence"
        static let aiEnabled = "aiEnabled"
        static let aiProvider = "aiProvider"
        static let aiBaseURL = "aiBaseURL"
        static let aiModel = "aiModel"
        static let aiConfirm = "aiConfirm"
        static let autoSummary = "autoSummary"
        static let audioRetentionDays = "audioRetentionDays"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.autoTranscribe: true,
            Key.preferOnDevice: true,
            Key.speechLocale: "zh-CN",
            Key.skipSilence: true,
            Key.aiEnabled: false,
            Key.aiProvider: AIProvider.deepseek.rawValue,
            Key.aiBaseURL: "",
            Key.aiModel: "",
            Key.aiConfirm: true,
            Key.autoSummary: false,
            Key.audioRetentionDays: 0,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var autoTranscribe: Bool { d.bool(forKey: Key.autoTranscribe) }
    static var preferOnDevice: Bool { d.bool(forKey: Key.preferOnDevice) }
    static var speechLocale: String { d.string(forKey: Key.speechLocale) ?? "zh-CN" }
    static var skipSilence: Bool { d.bool(forKey: Key.skipSilence) }
    static var aiEnabled: Bool { d.bool(forKey: Key.aiEnabled) }
    static var aiProvider: AIProvider { AIProvider(rawValue: d.string(forKey: Key.aiProvider) ?? "") ?? .deepseek }
    static var aiBaseURL: String {
        let s = (d.string(forKey: Key.aiBaseURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? aiProvider.defaultBaseURL : s
    }
    static var aiModel: String {
        let s = (d.string(forKey: Key.aiModel) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? aiProvider.defaultModel : s
    }
    static var aiConfirm: Bool { d.bool(forKey: Key.aiConfirm) }
    static var autoSummary: Bool { d.bool(forKey: Key.autoSummary) }
    static var audioRetentionDays: Int { d.integer(forKey: Key.audioRetentionDays) }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case deepseek, qwen, kimi, zhipu, openai, anthropic, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .qwen: return "通义千问（百炼）"
        case .kimi: return "Kimi（月之暗面）"
        case .zhipu: return "智谱 GLM"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .qwen: return "qwen-plus"
        case .kimi: return "moonshot-v1-32k"
        case .zhipu: return "glm-4-flash"
        case .openai: return "gpt-4.1-mini"
        case .anthropic: return "claude-sonnet-5-5"
        case .custom: return ""
        }
    }

    var isAnthropic: Bool { self == .anthropic }
}

/// API Key 只保存在 Keychain（仅本机、首次解锁后可读），不写入 UserDefaults、日志或数据库。
enum Keychain {
    private static let service = "com.kyte.watchmemo.ai"

    static func apiKey(for provider: AIProvider) -> String? { get(account: "apikey.\(provider.rawValue)") }

    @discardableResult
    static func setAPIKey(_ key: String, for provider: AIProvider) -> Bool {
        set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: "apikey.\(provider.rawValue)")
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func set(_ value: String, account: String) -> Bool {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        if value.isEmpty { return true }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func get(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }
}
