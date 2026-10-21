import Foundation

// MARK: - 模型

struct TranscriptLine: Codable, Hashable, Identifiable {
    var id: String                 // "<segmentIndex>-<n>"
    var segmentIndex: Int
    var start: TimeInterval        // 分段内偏移（秒）
    var end: TimeInterval
    var text: String
}

enum SegmentTranscriptStatus: String, Codable {
    case done       // 已转录（可能为空：没有识别到语音）
    case silent     // 静音检测判定为无语音，跳过
    case failed     // 失败，可重试
}

struct AudioStats: Codable, Hashable {
    var speechRatio: Double        // 超过阈值的 100ms 窗口占比
    var meanDb: Double
    var peakDb: Double
}

struct SegmentTranscript: Codable, Hashable, Identifiable {
    var index: Int
    var status: SegmentTranscriptStatus
    var lines: [TranscriptLine] = []
    var error: String?
    var engine: String?            // "设备端" / "服务器"
    var stats: AudioStats?
    var elapsed: TimeInterval?     // 转录耗时
    var updatedAt: Date = Date()

    var id: Int { index }
}

struct RecordingTranscript: Codable, Hashable {
    var recordingId: UUID
    var segments: [SegmentTranscript] = []   // 按 index 升序

    func segment(_ index: Int) -> SegmentTranscript? { segments.first { $0.index == index } }

    var lines: [TranscriptLine] {
        segments.sorted { $0.index < $1.index }.flatMap(\.lines)
    }

    var plainText: String { lines.map(\.text).joined() }
}

struct TodoItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var owner: String?
    var done = false
}

struct RecordingSummary: Codable, Hashable {
    var title: String
    var overview: String
    var keyPoints: [String]
    var todos: [TodoItem]
    var openQuestions: [String]
    var tags: [String]
    var model: String
    var provider: String
    var createdAt: Date
    var inputChars: Int
}

struct DailyReview: Codable, Hashable {
    var day: String                // yyyy-MM-dd
    var headline: String
    var highlights: [String]
    var reflection: String
    var todos: [String]
    var model: String
    var createdAt: Date
    var recordingCount: Int
}

/// 每条录音的转录状态汇总（用于列表徽标与自动摘要判断）。
struct TranscriptProgress: Hashable {
    var total = 0
    var done = 0
    var silent = 0
    var failed = 0
    var pending: Int { max(total - done - silent - failed, 0) }
    var isFinished: Bool { total > 0 && pending == 0 }
}

// MARK: - 存储

/// 文字数据：转录、摘要、每日回顾、自定义标题。
/// 与音频分开保存：Documents/Memo/…，清理音频后文字仍保留。
@MainActor
final class MemoStore: ObservableObject {
    static let shared = MemoStore()

    @Published private(set) var transcripts: [UUID: RecordingTranscript] = [:]
    @Published private(set) var summaries: [UUID: RecordingSummary] = [:]
    @Published private(set) var dailyReviews: [String: DailyReview] = [:]
    @Published private(set) var titles: [UUID: String] = [:]

    private let root: URL
    private let transcriptsDir: URL
    private let summariesDir: URL
    private let dailyDir: URL
    private let titlesURL: URL

