import Foundation
import AVFAudio
import Speech

/// 静音检测：按 100ms 窗口计算 RMS，统计超过阈值的窗口占比。
enum AudioAnalyzer {
    /// 窗口 RMS 超过该值（dBFS）视为“有声音”。真机上请根据诊断页数据校准。
    static let activeThresholdDb: Double = -42
    /// 有声窗口占比低于该值视为静音分段。
    static let silentRatio: Double = 0.02

    static func analyze(_ url: URL) -> AudioStats? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sr = format.sampleRate
        guard sr > 0, file.length > 0 else { return nil }
        let window = max(Int(sr * 0.1), 1)
        let capacity = AVAudioFrameCount(window * 50)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var windows = 0
        var active = 0
        var sumDb = 0.0
        var peakDb = -160.0

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channel = buffer.floatChannelData?[0] else { break }
            var start = 0
            while start < n {
                let end = min(start + window, n)
                var sum: Float = 0
                for i in start..<end { sum += channel[i] * channel[i] }
                let rms = sqrt(Double(sum) / Double(end - start))
                let db = 20 * log10(max(rms, 1e-9))
                windows += 1
                sumDb += db
                peakDb = max(peakDb, db)
                if db > activeThresholdDb { active += 1 }
                start = end
            }
        }
        guard windows > 0 else { return nil }
        return AudioStats(speechRatio: Double(active) / Double(windows),
                          meanDb: sumDb / Double(windows),
                          peakDb: peakDb)
    }
}

enum SpeechEngineError: LocalizedError {
    case unsupportedLocale(String)
    case unavailable
    case timeout
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): return "不支持的识别语言：\(id)"
        case .unavailable: return "语音识别当前不可用（设备端模型未就绪且无网络，或系统限制）"
        case .timeout: return "转录超时"
        case .notAuthorized: return "未获得语音识别授权，请在 设置 → 隐私与安全性 → 语音识别 中允许 WatchMemo"
        }
    }
}

/// 用系统 Speech 框架转录单个音频文件。
enum SpeechEngine {
    struct Output {
        var lines: [TranscriptLine]
        var onDevice: Bool
    }

    static func supportsOnDevice(localeId: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeId))?.supportsOnDeviceRecognition ?? false
    }

    static func transcribe(url: URL, segmentIndex: Int, localeId: String, preferOnDevice: Bool) async throws -> Output {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) else {
            throw SpeechEngineError.unsupportedLocale(localeId)
        }
        let onDevice = preferOnDevice && recognizer.supportsOnDeviceRecognition
        guard recognizer.isAvailable else { throw SpeechEngineError.unavailable }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = onDevice

        let gate = ResumeGate()
        let holder = TaskHolder()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
            holder.task = recognizer.recognitionTask(with: request) { result, error in
                _ = recognizer   // 保持识别器存活直到回调结束
                if let result, result.isFinal {
                    let lines = makeLines(result.bestTranscription, segmentIndex: segmentIndex)
                    if gate.claim() { cont.resume(returning: Output(lines: lines, onDevice: onDevice)) }
                    return
                }
                if let error {
                    let ns = error as NSError
                    // 1110：No speech detected —— 视为成功但没有文字
                    if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 {
                        if gate.claim() { cont.resume(returning: Output(lines: [], onDevice: onDevice)) }
                    } else {
                        if gate.claim() { cont.resume(throwing: error) }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                if gate.claim() {
                    holder.task?.cancel()
                    cont.resume(throwing: SpeechEngineError.timeout)
                }
            }
        }
    }

    /// 把识别结果切成句子，并把每句对齐到词级时间戳。
    static func makeLines(_ t: SFTranscription, segmentIndex: Int) -> [TranscriptLine] {
        let text = t.formattedString
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // 1. 按句末标点切句；过长时在逗号处切
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]
        let softBreaks: Set<Character> = ["，", ",", "、", " "]
        var sentences: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if enders.contains(ch) || (cur.count >= 48 && softBreaks.contains(ch)) {
                sentences.append(cur)
                cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sentences.append(cur) }

        // 2. 按“字母/数字字符数”顺序消耗词段，得到每句的起止时间
        func core(_ s: String) -> Int { s.filter { $0.isLetter || $0.isNumber }.count }
        let segs = t.segments
        var i = 0
        var usedInSeg = 0
        var lines: [TranscriptLine] = []

        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            var need = core(trimmed)
            if need == 0 {
                // 纯标点：并入上一句
                if !lines.isEmpty { lines[lines.count - 1].text += trimmed }
                continue
            }
            // 跳过没有有效字符的词段
            while i < segs.count && core(segs[i].substring) == 0 { i += 1 }
            let startTime = i < segs.count ? segs[i].timestamp : (lines.last?.end ?? 0)
            var endTime = startTime
            while need > 0 && i < segs.count {
                let avail = core(segs[i].substring) - usedInSeg
                endTime = segs[i].timestamp + segs[i].duration
                if avail <= need {
                    need -= avail
                    i += 1
                    usedInSeg = 0
                } else {
                    usedInSeg += need
                    need = 0
                }
            }
            lines.append(TranscriptLine(id: "\(segmentIndex)-\(lines.count)", segmentIndex: segmentIndex,
                                        start: startTime, end: max(endTime, startTime), text: trimmed))
        }
        return lines
    }
}

/// 保证 continuation 只 resume 一次。
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private final class TaskHolder: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
}
