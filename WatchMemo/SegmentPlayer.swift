import Foundation
import AVFAudio

/// 按顺序播放一个或多个分段，用来人工检查分段衔接处是否有丢音。
final class SegmentPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    struct Item {
        let key: String
        let url: URL
    }

    @Published private(set) var playingKey: String?

    private var player: AVAudioPlayer?
    private var queue: [Item] = []

    func play(_ items: [Item]) {
        stop()
        queue = items
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            EventLog.shared.warn("播放音频会话设置失败：\(error.localizedDescription)")
        }
        playNext()
    }

    func stop() {
        player?.stop()
        player = nil
        queue.removeAll()
        playingKey = nil
    }

    private func playNext() {
        guard !queue.isEmpty else {
            playingKey = nil
            player = nil
            return
        }
        let item = queue.removeFirst()
        do {
            let p = try AVAudioPlayer(contentsOf: item.url)
            p.delegate = self
            p.play()
            player = p
            playingKey = item.key
        } catch {
            EventLog.shared.error("无法播放 \(item.url.lastPathComponent)：\(error.localizedDescription)（文件可能不完整）")
            playNext()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playNext() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            EventLog.shared.error("解码错误：\(error?.localizedDescription ?? "未知")")
            self.playNext()
        }
    }
}
