import Foundation
import WatchConnectivity

/// 手表端同步：
/// 1. 分段完成后进入持久化队列（pending.json），App 重启后继续。
/// 2. 用 transferFile 发送；系统会在断连时排队，恢复连接后自动送达。
/// 3. 只有收到手机的 ack（文件已落盘且校验通过）才删除本地文件——“确认后删除”。
/// 4. 未确认的分段按指数退避重发；重复发送由手机端按 (recordingId, segmentIndex, sha256) 去重。
final class WatchSyncManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSyncManager()

    struct PendingSegment: Codable, Identifiable {
        var info: SegmentInfo
        var attempts = 0
        var lastAttempt: Date?
        var delivered = false   // 系统已送达，等待手机确认
        var id: String { info.key }

        var fileURL: URL {
            AppPaths.recordings
                .appendingPathComponent(info.recordingId.uuidString, isDirectory: true)
                .appendingPathComponent(info.fileName)
        }
    }

    struct PendingEnd: Codable {
        var recordingId: UUID
        var segmentCount: Int
        var endedAt: Date
    }

    private struct Persisted: Codable {
        var segments: [PendingSegment] = []
        var ends: [PendingEnd] = []
        var ackedCount = 0
    }

    @Published private(set) var pending: [PendingSegment] = []
    @Published private(set) var isReachable = false
    @Published private(set) var isActivated = false
    @Published private(set) var ackedCount = 0

    private var pendingEnds: [PendingEnd] = []
    private var retryTimer: Timer?
    private let storeURL = AppPaths.documents.appendingPathComponent("pending.json")
    private let log = EventLog.shared

    // MARK: - 启动

    func activate() {
        load()
        recoverOrphans()
        guard WCSession.isSupported() else {
            log.error("WCSession 不受支持")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.retryDue()
        }
    }

    /// 启动时扫描：磁盘上存在、但不在队列里的分段（例如录音中 App 被杀）。
    /// 注意：被杀时正在写入的 .m4a 可能不完整、无法播放——这正是阶段 A 要验证的。
    private func recoverOrphans() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: AppPaths.recordings, includingPropertiesForKeys: nil) else { return }
        let known = Set(pending.map(\.id))
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { continue }
            if files.isEmpty { try? fm.removeItem(at: dir); continue }
            for file in files where file.pathExtension == "m4a" {
                guard let index = Int(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "seg_", with: "")),
                      !known.contains(SegmentInfo.makeKey(id, index)) else { continue }
                let size = FileHash.size(of: file)
                guard size > 0, let hash = try? FileHash.sha256(of: file) else {
                    log.warn("恢复：删除空分段 \(id.uuidString.prefix(8))#\(index)")
                    try? fm.removeItem(at: file)
                    continue
                }
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                let info = SegmentInfo(recordingId: id, segmentIndex: index, startedAt: created,
                                       duration: 0, byteCount: size, sha256: hash, recovered: true)
                pending.append(PendingSegment(info: info))
                log.warn("恢复孤儿分段 \(id.uuidString.prefix(8))#\(index)（\(size.byteString)），加入同步队列")
            }
        }
        save()
    }

    // MARK: - 入队

    func enqueue(_ info: SegmentInfo) {
        guard !pending.contains(where: { $0.id == info.key }) else { return }
        pending.append(PendingSegment(info: info))
        save()
        send(key: info.key)
    }

    func enqueueRecordingEnd(id: UUID, segmentCount: Int, endedAt: Date) {
        pendingEnds.append(PendingEnd(recordingId: id, segmentCount: segmentCount, endedAt: endedAt))
        save()
        flushEnds()
    }

    func sendLogToPhone() {
        guard isActivated else { log.warn("WCSession 未激活，无法发送日志"); return }
        guard let snapshot = log.snapshot() else { log.warn("日志为空"); return }
        WCSession.default.transferFile(snapshot, metadata: [TransferKey.kind: TransferKind.log.rawValue])
        log.info("日志已加入发送队列")
    }

    // MARK: - 发送与重试

    private func send(key: String) {
        guard isActivated, let i = pending.firstIndex(where: { $0.id == key }) else { return }
        let p = pending[i]
        guard FileManager.default.fileExists(atPath: p.fileURL.path) else {
            log.error("分段文件丢失：\(key)，移出队列")
            pending.remove(at: i)
            save()
            return
        }
        if isOutstanding(key) { return }
        WCSession.default.transferFile(p.fileURL, metadata: p.info.metadata)
        pending[i].attempts += 1
        pending[i].lastAttempt = Date()
        pending[i].delivered = false
        save()
        log.info("发送分段 \(p.info.recordingId.uuidString.prefix(8))#\(p.info.segmentIndex)（第 \(pending[i].attempts) 次）")
    }

    /// 对所有未确认、且已过退避时间的分段重新发送。
    func retryDue() {
        guard isActivated else { return }
        let now = Date()
        for p in pending {
            let backoff = min(30 * pow(2, Double(max(p.attempts - 1, 0))), 1800)
            if let last = p.lastAttempt, now.timeIntervalSince(last) < backoff { continue }
            send(key: p.id)
        }
    }

    private func isOutstanding(_ key: String) -> Bool {
        WCSession.default.outstandingFileTransfers.contains { transfer in
            guard let meta = transfer.file.metadata else { return false }
            return SegmentInfo(metadata: meta)?.key == key
        }
    }

    private func flushEnds() {
        guard isActivated, !pendingEnds.isEmpty else { return }
        for end in pendingEnds {
            WCSession.default.transferUserInfo([
                TransferKey.kind: TransferKind.recordingEnd.rawValue,
                TransferKey.recordingId: end.recordingId.uuidString,
                TransferKey.segmentCount: end.segmentCount,
                TransferKey.endedAt: end.endedAt.timeIntervalSince1970,
            ])
            log.info("发送结束标记 \(end.recordingId.uuidString.prefix(8))，共 \(end.segmentCount) 段")
        }
        pendingEnds.removeAll()   // transferUserInfo 由系统排队保证送达
        save()
    }

    private func handleAck(_ userInfo: [String: Any]) {
        guard userInfo[TransferKey.kind] as? String == TransferKind.ack.rawValue,
              let key = userInfo[TransferKey.ackKey] as? String,
              let statusRaw = userInfo[TransferKey.ackStatus] as? String,
              let status = AckStatus(rawValue: statusRaw) else { return }
        guard let i = pending.firstIndex(where: { $0.id == key }) else {
            log.info("收到确认 \(key)（已不在队列中，忽略）")
            return
        }
        switch status {
        case .stored, .duplicate:
            let p = pending.remove(at: i)
            try? FileManager.default.removeItem(at: p.fileURL)
            let dir = p.fileURL.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: dir)
            }
            ackedCount += 1
            save()
            log.info("手机已确认 \(p.info.recordingId.uuidString.prefix(8))#\(p.info.segmentIndex)（\(status.rawValue)），本地文件已删除")
        case .checksumMismatch:
            log.error("手机报告校验失败 \(key)，立即重发")
            pending[i].lastAttempt = nil
            save()
            send(key: key)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isActivated = state == .activated
            self.isReachable = session.isReachable
            if let error {
                self.log.error("WCSession 激活失败：\(error.localizedDescription)")
            } else {
                self.log.info("WCSession 已激活，iPhone App 已安装：\(session.isCompanionAppInstalled)，可达：\(session.isReachable)")
            }
            self.flushEnds()
            self.retryDue()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.log.info("iPhone 可达性变化：\(session.isReachable ? "可达" : "不可达")")
            if session.isReachable { self.retryDue() }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let meta = fileTransfer.file.metadata ?? [:]
        let fileURL = fileTransfer.file.fileURL
        DispatchQueue.main.async {
            if meta[TransferKey.kind] as? String == TransferKind.log.rawValue {
                try? FileManager.default.removeItem(at: fileURL)
                if let error { self.log.warn("日志发送失败：\(error.localizedDescription)") }
                else { self.log.info("日志已送达 iPhone") }
                return
            }
            guard let info = SegmentInfo(metadata: meta),
                  let i = self.pending.firstIndex(where: { $0.id == info.key }) else { return }
            self.pending[i].lastAttempt = Date()   // 从现在开始计算退避（等待确认或等待重试）
            if let error {
                self.pending[i].delivered = false
                self.log.warn("分段 #\(info.segmentIndex) 传输失败：\(error.localizedDescription)，将按退避重试")
            } else {
                self.pending[i].delivered = true
                self.log.info("分段 #\(info.segmentIndex) 已送达 iPhone，等待确认")
            }
            self.save()
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async { self.handleAck(userInfo) }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        pending = p.segments
        pendingEnds = p.ends
        ackedCount = p.ackedCount
        if !pending.isEmpty { log.info("从磁盘恢复同步队列：\(pending.count) 个分段") }
    }

    private func save() {
        let p = Persisted(segments: pending, ends: pendingEnds, ackedCount: ackedCount)
        do {
            try JSONEncoder().encode(p).write(to: storeURL, options: .atomic)
        } catch {
            log.error("保存同步队列失败：\(error.localizedDescription)")
        }
    }
}
