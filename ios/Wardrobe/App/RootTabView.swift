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
        // 页面铺满整屏，底栏浮在上面：滚动内容会从玻璃下面穿过去（不是被一条色块挡住）
        ZStack(alignment: .bottom) {
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
        // 页面里自带的底部操作栏按这个高度往上让，避免被悬浮底栏压住
        .environment(
            \.floatingBarInset,
            Theme.floatingBarHeight + Theme.floatingBarBottomGap
        )
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
        barBody
            .modifier(FloatingGlassBar())
            .shadow(color: Theme.barShadow, radius: 18, x: 0, y: 8)
            .padding(.horizontal, 20)
            .padding(.bottom, Theme.floatingBarBottomGap)
    }

    private var barBody: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    tabItem(tab)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: Theme.floatingBarHeight)
    }

    /// 一个 tab：图标 + 文字。拆成单独的方法，避免编译器在 ForEach 里推断超时
    private func tabItem(_ tab: AppTab) -> some View {
        let isSelected = selection == tab
        let tint = isSelected ? Theme.primary : Theme.textSub
        return VStack(spacing: 3) {
            tabIcon(tab, isSelected: isSelected)
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(tint)
            Text(tab.title)
                .font(.system(size: titleSize, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// 选中的用小程序那套橙色图标；未选中的走模板渲染，深色模式下会自动提亮
    @ViewBuilder
    private func tabIcon(_ tab: AppTab, isSelected: Bool) -> some View {
        if isSelected {
            Image(tab.activeIcon)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(tab.icon)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

/// 底栏的「玻璃」背景：iOS 26 起用系统的 Liquid Glass（就是 P1 那种系统毛玻璃），
/// 更早的系统退回系统的 ultraThinMaterial 材质 —— 两种都是真·半透明，会透出下面滚动的内容。
private struct FloatingGlassBar: ViewModifier {
    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.barStroke, lineWidth: 0.5))
        }
    }
}
