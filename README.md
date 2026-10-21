# WatchMemo

个人 AI 录音与记忆助手（Apple Watch + iPhone），参考 Auday 的产品思路。当前为 **v0.1.0 功能版**，等待首轮真机验证。

- 需求文档：[docs/WatchMemo-v0.1.0-需求.md](docs/WatchMemo-v0.1.0-需求.md)
- 阶段 A 测试计划：[docs/阶段A-技术验证计划.md](docs/阶段A-技术验证计划.md)
- 首轮真机验证清单：[docs/首轮真机验证清单.md](docs/首轮真机验证清单.md)

## 功能一览

| 模块 | 功能 | 代码 |
|---|---|---|
| 手表录音 | 一键录音（震动反馈）、暂停/继续、结束确认、分段保存、三种保活方案、今日统计 | `WatchMemoWatch/` |
| 同步 | 持久化队列、SHA-256 校验、去重、确认后删除、孤儿分段恢复 | `WatchSyncManager.swift`、`PhoneSyncManager.swift` |
| 转录 | iOS 系统语音识别（优先设备端）、逐段转录、句级时间戳、静音分段跳过、失败重试、重启续传 | `SpeechEngine.swift`、`TranscriptionService.swift` |
| 回顾 | 按天时间线、日期筛选、连续播放 / 拖动 / 倍速、点句子跳转播放、当前句高亮、导出文字 | `RecordsView.swift`、`RecordingDetailView.swift`、`RecordingPlayer.swift` |
| 搜索 | 转录 / 标题 / 摘要关键词搜索、时间范围、命中高亮、直达原句 | `SearchView.swift` |
| AI（可选） | 单条摘要（标题/概述/要点/待办/待解决）、每日回顾、问问（本地检索 + 模型回答）、待办汇总 | `SummaryService.swift`、`AskService.swift` |
| 隐私 | 默认关闭云端 AI；只发文字不发音频；每次发送前告知；API Key 存钥匙串；删除级联；音频保留期 | `AIClient.swift`、`Prefs.swift`、`AppActions.swift` |

支持的模型服务：DeepSeek、通义千问（百炼）、Kimi、智谱 GLM、OpenAI、Anthropic，以及任意 OpenAI 兼容接口。

## 这个 Demo 验证什么

| 能力 | 实现位置 |
|---|---|
| 手表录音：开始 / 暂停 / 继续 / 结束，时长显示 | `WatchMemoWatch/SegmentedRecorder.swift` |
| 分段保存（30s / 1min / 5min / 10min 可选），16kHz 单声道 AAC | 同上 |
| 麦克风权限、音频中断（来电/Siri）、存储不足处理 | 同上 |
| 三种保活方案对比：后台音频 / 延长运行会话 / 体能训练会话 | `WatchMemoWatch/KeepAliveController.swift` |
| 持久化同步队列、指数退避重试、**收到确认后才删除**、孤儿分段恢复 | `WatchMemoWatch/WatchSyncManager.swift` |
| iPhone 接收：SHA-256 校验、去重、落盘、回确认 | `WatchMemo/PhoneSyncManager.swift`、`RecordingStore.swift` |
| 按日期浏览、顺序播放分段、显示缺失分段、删除 | `WatchMemo/ContentView.swift` |
| 两端事件日志（含电量、定时器停顿检测），可导出做测试记录 | `Shared/EventLog.swift` |

元数据用 JSON 文件保存（`Documents/index.json`、`Documents/Memo/`），音频单独存放在 `Documents/Recordings/`。

## 同步协议（简述）

```
手表                                           iPhone
 ├─ 分段写完 → 计算 sha256 → 写入 pending.json
 ├─ transferFile(seg, metadata) ───────────────▶ didReceive(file)
 │                                               ├─ 校验 sha256
 │                                               ├─ (recordingId, index, sha256) 已存在？→ duplicate
 │                                               ├─ 移动到 Recordings/<id>/seg_xxxx.m4a，写 index.json
 │◀───────────── transferUserInfo(ack) ──────────┘
 ├─ 收到 ack(stored/duplicate) → 删除本地文件
 ├─ 收到 ack(checksumMismatch) → 立即重发
 └─ 超时未确认 → 指数退避重发（30s → 30min）
 录音结束 → transferUserInfo(recordingEnd, 总分段数) → iPhone 据此判断“完整 / 缺 N 段”
```

## 如何运行

> ⚠️ 需要一台 **Mac + Xcode 15 或以上**。Windows 上无法编译 iOS/watchOS 应用，这个文件夹可以通过 Git 或网盘同步到 Mac 上使用。

### 方式一：XcodeGen（推荐）

```bash
brew install xcodegen
cd watchMemo
# 先在 project.yml 里填入 DEVELOPMENT_TEAM，并按需修改 bundle id（com.kyte.watchmemo）
xcodegen generate
open WatchMemo.xcodeproj
```

### 方式二：用 Xcode 模板手动建工程

如果 XcodeGen 生成的工程有问题，可以手动建：

1. Xcode → New Project → **watchOS → App** → 选择 **Watch App with New Companion iOS App**，产品名 `WatchMemo`。
2. 删除模板自动生成的 `ContentView.swift` 和 `*App.swift`。
3. 把 `WatchMemo/` 下的文件加入 iOS target，把 `WatchMemoWatch/` 下的文件加入 Watch target，`Shared/` 同时勾选两个 target。
4. 在 Watch target 中：
   - Signing & Capabilities 添加 **HealthKit**、**Background Modes**（勾选 Audio 和 Workout processing）。
   - Info 中添加 `NSMicrophoneUsageDescription`、`NSHealthShareUsageDescription`、`NSHealthUpdateUsageDescription`，以及 `WKBackgroundModes = [physical-therapy]`（参考 `project.yml` 中的值）。
5. 部署版本：iOS 17.0 / watchOS 10.0。

### 安装到真机

1. iPhone 和 Apple Watch 都要打开**开发者模式**（设置 → 隐私与安全性 → 开发者模式）。
2. 在 Xcode 中选择 `WatchMemoWatch` scheme 和你的手表，Run。首次安装手表 App 可能比较慢。
3. 再选择 `WatchMemo` scheme 和 iPhone，Run。
4. **耗电测试请用 Release 构建并断开调试器**，调试器会让系统不挂起 App，导致后台行为测不准。

### 关于开发者账号

- 免费 Apple ID 可以安装，但签名 **7 天后过期**，需要重新安装。
- 如果免费账号无法签名 HealthKit，可以先删掉 `project.yml` 中的 `entitlements` 段，不测 M3（体能训练会话）方案。

## 目录结构

```
watchMemo/
├── project.yml                 # XcodeGen 工程描述
├── Shared/                     # 两端共用：传输协议、校验、日志
├── WatchMemoWatch/             # watchOS App
├── WatchMemo/                  # iOS App
└── docs/
    ├── WatchMemo-v0.1.0-需求.md
    ├── 阶段A-技术验证计划.md
    └── test-logs/              # 测试日志归档（自行创建）
```

## 状态

所有能力均为 **待验证**，以真机测试结果为准。
