import SwiftUI

/// 阶段 A 的连接与同步统计（保留用于真机验证）。
struct SyncDiagnosticsView: View {
    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var sync = PhoneSyncManager.shared

    var body: some View {
        List {
            Section("连接") {
                LabeledContent("WCSession", value: sync.isActivated ? "已激活" : "未激活")
                LabeledContent("手表", value: sync.isPaired ? (sync.isWatchAppInstalled ? "已配对 · App 已安装" : "已配对 · App 未安装") : "未配对")
                LabeledContent("手表可达", value: sync.isReachable ? "是" : "否")
            }
            Section("同步统计") {
                LabeledContent("已保存分段", value: "\(store.stats.stored)")
                LabeledContent("重复（已去重）", value: "\(store.stats.duplicates)")
                LabeledContent("校验失败", value: "\(store.stats.checksumFailures)")
                LabeledContent("收到手表日志", value: "\(store.stats.logs)")
            }
            Section("录音完整性") {
                let recs = store.recordings
                LabeledContent("录音", value: "\(recs.count)")
                LabeledContent("完整", value: "\(recs.filter(\.isComplete).count)")
                LabeledContent("缺失分段合计", value: "\(recs.reduce(0) { $0 + $1.missingIndices.count })")
                LabeledContent("无法解码的分段", value: "\(recs.reduce(0) { acc, r in acc + r.segments.filter { seg in seg.playable == false }.count })")
                LabeledContent("恢复的分段", value: "\(recs.reduce(0) { acc, r in acc + r.segments.filter { seg in seg.recovered }.count })")
            }
        }
        .navigationTitle("同步与连接")
    }
}

struct WatchLogsView: View {
    @State private var files: [URL] = []

    var body: some View {
        List(files, id: \.self) { url in
            NavigationLink(url.lastPathComponent) { LogFileView(url: url) }
        }
        .overlay {
            if files.isEmpty {
                ContentUnavailableView("暂无手表日志", systemImage: "doc.text",
                                       description: Text("在手表「设置与日志」中点击“发送日志到 iPhone”。"))
            }
        }
        .navigationTitle("手表日志")
        .onAppear {
            let urls = (try? FileManager.default.contentsOfDirectory(at: PhoneSyncManager.watchLogsDir,
                                                                    includingPropertiesForKeys: nil)) ?? []
            files = urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
    }
}

struct LogFileView: View {
    let url: URL

    var body: some View {
        ScrollView {
            Text((try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: url)
        }
    }
}
