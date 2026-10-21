import Foundation
import AVFAudio

struct StoredSegment: Codable, Hashable, Identifiable {
    var index: Int
    var sha256: String
    var byteCount: Int64
    var duration: TimeInterval          // 手表报告的墙钟时长（恢复分段为 0）
    var startedAt: Date
    var receivedAt: Date
    var recovered: Bool
    var audioDuration: TimeInterval?    // iPhone 读取文件得到的真实音频时长
    var playable: Bool?                 // 文件能否被解码（App 被杀时的分段可能为 false）

    var id: Int { index }
    var fileName: String { SegmentInfo.fileName(for: index) }

    /// 播放与时间轴使用的时长：优先真实音频时长。
    var effectiveDuration: TimeInterval {
        if let d = audioDuration, d > 0 { return d }
        return duration
    }
}

struct StoredRecording: Codable, Hashable, Identifiable {
    var id: UUID
    var segments: [StoredSegment] = []     // 按 index 升序
    var expectedSegmentCount: Int?         // 收到手表“结束标记”后才知道
    var endedAt: Date?
    var firstReceivedAt: Date
    var audioPurged: Bool?                 // 按保留策略清理了原始音频（文字保留）

    var startedAt: Date { segments.map(\.startedAt).min() ?? firstReceivedAt }
    var totalDuration: TimeInterval { segments.reduce(0) { $0 + $1.effectiveDuration } }
    var totalBytes: Int64 { segments.reduce(0) { $0 + $1.byteCount } }
    var isAudioPurged: Bool { audioPurged == true }

    /// 估算的结束时间：优先结束标记，否则用最后一段的开始 + 时长。
    var approxEnd: Date {
        if let endedAt { return endedAt }
        if let last = segments.last { return last.startedAt.addingTimeInterval(last.effectiveDuration) }
        return startedAt
    }

    var missingIndices: [Int] {
        let have = Set(segments.map(\.index))
        let upper = max(expectedSegmentCount ?? 0, (segments.map(\.index).max() ?? -1) + 1)
        return (0..<upper).filter { !have.contains($0) }
    }

    var statusText: String {
        let missing = missingIndices.count
        if expectedSegmentCount != nil {
            return missing == 0 ? "完整" : "缺 \(missing) 段"
        }
        return missing == 0 ? "接收中" : "接收中 · 缺 \(missing) 段"
    }

    var isComplete: Bool { expectedSegmentCount != nil && missingIndices.isEmpty }

    /// 每个分段在“连续播放时间轴”上的起点（暂停造成的间隔不计入）。
    func segmentOffsets() -> [Int: TimeInterval] {
        var t: TimeInterval = 0
        var result: [Int: TimeInterval] = [:]
        for s in segments {
            result[s.index] = t
            t += s.effectiveDuration
        }
        return result
    }
}

struct SyncStats: Codable {
    var stored = 0
    var duplicates = 0
    var checksumFailures = 0
    var logs = 0
}

