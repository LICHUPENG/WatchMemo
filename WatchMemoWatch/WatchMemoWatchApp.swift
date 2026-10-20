import SwiftUI

/// 把录音器、保活、同步三者串起来。
final class WatchAppModel: ObservableObject {
    let recorder = SegmentedRecorder()
    let keepAlive = KeepAliveController()
    let sync = WatchSyncManager.shared

    init() {
        sync.activate()
        recorder.onSegmentFinished = { [weak self] info in
            self?.sync.enqueue(info)
        }
        recorder.onRecordingEnded = { [weak self] id, count, endedAt in
            self?.sync.enqueueRecordingEnd(id: id, segmentCount: count, endedAt: endedAt)
            self?.keepAlive.stop()
        }
        recorder.onStartFailed = { [weak self] in
            self?.keepAlive.stop()
        }
    }

    func startRecording(mode: KeepAliveMode, segmentLength: TimeInterval, minFreeMB: Int) {
        recorder.segmentLength = segmentLength
        recorder.minFreeBytes = Int64(minFreeMB) * 1024 * 1024
        EventLog.shared.info("保活方案：\(mode.title)")
        keepAlive.start(mode) { [weak self] in
            self?.recorder.start()
        }
    }
}

@main
struct WatchMemoWatchApp: App {
    @StateObject private var model = WatchAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RecorderView()
            }
            .environmentObject(model)
            .environmentObject(model.recorder)
            .environmentObject(model.sync)
            .environmentObject(model.keepAlive)
        }
        .onChange(of: scenePhase) { _, phase in
            // 记录前后台切换，配合“定时器停顿”日志判断 App 何时被挂起
            EventLog.shared.info("App 状态：\(String(describing: phase))")
            if phase == .active { model.sync.retryDue() }
        }
    }
}
