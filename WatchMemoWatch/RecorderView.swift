import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var model: WatchAppModel
    @EnvironmentObject private var recorder: SegmentedRecorder
    @EnvironmentObject private var sync: WatchSyncManager
    @EnvironmentObject private var history: RecordingHistory

    @AppStorage("keepAliveMode") private var modeRaw = KeepAliveMode.backgroundAudio.rawValue
    @AppStorage("segmentLength") private var segmentLength = 60.0
    @AppStorage("minFreeMB") private var minFreeMB = 50

    @State private var confirmStop = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                statusLabel

                Text(recorder.elapsed.clockString)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(recorder.state == .recording ? .primary : .secondary)

                controls

                if let error = recorder.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                footer

                NavigationLink("设置与日志") { SettingsView() }
                    .font(.footnote)
            }
        }
        .navigationTitle("WatchMemo")
        .confirmationDialog("结束这次录音？", isPresented: $confirmStop) {
            Button("结束并同步", role: .destructive) { recorder.stop() }
            Button("继续录音", role: .cancel) {}
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText).font(.caption)
        }
    }

    private var statusText: String {
        switch recorder.state {
        case .idle: return "就绪"
        case .recording: return "录音中 · 可放下手腕"
        case .paused: return "已暂停"
        }
    }

    private var statusColor: Color {
        switch recorder.state {
        case .idle: return .gray
        case .recording: return .red
        case .paused: return .orange
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .idle:
            Button {
                model.startRecording(mode: KeepAliveMode(rawValue: modeRaw) ?? .backgroundAudio,
                                     segmentLength: segmentLength,
                                     minFreeMB: minFreeMB)
            } label: {
                ZStack {
                    Circle().fill(Color.red).frame(width: 76, height: 76)
                    Image(systemName: "mic.fill").font(.system(size: 30)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

        case .recording, .paused:
            HStack(spacing: 14) {
                if recorder.state == .recording {
                    roundButton("pause.fill", .orange) { recorder.pause() }
                } else {
                    roundButton("play.fill", .green) { recorder.resume() }
                }
                roundButton("stop.fill", .red) { confirmStop = true }
            }
        }
    }

    private func roundButton(_ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color.opacity(0.9)).frame(width: 58, height: 58)
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            if recorder.state != .idle {
                Text("分段 #\(recorder.segmentIndex) · 待同步 \(sync.pending.count)")
            } else {
                Text("今天 \(history.today.count) 条 · \(history.todayDuration.clockString)")
                Text(sync.pending.isEmpty ? "已全部同步到 iPhone" : "待同步 \(sync.pending.count) 段")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var recorder: SegmentedRecorder
    @EnvironmentObject private var sync: WatchSyncManager
    @EnvironmentObject private var keepAlive: KeepAliveController

    @AppStorage("keepAliveMode") private var modeRaw = KeepAliveMode.backgroundAudio.rawValue
    @AppStorage("segmentLength") private var segmentLength = 60.0
    @AppStorage("minFreeMB") private var minFreeMB = 50

    private var isBusy: Bool { recorder.state != .idle }

    var body: some View {
        List {
            Section("测试参数") {
                Picker("保活方案", selection: $modeRaw) {
                    ForEach(KeepAliveMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("分段长度", selection: $segmentLength) {
                    Text("30 秒").tag(30.0)
                    Text("1 分钟").tag(60.0)
                    Text("5 分钟").tag(300.0)
                    Text("10 分钟").tag(600.0)
                }
                Picker("最低剩余空间", selection: $minFreeMB) {
                    Text("50 MB").tag(50)
                    Text("500 MB").tag(500)
                    Text("2 GB").tag(2_000)
                    Text("50 GB（模拟不足）").tag(50_000)
                }
            }
            .disabled(isBusy)

            Section("状态") {
                row("保活", keepAlive.status)
                row("连接", sync.isActivated ? (sync.isReachable ? "iPhone 可达" : "已激活，不可达") : "未激活")
                row("待同步", "\(sync.pending.count)")
                row("已确认", "\(sync.ackedCount)")
                row("剩余空间", AppPaths.freeSpaceBytes()?.byteString ?? "未知")
            }

            Section {
                Button("立即重试同步") { sync.retryDue() }
                Button("发送日志到 iPhone") { sync.sendLogToPhone() }
                NavigationLink("查看日志") { LogView() }
                Button("清空日志", role: .destructive) { EventLog.shared.clear() }
            }
        }
        .navigationTitle("设置")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}
