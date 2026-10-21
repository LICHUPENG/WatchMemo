import SwiftUI

@main
struct WatchMemoApp: App {
    @StateObject private var player = RecordingPlayer()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Prefs.registerDefaults()
        // 尽早激活：iPhone App 可能被系统在后台唤醒来接收手表文件
        PhoneSyncManager.shared.activate()
        TranscriptionService.shared.bootstrap()
        AppActions.applyRetention()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { AppActions.maintenance() }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            RecordsView()
                .tabItem { Label("记录", systemImage: "waveform") }
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            AskView()
                .tabItem { Label("问问", systemImage: "bubble.left.and.text.bubble.right") }
            PhoneSettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
