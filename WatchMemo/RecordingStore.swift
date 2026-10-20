import Foundation

struct StoredSegment: Codable, Hashable, Identifiable {
    var index: Int
    var sha256: String
    var byteCount: Int64
    var duration: TimeInterval
    var startedAt: Date
    var receivedAt: Date
    var recovered: Bool

    var id: Int { index }
    var fileName: String { SegmentInfo.fileName(for: index) }
}

struct StoredRecording: Codable, Hashable, Identifiable {
    var id: UUID
    var segments: [StoredSegment] = []     // 按 index 升序
    var expectedSegmentCount: Int?         // 收到手表“结束标记”后才知道
    var endedAt: Date?
    var firstReceivedAt: Date

    var startedAt: Date { segments.map(\.startedAt).min() ?? firstReceivedAt }
    var totalDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    var totalBytes: Int64 { segments.reduce(0) { $0 + $1.byteCount } }

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
}

struct SyncStats: Codable {
    var stored = 0
    var duplicates = 0
    var checksumFailures = 0
    var logs = 0
}

/// 阶段 A 用简单的 JSON 索引（Documents/index.json）保存元数据；
/// 阶段 B 再换成 SwiftData / SQLite。音频文件与索引分开存放，索引只存相对信息。
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

    func fileURL(_ recording: StoredRecording, _ segment: StoredSegment) -> URL {
        AppPaths.recordings
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
            .appendingPathComponent(segment.fileName)
    }

    /// 必须在 WCSession 的 didReceive(file:) 回调中同步调用：回调返回后系统会删除临时文件。
    func ingest(fileAt tempURL: URL, info: SegmentInfo) -> IngestResult {
        let actual: String
        do {
            actual = try FileHash.sha256(of: tempURL)
        } catch {
            return .failed("读取临时文件失败：\(error.localizedDescription)")
        }

        lock.lock()
        defer {
            lock.unlock()
            publish()
        }

        guard actual == info.sha256 else {
            statsStorage.checksumFailures += 1
            save()
            return .checksumMismatch(actual: actual)
        }

        var rec = byId[info.recordingId] ?? StoredRecording(id: info.recordingId, firstReceivedAt: Date())

        if let existing = rec.segments.first(where: { $0.index == info.segmentIndex }),
           existing.sha256 == info.sha256,
           FileManager.default.fileExists(atPath: fileURL(rec, existing).path) {
            statsStorage.duplicates += 1
            save()
            return .duplicate
        }

        let dest = AppPaths.recordingDir(info.recordingId).appendingPathComponent(info.fileName)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            return .failed("保存分段失败：\(error.localizedDescription)")
        }

        rec.segments.removeAll { $0.index == info.segmentIndex }
        rec.segments.append(StoredSegment(index: info.segmentIndex, sha256: info.sha256, byteCount: info.byteCount,
                                          duration: info.duration, startedAt: info.startedAt,
                                          receivedAt: Date(), recovered: info.recovered))
        rec.segments.sort { $0.index < $1.index }
        byId[rec.id] = rec
        statsStorage.stored += 1
        save()
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
    }

    func noteLogReceived() {
        lock.lock()
        statsStorage.logs += 1
        save()
        lock.unlock()
        publish()
    }

    /// 删除录音：同时删除音频目录和索引记录（阶段 C/D 起还要级联删除转录与摘要）。
    func delete(_ id: UUID) {
        lock.lock()
        byId[id] = nil
        save()
        lock.unlock()
        try? FileManager.default.removeItem(at: AppPaths.recordings.appendingPathComponent(id.uuidString, isDirectory: true))
        publish()
        EventLog.shared.info("已删除录音 \(id.uuidString.prefix(8)) 及其音频文件")
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
        byId = Dictionary(uniqueKeysWithValues: p.recordings.map { ($0.id, $0) })
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
