//
//  OutfitDetailView.swift —— 穿搭详情（对应 pages/outfit-detail）
//
//  展示：封面（合成图或第一件衣物）、日期、关联衣物、备注。
//  动作：编辑（回穿搭编辑页）、在试衣间编辑（切到试衣间并把这套搭配装进画布）、删除。
//
//  与试衣间的约定：把待编辑的 outfitId 放进 AppState.pendingFitting 并切到试衣间，
//  试衣间在 onShow（切回可见）时取走并清空（见 App/AppState.swift）。
//

import SwiftUI

final class OutfitDetailModel: ObservableObject {
    let outfitId: String

    @Published var outfit: Outfit?
    @Published var items: [ClothingItem] = []
    @Published var missing = false

    private var deleting = false

    init(outfitId: String) {
        self.outfitId = outfitId
        load()
        AppState.shared.bus.on(.outfitChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.load() }
        }
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.load() }
        }
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
    }

    func load() {
        guard let outfit = Database.shared.getOutfit(outfitId) else {
            if !deleting { missing = true }
            return
        }
        self.outfit = outfit
        // 关联衣物可能被删掉（deleteClothing 会同步清理 clothingIds），这里按现存衣物展示
        items = Database.shared.listClothingByIds(outfit.clothingIds)
        missing = false
    }

    var cover: String {
        guard let outfit else { return "" }
        if !outfit.cover.isEmpty { return outfit.cover }
        guard let first = items.first else { return "" }
        return first.coverImage.isEmpty ? first.originalImage : first.coverImage
    }

    var countText: String {
        items.isEmpty ? "没有关联衣物" : "\(items.count) 件衣物"
    }

    var seasonText: String {
        (outfit?.seasons ?? []).joined(separator: " · ")
    }

    var dateLabel: String {
        DateUtil.friendlyDate(outfit?.date ?? DateUtil.today())
    }

    var createTimeText: String {
        guard let outfit else { return "" }
        return DateUtil.formatDate(Date(timeIntervalSince1970: outfit.createTime / 1000))
    }

    func delete() {
        guard let outfit else { return }
        deleting = true
        let cover = outfit.cover
        Database.shared.deleteOutfit(outfitId)
        // 自定义封面图是我们沙箱里的文件；没有别处引用时一起删掉
        if !cover.isEmpty, !Database.shared.isImageInUse(cover) {
            ImageStore.shared.removeFile(cover)
        }
    }

    /// 在试衣间继续编辑这套搭配
    func openInFitting() {
        AppState.shared.pendingFitting = PendingFitting(outfitId: outfitId)
        AppState.shared.selectedTab = .fitting
    }
}

struct OutfitDetailView: View {
    let outfitId: String

    @StateObject private var model: OutfitDetailModel
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.floatingBarInset) private var floatingBarInset
    @Environment(\.dismiss) private var dismiss

    @State private var clothingId: String?
    @State private var showEdit = false
    @State private var showPreview = false
    @State private var confirmDelete = false

    init(outfitId: String) {
        self.outfitId = outfitId
        _model = StateObject(wrappedValue: OutfitDetailModel(outfitId: outfitId))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                infoCard
                if let outfit = model.outfit, !outfit.note.isEmpty {
                    noteCard(outfit.note)
                }
                SectionTitle(text: "关联衣物")
                    .padding(.horizontal, 0)
                if model.items.isEmpty {
                    Text("这套穿搭关联的衣物都已经被删除了")
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.textLight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                        spacing: 10
                    ) {
                        ForEach(model.items) { item in
                            ClothingCard(
                                item: item,
                                showLastWorn: false,
                                onTapImage: { clothingId = item.id },
                                onTapCard: { clothingId = item.id }
                            )
                        }
                    }
                }
                Text("创建于 \(model.createTimeText)")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
            }
            .padding(Theme.pagePadding)
        }
        .background(Theme.bg)
        .navigationTitle("穿搭详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { toolbar }
        .navigationDestination(item: $clothingId) { id in
            ClothingDetailView(clothingId: id)
        }
        .navigationDestination(isPresented: $showEdit) {
            OutfitEditView(outfitId: outfitId)
        }
        .fullScreenCover(isPresented: $showPreview) {
            ImagePreviewSheet(paths: [model.cover], isPresented: $showPreview)
        }
        .alert("删除穿搭", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                model.delete()
                ToastCenter.shared.show("已删除")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
            }
        } message: {
            Text("删除后不可恢复（关联的衣物不会被删除）。")
        }
        .onChange(of: model.missing) { _, missing in
            if missing {
                ToastCenter.shared.show("这套穿搭已不存在")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() }
            }
        }
    }

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.card)
            if model.cover.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有搭配封面")
                        .font(.system(size: Theme.fontSubtitle, weight: .medium))
                    Text("去试衣间把这套里的衣物拖到一起，保存时会生成一张合成封面")
                        .font(.system(size: Theme.fontCaption))
                        .foregroundStyle(Theme.textSub)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            } else {
                StoredImage(path: model.cover, mode: .fit, maxPixel: 1400)
                    .frame(height: 240)
            }
        }
        .frame(minHeight: 260)
        .padding(12)
        .cardStyle()
        .contentShape(Rectangle())
        .onTapGesture {
            if !model.cover.isEmpty { showPreview = true }
        }
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            ValueRow(label: "日期", value: model.dateLabel)
            ValueRow(label: "关联衣物", value: model.countText)
            ValueRow(label: "季节", value: model.seasonText, placeholder: "未设置", showDivider: false)
        }
        .padding(.horizontal, 12)
        .cardStyle()
        .padding(.top, 10)
    }

    private func noteCard(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("备注")
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textSub)
            Text(note)
                .font(.system(size: Theme.fontBody))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardStyle()
        .padding(.top, 10)
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
            HStack(spacing: 8) {
                Button("删除") { confirmDelete = true }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                Button("试衣间编辑") { model.openInFitting() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                Button("编辑") { showEdit = true }
                    .buttonStyle(AppButtonStyle(kind: .primary, small: true))
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.card)
        // 悬浮底栏浮在页面之上，这条操作栏往上让开
        .padding(.bottom, floatingBarInset)
    }
}
