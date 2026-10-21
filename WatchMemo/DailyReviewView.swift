import SwiftUI

/// 每日回顾：当天的高光、回顾、待办，以及当天的录音时间线。
struct DailyReviewView: View {
    let day: Date

    @ObservedObject private var store = RecordingStore.shared
    @ObservedObject private var memo = MemoStore.shared
    @ObservedObject private var summarizer = SummaryService.shared
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = false
    @State private var consent: CloudConsentRequest?

    private var key: String { SummaryService.dayKey(day) }

    var body: some View {
        let recs = store.recordings
            .filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
            .sorted { $0.startedAt < $1.startedAt }
        let review = memo.dailyReviews[key]
        let running = summarizer.runningDays.contains(key)
        let missingSummaries = recs.filter { memo.summaries[$0.id] == nil && !(memo.transcripts[$0.id]?.plainText.isEmpty ?? true) }

        List {
            Section {
                HStack(spacing: 16) {
                    stat("\(recs.count)", "条录音")
                    stat(recs.reduce(0) { $0 + $1.totalDuration }.clockString, "总时长")
                    stat("\(recs.reduce(0) { $0 + (memo.transcripts[$1.id]?.plainText.count ?? 0) })", "字")
                }
                .frame(maxWidth: .infinity)
            }

            if let r = review {
                if !r.headline.isEmpty {
                    Section { Text(r.headline).font(.title3.weight(.semibold)) }
                }
                if !r.highlights.isEmpty {
                    Section("高光") {
                        ForEach(Array(r.highlights.enumerated()), id: \.offset) { _, h in
                            Label(h, systemImage: "star.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                }
                if !r.reflection.isEmpty {
                    Section("回顾") { Text(r.reflection) }
                }
                if !r.todos.isEmpty {
                    Section("待办") {
                        ForEach(Array(r.todos.enumerated()), id: \.offset) { _, t in
                            Label(t, systemImage: "circle")
                        }
                    }
                }
            }

            Section {
                if aiEnabled {
                    Button {
                        let material = summarizer.dailyMaterial(day)
                        consent = CloudGate.request(what: "当天 \(material.count) 条录音的摘要或转录节选", chars: material.text.count) {
                            Task { await summarizer.reviewDay(day) }
                        }
                    } label: {
                        HStack {
                            Label(review == nil ? "生成每日回顾" : "重新生成", systemImage: "sun.max")
                            if running { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(running || recs.isEmpty)
                } else {
                    Text("开启云端 AI 后可以生成每日回顾（设置 → AI）。")
                        .foregroundStyle(.secondary)
                }
                if let err = summarizer.dayErrors[key] {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                if let r = review {
                    Text("\(r.model) · \(r.createdAt.formatted(date: .abbreviated, time: .shortened)) · 基于 \(r.recordingCount) 条录音")
                } else if !missingSummaries.isEmpty && aiEnabled {
                    Text("有 \(missingSummaries.count) 条录音还没有摘要，将使用转录节选。先生成单条摘要效果更好。")
                }
            }

            Section("时间线") {
                if recs.isEmpty {
                    Text("这一天没有录音").foregroundStyle(.secondary)
                }
                ForEach(recs) { rec in
                    NavigationLink {
                        RecordingDetailView(recordingId: rec.id)
                    } label: {
                        RecordingRow(recording: rec)
                    }
                }
            }
        }
        .navigationTitle(day.formatted(.dateTime.month().day().weekday()))
        .navigationBarTitleDisplayMode(.inline)
        .cloudConsent($consent)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
