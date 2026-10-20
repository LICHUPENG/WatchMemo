import Foundation
import SwiftUI

/// 阶段 A 的核心产出之一：带时间戳的事件日志。
/// 同时写入 Documents/events.log（可导出做测试记录）和内存（界面显示最近 300 条）。
final class EventLog: ObservableObject {
    static let shared = EventLog()

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let time: Date
        let level: String
        let message: String
    }

    @Published private(set) var recent: [Entry] = []
    let fileURL: URL

    private let queue = DispatchQueue(label: "watchmemo.eventlog")
    private let formatter: DateFormatter

    private init() {
        fileURL = AppPaths.documents.appendingPathComponent("events.log")
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func info(_ message: String) { write("INFO", message) }
    func warn(_ message: String) { write("WARN", message) }
    func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        let entry = Entry(time: Date(), level: level, message: message)
        queue.async {
            let line = "\(self.formatter.string(from: entry.time)) [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: self.fileURL)
            }
        }
        DispatchQueue.main.async {
            self.recent.insert(entry, at: 0)
            if self.recent.count > 300 { self.recent.removeLast(self.recent.count - 300) }
        }
        #if DEBUG
        print("[WatchMemo][\(level)] \(message)")
        #endif
    }

    /// 生成一份日志快照（用于传输或分享，避免传输过程中原文件仍在被追加）。
    func snapshot() -> URL? {
        queue.sync {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("events-\(Int(Date().timeIntervalSince1970)).log")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: fileURL, to: dest)
                return dest
            } catch {
                return nil
            }
        }
    }

    func clear() {
        queue.async { try? FileManager.default.removeItem(at: self.fileURL) }
        DispatchQueue.main.async { self.recent.removeAll() }
    }
}

struct LogView: View {
    @ObservedObject private var log = EventLog.shared

    var body: some View {
        List(log.recent) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.time, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(color(for: entry.level))
            }
        }
        .navigationTitle("日志")
    }

    private func color(for level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        default: return .primary
        }
    }
}
