import SwiftUI

/// 问问过去的自己：先在本机检索相关片段，再把片段发给模型回答。
struct AskView: View {
    @ObservedObject private var ask = AskService.shared
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = false
    @State private var input = ""
    @State private var consent: CloudConsentRequest?
    @FocusState private var focused: Bool

    private let suggestions = [
        "今天我都聊了些什么？",
        "昨天会议上定了哪些事？",
        "最近有哪些我答应别人要做的事？",
        "上周有人提到过预算吗？",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if ask.turns.isEmpty { intro }
                            ForEach(ask.turns) { turn in
                                bubble(turn).id(turn.id)
                            }
                            if ask.isThinking {
                                HStack { ProgressView(); Text("正在检索并思考…").foregroundStyle(.secondary) }
                                    .id("thinking")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: ask.turns.count) { _, _ in
                        if let last = ask.turns.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                inputBar
            }
            .navigationTitle("问问")
            .toolbar {
                if !ask.turns.isEmpty {
                    Button("新对话") { ask.reset() }
                }
            }
            .cloudConsent($consent)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("向你的录音提问")
                .font(.title3.weight(.semibold))
            Text("WatchMemo 会先在本机的转录文字里找到相关片段，只把这些片段发给你配置的 AI，不会上传音频，也不会上传全部记录。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !aiEnabled {
                Label("云端 AI 未开启，请先到「设置 → AI」中配置。", systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            ForEach(suggestions, id: \.self) { s in
                Button {
                    input = s
                    send()
                } label: {
                    Text(s)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!aiEnabled)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ turn: ChatTurn) -> some View {
        switch turn.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
        case "error":
            Label(turn.text, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey(turn.text))
                    .textSelection(.enabled)
                if !turn.sources.isEmpty {
                    Text("参考的录音").font(.caption).foregroundStyle(.secondary)
                    ForEach(turn.sources) { src in
                        NavigationLink {
                            RecordingDetailView(recordingId: src.recordingId, focusLineId: src.lineId)
                        } label: {
                            Label(src.label, systemImage: "waveform")
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("问点什么…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ask.isThinking || !aiEnabled)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, aiEnabled, !ask.isThinking else { return }
        let prepared = ask.prepare(q)
        let action = {
            input = ""
            focused = false
            Task { await ask.ask(q, prepared: prepared) }
        }
        let what = prepared.recordingCount > 0 ? "问题和 \(prepared.recordingCount) 条录音中的相关片段" : "问题（未检索到相关录音）"
        consent = CloudGate.request(what: what, chars: prepared.context.count + q.count, action: action)
    }
}
