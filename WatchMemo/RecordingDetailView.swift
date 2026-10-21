import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case transcript = "转录"
    case summary = "摘要"
    case info = "详情"
    var id: String { rawValue }
}

struct RecordingDetailView: View {
    let recordingId: UUID
    var focusLineId: String? = nil
    var highlight: String? = nil

    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var memo = MemoStore.shared
    @ObservedObject private var transcriber = TranscriptionService.shared
    @ObservedObject private var summarizer = SummaryService.shared
    @EnvironmentObject private var player: RecordingPlayer
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = false
    @State private var tab: DetailTab = .transcript
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var consent: CloudConsentRequest?
    @State private var didFocus = false

    var body: some View {
        if let rec = store.recordings.first(where: { $0.id == recordingId }) {
            content(rec)
        } else {
            ContentUnavailableView("录音已删除", systemImage: "trash")
        }
    }

    private func content(_ rec: StoredRecording) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    header(rec)
                    Section {
                        Picker("视图", selection: $tab) {
                            ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    switch tab {
                    case .transcript: transcriptSection(rec)
                    case .summary: summarySection(rec)
                    case .info: infoSection(rec)
                    }
                }
                .listStyle(.insetGrouped)
                .onAppear {
                    player.load(rec)
                    guard !didFocus, let focus = focusLineId else { return }
                    didFocus = true
                    tab = .transcript
                    if let line = memo.transcripts[rec.id]?.lines.first(where: { $0.id == focus }) {
                        let offsets = rec.segmentOffsets()
                        player.seek(to: (offsets[line.segmentIndex] ?? 0) + line.start, autoplay: false)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation { proxy.scrollTo(focus, anchor: .center) }
                    }
                }
            }
            if !rec.isAudioPurged {
                PlayerBar(recording: rec)
            }
        }
        .navigationTitle(memo.title(for: rec))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu(rec) }
        .alert("重命名", isPresented: $renaming) {
            TextField("标题", text: $newTitle)
            Button("保存") { memo.setTitle(rec.id, newTitle) }
            Button("恢复默认") { memo.setTitle(rec.id, nil) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除这条录音？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除录音、转录和摘要", role: .destructive) {
                AppActions.deleteRecording(rec.id, player: player)
                dismiss()
            }
        } message: {
            Text("会删除本机上的音频、转录文字、摘要和待办。已发送给 AI 服务商的文字需在服务商处另行处理。")
        }
        .cloudConsent($consent)
    }

    // MARK: - 头部

    private func header(_ rec: StoredRecording) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(rec.startedAt.formatted(.dateTime.year().month().day().weekday().hour().minute()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Chip(text: rec.totalDuration.clockString, color: .primary)
                    Chip(text: rec.statusText, color: rec.isComplete ? .green : .orange)
                    let p = memo.progress(for: rec)
                    if rec.isAudioPurged {
                        Chip(text: "音频已清理", color: .gray)
                    } else if p.pending > 0 || transcriber.isBusy(rec.id) {
                        Chip(text: "转录中 \(p.done + p.silent)/\(p.total)", color: .blue)
                    } else if p.failed > 0 {
                        Chip(text: "\(p.failed) 段失败", color: .red)
                    } else if p.isFinished {
                        Chip(text: "已转录", color: .green)
                    }
                }
                if let tags = memo.summaries[rec.id]?.tags, !tags.isEmpty {
                    Text(tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    // MARK: - 转录

    @ViewBuilder
    private func transcriptSection(_ rec: StoredRecording) -> some View {
        let lines = memo.transcripts[rec.id]?.lines ?? []
        let offsets = rec.segmentOffsets()
        let starts = rec.segments.reduce(into: [Int: Date]()) { $0[$1.index] = $1.startedAt }
        let activeId = player.recordingId == rec.id && (player.isPlaying || player.currentTime > 0)
            ? activeLine(lines, offsets: offsets, time: player.currentTime) : nil
        let p = memo.progress(for: rec)

        if lines.isEmpty {
            Section {
                if transcriber.isBusy(rec.id) {
                    HStack { ProgressView(); Text("正在转录…") }
                } else if rec.isAudioPurged {
                    Text("原始音频已清理，且没有转录文字。")
                } else if p.isFinished && p.failed == 0 {
                    Text(p.silent == p.total ? "所有分段都被判定为静音，已跳过转录。" : "没有识别到语音。")
                        .foregroundStyle(.secondary)
                    Button("强制重新转录（忽略静音检测）") { transcriber.transcribe(recordingId: rec.id, force: true) }
                } else if p.failed > 0 {
                    Text(memo.transcripts[rec.id]?.segments.first(where: { $0.status == .failed })?.error ?? "转录失败")
                        .foregroundStyle(.red)
                    Button("重试") { transcriber.transcribe(recordingId: rec.id, force: false) }
                } else {
                    Text("尚未转录").foregroundStyle(.secondary)
                    Button("开始转录") { transcriber.transcribe(recordingId: rec.id, force: false) }
                }
            }
        } else {
            Section {
                ForEach(lines) { line in
                    Button {
                        player.load(rec)
                        player.seek(to: (offsets[line.segmentIndex] ?? 0) + line.start)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text((starts[line.segmentIndex] ?? rec.startedAt).addingTimeInterval(line.start),
                                 format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(Highlight.make(line.text, term: highlight))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .id(line.id)
                    .listRowBackground(line.id == activeId ? Color.accentColor.opacity(0.15)
                                       : (line.id == focusLineId ? Color.yellow.opacity(0.15) : nil))
                }
            } footer: {
                if p.pending > 0 || transcriber.isBusy(rec.id) {
                    Text("还有 \(p.pending) 段在转录…")
                } else if p.failed > 0 {
                    Text("\(p.failed) 段转录失败，可在右上角菜单中重试。")
                } else if p.silent > 0 {
                    Text("\(p.silent) 段被判定为静音，已跳过。")
                }
            }
        }
    }

    private func activeLine(_ lines: [TranscriptLine], offsets: [Int: TimeInterval], time: TimeInterval) -> String? {
        var result: String?
        for line in lines {
            let t = (offsets[line.segmentIndex] ?? 0) + line.start
            if t <= time + 0.2 { result = line.id } else { break }
        }
        return result
    }

    // MARK: - 摘要

    @ViewBuilder
    private func summarySection(_ rec: StoredRecording) -> some View {
        let running = summarizer.running.contains(rec.id)
        if let s = memo.summaries[rec.id] {
            if !s.overview.isEmpty {
                Section("概述") { Text(s.overview) }
            }
            if !s.keyPoints.isEmpty {
                Section("要点") {
                    ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, point in
                        Label(point, systemImage: "circle.fill")
                            .labelStyle(BulletLabelStyle())
                    }
                }
            }
            if !s.todos.isEmpty {
                Section("待办") {
                    ForEach(s.todos) { TodoRow(recordingId: rec.id, todo: $0) }
                }
            }
            if !s.openQuestions.isEmpty {
                Section("待解决") {
                    ForEach(Array(s.openQuestions.enumerated()), id: \.offset) { _, q in
                        Label(q, systemImage: "questionmark.circle")
                    }
                }
            }
            Section {
                generateButton(rec, title: "重新生成摘要", running: running)
            } footer: {
                Text("\(s.provider) · \(s.model) · \(s.createdAt.formatted(date: .abbreviated, time: .shortened)) · 输入约 \(s.inputChars) 字")
            }
        } else {
            Section {
                if !aiEnabled {
                    Text("云端 AI 未开启。摘要会把转录文字（不含音频）发送给你配置的模型服务商。可在「设置 → AI」中开启并填写自己的 API Key。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("提取主题、关键结论、待办事项和未解决问题。只发送转录文字，不发送音频。")
                        .foregroundStyle(.secondary)
                    generateButton(rec, title: "生成摘要", running: running)
                }
            }
        }
        if let err = summarizer.errors[rec.id] {
            Section {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func generateButton(_ rec: StoredRecording, title: String, running: Bool) -> some View {
        let chars = summarizer.transcriptText(rec.id).count
        Button {
            consent = CloudGate.request(what: "这条录音的转录文字", chars: chars) {
                Task { await summarizer.summarize(rec.id) }
            }
        } label: {
            HStack {
                Label(title, systemImage: "sparkles")
                if running { Spacer(); ProgressView() }
            }
        }
        .disabled(running || chars == 0 || !aiEnabled)
    }

    // MARK: - 详情 / 诊断

    @ViewBuilder
    private func infoSection(_ rec: StoredRecording) -> some View {
        Section("概要") {
            LabeledContent("开始", value: rec.startedAt.formatted(date: .abbreviated, time: .standard))
            if let end = rec.endedAt {
                LabeledContent("结束", value: end.formatted(date: .omitted, time: .standard))
            }
            LabeledContent("音频时长", value: rec.totalDuration.clockString)
            LabeledContent("分段", value: "\(rec.segments.count)" + (rec.expectedSegmentCount.map { " / \($0)" } ?? ""))
            LabeledContent("大小", value: rec.totalBytes.byteString)
            LabeledContent("同步状态", value: rec.statusText)
            if !rec.missingIndices.isEmpty {
                LabeledContent("缺失分段", value: rec.missingIndices.map { "#\($0)" }.joined(separator: " "))
            }
            LabeledContent("ID", value: String(rec.id.uuidString.prefix(8)))
        }

        Section {
            ForEach(rec.segments) { seg in
                SegmentDiagnosticRow(rec: rec, seg: seg, transcript: memo.transcripts[rec.id]?.segment(seg.index))
            }
        } header: {
            Text("分段")
        } footer: {
            Text("点击分段从该处播放；左滑可对单个分段强制转录。“有声”为 100ms 窗口超过 \(Int(AudioAnalyzer.activeThresholdDb)) dBFS 的占比，低于 \(Int(AudioAnalyzer.silentRatio * 100))% 判定为静音。")
        }

        Section {
            Button("删除录音", role: .destructive) { confirmDelete = true }
        }
    }

    // MARK: - 菜单

    @ToolbarContentBuilder
    private func toolbarMenu(_ rec: StoredRecording) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    newTitle = memo.title(for: rec)
                    renaming = true
                } label: { Label("重命名", systemImage: "pencil") }

                ShareLink(item: exportText(rec)) { Label("导出文字", systemImage: "square.and.arrow.up") }

                if !rec.isAudioPurged {
                    Button {
                        transcriber.transcribe(recordingId: rec.id, force: false)
                    } label: { Label("重试失败 / 未转录分段", systemImage: "arrow.clockwise") }
                    Button {
                        transcriber.transcribe(recordingId: rec.id, force: true)
                    } label: { Label("全部重新转录", systemImage: "text.badge.checkmark") }
                }

                Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func exportText(_ rec: StoredRecording) -> String {
        var out = "# \(memo.title(for: rec))\n\n"
        out += "\(rec.startedAt.formatted(date: .complete, time: .shortened)) · \(rec.totalDuration.clockString)\n\n"
        if let s = memo.summaries[rec.id] {
            out += "## 概述\n\(s.overview)\n\n"
            if !s.keyPoints.isEmpty { out += "## 要点\n" + s.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !s.todos.isEmpty { out += "## 待办\n" + s.todos.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") + "\n\n" }
            if !s.openQuestions.isEmpty { out += "## 待解决\n" + s.openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        }
        let text = summarizer.transcriptText(rec.id)
        if !text.isEmpty { out += "## 转录\n\(text)\n" }
        return out
    }
}

struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}

struct SegmentDiagnosticRow: View {
    let rec: StoredRecording
    let seg: StoredSegment
    let transcript: SegmentTranscript?
    @EnvironmentObject private var player: RecordingPlayer

    var body: some View {
        Button {
            player.load(rec)
            player.seek(to: rec.segmentOffsets()[seg.index] ?? 0)
        } label: {
            HStack(alignment: .top) {
                Image(systemName: player.recordingId == rec.id && player.currentSegment == seg.index
                      ? "speaker.wave.2.fill" : "play.circle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(seg.index) · \(String(format: "%.1f", seg.effectiveDuration))s · \(seg.byteCount.byteString)\(seg.recovered ? " · 恢复" : "")\(seg.playable == false ? " · 无法解码" : "")")
                        .font(.subheadline)
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(transcript?.status == .failed ? .red : .secondary)
                    Text("\(seg.startedAt.formatted(date: .omitted, time: .standard)) · 手表计时 \(String(format: "%.1f", seg.duration))s · sha \(seg.sha256.prefix(8))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("强制转录") {
                TranscriptionService.shared.transcribeSegment(SegmentRef(recordingId: rec.id, index: seg.index))
            }
            .tint(.blue)
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        switch transcript?.status {
        case .done: parts.append("已转录 \(transcript?.lines.count ?? 0) 句")
        case .silent: parts.append("静音跳过")
        case .failed: parts.append("失败：\(transcript?.error ?? "")")
        case nil: parts.append("未转录")
        }
        if let e = transcript?.engine { parts.append(e) }
        if let t = transcript?.elapsed { parts.append(String(format: "耗时 %.1fs", t)) }
        if let s = transcript?.stats {
            parts.append(String(format: "有声 %.0f%% · 均值 %.0f dB · 峰值 %.0f dB", s.speechRatio * 100, s.meanDb, s.peakDb))
        }
        return parts.joined(separator: " · ")
    }
}

/// 底部播放条。
struct PlayerBar: View {
    let recording: StoredRecording
    @EnvironmentObject private var player: RecordingPlayer
    @State private var scrub: Double?

    var body: some View {
        let isThis = player.recordingId == recording.id
        let total = max(recording.totalDuration, 0.1)
        let current = isThis ? min(player.currentTime, total) : 0
        VStack(spacing: 4) {
            Slider(value: Binding(get: { scrub ?? current }, set: { scrub = $0 }),
                   in: 0...total,
                   onEditingChanged: { editing in
                       if !editing, let s = scrub {
                           player.load(recording)
                           player.seek(to: s, autoplay: player.isPlaying)
                           scrub = nil
                       }
                   })
            HStack {
                Text((scrub ?? current).clockString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Spacer()
                Button { player.load(recording); player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button {
                    player.load(recording)
                    player.toggle()
                } label: {
                    Image(systemName: isThis && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                }
                .padding(.horizontal, 20)
                Button { player.load(recording); player.skip(15) } label: { Image(systemName: "goforward.15") }
                Spacer()
                Menu {
                    ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button(String(format: "%gx", r)) { player.rate = r }
                    }
                } label: {
                    Text(String(format: "%gx", player.rate))
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .font(.title3)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }
}
