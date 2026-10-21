import Foundation
import AVFAudio

/// 把一条录音的多个分段当作一条连续音频播放：支持拖动进度、跳转到某句话、倍速。
@MainActor
final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    struct Item {
        let index: Int
        let url: URL
        let offset: TimeInterval
        let duration: TimeInterval
    }

    @Published private(set) var recordingId: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var totalDuration: TimeInterval = 0
    @Published private(set) var currentSegment: Int?
    @Published var rate: Float = 1.0 {
        didSet { player?.rate = rate }
    }

    private var items: [Item] = []
    private var itemIndex = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// 准备播放某条录音（同一条录音重复调用不会打断当前播放）。
    func load(_ rec: StoredRecording) {
        if recordingId == rec.id && !items.isEmpty { return }
        stop()
        let store = RecordingStore.shared
        let offsets = rec.segmentOffsets()
        items = rec.segments.compactMap { seg in
            guard seg.playable != false else { return nil }
            return Item(index: seg.index, url: store.fileURL(rec, seg),
                        offset: offsets[seg.index] ?? 0, duration: seg.effectiveDuration)
        }
        recordingId = rec.id
        totalDuration = rec.totalDuration
        currentTime = 0
        itemIndex = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard !items.isEmpty else { return }
        if let p = player {
            activateSession()
            p.play()
            isPlaying = true
            startTimer()
        } else {
            seek(to: currentTime >= totalDuration - 0.5 ? 0 : currentTime)
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentSegment = nil
        stopTimer()
    }

    /// 跳到时间轴上的某个位置并播放。
    func seek(to time: TimeInterval, autoplay: Bool = true) {
        guard !items.isEmpty else { return }
        let t = max(0, min(time, totalDuration))
        let i = items.lastIndex(where: { $0.offset <= t }) ?? 0
        startItem(i, at: t - items[i].offset, autoplay: autoplay)
    }

    func skip(_ delta: TimeInterval) {
        seek(to: currentTime + delta, autoplay: isPlaying)
    }

    // MARK: - 内部

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            EventLog.shared.warn("播放音频会话设置失败：\(error.localizedDescription)")
        }
    }

    private func startItem(_ i: Int, at local: TimeInterval, autoplay: Bool) {
        player?.stop()
        player = nil
        var idx = i
        while idx < items.count {
            let item = items[idx]
            do {
                let p = try AVAudioPlayer(contentsOf: item.url)
                p.delegate = self
                p.enableRate = true
                p.rate = rate
                p.currentTime = max(0, min(local, p.duration))
                player = p
                itemIndex = idx
                currentSegment = item.index
                currentTime = item.offset + p.currentTime
                if autoplay {
                    activateSession()
                    p.play()
                    isPlaying = true
                    startTimer()
                } else {
                    isPlaying = false
                }
                return
            } catch {
                EventLog.shared.error("无法播放分段 #\(item.index)：\(error.localizedDescription)")
                idx += 1
            }
        }
        finish()
    }

    private func advance() {
        if itemIndex + 1 < items.count {
            startItem(itemIndex + 1, at: 0, autoplay: true)
        } else {
            finish()
        }
    }

    private func finish() {
        player = nil
        isPlaying = false
        currentSegment = nil
        currentTime = totalDuration
        stopTimer()
    }

    private func tick() {
        guard let p = player, itemIndex < items.count else { return }
        currentTime = items[itemIndex].offset + p.currentTime
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.advance()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "未知"
        Task { @MainActor in
            EventLog.shared.error("解码错误：\(message)")
            guard player === self.player else { return }
            self.advance()
        }
    }
}
