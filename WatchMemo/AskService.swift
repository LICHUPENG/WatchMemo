import Foundation
import NaturalLanguage

struct SourceRef: Hashable, Identifiable {
    var recordingId: UUID
    var lineId: String?
    var label: String
    var id: String { recordingId.uuidString + (lineId ?? "") }
}

struct ChatTurn: Identifiable, Hashable {
    let id = UUID()
    var role: String                // "user" / "assistant" / "error"
    var text: String
    var sources: [SourceRef] = []
}

/// “问问过去的我”：在本地检索相关转录片段，只把检索到的片段发送给模型。
@MainActor
final class AskService: ObservableObject {
    static let shared = AskService()

    @Published private(set) var turns: [ChatTurn] = []
    @Published private(set) var isThinking = false

    private let store = RecordingStore.shared
    private let memo = MemoStore.shared
    private let contextLimit = 20_000

    private init() {}

    func reset() { turns.removeAll() }

    struct Prepared {
        var context: String
        var sources: [SourceRef]
        var recordingCount: Int
    }

    /// 本地检索（不联网）。返回将要发送的上下文，供发送前告知用户。
    func prepare(_ question: String) -> Prepared {
        let scope = scopedRecordings(for: question)
        let terms = Self.keywords(question)

        // 1. 给每一句打分：命中的关键词数
        struct Hit { var rec: StoredRecording; var lineIndex: Int; var score: Int }
        var hits: [Hit] = []
        var linesByRec: [UUID: [TranscriptLine]] = [:]
        for rec in scope {
            guard let lines = memo.transcripts[rec.id]?.lines, !lines.isEmpty else { continue }
            linesByRec[rec.id] = lines
            guard !terms.isEmpty else { continue }
            for (i, line) in lines.enumerated() {
                let lower = line.text.lowercased()
                let score = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
                if score > 0 { hits.append(Hit(rec: rec, lineIndex: i, score: score)) }
            }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.rec.startedAt > $1.rec.startedAt }

        // 2. 取前若干句，扩展前后各 2 句作为上下文
        var picked: [UUID: Set<Int>] = [:]
        var sources: [SourceRef] = []
        for hit in hits.prefix(16) {
            let lines = linesByRec[hit.rec.id] ?? []
            let lo = max(hit.lineIndex - 2, 0), hi = min(hit.lineIndex + 2, lines.count - 1)
            picked[hit.rec.id, default: []].formUnion(lo...hi)
            if !sources.contains(where: { $0.recordingId == hit.rec.id }) {
                sources.append(SourceRef(recordingId: hit.rec.id, lineId: lines[hit.lineIndex].id,
                                         label: label(hit.rec)))
            }
        }

        var parts: [String] = []
        var used = 0
        var recCount = 0

        // 3. 先放命中片段
        for rec in scope.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let idx = picked[rec.id], let lines = linesByRec[rec.id] else { continue }
            let offsets = rec.segments.reduce(into: [Int: Date]()) { $0[$1.index] = $1.startedAt }
            var block = "### \(label(rec))\n"
            if let s = memo.summaries[rec.id] { block += "摘要：\(s.overview)\n" }
            var last = -2
            for i in idx.sorted() {
                if i != last + 1 { block += "…\n" }
                let line = lines[i]
                let t = (offsets[line.segmentIndex] ?? rec.startedAt).addingTimeInterval(line.start)
                block += "[\(t.formatted(date: .omitted, time: .shortened))] \(line.text)\n"
                last = i
            }
            if used + block.count > contextLimit { break }
            parts.append(block)
            used += block.count
            recCount += 1
        }

