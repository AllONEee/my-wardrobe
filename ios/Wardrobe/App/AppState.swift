//
//  AppState.swift —— 极简全局状态 + 事件总线（对应 store/global.js）
//
//  用法（和页面里原来的写法一一对应）：
//    onLoad   → bus.on(.clothingChange, ctx: self) { [weak self] _ in self?.loadList() }
//    onUnload → bus.offBy(ctx: self)
//    数据层写完后会自动 emit，页面监听到就刷新
//
//  约定：
//   - 只放「跨页面共享」的少量状态（设置、筛选条件、就绪标记、待编辑的搭配），业务数据一律走 Database。
//   - 不做深层响应式，页面需要响应变化请订阅事件（而不是直接读 state）。
//

import Foundation
import SwiftUI
import UIKit

/// 事件类型（对应 store/global.js 的 EVENTS）
enum AppEvent: String, CaseIterable {
    case appReady
    case clothingChange
    case outfitChange
    case inspirationChange
    case settingsChange
    case wardrobeFilterChange
    case categoryChange
    case weatherChange
}

/// 事件负载（对应 emit 时传的 payload）
struct AppEventPayload {
    var type: String = ""
    var action: String = ""
    var id: String = ""
    var reason: String = ""
}

/// 别的页面要「在试衣间继续编辑某套搭配」时先写这里，再切到试衣间
/// （tabBar 页不能带参数，所以走共享状态，见 store/global.js 的 pendingFitting）
struct PendingFitting: Equatable {
    var outfitId: String
    var ts: Double = Date().milliseconds
}

/// 事件总线：evt -> [(ctx, handler)]，ctx 弱引用，页面卸载时 offBy 一次性注销
final class EventBus {
    private struct Entry {
        weak var ctx: AnyObject?
        let handler: (AppEventPayload) -> Void
    }

    private var listeners: [AppEvent: [Entry]] = [:]

    func on(_ event: AppEvent, ctx: AnyObject?, _ handler: @escaping (AppEventPayload) -> Void) {
        listeners[event, default: []].append(Entry(ctx: ctx, handler: handler))
    }

    /// 只触发一次（对应 store.once）
    func once(_ event: AppEvent, ctx: AnyObject?, _ handler: @escaping (AppEventPayload) -> Void) {
        var fired = false
        on(event, ctx: ctx) { payload in
            guard !fired else { return }
            fired = true
            handler(payload)
        }
    }

    /// 移除该事件下某个 ctx 的监听
    func off(_ event: AppEvent, ctx: AnyObject?) {
        guard var entries = listeners[event] else { return }
        entries.removeAll { $0.ctx === ctx }
        listeners[event] = entries
    }

    /// 页面 onUnload 里一次性注销本页面注册的所有监听，避免内存泄漏
    func offBy(ctx: AnyObject?) {
        guard let ctx else { return }
        for event in AppEvent.allCases {
            off(event, ctx: ctx)
        }
    }

    func emit(_ event: AppEvent, _ payload: AppEventPayload = AppEventPayload()) {
        guard let entries = listeners[event], !entries.isEmpty else { return }
        for entry in entries {
            guard entry.ctx != nil else { continue }
            entry.handler(payload)
        }
    }

    /// 清理已经释放的监听（长时间运行后调一次即可）
    func prune() {
        for event in AppEvent.allCases {
            listeners[event]?.removeAll { $0.ctx == nil }
        }
    }
}

/// 全局状态（由 App 入口 / Database 写入）
final class AppState: ObservableObject {
    static let shared = AppState()

    /// 事件总线（页面订阅 / 数据层派发）
    let bus = EventBus()

    @Published private(set) var ready = false
    @Published var settings = AppSettings()
    @Published var wardrobeFilter = WardrobeFilter()
    @Published var pendingFitting: PendingFitting?
    /// 当前选中的 tab（「在试衣间编辑」这类跨 tab 跳转要用）
    @Published var selectedTab: AppTab = .wardrobe

    private init() {}

    func markReady(settings: AppSettings, filter: WardrobeFilter) {
        self.settings = settings
        self.wardrobeFilter = filter
        ready = true
        bus.emit(.appReady, AppEventPayload(type: "app"))
    }
}

/// 系统信息（对应 app.js 的 globalData.systemInfo / statusBarHeight / pixelRatio / safeAreaBottom）
struct SystemInfo {
    var windowWidth: CGFloat = 375
    var windowHeight: CGFloat = 667
    var pixelRatio: CGFloat = 3
    var safeAreaBottom: CGFloat = 0
    var safeAreaTop: CGFloat = 0
    /// 设置页「关于」里展示
    var systemName: String = ""
    var systemVersion: String = ""
    var deviceModel: String = ""

    static let current: SystemInfo = {
        var info = SystemInfo()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first?.windows.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        if let window {
            let bounds = window.bounds
            info.windowWidth = bounds.width
            info.windowHeight = bounds.height
            info.pixelRatio = window.screen.scale
            info.safeAreaTop = window.safeAreaInsets.top
            info.safeAreaBottom = window.safeAreaInsets.bottom
        } else {
            let screen = UIScreen.main
            info.windowWidth = screen.bounds.width
            info.windowHeight = screen.bounds.height
            info.pixelRatio = screen.scale
        }
        info.systemName = UIDevice.current.systemName
        info.systemVersion = UIDevice.current.systemVersion
        info.deviceModel = UIDevice.current.model
        return info
    }()
}
