//
//  TagManagerView.swift —— 标签管理
//
//  标签本来是随手写在衣物上的自由文本，时间久了很容易分裂出
//  「白衬衫 / 白色衬衫 / 白衬衣」这种同一件事的好几个写法。
//  这一页把它们汇总起来，支持改名、合并（改成已有的名字就是合并）、删除。
//

import SwiftUI

final class TagManagerModel: ObservableObject {
    @Published var tags: [TagSummary] = []
    @Published var keyword = ""

    init() {
        reload()
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
    }

    func reload() {
        tags = Database.shared.listTags()
    }

    var filtered: [TagSummary] {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return tags }
        return tags.filter { $0.name.lowercased().contains(word) }
    }

    /// 改名（新名字已存在就是合并）
    func rename(_ name: String, to value: String) {
        let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        guard target != name else { return }
        let merged = tags.contains { $0.name == target }
        let count = Database.shared.renameTag(from: name, to: target)
        Haptic.success()
        ToastCenter.shared.show(
            merged
            ? "已把「\(name)」并进「\(target)」（\(count) 件）"
            : "「\(name)」已改名为「\(target)」（\(count) 件）"
        )
    }

    func remove(_ name: String) {
        let count = Database.shared.deleteTag(name)
        Haptic.success()
        ToastCenter.shared.show("已从 \(count) 件衣物上摘掉「\(name)」")
    }
}

struct TagManagerView: View {
    @StateObject private var model = TagManagerModel()
    @State private var renameTarget: String = ""
    @State private var showRename = false
    @State private var deleteTarget: String = ""
    @State private var showDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.tags.isEmpty {
                    EmptyStateView(
                        text: "还没有用过标签",
                        desc: "在衣物编辑页可以给衣服打标签（比如「通勤」「显瘦」），这里会把它们汇总起来管理。"
                    )
                } else {
                    searchBar
                    list
                    Text("改成已有的标签名就是合并；删标签只是把标签从衣物上摘掉，衣物本身不受影响。")
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textLight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                }
            }
            .padding(Theme.pagePadding)
            .padding(.bottom, 40)
        }
        .background(Theme.bg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("标签管理")
        .navigationBarTitleDisplayMode(.inline)
        .textInputDialog(
            isPresented: $showRename,
            title: "标签改名 / 合并",
            message: "输入一个已有的标签名就会合并过去",
            placeholder: "新的标签名",
            initialText: renameTarget
        ) { value in
            model.rename(renameTarget, to: value)
        }
        .alert("删除标签", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { model.remove(deleteTarget) }
        } message: {
            Text("会把「\(deleteTarget)」从所有衣物上摘掉，衣物本身不会被删除。")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textLight)
            TextField("找标签", text: $model.keyword)
                .font(.system(size: Theme.fontBody))
                .submitLabel(.search)
            if !model.keyword.isEmpty {
                Button {
                    model.keyword = ""
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

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(model.filtered) { tag in
                row(tag)
                if tag.id != model.filtered.last?.id {
                    Rectangle().fill(Theme.border).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    private func row(_ tag: TagSummary) -> some View {
        HStack(spacing: 10) {
            Text("# \(tag.name)")
                .font(.system(size: Theme.fontBody))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(tag.count) 件")
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textSub)
            Menu {
                Button("改名 / 合并") {
                    renameTarget = tag.name
                    showRename = true
                }
                Button("删除这个标签", role: .destructive) {
                    deleteTarget = tag.name
                    showDelete = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSub)
                    .frame(width: 30, height: 30)
            }
        }
        .frame(height: Theme.cellHeight)
    }
}
