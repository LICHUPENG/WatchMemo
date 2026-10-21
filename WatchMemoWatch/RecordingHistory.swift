import Foundation

/// 手表上最近的录音记录（只存元数据，用于首页显示“今天录了多少”）。
final class RecordingHistory: ObservableObject {
    struct Entry: Codable, Identifiable, Hashable {
        var id: UUID
        var endedAt: Date
        var duration: TimeInterval
        var segments: Int
    }

    @Published private(set) var entries: [Entry] = []
    private let key = "recordingHistory"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
    }

    func add(id: UUID, endedAt: Date, duration: TimeInterval, segments: Int) {
        entries.insert(Entry(id: id, endedAt: endedAt, duration: duration, segments: segments), at: 0)
        if entries.count > 50 { entries.removeLast(entries.count - 50) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    var today: [Entry] { entries.filter { Calendar.current.isDateInToday($0.endedAt) } }
    var todayDuration: TimeInterval { today.reduce(0) { $0 + $1.duration } }
}
