import Foundation
import WatchConnectivity

/// iPhone 端接收：校验 → 落盘 → 去重 → 回 ack。
final class PhoneSyncManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneSyncManager()

    @Published private(set) var isActivated = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false

    private let store = RecordingStore.shared
    private let log = EventLog.shared

    static var watchLogsDir: URL {
        let url = AppPaths.documents.appendingPathComponent("WatchLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func activate() {
        guard WCSession.isSupported() else {
            log.error("此设备不支持 WCSession")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func refresh(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isActivated = session.activationState == .activated
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isReachable = session.isReachable
        }
    }

    // MARK: - 状态回调

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        refresh(session)
        if let error {
            log.error("WCSession 激活失败：\(error.localizedDescription)")
        } else {
            log.info("WCSession 已激活，配对：\(session.isPaired)，手表 App 已安装：\(session.isWatchAppInstalled)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        log.warn("WCSession 变为 inactive（可能在切换手表）")
        refresh(session)
    }

    func sessionDidDeactivate(_ session: WCSession) {
        log.warn("WCSession 已停用，重新激活")
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) { refresh(session) }

    func sessionReachabilityDidChange(_ session: WCSession) {
        refresh(session)
        log.info("手表可达性变化：\(session.isReachable ? "可达" : "不可达")")
    }

    // MARK: - 接收文件

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let meta = file.metadata ?? [:]

        if meta[TransferKey.kind] as? String == TransferKind.log.rawValue {
            saveWatchLog(file.fileURL)
            return
        }

        guard let info = SegmentInfo(metadata: meta) else {
            log.error("收到无法识别的文件：\(file.fileURL.lastPathComponent)")
            return
        }

        let label = "\(info.recordingId.uuidString.prefix(8))#\(info.segmentIndex)"
        switch store.ingest(fileAt: file.fileURL, info: info) {
        case .stored:
            log.info("收到分段 \(label)：\(info.byteCount.byteString)，\(String(format: "%.1f", info.duration))s\(info.recovered ? "（恢复）" : "")")
            ack(info, .stored)
        case .duplicate:
            log.warn("重复分段 \(label)，已忽略并确认")
            ack(info, .duplicate)
        case .checksumMismatch(let actual):
            log.error("分段 \(label) 校验失败：期望 \(info.sha256.prefix(12))，实际 \(actual.prefix(12))")
            ack(info, .checksumMismatch)
        case .failed(let message):
            // 不回 ack：手表会按退避重发
            log.error("分段 \(label) 处理失败：\(message)")
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo[TransferKey.kind] as? String == TransferKind.recordingEnd.rawValue,
              let idString = userInfo[TransferKey.recordingId] as? String,
              let id = UUID(uuidString: idString),
              let count = (userInfo[TransferKey.segmentCount] as? NSNumber)?.intValue else { return }
        let ended = (userInfo[TransferKey.endedAt] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        store.markEnded(id: id, segmentCount: count, endedAt: ended)
        log.info("收到结束标记 \(id.uuidString.prefix(8))：共 \(count) 段")
    }

    private func ack(_ info: SegmentInfo, _ status: AckStatus) {
        // transferUserInfo 由系统排队，手表 App 不在前台也能稍后收到
        WCSession.default.transferUserInfo([
            TransferKey.kind: TransferKind.ack.rawValue,
            TransferKey.ackKey: info.key,
            TransferKey.ackStatus: status.rawValue,
        ])
    }

    private func saveWatchLog(_ tempURL: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dest = Self.watchLogsDir.appendingPathComponent("watch-\(formatter.string(from: Date())).log")
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
            store.noteLogReceived()
            log.info("收到手表日志：\(dest.lastPathComponent)")
        } catch {
            log.error("保存手表日志失败：\(error.localizedDescription)")
        }
    }
}
