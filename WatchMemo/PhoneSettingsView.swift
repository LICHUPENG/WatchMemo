import SwiftUI
import Speech

struct PhoneSettingsView: View {
    @ObservedObject private var transcriber = TranscriptionService.shared
    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var memo = MemoStore.shared

    @AppStorage(Prefs.Key.autoTranscribe) private var autoTranscribe = true
    @AppStorage(Prefs.Key.preferOnDevice) private var preferOnDevice = true
    @AppStorage(Prefs.Key.speechLocale) private var speechLocale = "zh-CN"
    @AppStorage(Prefs.Key.skipSilence) private var skipSilence = true
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = false
    @AppStorage(Prefs.Key.aiConfirm) private var aiConfirm = true
    @AppStorage(Prefs.Key.autoSummary) private var autoSummary = false
    @AppStorage(Prefs.Key.audioRetentionDays) private var retentionDays = 0
    @AppStorage(Prefs.Key.aiProvider) private var providerRaw = AIProvider.deepseek.rawValue

    @State private var purgeMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                transcriptionSection
                aiSection
                storageSection
                Section("诊断") {
                    NavigationLink { SyncDiagnosticsView() } label: { Label("同步与连接", systemImage: "applewatch.radiowaves.left.and.right") }
                    NavigationLink { WatchLogsView() } label: { Label("手表日志", systemImage: "applewatch") }
                    NavigationLink { LogView() } label: { Label("本机日志", systemImage: "list.bullet.rectangle") }
                    ShareLink(item: EventLog.shared.fileURL) { Label("导出本机日志", systemImage: "square.and.arrow.up") }
                }
                Section {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                } footer: {
                    Text("录音、转录和搜索都在本机完成，没有 WatchMemo 服务器。录制他人谈话前请先取得对方同意。")
                }
            }
            .navigationTitle("设置")
        }
    }

    // MARK: - 转录

    private var transcriptionSection: some View {
        Section {
            HStack {
                Text("语音识别权限")
                Spacer()
                if transcriber.authStatus == .authorized {
                    Text("已允许").foregroundStyle(.green)
                } else if transcriber.authStatus == .notDetermined {
                    Button("请求授权") { transcriber.requestAuthorization() }
                } else {
                    Text(transcriber.authStatus == .denied ? "已拒绝" : "受限制").foregroundStyle(.red)
                }
            }
            if transcriber.authStatus == .denied {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Toggle("自动转录新录音", isOn: $autoTranscribe)
                .onChange(of: autoTranscribe) { _, on in if on { transcriber.enqueueAllPending() } }
            Picker("识别语言", selection: $speechLocale) {
                Text("普通话（简体）").tag("zh-CN")
                Text("粤语（香港）").tag("zh-HK")
                Text("国语（台湾）").tag("zh-TW")
                Text("English (US)").tag("en-US")
            }
            Toggle("优先设备端识别", isOn: $preferOnDevice)
            LabeledContent("此语言支持设备端识别", value: SpeechEngine.supportsOnDevice(localeId: speechLocale) ? "是" : "否")
            Toggle("跳过静音分段", isOn: $skipSilence)
            Button("重试所有失败的分段") { transcriber.retryAllFailed() }
        } header: {
            Text("转录")
        } footer: {
            Text("使用 iOS 系统语音识别。设备端识别不联网；不支持时会使用 Apple 的服务器识别（需联网，单段不超过 1 分钟）。中英混说时请选普通话。")
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        Section {
            Toggle("启用云端 AI", isOn: $aiEnabled)
            if aiEnabled {
                NavigationLink { AIProviderSettingsView() } label: {
                    LabeledContent("模型服务", value: (AIProvider(rawValue: providerRaw) ?? .deepseek).title)
                }
                Toggle("每次发送前确认", isOn: $aiConfirm)
                Toggle("转录完成后自动生成摘要", isOn: $autoSummary)
            }
        } header: {
            Text("AI")
        } footer: {
            Text(aiEnabled
                 ? "只发送转录文字，不发送音频；iPhone 直连你配置的服务商。开启“自动生成摘要”即表示同意每条录音转录完成后自动发送。"
                 : "关闭时，录音、转录、搜索仍可正常使用，任何内容都不会发送到云端。")
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section {
            Picker("原始音频保留", selection: $retentionDays) {
                Text("永久").tag(0)
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
            }
            LabeledContent("音频占用", value: store.audioBytesOnDisk().byteString)
            LabeledContent("文字占用", value: memo.textBytesOnDisk().byteString)
            LabeledContent("剩余空间", value: AppPaths.freeSpaceBytes()?.byteString ?? "未知")
            if retentionDays > 0 {
                Button("立即按保留策略清理") {
                    let n = AppActions.applyRetention()
                    purgeMessage = n == 0 ? "没有需要清理的录音" : "已清理 \(n) 条录音的原始音频"
                }
            }
            if let m = purgeMessage {
                Text(m).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("存储")
        } footer: {
            Text("超过保留期、且已完整转录的录音会删除原始音频，转录、摘要和待办保留。数据只保存在本机。")
        }
    }
}

struct AIProviderSettingsView: View {
    @AppStorage(Prefs.Key.aiProvider) private var providerRaw = AIProvider.deepseek.rawValue
    @AppStorage(Prefs.Key.aiBaseURL) private var baseURL = ""
    @AppStorage(Prefs.Key.aiModel) private var model = ""

    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var testResult: String?

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .deepseek }

    var body: some View {
        Form {
            Section("服务商") {
                Picker("服务商", selection: $providerRaw) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: providerRaw) { _, _ in
                    baseURL = ""
                    model = ""
                    loadKey()
                    testResult = nil
                }
            }
            Section {
                TextField(provider.defaultBaseURL.isEmpty ? "https://…/v1" : provider.defaultBaseURL, text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField(provider.defaultModel.isEmpty ? "模型名" : provider.defaultModel, text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("接口地址与模型")
            } footer: {
                Text("留空则使用灰色的默认值。模型名以服务商文档为准。")
            }
            Section {
                SecureField(hasKey ? "已保存（输入新值可替换）" : "粘贴 API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("保存") {
                        Keychain.setAPIKey(apiKey, for: provider)
                        apiKey = ""
                        loadKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    if hasKey {
                        Button("删除", role: .destructive) {
                            Keychain.setAPIKey("", for: provider)
                            loadKey()
                        }
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("API Key")
            } footer: {
                Text("保存在 iOS 钥匙串中，仅本机可读，不写入日志或数据库。费用由服务商按你的账户计费。")
            }
            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Text("测试连接")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || !hasKey)
                if let r = testResult {
                    Text(r).font(.footnote).foregroundStyle(r.hasPrefix("✓") ? .green : .red)
                }
            } footer: {
                Text("测试只发送一句固定的问候语。")
            }
        }
        .navigationTitle(provider.title)
        .onAppear(perform: loadKey)
    }

    private func loadKey() {
        hasKey = Keychain.apiKey(for: provider) != nil
    }

    private func test() {
        testing = true
        testResult = nil
        Task { @MainActor in
            defer { testing = false }
            do {
                let client = try AIClient.current()
                let reply = try await client.chat(system: "你是一个测试助手。",
                                                  messages: [AIMessage(role: "user", content: "请只回复：连接成功")],
                                                  json: false, maxTokens: 20)
                testResult = "✓ \(client.host) 回复：\(reply.prefix(40))"
            } catch {
                testResult = "✗ \(error.localizedDescription)"
            }
        }
    }
}
