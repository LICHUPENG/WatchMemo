import SwiftUI

@main
struct WatchMemoApp: App {
    @StateObject private var player = SegmentPlayer()

    init() {
        // 尽早激活：iPhone App 可能被系统在后台唤醒来接收手表文件
        PhoneSyncManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
        }
    }
}
