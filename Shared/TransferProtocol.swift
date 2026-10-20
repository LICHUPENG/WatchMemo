import Foundation

/// 手表与手机之间通过 WatchConnectivity 传递的元数据约定。
/// 所有 key 都是字符串，值只使用 property-list 类型（String / Double / Int / Bool）。
enum TransferKey {
    static let kind = "kind"
    static let recordingId = "recordingId"
    static let segmentIndex = "segmentIndex"
    static let sha256 = "sha256"
    static let byteCount = "byteCount"
    static let startedAt = "startedAt"      // timeIntervalSince1970
    static let duration = "duration"        // 秒
    static let recovered = "recovered"      // 是否为重启后恢复的孤儿分段
    static let segmentCount = "segmentCount"
    static let endedAt = "endedAt"
    static let ackKey = "ackKey"
    static let ackStatus = "ackStatus"
}

enum TransferKind: String {
    case segment        // 手表 → 手机：音频分段文件（transferFile）
    case log            // 手表 → 手机：日志文件（transferFile）
    case recordingEnd   // 手表 → 手机：一次录音结束，告知总分段数（transferUserInfo）
    case ack            // 手机 → 手表：分段已落盘确认（transferUserInfo）
}

enum AckStatus: String {
    case stored             // 新文件，已保存
    case duplicate          // 已存在且校验一致，视为成功
    case checksumMismatch   // 校验失败，请手表重发
}

/// 一个音频分段的描述。录音 ID 在手表端生成，(recordingId, segmentIndex) 是全局唯一键。
struct SegmentInfo: Codable, Hashable, Identifiable {
    var recordingId: UUID
    var segmentIndex: Int
    var startedAt: Date
    var duration: TimeInterval
    var byteCount: Int64
    var sha256: String
    var recovered: Bool = false

    var key: String { Self.makeKey(recordingId, segmentIndex) }
    var id: String { key }
    var fileName: String { Self.fileName(for: segmentIndex) }

    static func makeKey(_ id: UUID, _ index: Int) -> String { "\(id.uuidString)#\(index)" }
    static func fileName(for index: Int) -> String { String(format: "seg_%04d.m4a", index) }

    var metadata: [String: Any] {
        [
            TransferKey.kind: TransferKind.segment.rawValue,
            TransferKey.recordingId: recordingId.uuidString,
            TransferKey.segmentIndex: segmentIndex,
            TransferKey.startedAt: startedAt.timeIntervalSince1970,
            TransferKey.duration: duration,
            TransferKey.byteCount: byteCount,
            TransferKey.sha256: sha256,
            TransferKey.recovered: recovered,
        ]
    }

    init(recordingId: UUID, segmentIndex: Int, startedAt: Date, duration: TimeInterval,
         byteCount: Int64, sha256: String, recovered: Bool = false) {
        self.recordingId = recordingId
        self.segmentIndex = segmentIndex
        self.startedAt = startedAt
        self.duration = duration
        self.byteCount = byteCount
        self.sha256 = sha256
        self.recovered = recovered
    }

    init?(metadata: [String: Any]) {
        guard
            let idString = metadata[TransferKey.recordingId] as? String,
            let id = UUID(uuidString: idString),
            let index = (metadata[TransferKey.segmentIndex] as? NSNumber)?.intValue,
            let started = (metadata[TransferKey.startedAt] as? NSNumber)?.doubleValue,
            let sha = metadata[TransferKey.sha256] as? String
        else { return nil }
        self.recordingId = id
        self.segmentIndex = index
        self.startedAt = Date(timeIntervalSince1970: started)
        self.duration = (metadata[TransferKey.duration] as? NSNumber)?.doubleValue ?? 0
        self.byteCount = (metadata[TransferKey.byteCount] as? NSNumber)?.int64Value ?? 0
        self.sha256 = sha
        self.recovered = (metadata[TransferKey.recovered] as? Bool) ?? false
    }
}

enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 录音根目录：Documents/Recordings/<recordingId>/seg_0000.m4a
    static var recordings: URL {
        let url = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func recordingDir(_ id: UUID) -> URL {
        let url = recordings.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func freeSpaceBytes() -> Int64? {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}

extension TimeInterval {
    /// 03:25 或 1:03:25
    var clockString: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
