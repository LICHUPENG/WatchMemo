import Foundation
import WatchKit
import HealthKit

/// 阶段 A 要对比的几种“让录音在放下手腕后继续”的方案。
enum KeepAliveMode: String, CaseIterable, Identifiable {
    case backgroundAudio     // 仅依赖 UIBackgroundModes = audio
    case extendedRuntime     // WKExtendedRuntimeSession（physical-therapy 类型）
    case workout             // HKWorkoutSession（自用可行，上架有审核风险）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backgroundAudio: return "仅后台音频"
        case .extendedRuntime: return "延长运行会话"
        case .workout: return "体能训练会话"
        }
    }
}

final class KeepAliveController: NSObject, ObservableObject,
                                 WKExtendedRuntimeSessionDelegate, HKWorkoutSessionDelegate {
    @Published private(set) var status = "未启用"

    private var runtimeSession: WKExtendedRuntimeSession?
    private var workoutSession: HKWorkoutSession?
    private let healthStore = HKHealthStore()
    private let log = EventLog.shared

    /// 启动保活方案，无论成功与否最终都会在主线程调用 completion（录音照常开始，结果写入日志）。
    func start(_ mode: KeepAliveMode, completion: @escaping () -> Void) {
        stop()
        switch mode {
        case .backgroundAudio:
            setStatus("仅后台音频")
            completion()

        case .extendedRuntime:
            let session = WKExtendedRuntimeSession()
            session.delegate = self
            runtimeSession = session
            session.start()
            setStatus("延长运行会话：启动中")
            completion()

        case .workout:
            guard HKHealthStore.isHealthDataAvailable() else {
                log.error("此设备不支持 HealthKit，无法启动体能训练会话")
                setStatus("HealthKit 不可用")
                completion()
                return
            }
            healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { ok, error in
                DispatchQueue.main.async {
                    if let error { self.log.warn("HealthKit 授权出错：\(error.localizedDescription)") }
                    do {
                        let config = HKWorkoutConfiguration()
                        config.activityType = .other
                        config.locationType = .indoor
                        let session = try HKWorkoutSession(healthStore: self.healthStore, configuration: config)
                        session.delegate = self
                        session.startActivity(with: Date())
                        self.workoutSession = session
                        self.setStatus("体能训练会话：启动中")
                    } catch {
                        self.log.error("启动体能训练会话失败：\(error.localizedDescription)（授权：\(ok)）")
                        self.setStatus("体能训练会话失败")
                    }
                    completion()
                }
            }
        }
    }

    func stop() {
        if let s = runtimeSession {
            if s.state == .running || s.state == .scheduled { s.invalidate() }
            runtimeSession = nil
        }
        if let w = workoutSession {
            w.end()
            workoutSession = nil
        }
        setStatus("未启用")
    }

    private func setStatus(_ s: String) {
        if Thread.isMainThread { status = s } else { DispatchQueue.main.async { self.status = s } }
    }

    // MARK: - WKExtendedRuntimeSessionDelegate

    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        log.info("延长运行会话已开始，预计到期：\(session.expirationDate.map { "\($0)" } ?? "未知")")
        setStatus("延长运行会话：运行中")
    }

    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        log.warn("延长运行会话即将到期")
        setStatus("延长运行会话：即将到期")
    }

    func extendedRuntimeSession(_ session: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        log.warn("延长运行会话结束，原因码 \(reason.rawValue)\(error.map { "，错误：\($0.localizedDescription)" } ?? "")")
        setStatus("延长运行会话：已结束（\(reason.rawValue)）")
    }

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        log.info("体能训练会话状态：\(fromState.rawValue) → \(toState.rawValue)")
        if toState == .running { setStatus("体能训练会话：运行中") }
        if toState == .ended { setStatus("体能训练会话：已结束") }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        log.error("体能训练会话出错：\(error.localizedDescription)")
        setStatus("体能训练会话出错")
    }
}
