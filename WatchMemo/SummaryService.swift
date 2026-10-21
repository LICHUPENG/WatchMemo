import Foundation

/// 单条录音摘要 + 每日回顾。只发送转录文字（及录音时间），不发送音频。
@MainActor
final class SummaryService: ObservableObject {
    static let shared = SummaryService()

    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var runningDays: Set<String> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var dayErrors: [String: String] = [:]

    private let store = RecordingStore.shared
    private let memo = MemoStore.shared
    private let log = EventLog.shared

    /// 单次请求的最大字数；更长的录音先分块提取要点，再汇总。
    private let chunkChars = 12_000

    private init() {}

    // MARK: - 发送前告知用的估算

    func transcriptText(_ id: UUID) -> String {
        guard let rec = store.recording(id), let t = memo.transcripts[id] else { return "" }
        let offsets = rec.segments.reduce(into: [Int: Date]()) { $0[$1.index] = $1.startedAt }
        return t.lines.map { line -> String in
            let base = offsets[line.segmentIndex] ?? rec.startedAt
            let ts = base.addingTimeInterval(line.start).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
            return "[\(ts)] \(line.text)"
        }.joined(separator: "\n")
    }

    // MARK: - 单条摘要

    func summarize(_ id: UUID) async {
        guard !running.contains(id), let rec = store.recording(id) else { return }
        let text = transcriptText(id)
        guard !text.isEmpty else {
            errors[id] = "还没有转录文字"
            return
        }
        running.insert(id)
        errors[id] = nil
        defer { running.remove(id) }

        do {
            let client = try AIClient.current()
            log.info("生成摘要 \(id.uuidString.prefix(8))：\(text.count) 字 → \(client.host)")

            var material = text
            if text.count > chunkChars {
                material = try await condense(text, client: client)
            }

            let header = """
            录音开始：\(rec.startedAt.formatted(date: .complete, time: .shortened))
            时长：\(rec.totalDuration.clockString)
            """
            let system = """
            你是用户的个人录音助理。用户用 Apple Watch 录下日常对话或会议，下面是语音识别得到的中文转录（可能有错别字、同音字、缺少说话人区分）。
            请只依据转录内容整理，不要编造；可以根据上下文纠正明显的识别错误。
            只输出一个 JSON 对象，不要输出其他文字。
            """
            let user = """
            \(header)

            转录内容：
            \(material)

            请输出 JSON，字段如下：
            {
              "title": "不超过 16 个字的标题",
              "overview": "2～4 句话的概述",
              "key_points": ["关键结论或要点"],
              "todos": [{"text": "待办事项（动词开头）", "owner": "负责人，没有就留空"}],
              "open_questions": ["尚未解决或需要跟进的问题"],
              "tags": ["2～5 个关键词"]
            }
            没有的项给空数组。如果内容几乎没有有效信息（例如只是环境声或零碎词语），overview 写明这一点，其他数组留空。
            """
            let reply = try await client.chat(system: system, messages: [AIMessage(role: "user", content: user)], json: true)
            guard let obj = AIClient.parseJSONObject(reply) else { throw AIError.badResponse(String(reply.prefix(200))) }

            let todos: [TodoItem] = ((obj["todos"] as? [Any]) ?? []).compactMap { item in
                if let s = item as? String { return TodoItem(text: s) }
                if let d = item as? [String: Any], let s = d["text"] as? String, !s.isEmpty {
                    let owner = (d["owner"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    return TodoItem(text: s, owner: owner)
                }
                return nil
            }
            let summary = RecordingSummary(
                title: (obj["title"] as? String) ?? "",
                overview: (obj["overview"] as? String) ?? "",
                keyPoints: AIClient.strings(obj["key_points"]),
                todos: todos,
                openQuestions: AIClient.strings(obj["open_questions"]),
                tags: AIClient.strings(obj["tags"]),
                model: client.model,
                provider: client.provider.title,
                createdAt: Date(),
                inputChars: text.count)
            memo.setSummary(id, summary)
            log.info("摘要完成 \(id.uuidString.prefix(8))：\(summary.title)")
        } catch {
            errors[id] = error.localizedDescription
            log.error("摘要失败 \(id.uuidString.prefix(8))：\(error.localizedDescription)")
        }
    }

    /// 长文本：分块提取要点，拼成较短的材料。
    private func condense(_ text: String, client: AIClient) async throws -> String {
        var chunks: [String] = []
        var cur = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if cur.count + line.count > chunkChars, !cur.isEmpty {
                chunks.append(cur)
                cur = ""
            }
            cur += String(line) + "\n"
        }
        if !cur.isEmpty { chunks.append(cur) }

        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let reply = try await client.chat(
                system: "你在帮用户整理一段很长的录音转录。只依据原文，不要编造。",
                messages: [AIMessage(role: "user", content: """
                以下是录音转录的第 \(i + 1)/\(chunks.count) 部分。请用简洁的中文要点列出：讨论内容、结论、待办、未解决问题，保留关键时间戳。

                \(chunk)
                """)],
                json: false, maxTokens: 1500)
            notes.append("【第 \(i + 1) 部分要点】\n\(reply)")
        }
        return notes.joined(separator: "\n\n")
    }

