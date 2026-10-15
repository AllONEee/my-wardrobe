//
//  WardrobeApp.swift —— App 入口（对应 app.js）
//
//  onLaunch 里做两件事：
//   1. 初始化数据层（建默认数据、自愈 id 索引）
//   2. 把设置 / 筛选条件搬进全局状态，并派发「就绪」事件
//

import SwiftUI

@main
struct WardrobeApp: App {
    @StateObject private var appState = AppState.shared

    init() {
        // 对应 app.js 的 onLaunch：先初始化数据层
        Database.shared.initialize()

        let settings = Database.shared.getSettings()
        AppState.shared.markReady(
            settings: settings,
            filter: Database.shared.getWardrobeFilter()
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .tint(Theme.primary)
                .preferredColorScheme(.light)
        }
    }
}
