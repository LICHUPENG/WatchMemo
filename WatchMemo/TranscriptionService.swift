import Foundation
import Speech
import UIKit

struct SegmentRef: Hashable {
    var recordingId: UUID
    var index: Int
}

/// 转录队列：分段一到就排队转录；状态全部持久化在 MemoStore，App 重启后自动续上未完成的分段。
@MainActor
final class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published private(set) var current: SegmentRef?
    @Published private(set) var queued: [SegmentRef] = []
    @Published private(set) var authStatus: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    @Published private(set) var lastError: String?

    private var forced: Set<SegmentRef> = []
    private var worker: Task<Void, Never>?
    private let store = RecordingStore.shared
    private let memo = MemoStore.shared
    private let log = EventLog.shared

    private init() {}

    func bootstrap() {
        store.onSegmentStored = { id, index in
            Task { @MainActor in TranscriptionService.shared.segmentArrived(id, index) }
        }
        store.onRecordingEnded = { id in
            Task { @MainActor in TranscriptionService.shared.recordingMaybeFinished(id) }
        }
        enqueueAllPending()
    }

    func isBusy(_ recordingId: UUID) -> Bool {
        current?.recordingId == recordingId || queued.contains { $0.recordingId == recordingId }
    }

    // MARK: - 入队

    /// 扫描所有录音中尚未转录的分段（App 启动、回到前台、开启自动转录时调用）。
    func enqueueAllPending() {
        guard Prefs.autoTranscribe else { return }
        for rec in store.snapshot().reversed() where !rec.isAudioPurged {
            let t = memo.transcripts[rec.id]
            for seg in rec.segments where t?.segment(seg.index) == nil {
                enqueue(SegmentRef(recordingId: rec.id, index: seg.index))
            }
        }
        if !queued.isEmpty { startWorkerIfNeeded() }
    }

    private func segmentArrived(_ id: UUID, _ index: Int) {
        guard Prefs.autoTranscribe else { return }
        // 重新收到的分段（例如重传覆盖）需要重新转录
        if memo.transcripts[id]?.segment(index) != nil {
            return
        }
        enqueue(SegmentRef(recordingId: id, index: index))
    }

    /// 手动转录整条录音。force = true 时清除已有结果并忽略静音检测。
    func transcribe(recordingId: UUID, force: Bool) {
        guard let rec = store.recording(recordingId), !rec.isAudioPurged else { return }
        if force {
            memo.resetTranscript(recordingId)
        } else {
            memo.resetTranscript(recordingId, onlyFailed: true)
        }
        for seg in rec.segments where memo.transcripts[recordingId]?.segment(seg.index) == nil {
            let ref = SegmentRef(recordingId: recordingId, index: seg.index)
            if force { forced.insert(ref) }
            enqueue(ref)
        }
    }

    /// 只转录某一个分段（诊断页里对“静音”分段强制转录）。
    func transcribeSegment(_ ref: SegmentRef) {
        forced.insert(ref)
        enqueue(ref, front: true)
    }

    func retryAllFailed() {
        for (id, t) in memo.transcripts where t.segments.contains(where: { $0.status == .failed }) {
            transcribe(recordingId: id, force: false)
        }
    }

    private func enqueue(_ ref: SegmentRef, front: Bool = false) {
        guard ref != current, !queued.contains(ref) else { return }
        if front { queued.insert(ref, at: 0) } else { queued.append(ref) }
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { @MainActor in
            await self.drain()
            self.worker = nil
        }
    }

    // MARK: - 处理

    private func drain() async {
        while !queued.isEmpty {
            // 只在前台转录：后台被唤醒接收文件时时间很短，转录容易失败；回到前台会自动继续
            if UIApplication.shared.applicationState == .background {
                log.info("App 在后台，转录暂停（\(queued.count) 个分段待处理）")
                return
            }
            if authStatus != .authorized {
                let ok = await ensureAuthorized()
                if !ok {
                    lastError = SpeechEngineError.notAuthorized.localizedDescription
                    log.error("语音识别未授权，转录队列暂停（\(queued.count) 个分段待处理）")
                    return
                }
            }
            guard !queued.isEmpty else { break }
            let ref = queued.removeFirst()
            current = ref
            await process(ref)
            current = nil
            recordingMaybeFinished(ref.recordingId)
        }
    }

    private func ensureAuthorized() async -> Bool {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        authStatus = status
        return status == .authorized
    }

    func requestAuthorization() {
        Task { @MainActor in
            if await ensureAuthorized() {
                lastError = nil
                startWorkerIfNeeded()
            }
        }
    }

    func refreshAuthStatus() {
        authStatus = SFSpeechRecognizer.authorizationStatus()
    }

    private func process(_ ref: SegmentRef) async {
        guard let rec = store.recording(ref.recordingId),
              let seg = rec.segments.first(where: { $0.index == ref.index }),
              !rec.isAudioPurged else { return }
        let url = store.fileURL(rec, seg)
        let label = "\(ref.recordingId.uuidString.prefix(8))#\(ref.index)"
        let isForced = forced.remove(ref) != nil

        guard FileManager.default.fileExists(atPath: url.path) else {
            memo.setSegmentTranscript(ref.recordingId, SegmentTranscript(index: ref.index, status: .failed, error: "音频文件不存在"))
            return
        }

        // 后台多争取一点时间把当前分段做完
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "transcribe") {}
        defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }

        let stats = await Task.detached(priority: .utility) { AudioAnalyzer.analyze(url) }.value

        if seg.playable == false && stats == nil {
            memo.setSegmentTranscript(ref.recordingId, SegmentTranscript(index: ref.index, status: .failed,
                                                                          error: "音频无法解码（文件可能不完整）"))
            log.warn("转录 \(label)：音频无法解码")
            return
        }

        if !isForced, Prefs.skipSilence, let stats, stats.speechRatio < AudioAnalyzer.silentRatio {
            memo.setSegmentTranscript(ref.recordingId, SegmentTranscript(index: ref.index, status: .silent, stats: stats))
            log.info("转录 \(label)：判定为静音（有声占比 \(String(format: "%.1f%%", stats.speechRatio * 100))），跳过")
            return
        }

        let started = Date()
        do {
            let out = try await SpeechEngine.transcribe(url: url, segmentIndex: ref.index,
                                                        localeId: Prefs.speechLocale,
                                                        preferOnDevice: Prefs.preferOnDevice)
            let elapsed = Date().timeIntervalSince(started)
            memo.setSegmentTranscript(ref.recordingId, SegmentTranscript(index: ref.index, status: .done, lines: out.lines,
                                                                          engine: out.onDevice ? "设备端" : "服务器",
                                                                          stats: stats, elapsed: elapsed))
            lastError = nil
            log.info("转录 \(label) 完成：\(out.lines.count) 句，\(out.onDevice ? "设备端" : "服务器")，耗时 \(String(format: "%.1f", elapsed))s")
        } catch {
            memo.setSegmentTranscript(ref.recordingId, SegmentTranscript(index: ref.index, status: .failed,
                                                                          error: error.localizedDescription, stats: stats))
            lastError = error.localizedDescription
            log.error("转录 \(label) 失败：\(error.localizedDescription)")
        }
    }

    /// 录音完整且全部分段已处理 → 如开启自动摘要则生成。
    private func recordingMaybeFinished(_ id: UUID) {
        guard let rec = store.recording(id), rec.isComplete, !isBusy(id) else { return }
        let p = memo.progress(for: rec)
        guard p.isFinished else { return }
        if Prefs.autoSummary, Prefs.aiEnabled, memo.summaries[id] == nil,
           !(memo.transcripts[id]?.plainText.isEmpty ?? true) {
            log.info("录音 \(id.uuidString.prefix(8)) 转录完成，自动生成摘要")
            Task { @MainActor in await SummaryService.shared.summarize(id) }
        }
    }
}
