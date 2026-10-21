import SwiftUI

/// 首页：按天的时间线。每天可以生成“每日回顾”。
struct RecordsView: View {
    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var memo = MemoStore.shared
    @ObservedObject private var sync = PhoneSyncManager.shared
    @ObservedObject private var transcriber = TranscriptionService.shared
    @EnvironmentObject private var player: RecordingPlayer

    @State private var filterDay: Date?
    @State private var showDatePicker = false
    @State private var pickedDate = Date()

    private var groupedByDay: [(day: Date, items: [StoredRecording])] {
        let cal = Calendar.current
        let source = filterDay.map { d in store.recordings.filter { cal.isDate($0.startedAt, inSameDayAs: d) } } ?? store.recordings
        let groups = Dictionary(grouping: source) { cal.startOfDay(for: $0.startedAt) }
        return groups
            .map { (day: $0.key, items: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection

                if store.recordings.isEmpty {
                    Section {
                        ContentUnavailableView("还没有录音", systemImage: "applewatch",
                                               description: Text("在 Apple Watch 上开始录音，结束的分段会自动同步到这里并转成文字。"))
                    }
                } else if groupedByDay.isEmpty {
                    Section {
                        ContentUnavailableView("这一天没有录音", systemImage: "calendar")
                    }
                }

                ForEach(groupedByDay, id: \.day) { group in
                    Section {
                        NavigationLink {
                            DailyReviewView(day: group.day)
                        } label: {
                            DayHeaderRow(day: group.day, items: group.items)
                        }
                        ForEach(group.items) { rec in
                            NavigationLink {
                                RecordingDetailView(recordingId: rec.id)
                            } label: {
                                RecordingRow(recording: rec)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { AppActions.deleteRecording(group.items[i].id, player: player) }
                        }
                    } header: {
                        Text(group.day, format: .dateTime.month().day().weekday(.wide))
                    }
                }
            }
            .navigationTitle(filterDay == nil ? "记录" : filterDay!.formatted(.dateTime.month().day()))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { TodoListView() } label: { Image(systemName: "checklist") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if filterDay != nil {
                        Button("全部") { filterDay = nil }
                    } else {
                        Button { showDatePicker = true } label: { Image(systemName: "calendar") }
                    }
                }
            }
            .sheet(isPresented: $showDatePicker) {
                NavigationStack {
                    DatePicker("选择日期", selection: $pickedDate, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                        .navigationTitle("按日期查看")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { showDatePicker = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("查看") {
                                    filterDay = pickedDate
                                    showDatePicker = false
                                }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        let watchOK = sync.isPaired && sync.isWatchAppInstalled
        let busy = transcriber.current != nil || !transcriber.queued.isEmpty
        if !watchOK || busy || transcriber.lastError != nil {
            Section {
                if !watchOK {
                    Label(sync.isPaired ? "手表上还没有安装 WatchMemo" : "没有检测到配对的 Apple Watch",
                          systemImage: "applewatch.slash")
                        .foregroundStyle(.orange)
                }
                if busy {
                    HStack {
                        ProgressView()
                        Text("正在转录… 剩余 \(transcriber.queued.count + (transcriber.current == nil ? 0 : 1)) 段")
                            .font(.subheadline)
                    }
                }
                if let err = transcriber.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

struct DayHeaderRow: View {
    let day: Date
    let items: [StoredRecording]
    @ObservedObject private var memo = MemoStore.shared

    var body: some View {
        let total = items.reduce(0) { $0 + $1.totalDuration }
        let review = memo.dailyReviews[SummaryService.dayKey(day)]
        HStack(spacing: 12) {
            Image(systemName: review == nil ? "sun.max" : "sun.max.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(review?.headline.isEmpty == false ? review!.headline : "每日回顾")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(items.count) 条录音 · \(total.clockString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RecordingRow: View {
    let recording: StoredRecording
    @ObservedObject private var memo = MemoStore.shared
    @ObservedObject private var summarizer = SummaryService.shared

    var body: some View {
        let progress = memo.progress(for: recording)
        let summary = memo.summaries[recording.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(memo.title(for: recording))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let s = summary, !s.overview.isEmpty {
                Text(s.overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let first = memo.transcripts[recording.id]?.plainText, !first.isEmpty {
                Text(first)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(recording.totalDuration.clockString)
                    .monospacedDigit()
                badges(progress)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        let s = recording.startedAt.formatted(date: .omitted, time: .shortened)
        let e = recording.approxEnd.formatted(date: .omitted, time: .shortened)
        return s == e ? s : "\(s)–\(e)"
    }

    @ViewBuilder
    private func badges(_ p: TranscriptProgress) -> some View {
        if !recording.isComplete {
            Chip(text: recording.statusText, color: recording.missingIndices.isEmpty ? .blue : .orange)
        }
        if recording.isAudioPurged {
            Chip(text: "仅文字", color: .gray)
        }
        if p.pending > 0 && !recording.isAudioPurged {
            Chip(text: "转录 \(p.done + p.silent)/\(p.total)", color: .blue)
        }
        if p.failed > 0 {
            Chip(text: "\(p.failed) 段转录失败", color: .red)
        }
        let openTodos = (memo.summaries[recording.id]?.todos ?? []).filter { !$0.done }.count
        if summarizer.running.contains(recording.id) {
            Chip(text: "摘要中", color: .purple)
        } else if openTodos > 0 {
            Chip(text: "待办 \(openTodos)", color: .green)
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// 汇总所有摘要中的待办。
struct TodoListView: View {
    @ObservedObject private var memo = MemoStore.shared
    @ObservedObject private var store = RecordingStore.shared
    @State private var showDone = false

    private var groups: [(rec: StoredRecording, todos: [TodoItem])] {
        store.recordings.compactMap { rec in
            guard let s = memo.summaries[rec.id] else { return nil }
            let todos = s.todos.filter { showDone || !$0.done }
            return todos.isEmpty ? nil : (rec, todos)
        }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView("没有待办", systemImage: "checkmark.circle",
                                       description: Text("生成摘要后，录音里提到的待办会汇总到这里。"))
            }
            ForEach(groups, id: \.rec.id) { g in
                Section {
                    ForEach(g.todos) { todo in
                        TodoRow(recordingId: g.rec.id, todo: todo)
                    }
                } header: {
                    NavigationLink {
                        RecordingDetailView(recordingId: g.rec.id)
                    } label: {
                        Text("\(g.rec.startedAt.formatted(.dateTime.month().day().hour().minute())) · \(memo.title(for: g.rec))")
                    }
                }
            }
        }
        .navigationTitle("待办")
        .toolbar {
            Toggle("显示已完成", isOn: $showDone)
                .toggleStyle(.button)
        }
    }
}

struct TodoRow: View {
    let recordingId: UUID
    let todo: TodoItem

    var body: some View {
        Button {
            MemoStore.shared.toggleTodo(recordingId, todo.id)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.done ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.text)
                        .strikethrough(todo.done)
                        .foregroundStyle(todo.done ? .secondary : .primary)
                    if let owner = todo.owner {
                        Text(owner).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
