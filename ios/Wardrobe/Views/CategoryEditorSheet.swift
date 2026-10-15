//
//  CategoryEditorSheet.swift —— 衣物分类管理（分类改成可自定义之后的编辑器）
//
//  内置的六个分类（上衣 / 裤子 / 裙子 / 鞋 / 配饰 / 套装）只是默认值：
//  在这里改名、删掉、加新的都可以，点「完成」一次性写回。
//
//  三件事在提交时会同步到已有数据（见 Database 里的同名方法）：
//   - 改名：已经用了这个分类的衣物跟着改名
//   - 删除：这个分类下的衣物挪到列表里的第一个分类，不会变成孤儿
//   - 同名合并：改名改成了已有的名字时，两个分类的衣物合到一起
//
//  编辑过程中所有改动都留在本地草稿里（取消就什么都不写），避免边打字边改数据。
//

import SwiftUI

struct CategoryEditorSheet: View {
    /// 编辑完成后回调（外部据此刷新筛选条、表单里的分类胶囊）
    var onDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// 一行 = 一个分类；original 为空表示这次新加的
    private struct Row: Identifiable {
        let id = UUID()
        var original: String
        var name: String
    }

    @State private var rows: [Row]
    @State private var newName = ""
    @FocusState private var focused: UUID?

    private let originalList: [String]

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
        let list = Database.shared.listCategories()
        originalList = list
        _rows = State(initialValue: list.map { Row(original: $0, name: $0) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    SectionTitle(text: "分类")
                    card
                    SectionTitle(text: "操作")
                    actions
                }
                .padding(Theme.pagePadding)
                .padding(.bottom, 30)
            }
            .background(Theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("分类管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.textSub)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commit() }
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.primary)
                }
            }
        }
    }

    /* ==================== 列表 ==================== */

    private var card: some View {
        VStack(spacing: 0) {
            ForEach($rows) { $row in
                HStack(spacing: 10) {
                    TextField("分类名", text: $row.name)
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.text)
                        .focused($focused, equals: row.id)
                        .submitLabel(.done)
                        .onSubmit { focused = nil }

                    Button {
                        remove(row)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(rows.count > 1 ? Theme.danger.opacity(0.85) : Theme.textLight.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(rows.count <= 1)
                }
                .frame(height: Theme.cellHeight)
                .cellDivider()
            }

            HStack(spacing: 8) {
                TextField("新增分类，如：外套", text: $newName)
                    .font(.system(size: Theme.fontBody))
                    .submitLabel(.done)
                    .onSubmit { add() }
                Button("添加") { add() }
                    .buttonStyle(AppButtonStyle(kind: .soft, small: true))
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(height: 48)
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    /* ==================== 底部操作 ==================== */

    private var actions: some View {
        VStack(spacing: 0) {
            TapRow(label: "恢复默认分类", value: "恢复", placeholder: "恢复") {
                rows = Wardrobe.categories.map { Row(original: "", name: $0) }
                ToastCenter.shared.show("点「完成」后生效")
            }
            Text("默认分类是内置的六个：\(Wardrobe.categories.joined(separator: " / "))。改名 / 删除会同步到已经用了这些分类的衣物上。")
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textLight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    /* ==================== 动作 ==================== */

    private func add() {
        let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard rows.count < Database.maxCategories else {
            ToastCenter.shared.show("最多 \(Database.maxCategories) 个分类")
            return
        }
        guard !rows.contains(where: { $0.name == value }) else {
            ToastCenter.shared.show("已经有这个分类了")
            return
        }
        rows.append(Row(original: "", name: value))
        newName = ""
        focused = nil
    }

    private func remove(_ row: Row) {
        guard rows.count > 1 else {
            ToastCenter.shared.show("至少留一个分类")
            return
        }
        rows.removeAll { $0.id == row.id }
    }

    /// 先做本地校验，再按「改名 → 删除 → 新增」的顺序写回数据层
    private func commit() {
        var cleaned: [Row] = []
        for row in rows {
            let value = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                ToastCenter.shared.show("分类名不能为空")
                return
            }
            guard value.count <= Database.maxCategoryLength else {
                ToastCenter.shared.show("分类名最多 \(Database.maxCategoryLength) 个字")
                return
            }
            // 重名的话直接丢掉后面的那个（等同合并），不弹提示打断操作
            if cleaned.contains(where: { $0.name == value }) { continue }
            cleaned.append(Row(original: row.original, name: value))
        }
        guard !cleaned.isEmpty else {
            ToastCenter.shared.show("至少留一个分类")
            return
        }

        // 1) 改名（新名字已被占用时数据层会自动合并）
        for row in cleaned where !row.original.isEmpty && row.original != row.name {
            Database.shared.renameCategory(row.original, to: row.name)
        }
        // 2) 删掉这次没留下的分类（衣物挪到第一个分类）
        let kept = Set(cleaned.map(\.original).filter { !$0.isEmpty })
        let fallback = cleaned.first?.name ?? Wardrobe.categories[0]
        for name in originalList where !kept.contains(name) {
            Database.shared.deleteCategory(name, fallback: fallback)
        }
        // 3) 新增
        for row in cleaned where row.original.isEmpty {
            Database.shared.addCategory(row.name)
        }

        onDone?()
        Haptic.success()
        dismiss()
    }
}
