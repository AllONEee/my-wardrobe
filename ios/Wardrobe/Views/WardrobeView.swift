//
//  WardrobeView.swift —— 衣橱（对应 pages/wardrobe）
//
//  功能：分类 / 季节筛选、按名称和备注搜索、网格（3 列 / 4 列）、排序、
//       点图片进详情、点卡片空白区 wearCount++（带撤销）、右下角 + 添加衣物。
//  多选：进「批量管理」后点卡片是勾选，底部一排批量动作（分类 / 季节 / 标签 / 处置 / 删除）。
//  筛选、排序、视图密度、是否显示已处置都存本地，下次进入自动恢复。
//

import SwiftUI

final class WardrobeModel: ObservableObject {
    @Published var filter = WardrobeFilter()
    /// 输入框的即时值（防抖后才写进 filter）
    @Published var keyword = ""
    @Published var showLastWorn = true
    @Published var showCost = true
    @Published var gridColumns = 3
    @Published var list: [ClothingItem] = []
    @Published var total = 0
    /// 已断舍离的件数（>0 时摘要行里才出现「含已处置」开关）
    @Published var releasedCount = 0

    /* 多选 */
    @Published var selecting = false
    @Published var selected: Set<String> = []

    private var searchWork: DispatchWorkItem?

    init() {
        filter = Database.shared.getWardrobeFilter()
        keyword = filter.keyword
        applySettings()
        loadList()

        // 数据层写入后会自动派发事件，这里订阅后自动刷新
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.loadList() }
        }
        AppState.shared.bus.on(.settingsChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async {
                self?.applySettings()
                self?.loadList()
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
    var sort: WardrobeSort { filter.currentSort }

    private func applySettings() {
        let settings = Database.shared.getSettings()
        showLastWorn = settings.showLastWorn
        showCost = settings.showCostPerWear
        gridColumns = settings.gridColumns
    }

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
        list = Database.shared.listClothing(filter: filter)
        let all = Database.shared.listAllClothing()
        total = all.filter { $0.isActive }.count
        releasedCount = all.count - total
        // 列表里没有的（被删 / 被筛掉）从选中集合里清掉，避免批量操作打到看不见的东西上
        if selecting {
            let alive = Set(list.map { $0.id })
            selected.formIntersection(alive)
        }
    }

    /* ==================== 筛选 / 搜索 / 排序 ==================== */

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

    func selectSort(_ value: WardrobeSort) {
        guard value != filter.currentSort else { return }
        var next = filter
        next.sort = value.rawValue
        apply(next)
    }

    /// 衣橱里连已断舍离的衣物一起显示（回看 / 恢复用）
    func toggleShowReleased() {
        var next = filter
        next.showReleased.toggle()
        apply(next)
    }

    /// 网格密度：3 列 ↔ 4 列（写进设置，衣橱页和下次启动都跟着走）
    func toggleDensity() {
        Database.shared.saveSettings { $0.gridColumns = $0.gridColumns == 3 ? 4 : 3 }
        applySettings()
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
        var next = WardrobeFilter()
        next.sort = filter.sort
        apply(next)
    }

    private func apply(_ next: WardrobeFilter) {
        // 筛选状态落本地存储
        filter = Database.shared.saveWardrobeFilter(next)
        loadList()
    }

    /* ==================== 卡片交互 ==================== */

    /// 点卡片空白区 -> 穿着次数 +1；提示条里带「撤销」，点错了能退回来
    func wearOnce(_ id: String) {
        guard let before = Database.shared.getClothing(id),
              let after = Database.shared.increaseWearCount(id, step: 1) else {
            loadList()
            return
        }
        loadList()
        Haptic.light()
        ToastCenter.shared.show("已 +1 · 共 \(after.wearCount) 次", actionTitle: "撤销") {
            Database.shared.restoreWear(id, wearCount: before.wearCount, lastWornDate: before.lastWornDate)
        }
    }

    /* ==================== 多选 ==================== */

    func beginSelecting() {
        selecting = true
        selected = []
    }

    func endSelecting() {
        selecting = false
        selected = []
    }

    func toggleSelect(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        Haptic.light()
    }

    func selectAll() {
        if selected.count == list.count {
            selected = []
        } else {
            selected = Set(list.map { $0.id })
        }
    }

    /* ==================== 批量动作 ==================== */

    /// 批量设分类
    func batchSetCategory(_ value: String) {
        let ids = Array(selected)
        let count = Database.shared.updateClothingBatch(ids) { item in
            item.category = value
        }
        endSelecting()
        ToastCenter.shared.show("\(count) 件已归到「\(value)」")
    }

    /// 批量设季节（整体替换成选中的那几个）
    func batchSetSeasons(_ values: [String]) {
        let ids = Array(selected)
        let count = Database.shared.updateClothingBatch(ids) { item in
            item.seasons = values
        }
        endSelecting()
        ToastCenter.shared.show(count > 0 ? "已更新 \(count) 件的季节" : "没有改动")
    }

    /// 批量加标签
    func batchAddTag(_ raw: String) {
        let ids = Array(selected)
        let count = Database.shared.addTagBatch(raw, ids: ids)
        endSelecting()
        ToastCenter.shared.show(count > 0 ? "已给 \(count) 件加上标签" : "这些衣物都已经有这个标签了")
    }

    /// 批量断舍离
    func batchRelease(_ method: ReleaseMethod) {
        let ids = Array(selected)
        let count = Database.shared.releaseClothingBatch(ids, method: method)
        endSelecting()
        Haptic.success()
        ToastCenter.shared.show("\(count) 件\(method.title)")
    }

    /// 批量删除
    func batchDelete() {
        let ids = Array(selected)
        let result = Database.shared.deleteClothingBatch(ids)
        endSelecting()
        Haptic.success()
        let extra = result.outfits > 0 ? "，已从 \(result.outfits) 套穿搭中移除" : ""
        ToastCenter.shared.show("已删除 \(result.clothing) 件\(extra)")
    }
}