        // 4. 没有命中（或问题很笼统）：用时间范围内的摘要 / 转录开头兜底
        if parts.isEmpty {
            for rec in scope.prefix(20) {
                var block = "### \(label(rec))\n"
                if let s = memo.summaries[rec.id] {
                    block += "摘要：\(s.overview)\n要点：\(s.keyPoints.joined(separator: "；"))\n"
                    if !s.todos.isEmpty { block += "待办：\(s.todos.map(\.text).joined(separator: "；"))\n" }
                } else if let text = memo.transcripts[rec.id]?.plainText, !text.isEmpty {
                    block += String(text.prefix(1500)) + "\n"
                } else {
                    continue
                }
                if used + block.count > contextLimit { break }
                parts.append(block)
                used += block.count
                recCount += 1
                sources.append(SourceRef(recordingId: rec.id, lineId: nil, label: label(rec)))
            }
        }
        return Prepared(context: parts.joined(separator: "\n"), sources: Array(sources.prefix(8)), recordingCount: recCount)
    }

    func ask(_ question: String, prepared: Prepared) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking else { return }
        let history = turns.filter { $0.role != "error" }.suffix(6).map { AIMessage(role: $0.role, content: $0.text) }
        turns.append(ChatTurn(role: "user", text: q))
        isThinking = true
        defer { isThinking = false }

        let system = """
        你是用户的个人记忆助理。用户用 Apple Watch 录下日常对话和会议，以下是根据问题从本地记录中检索出的相关片段（语音识别转录，可能有错字，没有说话人区分）。
        回答要求：
        - 只依据提供的记录回答；记录里没有的就直说“记录里没有找到”，不要编造。
        - 提到具体内容时注明是哪条录音（用 ### 标题里的日期时间）。
        - 简洁，用中文。
        今天是 \(Date().formatted(date: .complete, time: .omitted))。
        """
        let user = prepared.context.isEmpty
            ? "（没有检索到相关记录）\n\n问题：\(q)"
            : "相关记录：\n\(prepared.context)\n\n问题：\(q)"

        do {
            let client = try AIClient.current()
            EventLog.shared.info("问 AI：上下文 \(prepared.context.count) 字（\(prepared.recordingCount) 条录音）→ \(client.host)")
            let reply = try await client.chat(system: system,
                                              messages: Array(history) + [AIMessage(role: "user", content: user)],
                                              json: false, maxTokens: 2000)
            turns.append(ChatTurn(role: "assistant", text: reply, sources: prepared.sources))
        } catch {
            turns.append(ChatTurn(role: "error", text: error.localizedDescription))
        }
    }

    // MARK: - 检索辅助

    private func label(_ rec: StoredRecording) -> String {
        rec.startedAt.formatted(.dateTime.month().day().hour().minute()) + " " + memo.title(for: rec)
    }

    /// 根据问题中的时间词限定范围（今天 / 昨天 / 本周 / 上周 / 最近），默认最近 90 天。
    private func scopedRecordings(for q: String) -> [StoredRecording] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var range: (Date, Date)? = nil
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        if q.contains("今天") || q.contains("今日") { range = (today, day(1)) }
        else if q.contains("昨天") || q.contains("昨日") { range = (day(-1), today) }
        else if q.contains("前天") { range = (day(-2), day(-1)) }
        else if q.contains("上周") || q.contains("上星期") { range = (day(-14), day(-7)) }
        else if q.contains("这周") || q.contains("本周") || q.contains("这星期") || q.contains("最近") { range = (day(-7), day(1)) }
        else if q.contains("这个月") || q.contains("本月") { range = (day(-31), day(1)) }

        let all = store.snapshot()
        if let r = range {
            return all.filter { $0.startedAt >= r.0 && $0.startedAt < r.1 }
        }
        let cutoff = day(-90)
        return all.filter { $0.startedAt >= cutoff }
    }

    private static let stopwords: Set<String> = [
        "什么", "怎么", "怎样", "为什么", "哪些", "哪个", "是不是", "有没有", "我们", "你们", "他们", "我的", "一下",
        "今天", "昨天", "前天", "本周", "这周", "上周", "最近", "这个", "那个", "时候", "关于", "说过", "提到", "讨论",
        "记得", "之前", "以前", "还有", "可以", "需要", "一个", "以及", "还是", "或者", "然后", "是否", "the", "and", "what",
    ]

    /// 用系统分词提取关键词（中文按词，英文按单词）。
    static func keywords(_ q: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = q
        var out: [String] = []
        tokenizer.enumerateTokens(in: q.startIndex..<q.endIndex) { range, _ in
            let w = String(q[range]).lowercased()
            let isAscii = w.allSatisfy { $0.isASCII }
            if (isAscii && w.count >= 3) || (!isAscii && w.count >= 2), !stopwords.contains(w), !out.contains(w) {
                out.append(w)
            }
            return true
        }
        return out
    }
}
