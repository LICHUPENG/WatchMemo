import SwiftUI

/// 跨模块的操作：删除、保留策略、启动恢复。
@MainActor
enum AppActions {
    /// 删除录音：音频、索引、转录、摘要、标题一起删除。
    static func deleteRecording(_ id: UUID, player: RecordingPlayer?) {
        if player?.recordingId == id { player?.stop() }
        RecordingStore.shared.delete(id)
        MemoStore.shared.deleteAll(for: id)
    }

    /// 启动 / 回到前台时：续上转录队列、执行音频保留策略。
    static func maintenance() {
        TranscriptionService.shared.refreshAuthStatus()
        TranscriptionService.shared.enqueueAllPending()
        applyRetention()
    }

    /// 超过保留天数、且已转录完成的录音：删除原始音频，保留文字。
    @discardableResult
    static func applyRetention() -> Int {
        let days = Prefs.audioRetentionDays
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var purged = 0
        for rec in RecordingStore.shared.snapshot() where !rec.isAudioPurged && rec.isComplete && rec.approxEnd < cutoff {
            let p = MemoStore.shared.progress(for: rec)
            guard p.isFinished, p.failed == 0 else { continue }
            RecordingStore.shared.purgeAudio(rec.id)
            purged += 1
        }
        return purged
    }
}

// MARK: - 云端发送前告知

struct CloudConsentRequest: Identifiable {
    let id = UUID()
    let message: String
    let action: () -> Void
}

extension View {
    /// 发送到云端 AI 之前弹出确认（可在设置中关闭）。
    func cloudConsent(_ request: Binding<CloudConsentRequest?>) -> some View {
        alert("发送到云端 AI？",
              isPresented: Binding(get: { request.wrappedValue != nil },
                                   set: { if !$0 { request.wrappedValue = nil } }),
              presenting: request.wrappedValue) { req in
            Button("发送") { req.action() }
            Button("取消", role: .cancel) {}
        } message: { req in
            Text(req.message)
        }
    }
}

@MainActor
enum CloudGate {
    /// 需要确认时返回请求对象，否则直接执行并返回 nil。
    static func request(what: String, chars: Int, action: @escaping () -> Void) -> CloudConsentRequest? {
        guard Prefs.aiConfirm else {
            action()
            return nil
        }
        let host = AIClient.currentHost ?? "未配置的服务"
        return CloudConsentRequest(
            message: "将把\(what)（约 \(chars) 字）发送到 \(host)。不会上传音频。服务商可能按其政策保留数据。",
            action: action)
    }
}
