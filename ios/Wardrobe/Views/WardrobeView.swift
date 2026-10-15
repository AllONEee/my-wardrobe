//
//  WardrobeView.swift —— 衣橱（对应 pages/wardrobe）
//
//  功能：分类 / 季节筛选、按名称和备注搜索、3 列网格、
//       点图片进详情、点卡片空白区 wearCount++、右下角 + 添加衣物。
//  筛选状态（分类/季节/关键词）存在本地，下次进入自动恢复。
//

import SwiftUI

final class WardrobeModel: ObservableObject {
    @Published var filter = WardrobeFilter()
    /// 输入框的即时值（防抖后才写进 filter）
    @Published var keyword = ""
    @Published var showLastWorn = true
    @Published var list: [ClothingItem] = []
    @Published var total = 0

    private var searchWork: DispatchWorkItem?
    /// 点卡片加次数时已经就地更新过那一张卡片，跳过这次整表刷新
    private var skipNextChange = false

    init() {
        filter = Database.shared.getWardrobeFilter()
        keyword = filter.keyword
        showLastWorn = Database.shared.getSettings().showLastWorn
        loadList()

        // 数据层写入后会自动派发事件，这里订阅后自动刷新
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.loadList() }
        }
        AppState.shared.bus.on(.settingsChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async {
                self?.showLastWorn = Database.shared.getSettings().showLastWorn
            }
        }
        // 分类被改名 / 删除后，筛选条要跟着变；当前选中的分类没了就退回「全部」
        AppState.shared.bus.on(.categoryChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.categories = [Wardrobe.all] + Database.shared.listCategories()
                if self.filter.category != Wardrobe.all, !self.categories.contains(self.filter.category) {
                    var next = self.filter
                    next.category = Wardrobe.all
                    self.apply(next)
                } else {
                    self.loadList()
                }
            }
        }
    }

    deinit {
        searchWork?.cancel()
        AppState.shared.bus.offBy(ctx: self)
    }

    /// 分类筛选条：跟着「分类管理」里的自定义分类走
    @Published var categories: [String] = [Wardrobe.all] + Database.shared.listCategories()
    var seasons: [String] { [Wardrobe.all] + Wardrobe.seasons }
    var hasFilter: Bool { filter.isFiltering }

    /// none | empty（衣橱为空） | noResult（筛选无结果）
    enum EmptyType {
        case none
        case empty
        case noResult
    }

    var emptyType: EmptyType {
        if !list.isEmpty { return .none }
        return total == 0 ? .empty : .noResult
    }

    func loadList() {
        if skipNextChange {
            skipNextChange = false
            return
        }
        list = Database.shared.listClothing(filter: filter)
        total = Database.shared.listClothing().count
    }

    /* ==================== 筛选 / 搜索 ==================== */

    func selectCategory(_ value: String) {
        guard value != filter.category else { return }
        var next = filter
        next.category = value
        apply(next)
    }

    func selectSeason(_ value: String) {
        guard value != filter.season else { return }
        var next = filter
        next.season = value
        apply(next)
    }

    /// 输入防抖：连续打字时只在停下来之后查一次
    func updateKeyword(_ value: String) {
        keyword = value
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.filter.keyword != value else { return }
            var next = self.filter
            next.keyword = value
            self.apply(next)
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
    }

    /// 键盘回车：立即搜索，不等防抖
    func confirmKeyword() {
        searchWork?.cancel()
        guard filter.keyword != keyword else { return }
        var next = filter
        next.keyword = keyword
        apply(next)
    }

    func clearKeyword() {
        searchWork?.cancel()
        keyword = ""
        var next = filter
        next.keyword = ""
        apply(next)
    }

    func resetFilter() {
        searchWork?.cancel()
        keyword = ""
        apply(WardrobeFilter())
    }

    private func apply(_ next: WardrobeFilter) {
        // 筛选状态落本地存储
        filter = Database.shared.saveWardrobeFilter(next)
        loadList()
    }

    /* ==================== 卡片交互 ==================== */

    /// 点卡片空白区 -> 穿着次数 +1
    func wearOnce(_ id: String) {
        skipNextChange = true
        guard let next = Database.shared.increaseWearCount(id, step: 1) else {
            // 衣物已被删除等异常情况，让事件监听照常刷新
            skipNextChange = false
            loadList()
            return
        }
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index].wearCount = next.wearCount
            list[index].lastWornDate = next.lastWornDate
        }
        Haptic.light()
    }
}

