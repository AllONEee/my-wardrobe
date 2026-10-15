//
//  ClothingSelectorSheet.swift —— 选衣弹层（穿搭编辑 / 试衣间添加衣物 / 灵感关联衣物共用）
//  对应 components/clothing-selector。
//
//  交互约定：
//   - 弹层内部的勾选是「草稿」：点「确定」才通过 onConfirm 回传，点关闭不影响外部数据
//   - 每次打开时用传入的 selected 重建草稿
//   - 打开期间订阅衣橱数据事件，别处删了衣物这里会立刻同步
//

import SwiftUI

final class ClothingSelectorModel: ObservableObject {
    @Published var category = Wardrobe.all
    @Published var keyword = ""
    @Published var list: [ClothingItem] = []
    @Published var picked: [String] = []
    @Published var total = 0
    /// 分类筛选条（跟着「分类管理」里的自定义分类走）
    @Published var categories: [String] = [Wardrobe.all] + Database.shared.listCategories()

    private var searchWork: DispatchWorkItem?

    init() {
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
        AppState.shared.bus.on(.categoryChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.categories = [Wardrobe.all] + Database.shared.listCategories()
                if self.category != Wardrobe.all, !self.categories.contains(self.category) {
                    self.category = Wardrobe.all
                }
                self.reload()
            }
        }
    }

    deinit {
        searchWork?.cancel()
        AppState.shared.bus.offBy(ctx: self)
    }

    func open(selected: [String]) {
        picked = selected
        category = Wardrobe.all
        keyword = ""
        reload()
    }

    func reload() {
        list = Database.shared.listClothing(category: category, keyword: keyword)
        total = Database.shared.listClothing().count
    }

    /// 输入防抖，避免每敲一个字都全量过滤一遍
    func updateKeyword(_ value: String) {
        keyword = value
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    func selectCategory(_ value: String) {
        guard value != category else { return }
        category = value
        reload()
    }

    /// 返回 false 表示到了上限，调用方给个提示
    func toggle(_ id: String, limit: Int) -> Bool {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
            Haptic.light()
            return true
        }
        if limit > 0, picked.count >= limit {
            return false
        }
        picked.append(id)
        Haptic.light()
        return true
    }

    func clearPicked() {
        picked = []
    }

    func isPicked(_ id: String) -> Bool {
        picked.contains(id)
    }
}

struct ClothingSelectorSheet: View {
    var title: String = "选择衣物"
    var confirmText: String = "确定"
    /// 最多可选数量，0 表示不限
    var max: Int = 0
    /// 打开时预选中的衣物 id
    let selected: [String]
    let onConfirm: ([String]) -> Void
    let onClose: () -> Void

    @StateObject private var model = ClothingSelectorModel()

    init(
        title: String = "选择衣物",
        confirmText: String = "确定",
        max: Int = 0,
        selected: [String],
        onConfirm: @escaping ([String]) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.confirmText = confirmText
        self.max = max
        self.selected = selected
        self.onConfirm = onConfirm
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            head
            filter
            list
            foot
        }
        .background(Theme.card)
        .appToast()
        .onAppear { model.open(selected: selected) }
    }

    private var head: some View {
        HStack {
            Text(title)
                .font(.system(size: Theme.fontTitle, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                onClose()
            } label: {
                Text("✕")
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.textSub)
                    .frame(width: 28, height: 28)
                    .background(Theme.bg)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var filter: some View {
        VStack(spacing: 6) {
            ChipRow(model.categories) { value in
                TagChip(title: value, active: value == model.category) {
                    model.selectCategory(value)
                }
            }
            HStack(spacing: 6) {
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
                .font(.system(size: Theme.fontSmall))
                .submitLabel(.search)
                if !model.keyword.isEmpty {
                    Button {
                        model.updateKeyword("")
                    } label: {
                        Text("✕")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSub)
                            .frame(width: 18, height: 18)
                            .background(Theme.card)
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Theme.bg)
            .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollView {
            if model.list.isEmpty {
                Text(model.total > 0 ? "没有匹配的衣物" : "衣橱里还没有衣物")
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.textLight)
                    .padding(.top, 60)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(model.list) { item in
                        pickCell(item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func pickCell(_ item: ClothingItem) -> some View {
        let picked = model.isPicked(item.id)
        return ZStack(alignment: .topTrailing) {
            ClothingCard(
                item: item,
                showLastWorn: false,
                showWearCount: false,
                onTapImage: { tap(item) },
                onTapCard: { tap(item) }
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(picked ? Theme.primary : Color.clear, lineWidth: 2)
            )
            Text(picked ? "✓" : "")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(picked ? Theme.primary : Color(hex: 0x2E2A28).opacity(0.28))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                .padding(5)
        }
    }

    private var foot: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    Text("已选")
                    Text("\(model.picked.count)")
                        .font(.system(size: Theme.fontSubtitle, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text("件")
                }
                .font(.system(size: Theme.fontSmall))
                .foregroundStyle(Theme.textSub)
                Spacer()
                Button("清空") { model.clearPicked() }
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.textSub)
                    .opacity(model.picked.isEmpty ? 0.35 : 1)
                    .disabled(model.picked.isEmpty)
                Button(confirmText) { confirm() }
                    .buttonStyle(AppButtonStyle(kind: .primary, small: true))
                    .frame(minWidth: 90)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.card)
    }

    private func tap(_ item: ClothingItem) {
        if !model.toggle(item.id, limit: max) {
            ToastCenter.shared.show("最多选 \(max) 件")
        }
    }

    private func confirm() {
        guard !model.picked.isEmpty else {
            ToastCenter.shared.show("还没有选中衣物")
            return
        }
        // 按勾选顺序回传，找不到的（刚被删掉）直接跳过
        let ids = model.picked.filter { Database.shared.getClothing($0) != nil }
        onConfirm(ids)
    }
}