/// 录音元数据索引（Documents/index.json）。音频文件与索引分开存放。
/// 转录、摘要等文字数据由 MemoStore 单独保存。
final class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    enum IngestResult {
        case stored
        case duplicate
        case checksumMismatch(actual: String)
        case failed(String)
    }

    @Published private(set) var recordings: [StoredRecording] = []
    @Published private(set) var stats = SyncStats()

    /// 新分段落盘后回调（在任意线程调用）。
    var onSegmentStored: (@Sendable (UUID, Int) -> Void)?
    /// 收到结束标记后回调（在任意线程调用）。
    var onRecordingEnded: (@Sendable (UUID) -> Void)?

    private var byId: [UUID: StoredRecording] = [:]
    private var statsStorage = SyncStats()
    private let lock = NSLock()
    private let indexURL = AppPaths.documents.appendingPathComponent("index.json")

    private struct Persisted: Codable {
        var recordings: [StoredRecording]
        var stats: SyncStats
    }

    private init() {
        load()
        publish()
    }

    // MARK: - 读取

    func recording(_ id: UUID) -> StoredRecording? {
        lock.lock(); defer { lock.unlock() }
        return byId[id]
    }

    func snapshot() -> [StoredRecording] {
        lock.lock(); defer { lock.unlock() }
        return byId.values.sorted { $0.startedAt > $1.startedAt }
    }

    func fileURL(_ recording: StoredRecording, _ segment: StoredSegment) -> URL {
        fileURL(recording.id, segment.index)
    }

    func fileURL(_ id: UUID, _ index: Int) -> URL {
        AppPaths.recordings
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(SegmentInfo.fileName(for: index))
    }

    /// 某天之内的所有录音（按开始时间升序）。
    func recordings(on day: Date) -> [StoredRecording] {
        let cal = Calendar.current
        return snapshot().filter { cal.isDate($0.startedAt, inSameDayAs: day) }.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - 接收

    /// 必须在 WCSession 的 didReceive(file:) 回调中同步调用：回调返回后系统会删除临时文件。
    func ingest(fileAt tempURL: URL, info: SegmentInfo) -> IngestResult {
        let actual: String
        do {
            actual = try FileHash.sha256(of: tempURL)
        } catch {
            return .failed("读取临时文件失败：\(error.localizedDescription)")
        }

        lock.lock()

        guard actual == info.sha256 else {
            statsStorage.checksumFailures += 1
            save()
            lock.unlock()
            publish()
            return .checksumMismatch(actual: actual)
        }

        var rec = byId[info.recordingId] ?? StoredRecording(id: info.recordingId, firstReceivedAt: Date())

        if let existing = rec.segments.first(where: { $0.index == info.segmentIndex }),
           existing.sha256 == info.sha256,
           FileManager.default.fileExists(atPath: fileURL(rec, existing).path) {
            statsStorage.duplicates += 1
            save()
            lock.unlock()
            publish()
            return .duplicate
        }

        let dest = AppPaths.recordingDir(info.recordingId).appendingPathComponent(info.fileName)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            lock.unlock()
            return .failed("保存分段失败：\(error.localizedDescription)")
        }

        let probe = Self.probeAudio(dest)
        var startedAt = info.startedAt
        // 恢复分段的开始时间来自文件创建时间，可能偏晚；用上一段推算更准确
        if info.recovered, let prev = rec.segments.last(where: { $0.index == info.segmentIndex - 1 }) {
            startedAt = prev.startedAt.addingTimeInterval(prev.effectiveDuration)
        }

        rec.segments.removeAll { $0.index == info.segmentIndex }
        rec.segments.append(StoredSegment(index: info.segmentIndex, sha256: info.sha256, byteCount: info.byteCount,
                                          duration: info.duration, startedAt: startedAt,
                                          receivedAt: Date(), recovered: info.recovered,
                                          audioDuration: probe.duration, playable: probe.playable))
        rec.segments.sort { $0.index < $1.index }
        rec.audioPurged = nil
        byId[rec.id] = rec
        statsStorage.stored += 1
        save()
        lock.unlock()
        publish()

        if probe.playable == false {
            EventLog.shared.warn("分段 \(info.recordingId.uuidString.prefix(8))#\(info.segmentIndex) 无法解码（文件可能不完整）")
        }
        onSegmentStored?(info.recordingId, info.segmentIndex)
        return .stored
    }

    func markEnded(id: UUID, segmentCount: Int, endedAt: Date) {
        lock.lock()
        var rec = byId[id] ?? StoredRecording(id: id, firstReceivedAt: Date())
        rec.expectedSegmentCount = segmentCount
        rec.endedAt = endedAt
        byId[id] = rec
        save()
        lock.unlock()
        publish()
        onRecordingEnded?(id)
    }

    func noteLogReceived() {
        lock.lock()
        statsStorage.logs += 1
        save()
        lock.unlock()
        publish()
    }

    // MARK: - 删除与清理

    /// 删除录音的音频目录和索引记录。转录、摘要由调用方（AppActions）一并删除。
    func delete(_ id: UUID) {
        lock.lock()
        byId[id] = nil
        save()
        lock.unlock()
        try? FileManager.default.removeItem(at: AppPaths.recordings.appendingPathComponent(id.uuidString, isDirectory: true))
        publish()
        EventLog.shared.info("已删除录音 \(id.uuidString.prefix(8)) 及其音频文件")
    }

    /// 只删除原始音频，保留元数据（文字由 MemoStore 保留）。
    func purgeAudio(_ id: UUID) {
        lock.lock()
        guard var rec = byId[id] else { lock.unlock(); return }
        rec.audioPurged = true
        byId[id] = rec
        save()
        lock.unlock()
        try? FileManager.default.removeItem(at: AppPaths.recordings.appendingPathComponent(id.uuidString, isDirectory: true))
        publish()
        EventLog.shared.info("按保留策略清理录音 \(id.uuidString.prefix(8)) 的原始音频")
    }

    /// Recordings 目录占用的空间。
    func audioBytesOnDisk() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: AppPaths.recordings, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - 音频探测

    static func probeAudio(_ url: URL) -> (duration: TimeInterval?, playable: Bool) {
        do {
            let file = try AVAudioFile(forReading: url)
            let sr = file.processingFormat.sampleRate
            guard sr > 0, file.length > 0 else { return (nil, false) }
            return (Double(file.length) / sr, true)
        } catch {
            return (nil, false)
        }
    }

    // MARK: - 持久化（调用方需持有 lock）

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Persisted(recordings: Array(byId.values), stats: statsStorage))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            EventLog.shared.error("保存索引失败：\(error.localizedDescription)")
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: indexURL),
              let p = try? decoder.decode(Persisted.self, from: data) else { return }
        byId = Dictionary(p.recordings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        statsStorage = p.stats
    }

    private func publish() {
        lock.lock()
        let list = byId.values.sorted { $0.startedAt > $1.startedAt }
        let s = statsStorage
        lock.unlock()
        DispatchQueue.main.async {
            self.recordings = list
            self.stats = s
        }
    }
}
