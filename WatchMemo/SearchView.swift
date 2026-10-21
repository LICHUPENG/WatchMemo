import SwiftUI

enum Highlight {
    /// 把 text 中所有 term（不区分大小写）标成高亮。
    static func make(_ text: String, term: String?) -> AttributedString {
        guard let term = term?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty else {
            return AttributedString(text)
        }
        var result = AttributedString()
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<text.endIndex) {
            result += AttributedString(String(text[cursor..<r.lowerBound]))
            var hit = AttributedString(String(text[r]))
            hit.backgroundColor = .yellow.opacity(0.4)
            hit.inlinePresentationIntent = .stronglyEmphasized
            result += hit
            cursor = r.upperBound
        }
        if cursor < text.endIndex { result += AttributedString(String(text[cursor...])) }
        return result
    }
}

enum DateScope: String, CaseIterable, Identifiable {
    case all = "全部"
    case today = "今天"
    case week = "近 7 天"
    case month = "近 30 天"
    case day = "指定日期"
    var id: String { rawValue }
}

/// 关键词搜索：转录文字、标题、摘要。全部在本机完成。
struct SearchView: View {
    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var memo = MemoStore.shared

    @State private var query = ""
    @State private var scope: DateScope = .all
    @State private var day = Date()

    struct LineHit: Identifiable {
        var line: TranscriptLine
        var time: Date
        var id: String { line.id }
    }

    struct RecordingHit: Identifiable {
        var rec: StoredRecording
        var titleMatch: Bool
        var summaryMatch: String?
        var lines: [LineHit]
        var id: UUID { rec.id }
    }

    private var scoped: [StoredRecording] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch scope {
        case .all: return store.recordings
        case .today: return store.recordings.filter { cal.isDateInToday($0.startedAt) }
        case .week: return store.recordings.filter { $0.startedAt >= cal.date(byAdding: .day, value: -6, to: today)! }
        case .month: return store.recordings.filter { $0.startedAt >= cal.date(byAdding: .day, value: -29, to: today)! }
        case .day: return store.recordings.filter { cal.isDate($0.startedAt, inSameDayAs: day) }
        }
    }

    private var results: [RecordingHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return scoped.compactMap { rec in
            let titleMatch = memo.title(for: rec).range(of: q, options: opts) != nil
            var summaryMatch: String?
            if let s = memo.summaries[rec.id] {
                let candidates = [s.overview] + s.keyPoints + s.todos.map(\.text) + s.openQuestions + s.tags
                summaryMatch = candidates.first { $0.range(of: q, options: opts) != nil }
            }
            let starts = rec.segments.reduce(into: [Int: Date]()) { $0[$1.index] = $1.startedAt }
            let lines = (memo.transcripts[rec.id]?.lines ?? [])
                .filter { $0.text.range(of: q, options: opts) != nil }
                .map { LineHit(line: $0, time: (starts[$0.segmentIndex] ?? rec.startedAt).addingTimeInterval($0.start)) }
            guard titleMatch || summaryMatch != nil || !lines.isEmpty else { return nil }
            return RecordingHit(rec: rec, titleMatch: titleMatch, summaryMatch: summaryMatch, lines: lines)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("时间范围", selection: $scope) {
                        ForEach(DateScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if scope == .day {
                        DatePicker("日期", selection: $day, in: ...Date(), displayedComponents: .date)
                    }
                }

                let hits = results
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Text("在转录文字、标题和摘要中搜索。搜索完全在本机进行。")
                            .foregroundStyle(.secondary)
                    }
                } else if hits.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    Section {
                        Text("\(hits.count) 条录音 · \(hits.reduce(0) { $0 + $1.lines.count }) 处匹配")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(hits) { hit in
                        Section {
                            NavigationLink {
                                RecordingDetailView(recordingId: hit.rec.id, highlight: query)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Highlight.make(memo.title(for: hit.rec), term: hit.titleMatch ? query : nil))
                                        .font(.headline)
                                    if let s = hit.summaryMatch {
                                        Text(Highlight.make(s, term: query))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            ForEach(hit.lines.prefix(20)) { lh in
                                NavigationLink {
                                    RecordingDetailView(recordingId: hit.rec.id, focusLineId: lh.line.id, highlight: query)
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(lh.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(Highlight.make(lh.line.text, term: query))
                                            .font(.subheadline)
                                            .lineLimit(3)
                                    }
                                }
                            }
                            if hit.lines.count > 20 {
                                Text("还有 \(hit.lines.count - 20) 处匹配，打开录音查看")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text(hit.rec.startedAt.formatted(.dateTime.year().month().day().weekday().hour().minute()))
                        }
                    }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "关键词，例如：预算、周五、合同")
        }
    }
}