    // MARK: - 每日回顾

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 每日回顾的输入材料：有摘要用摘要，否则用截断的转录。
    func dailyMaterial(_ day: Date) -> (text: String, count: Int) {
        let recs = store.recordings(on: day)
        var parts: [String] = []
        var count = 0
        for rec in recs {
            let time = rec.startedAt.formatted(date: .omitted, time: .shortened)
            if let s = memo.summaries[rec.id] {
                count += 1
                var p = "【\(time)·\(rec.totalDuration.clockString)】\(s.title)\n概述：\(s.overview)"
                if !s.keyPoints.isEmpty { p += "\n要点：" + s.keyPoints.joined(separator: "；") }
                if !s.todos.isEmpty { p += "\n待办：" + s.todos.map(\.text).joined(separator: "；") }
                parts.append(p)
            } else if let t = memo.transcripts[rec.id], !t.plainText.isEmpty {
                count += 1
                parts.append("【\(time)·\(rec.totalDuration.clockString)】（转录节选）\n" + String(t.plainText.prefix(3000)))
            }
        }
        return (parts.joined(separator: "\n\n"), count)
    }

    func reviewDay(_ day: Date) async {
        let key = Self.dayKey(day)
        guard !runningDays.contains(key) else { return }
        let material = dailyMaterial(day)
        guard material.count > 0 else {
            dayErrors[key] = "这一天还没有可用的转录或摘要"
            return
        }
        runningDays.insert(key)
        dayErrors[key] = nil
        defer { runningDays.remove(key) }

        do {
            let client = try AIClient.current()
            log.info("生成每日回顾 \(key)：\(material.text.count) 字 → \(client.host)")
            let system = """
            你是用户的个人记忆助理，帮助用户回顾一天里录下的对话与会议。语气平实、具体，不要空泛的鸡汤。只依据材料，不编造。只输出 JSON。
            """
            let user = """
            日期：\(day.formatted(date: .complete, time: .omitted))
            当天 \(material.count) 条录音的材料：

            \(String(material.text.prefix(30_000)))

            请输出 JSON：
            {
              "headline": "一句话概括这一天（不超过 24 字）",
              "highlights": ["3～6 条当天最值得记住的事、决定或信息"],
              "reflection": "一段 80～150 字的回顾：今天主要在忙什么、有哪些进展或值得注意的地方",
              "todos": ["从当天内容中汇总的待办"]
            }
            """
            let reply = try await client.chat(system: system, messages: [AIMessage(role: "user", content: user)], json: true)
            guard let obj = AIClient.parseJSONObject(reply) else { throw AIError.badResponse(String(reply.prefix(200))) }
            let review = DailyReview(day: key,
                                     headline: (obj["headline"] as? String) ?? "",
                                     highlights: AIClient.strings(obj["highlights"]),
                                     reflection: (obj["reflection"] as? String) ?? "",
                                     todos: AIClient.strings(obj["todos"]),
                                     model: client.displayName,
                                     createdAt: Date(),
                                     recordingCount: material.count)
            memo.setDailyReview(review)
        } catch {
            dayErrors[key] = error.localizedDescription
            log.error("每日回顾失败 \(key)：\(error.localizedDescription)")
        }
    }
}
