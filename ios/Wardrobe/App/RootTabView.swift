//
//  RootTabView.swift —— 四个主页面 + 底部 tab 栏（对应 app.json 的 tabBar）
//
//  tabBar 的图标直接用小程序 assets/tabbar 里的那两套图（选中 / 未选中），
//  颜色、文案、顺序都与 app.json 一致：衣橱 / 日记 / 试衣间 / 设置。
//
//  四个页面像小程序的 tabBar 页一样常驻：
//  切走再切回来不会重建，页面里的滚动位置、选中日期都保留。
//

import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case wardrobe
    case diary
    case fitting
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wardrobe: return "衣橱"
        case .diary: return "日记"
        case .fitting: return "试衣间"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .wardrobe: return "tab-wardrobe"
        case .diary: return "tab-diary"
        case .fitting: return "tab-fitting"
        case .settings: return "tab-settings"
        }
    }

    var activeIcon: String {
        icon + "-active"
    }
}

struct RootTabView: View {
    @ObservedObject private var appState = AppState.shared
    /// 首屏就要把当前选中的 tab 建出来（比如启动时直接落在「设置」上，否则内容区会是空的）
    @State private var visited: Set<AppTab> = [AppState.shared.selectedTab]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // 首次切到时才创建，之后常驻（和小程序 tabBar 页的生命周期一致）
                ForEach(AppTab.allCases) { value in
                    if visited.contains(value) {
                        page(value)
                            .opacity(appState.selectedTab == value ? 1 : 0)
                            .allowsHitTesting(appState.selectedTab == value)
                            .accessibilityHidden(appState.selectedTab != value)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            AppTabBar(selection: $appState.selectedTab)
        }
        .background(Theme.bg)
        .appToast()
        .onChange(of: appState.selectedTab) { _, value in
            visited.insert(value)
        }
    }

    /// 每个页面都拿到「自己是不是当前可见」，用来实现原来的 onShow（切回来时刷新）
    @ViewBuilder
    private func page(_ value: AppTab) -> some View {
        switch value {
        case .wardrobe:
            NavigationStack { WardrobeView(isActive: appState.selectedTab == .wardrobe) }
        case .diary:
            NavigationStack { DiaryView(isActive: appState.selectedTab == .diary) }
        case .fitting:
            NavigationStack { FittingView(isActive: appState.selectedTab == .fitting) }
        case .settings:
            NavigationStack { SettingsView(isActive: appState.selectedTab == .settings) }
        }
    }
}

/// 底部 tab 栏（对应 app.json 的 tabBar 配置）
struct AppTabBar: View {
    @Binding var selection: AppTab

    /// 图标与文字尺寸：比小程序那版放大了两号，小屏上也能一眼看清
    private let iconSize: CGFloat = 30
    private let titleSize: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 0.5)
            HStack(spacing: 0) {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        VStack(spacing: 3) {
                            Image(selection == tab ? tab.activeIcon : tab.icon)
                                .renderingMode(.original)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: iconSize, height: iconSize)
                            Text(tab.title)
                                .font(.system(size: titleSize, weight: selection == tab ? .semibold : .regular))
                                .foregroundStyle(selection == tab ? Theme.primary : Theme.textSub)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background {
            Theme.card.ignoresSafeArea(edges: .bottom)
        }
    }
}