struct WardrobeView: View {
    var isActive: Bool = true

    @StateObject private var model = WardrobeModel()
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.floatingBarInset) private var floatingBarInset
    @State private var detailId: String?
    @State private var outfitDetailId: String?
    @State private var showAddClothing = false
    @State private var showStats = false
    @State private var showDeclutter = false
    @State private var showTags = false
    @State private var showBatchImport = false
    @State private var showCategorySheet = false
    @State private var showSeasonSheet = false
    @State private var showTagInput = false
    @State private var releaseDialog = false
    @State private var confirmDelete = false
    @State private var showOutfitEdit = false

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
        .task {
            // 调试用：`-open stats / declutter / tags / batch` 启动后直接进某个子页面
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-open"), index + 1 < args.count else { return }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            switch args[index + 1] {
            case "stats": showStats = true
            case "declutter": showDeclutter = true
            case "tags": showTags = true
            case "batch": showBatchImport = true
            case "detail":
                detailId = args.count > index + 2 ? args[index + 2] : "c1"
            case "outfit":
                outfitDetailId = args.count > index + 2 ? args[index + 2] : "o1"
            case "clothingedit": showAddClothing = true
            case "outfitedit": showOutfitEdit = true
            case "select":
                model.beginSelecting()
                model.selected = Set(model.list.prefix(3).map { $0.id })
            default: break
            }
        }
        .toolbar { toolbarMenu }
        .overlay(alignment: .bottomTrailing) {
            if !model.selecting { fab }
        }
        .safeAreaInset(edge: .bottom) {
            if model.selecting { selectionBar }
        }
        .navigationDestination(item: $detailId) { id in
            ClothingDetailView(clothingId: id)
        }
        .navigationDestination(item: $outfitDetailId) { id in
            OutfitDetailView(outfitId: id)
        }
        .navigationDestination(isPresented: $showAddClothing) {
            ClothingEditView(clothingId: "")
        }
        .navigationDestination(isPresented: $showStats) { StatsView() }
        .navigationDestination(isPresented: $showDeclutter) { DeclutterView() }
        .navigationDestination(isPresented: $showTags) { TagManagerView() }
        .navigationDestination(isPresented: $showBatchImport) { BatchImportView() }
        .navigationDestination(isPresented: $showOutfitEdit) {
            OutfitEditView(outfitId: "", date: DateUtil.today())
        }
        .sheet(isPresented: $showCategorySheet) {
            BatchCategorySheet(categories: model.categories.filter { $0 != Wardrobe.all }) { value in
                showCategorySheet = false
                model.batchSetCategory(value)
            }
            .presentationDetents([.height(280)])
        }
        .sheet(isPresented: $showSeasonSheet) {
            BatchSeasonSheet { values in
                showSeasonSheet = false
                model.batchSetSeasons(values)
            }
            .presentationDetents([.height(280)])
        }
        .textInputDialog(
            isPresented: $showTagInput,
            title: "加标签",
            message: "会给选中的 \(model.selected.count) 件衣物都加上这个标签",
            placeholder: "例如：通勤"
        ) { value in
            model.batchAddTag(value)
        }
        .confirmationDialog("断舍离", isPresented: $releaseDialog, titleVisibility: .visible) {
            ForEach(ReleaseMethod.allCases) { method in
                Button(method.title) { model.batchRelease(method) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选中的 \(model.selected.count) 件会从衣橱列表里退出（数据保留，可在「断舍离」页找回）")
        }
        .alert("删除衣物", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { model.batchDelete() }
        } message: {
            Text("会删除选中的 \(model.selected.count) 件衣物（含图片），并自动从所有穿搭中移除。此操作不可恢复。")
        }
    }

    /* ==================== 顶部菜单 ==================== */

    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showStats = true
                } label: {
                    Label("统计", systemImage: "chart.bar")
                }
                Button {
                    showDeclutter = true
                } label: {
                    Label("断舍离", systemImage: "leaf")
                }
                Button {
                    showTags = true
                } label: {
                    Label("标签管理", systemImage: "tag")
                }
                Divider()
                Button {
                    showBatchImport = true
                } label: {
                    Label("批量导入", systemImage: "square.stack.3d.down.right")
                }
                Button {
                    model.beginSelecting()
                } label: {
                    Label("批量管理", systemImage: "checkmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
            }
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
        HStack(spacing: 8) {
            Text(model.hasFilter ? "共 \(model.list.count) 件 · 全部 \(model.total) 件" : "共 \(model.list.count) 件")
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textSub)
            Spacer()

            if model.releasedCount > 0 {
                Button {
                    model.toggleShowReleased()
                } label: {
                    Text(model.filter.showReleased ? "含已处置" : "只看在穿")
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(model.filter.showReleased ? Theme.primaryDark : Theme.textLight)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(model.filter.showReleased ? Theme.primarySoft : Theme.bg)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            sortMenu
            densityButton
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// 排序：菜单里 6 种排法（带一句说明），选完立刻生效并记住
    private var sortMenu: some View {
        Menu {
            ForEach(WardrobeSort.allCases) { value in
                Button {
                    model.selectSort(value)
                } label: {
                    if value == model.sort {
                        Label(value.title, systemImage: "checkmark")
                    } else {
                        Text(value.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10))
                Text(model.sort.title)
                    .font(.system(size: Theme.fontTiny))
            }
            .foregroundStyle(Theme.primaryDark)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Theme.primarySoft)
            .clipShape(Capsule())
        }
    }

    private var densityButton: some View {
        Button {
            model.toggleDensity()
        } label: {
            Image(systemName: model.gridColumns == 3 ? "square.grid.3x3" : "square.grid.2x2")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSub)
                .frame(width: 26, height: 22)
                .background(Theme.bg)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /* ==================== 网格 ==================== */

    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: model.gridColumns),
            spacing: 10
        ) {
            ForEach(model.list) { item in
                ClothingCard(
                    item: item,
                    showLastWorn: model.showLastWorn,
                    showCost: model.showCost,
                    selected: model.selecting ? model.selected.contains(item.id) : nil,
                    onTapImage: { detailId = item.id },
                    onTapCard: {
                        if model.selecting {
                            model.toggleSelect(item.id)
                        } else {
                            model.wearOnce(item.id)
                        }
                    }
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

    /* ==================== 多选操作栏 ==================== */

    private var selectionBar: some View {
        FloatingActionBar {
            Text(model.selected.isEmpty ? "选几件" : "已选 \(model.selected.count)")
                .font(.system(size: Theme.fontSmall))
                .foregroundStyle(Theme.textSub)
                .lineLimit(1)

            Button(model.selected.count == model.list.count && !model.list.isEmpty ? "取消全选" : "全选") {
                model.selectAll()
            }
            .buttonStyle(AppButtonStyle(kind: .ghost, small: true))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("分类") { showCategorySheet = true }
                        .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button("季节") { showSeasonSheet = true }
                        .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button("标签") { showTagInput = true }
                        .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button("处置") { releaseDialog = true }
                        .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button("删除") { confirmDelete = true }
                        .buttonStyle(AppButtonStyle(kind: .danger, small: true))
                }
                .padding(.vertical, 2)
            }
            .disabled(model.selected.isEmpty)
            .opacity(model.selected.isEmpty ? 0.5 : 1)

            Button("完成") { model.endSelecting() }
                .buttonStyle(AppButtonStyle(kind: .primary, small: true))
        }
    }
}

/* ==================== 批量：设分类 ==================== */

struct BatchCategorySheet: View {
    let categories: [String]
    let onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("归到哪个分类")
                .font(.system(size: Theme.fontTitle, weight: .semibold))
                .padding(.top, 18)
                .padding(.bottom, 14)

            ScrollView {
                ChipFlow(categories, spacing: 8) { value in
                    Button(value) { onPick(value) }
                        .buttonStyle(AppButtonStyle(kind: .ghost))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .background(Theme.card)
    }
}

/* ==================== 批量：设季节 ==================== */

struct BatchSeasonSheet: View {
    let onConfirm: ([String]) -> Void

    @State private var picked: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            Text("这套季节怎么设")
                .font(.system(size: Theme.fontTitle, weight: .semibold))
                .padding(.top, 18)

            Text("不选表示四季都能穿")
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textSub)
                .padding(.top, 4)
                .padding(.bottom, 14)

            ChipFlow(Wardrobe.seasons, spacing: 8) { value in
                TagChip(title: value, active: picked.contains(value)) {
                    if let index = picked.firstIndex(of: value) {
                        picked.remove(at: index)
                    } else {
                        picked.append(value)
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer()

            Button("应用") { onConfirm(picked) }
                .buttonStyle(AppButtonStyle(kind: .primary, fullWidth: true))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .background(Theme.card)
    }
}
