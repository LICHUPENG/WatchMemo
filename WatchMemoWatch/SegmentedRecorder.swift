import Foundation
import AVFAudio
import WatchKit

/// 分段录音器。
/// - 每个分段用 `record(forDuration:)` 录制，到时由系统回调切换到下一段，
///   这样即使 App 的定时器在后台被挂起，分段切换仍由音频系统驱动。
/// - 暂停 = 结束当前分段；继续 = 开始新分段。因此暂停状态下所有文件都已完整写入。
/// - App 崩溃或被杀时，最多只损失正在录制的那一段。
final class SegmentedRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, recording, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var segmentIndex = 0
    @Published var lastError: String?

    // 由外部在开始录音前设置
    var segmentLength: TimeInterval = 60
    var minFreeBytes: Int64 = 50 * 1024 * 1024

    var onSegmentFinished: ((SegmentInfo) -> Void)?
    var onRecordingEnded: ((_ id: UUID, _ segmentCount: Int, _ endedAt: Date, _ duration: TimeInterval) -> Void)?
    var onStartFailed: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var recordingId: UUID?
    private var nextIndex = 0
    private var segmentStart: Date?
    private var completedDuration: TimeInterval = 0
    private var pausedByInterruption = false
    private var uiTimer: Timer?
    private var lastTick: Date?
    private let log = EventLog.shared

    /// 16 kHz 单声道 AAC，约 14 MB/小时，足够语音转录，同时减轻蓝牙传输压力。
    private let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    // MARK: - 公共操作

    func start() {
        guard state == .idle else { return }
        lastError = nil
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginNewRecording()
        case .undetermined:
            log.info("请求麦克风权限")
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.log.info("麦克风权限：已允许")
                        self.beginNewRecording()
                    } else {
                        self.failToStart("麦克风权限被拒绝。请在手表「设置 → 隐私与安全性 → 麦克风」中开启。")
                    }
                }
            }
        case .denied:
            failToStart("麦克风权限被拒绝。请在手表「设置 → 隐私与安全性 → 麦克风」中开启。")
        @unknown default:
            failToStart("未知的麦克风权限状态")
        }
    }

    func pause() {
        guard state == .recording else { return }
        finishCurrentSegment()
        state = .paused
        refreshElapsed()
        WKInterfaceDevice.current().play(.click)
        log.info("暂停录音，已录 \(completedDuration.clockString)")
    }

    func resume() {
        guard state == .paused else { return }
        pausedByInterruption = false
        guard hasEnoughSpace() else {
            lastError = "存储空间不足，无法继续录音"
            log.error("继续录音失败：存储空间不足")
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.warn("重新激活音频会话失败：\(error.localizedDescription)")
        }
        if startSegment() {
            state = .recording
            WKInterfaceDevice.current().play(.start)
            log.info("继续录音")
        }
    }

    func stop() {
        guard state != .idle, let id = recordingId else { return }
        if state == .recording { finishCurrentSegment() }
        let count = nextIndex
        state = .idle
        stopUITimer()
        refreshElapsed()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        WKInterfaceDevice.current().play(.stop)
        log.info("结束录音 \(id.uuidString.prefix(8))：共 \(count) 段，总时长 \(completedDuration.clockString)，电量 \(batteryString())")
        recordingId = nil
        onRecordingEnded?(id, count, Date(), completedDuration)
    }

    // MARK: - 录音流程

    private func beginNewRecording() {
        guard hasEnoughSpace() else {
            failToStart("存储空间不足（低于 \(minFreeBytes.byteString)），无法开始录音")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            failToStart("音频会话启动失败：\(error.localizedDescription)")
            return
        }

        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        recordingId = UUID()
        nextIndex = 0
        completedDuration = 0
        elapsed = 0

        if startSegment() {
            state = .recording
            startUITimer()
            WKInterfaceDevice.current().play(.start)
            log.info("开始录音 \(recordingId!.uuidString.prefix(8))，分段长度 \(Int(segmentLength))s，电量 \(batteryString())，剩余空间 \(AppPaths.freeSpaceBytes()?.byteString ?? "?")")
        } else {
            recordingId = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            onStartFailed?()
        }
    }

    @discardableResult
    private func startSegment() -> Bool {
        guard let id = recordingId else { return false }
        let url = AppPaths.recordingDir(id).appendingPathComponent(SegmentInfo.fileName(for: nextIndex))
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            guard r.record(forDuration: segmentLength) else {
                throw NSError(domain: "WatchMemo", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "record() 返回 false（麦克风可能被占用）"])
            }
            recorder = r
            segmentStart = Date()
            segmentIndex = nextIndex
            return true
        } catch {
            lastError = "无法开始分段 #\(nextIndex)：\(error.localizedDescription)"
            log.error(lastError!)
            return false
        }
    }

    /// 主动结束当前分段（暂停 / 停止 / 中断 / 编码错误）。
    private func finishCurrentSegment() {
        guard let r = recorder else { return }
        recorder = nil                 // 先置空，delegate 回调中据此判断已处理
        if r.isRecording { r.stop() }  // stop() 会把文件完整写入磁盘
        finalize(url: r.url)
    }

    /// 分段文件已写完：计算校验值并交给同步模块。
    private func finalize(url: URL) {
        guard let id = recordingId else { return }
        let duration = Date().timeIntervalSince(segmentStart ?? Date())
        segmentStart = nil
        let size = FileHash.size(of: url)
        guard size > 0 else {
            log.warn("分段 #\(nextIndex) 为空文件，已丢弃")
            try? FileManager.default.removeItem(at: url)
            return
        }
        completedDuration += duration
        do {
            let hash = try FileHash.sha256(of: url)
            let info = SegmentInfo(recordingId: id, segmentIndex: nextIndex, startedAt: Date().addingTimeInterval(-duration),
                                   duration: duration, byteCount: size, sha256: hash)
            nextIndex += 1
            log.info("分段 #\(info.segmentIndex) 完成：\(String(format: "%.1f", duration))s，\(size.byteString)，电量 \(batteryString())")
            onSegmentFinished?(info)
        } catch {
            log.error("分段 #\(nextIndex) 计算校验失败：\(error.localizedDescription)")
            nextIndex += 1
        }
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async {
            // 只处理“到达分段时长自动结束”的情况；主动 stop 的已在 finishCurrentSegment 中处理。
            guard r === self.recorder else { return }
            self.recorder = nil
            if !flag { self.log.warn("分段 #\(self.nextIndex) 录制未正常结束（successfully = false）") }
            self.finalize(url: r.url)

            guard self.state == .recording else { return }
            if self.hasEnoughSpace() {
                if !self.startSegment() {
                    self.log.error("切换分段失败，录音停止")
                    self.stop()
                }
            } else {
                self.lastError = "存储空间不足，录音已自动结束"
                self.log.error("存储空间不足，自动结束录音")
                self.stop()
            }
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ r: AVAudioRecorder, error: Error?) {
        DispatchQueue.main.async {
            self.log.error("编码错误：\(error?.localizedDescription ?? "未知")，尝试开始新分段")
            guard r === self.recorder else { return }
            self.finishCurrentSegment()
            if self.state == .recording, !self.startSegment() { self.stop() }
        }
    }

    // MARK: - 中断处理（来电、Siri、其他 App 占用音频等）

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log.warn("音频中断开始（状态：\(state)）")
            if state == .recording {
                finishCurrentSegment()
                state = .paused
                pausedByInterruption = true
                refreshElapsed()
            }
        case .ended:
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            log.warn("音频中断结束，shouldResume = \(shouldResume)")
            if pausedByInterruption && state == .paused {
                if shouldResume {
                    resume()
                } else {
                    lastError = "录音被中断，已暂停。点击继续恢复录音。"
                }
            }
        @unknown default:
            break
        }
    }

    // MARK: - 辅助

    private func failToStart(_ message: String) {
        lastError = message
        log.error(message)
        onStartFailed?()
    }

    private func hasEnoughSpace() -> Bool {
        guard let free = AppPaths.freeSpaceBytes() else { return true }
        return free >= minFreeBytes
    }

    private func batteryString() -> String {
        let level = WKInterfaceDevice.current().batteryLevel
        return level < 0 ? "未知" : "\(Int(level * 100))%"
    }

    private func refreshElapsed() {
        var t = completedDuration
        if state == .recording, let s = segmentStart { t += Date().timeIntervalSince(s) }
        elapsed = t
    }

    private func startUITimer() {
        stopUITimer()
        lastTick = Date()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            // 定时器停顿说明 App 曾被挂起：阶段 A 判断后台行为的重要线索。
            if let last = self.lastTick, now.timeIntervalSince(last) > 5 {
                self.log.warn("定时器停顿 \(Int(now.timeIntervalSince(last)))s（App 可能曾被挂起），录音器状态：\(self.recorder?.isRecording == true ? "录音中" : "未录音")")
            }
            self.lastTick = now
            self.refreshElapsed()
        }
    }

    private func stopUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
        lastTick = nil
    }
}
