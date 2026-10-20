import SwiftUI

struct ContentView: View {
    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var sync = PhoneSyncManager.shared

    private var groupedByDay: [(day: Date, items: [StoredRecording])] {
        let groups = Dictionary(grouping: store.recordings) { Calendar.current.startOfDay(for: $0.startedAt) }
        return groups
            .map { (day: $0.key, items: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("连接与统计") {
                    LabeledContent("WCSession", value: sync.isActivated ? "已激活" : "未激活")
                    LabeledContent("手表", value: sync.isPaired ? (sync.isWatchAppInstalled ? "已配对 · App 已安装" : "已配对 · App 未安装") : "未配对")
                    LabeledContent("手表可达", value: sync.isReachable ? "是" : "否")
                    LabeledContent("已保存分段", value: "\(store.stats.stored)")
                    LabeledContent("重复（已去重）", value: "\(store.stats.duplicates)")
                    LabeledContent("校验失败", value: "\(store.stats.checksumFailures)")
                }

                if store.recordings.isEmpty {
                    Section {
                        ContentUnavailableView("还没有录音", systemImage: "applewatch",
                                               description: Text("在 Apple Watch 上开始录音，结束的分段会自动同步到这里。"))
                    }
                }

                ForEach(groupedByDay, id: \.day) { group in
                    Section {
                        ForEach(group.items) { rec in
                            NavigationLink {
                                RecordingDetailView(recordingId: rec.id)
                            } label: {
                                RecordingRow(recording: rec)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { store.delete(group.items[i].id) }
                        }
                    } header: {
                        Text(group.day, format: .dateTime.year().month().day().weekday())
                    }
                }
            }
            .navigationTitle("WatchMemo")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { WatchLogsView() } label: { Image(systemName: "applewatch") }
                    NavigationLink { LogView() } label: { Image(systemName: "list.bullet.rectangle") }
                    ShareLink(item: EventLog.shared.fileURL) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }
}

struct RecordingRow: View {
    let recording: StoredRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.startedAt, format: .dateTime.hour().minute())
                    .font(.headline)
                Spacer()
                Text(recording.statusText)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor)
            }
            Text("\(recording.totalDuration.clockString) · \(recording.segments.count) 段 · \(recording.totalBytes.byteString)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if recording.isComplete { return .green }
        return recording.missingIndices.isEmpty ? .blue : .orange
    }
}

struct RecordingDetailView: View {
    let recordingId: UUID

    @ObservedObject private var store = RecordingStore.shared
    @EnvironmentObject private var player: SegmentPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var recording: StoredRecording? { store.recordings.first { $0.id == recordingId } }

    var body: some View {
        if let rec = recording {
            List {
                Section("概要") {
                    LabeledContent("开始", value: rec.startedAt.formatted(date: .abbreviated, time: .standard))
                    if let end = rec.endedAt {
                        LabeledContent("结束", value: end.formatted(date: .omitted, time: .standard))
                    }
                    LabeledContent("时长", value: rec.totalDuration.clockString)
                    LabeledContent("分段", value: "\(rec.segments.count)" + (rec.expectedSegmentCount.map { " / \($0)" } ?? ""))
                    LabeledContent("大小", value: rec.totalBytes.byteString)
                    LabeledContent("状态", value: rec.statusText)
                    if !rec.missingIndices.isEmpty {
                        LabeledContent("缺失分段", value: rec.missingIndices.map { "#\($0)" }.joined(separator: " "))
                    }
                    LabeledContent("ID", value: String(rec.id.uuidString.prefix(8)))
                }

                Section {
                    Button {
                        if player.playingKey != nil {
                            player.stop()
                        } else {
                            player.play(rec.segments.map { SegmentPlayer.Item(key: key(rec, $0), url: store.fileURL(rec, $0)) })
                        }
                    } label: {
                        Label(player.playingKey != nil ? "停止播放" : "顺序播放全部",
                              systemImage: player.playingKey != nil ? "stop.fill" : "play.fill")
                    }
                }

                Section("分段") {
                    ForEach(rec.segments) { seg in
                        Button {
                            player.play([SegmentPlayer.Item(key: key(rec, seg), url: store.fileURL(rec, seg))])
                        } label: {
                            HStack {
                                Image(systemName: player.playingKey == key(rec, seg) ? "speaker.wave.2.fill" : "play.circle")
                                VStack(alignment: .leading) {
                                    Text("#\(seg.index) · \(String(format: "%.1f", seg.duration))s · \(seg.byteCount.byteString)")
                                    Text("sha256 \(seg.sha256.prefix(12))…\(seg.recovered ? " · 恢复" : "")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("删除录音", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(rec.startedAt.formatted(date: .omitted, time: .shortened))
            .confirmationDialog("删除这条录音及其所有分段？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    player.stop()
                    store.delete(rec.id)
                    dismiss()
                }
            }
            .onDisappear { player.stop() }
        } else {
            ContentUnavailableView("录音已删除", systemImage: "trash")
        }
    }

    private func key(_ rec: StoredRecording, _ seg: StoredSegment) -> String {
        SegmentInfo.makeKey(rec.id, seg.index)
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