    private init() {
        let fm = FileManager.default
        root = AppPaths.documents.appendingPathComponent("Memo", isDirectory: true)
        transcriptsDir = root.appendingPathComponent("transcripts", isDirectory: true)
        summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        dailyDir = root.appendingPathComponent("daily", isDirectory: true)
        titlesURL = root.appendingPathComponent("titles.json")
        for dir in [transcriptsDir, summariesDir, dailyDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        transcripts = Self.loadAll(transcriptsDir, RecordingTranscript.self)
            .reduce(into: [:]) { $0[$1.recordingId] = $1 }
        summaries = Self.loadAll(summariesDir, KeyedSummary.self)
            .reduce(into: [:]) { $0[$1.recordingId] = $1.summary }
        dailyReviews = Self.loadAll(dailyDir, DailyReview.self).reduce(into: [:]) { $0[$1.day] = $1 }
        if let data = try? Data(contentsOf: titlesURL),
           let t = try? Self.decoder.decode([String: String].self, from: data) {
            titles = t.reduce(into: [:]) { acc, kv in if let id = UUID(uuidString: kv.key) { acc[id] = kv.value } }
        }
    }

    // MARK: 读取

    func title(for rec: StoredRecording) -> String {
        if let t = titles[rec.id], !t.isEmpty { return t }
        if let t = summaries[rec.id]?.title, !t.isEmpty { return t }
        return "录音 " + rec.startedAt.formatted(date: .omitted, time: .shortened)
    }

    func progress(for rec: StoredRecording) -> TranscriptProgress {
        var p = TranscriptProgress()
        let t = transcripts[rec.id]
        for seg in rec.segments {
            p.total += 1
            switch t?.segment(seg.index)?.status {
            case .done: p.done += 1
            case .silent: p.silent += 1
            case .failed: p.failed += 1
            case nil: break
            }
        }
        return p
    }

    // MARK: 转录

    func setSegmentTranscript(_ recordingId: UUID, _ st: SegmentTranscript) {
        var t = transcripts[recordingId] ?? RecordingTranscript(recordingId: recordingId)
        t.segments.removeAll { $0.index == st.index }
        t.segments.append(st)
        t.segments.sort { $0.index < $1.index }
        transcripts[recordingId] = t
        write(t, to: transcriptsDir.appendingPathComponent("\(recordingId.uuidString).json"))
    }

    func resetTranscript(_ recordingId: UUID, onlyFailed: Bool = false) {
        guard var t = transcripts[recordingId] else { return }
        if onlyFailed {
            t.segments.removeAll { $0.status == .failed }
        } else {
            t.segments.removeAll()
        }
        transcripts[recordingId] = t
        write(t, to: transcriptsDir.appendingPathComponent("\(recordingId.uuidString).json"))
    }

    // MARK: 摘要

    func setSummary(_ recordingId: UUID, _ s: RecordingSummary) {
        summaries[recordingId] = s
        write(KeyedSummary(recordingId: recordingId, summary: s),
              to: summariesDir.appendingPathComponent("\(recordingId.uuidString).json"))
    }

    func toggleTodo(_ recordingId: UUID, _ todoId: UUID) {
        guard var s = summaries[recordingId],
              let i = s.todos.firstIndex(where: { $0.id == todoId }) else { return }
        s.todos[i].done.toggle()
        setSummary(recordingId, s)
    }

    func setDailyReview(_ review: DailyReview) {
        dailyReviews[review.day] = review
        write(review, to: dailyDir.appendingPathComponent("\(review.day).json"))
    }

    func setTitle(_ recordingId: UUID, _ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        titles[recordingId] = trimmed.isEmpty ? nil : trimmed
        let dict = titles.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        write(dict, to: titlesURL)
    }

    /// 删除录音时级联删除所有文字数据。
    func deleteAll(for recordingId: UUID) {
        transcripts[recordingId] = nil
        summaries[recordingId] = nil
        titles[recordingId] = nil
        let fm = FileManager.default
        try? fm.removeItem(at: transcriptsDir.appendingPathComponent("\(recordingId.uuidString).json"))
        try? fm.removeItem(at: summariesDir.appendingPathComponent("\(recordingId.uuidString).json"))
        let dict = titles.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        write(dict, to: titlesURL)
    }

    func textBytesOnDisk() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: 持久化

    private struct KeyedSummary: Codable {
        var recordingId: UUID
        var summary: RecordingSummary
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try Self.encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            EventLog.shared.error("保存 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
        }
    }

    private static func loadAll<T: Decodable>(_ dir: URL, _ type: T.Type) -> [T] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }
}