struct WardrobeView: View {
    var isActive: Bool = true

    @StateObject private var model = WardrobeModel()
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.floatingBarInset) private var floatingBarInset
    @State private var detailId: String?
    @State private var showAddClothing = false

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                searchBar
                filters
                summary
                if model.list.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .padding(Theme.pagePadding)
            .padding(.bottom, 90) // 给悬浮按钮留位置
        }
        .background(Theme.bg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("衣橱")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) { fab }
        .navigationDestination(item: $detailId) { id in
            ClothingDetailView(clothingId: id)
        }
        .navigationDestination(isPresented: $showAddClothing) {
            ClothingEditView(clothingId: "")
        }
    }

    /* ==================== 搜索 ==================== */

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textLight)
            TextField(
                "搜索名称或备注",
                text: Binding(
                    get: { model.keyword },
                    set: { model.updateKeyword($0) }
                )
            )
            .font(.system(size: Theme.fontBody))
            .submitLabel(.search)
            .onSubmit { model.confirmKeyword() }
            if !model.keyword.isEmpty {
                Button {
                    model.clearKeyword()
                } label: {
                    Text("✕")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSub)
                        .frame(width: 22, height: 22)
                        .background(Theme.bg)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.card)
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
        .padding(.bottom, 10)
    }

    /* ==================== 筛选 ==================== */

    private var filters: some View {
        VStack(spacing: 4) {
            filterRow(label: "分类", items: model.categories, selected: model.filter.category) { value in
                model.selectCategory(value)
            }
            filterRow(label: "季节", items: model.seasons, selected: model.filter.season) { value in
                model.selectSeason(value)
            }
        }
    }

    private func filterRow(
        label: String,
        items: [String],
        selected: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textLight)
                .frame(width: 38, alignment: .leading)
            ChipRow(items) { value in
                TagChip(title: value, active: value == selected) { onSelect(value) }
            }
        }
    }

    private var summary: some View {
        HStack {
            Text(model.hasFilter ? "共 \(model.list.count) 件 · 全部 \(model.total) 件" : "共 \(model.list.count) 件")
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textSub)
            Spacer()
            if model.hasFilter {
                Button("清除筛选") { model.resetFilter() }
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.primary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /* ==================== 网格 ==================== */

    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 10
        ) {
            ForEach(model.list) { item in
                ClothingCard(
                    item: item,
                    showLastWorn: model.showLastWorn,
                    onTapImage: { detailId = item.id },
                    onTapCard: { model.wearOnce(item.id) }
                )
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            text: model.emptyType == .empty ? "衣橱还是空的" : "没有匹配的衣物",
            desc: model.emptyType == .empty
                ? "点右下角的 + 添加第一件衣物，添加时可以顺手抠掉背景"
                : "换个关键词，或者清除筛选条件试试",
            actionText: model.emptyType == .empty ? "添加衣物" : "清除筛选",
            action: {
                if model.emptyType == .empty {
                    showAddClothing = true
                } else {
                    model.resetFilter()
                }
            }
        )
    }

    private var fab: some View {
        Button {
            showAddClothing = true
        } label: {
            Text("+")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Theme.primary)
                .clipShape(Circle())
                .shadow(color: Theme.primary.opacity(0.38), radius: 16, x: 0, y: 6)
        }
        .padding(.trailing, 20)
        // 悬浮底栏浮在页面之上，按钮要抬到它上方
        .padding(.bottom, floatingBarInset + 16)
    }
}
