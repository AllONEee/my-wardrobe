//
//  ClothingDetailView.swift —— 衣物详情（对应 pages/clothing-detail）
//
//  大图 + 属性展示，以及四个动作：编辑、重新抠图、删除、手动加次数。
//  删除的连带清理（从所有穿搭的 clothingIds / canvasData、灵感的 clothingIds 中移除）
//  在 Database.deleteClothing 里统一处理，页面只负责调用和提示。
//

import SwiftUI

final class ClothingDetailModel: ObservableObject {
    let clothingId: String

    @Published var item: ClothingItem?
    @Published var missing = false

    private var deleting = false

    init(clothingId: String) {
        self.clothingId = clothingId
        load()
        // 编辑页保存、衣橱页加次数等都会派发这个事件
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.load() }
        }
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
    }

    func load() {
        if let item = Database.shared.getClothing(clothingId) {
            self.item = item
            missing = false
            return
        }
        // 删除流程自己会提示并返回；这里再走一遍会多弹一个「已不存在」
        if !deleting { missing = true }
    }

    var image: String {
        guard let item else { return "" }
        return item.coverImage.isEmpty ? item.originalImage : item.coverImage
    }

    var priceText: String {
        guard let item, item.price > 0 else { return "" }
        return "¥" + Self.priceString(item.price)
    }

    var lastWornText: String {
        guard let item, !item.lastWornDate.isEmpty else { return "" }
        return DateUtil.friendlyDate(item.lastWornDate)
    }

    var createTimeText: String {
        guard let item else { return "" }
        return DateUtil.formatDate(Date(timeIntervalSince1970: item.createTime / 1000))
    }

    static func priceString(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    func wearOnce() {
        guard let next = Database.shared.increaseWearCount(clothingId, step: 1) else { return }
        load()
        Haptic.light()
        ToastCenter.shared.show("已记录，共 \(next.wearCount) 次")
    }

    /// 重新抠图：用原图（保留原图就是为了这个），没有原图时退回当前展示图
    var recutSource: String {
        guard let item else { return "" }
        return item.originalImage.isEmpty ? item.coverImage : item.originalImage
    }

    func applyRecut(_ path: String) {
        guard let item else { return }
        let oldCover = item.coverImage
        let next = Database.shared.updateClothing(clothingId) { record in
            record.coverImage = path
        }
        // 旧封面如果没别的地方在用，顺手删掉，别让图片目录越攒越大
        if !oldCover.isEmpty, oldCover != path, oldCover != (next?.originalImage ?? "") {
            ImageStore.shared.removeFile(oldCover)
        }
        load()
        ToastCenter.shared.show("已更新抠图")
    }

    /// - Returns: 删除后用于提示的文案
    func delete() -> String {
        guard let item else { return "已删除" }
        deleting = true
        let result = Database.shared.deleteClothing(clothingId)
        ImageStore.shared.removeFile(item.originalImage)
        ImageStore.shared.removeFile(item.coverImage)
        let extra = result.affectedOutfits > 0 ? "，已从 \(result.affectedOutfits) 套穿搭中移除" : ""
        return "已删除" + extra
    }
}

struct ClothingDetailView: View {
    let clothingId: String

    @StateObject private var model: ClothingDetailModel
    @Environment(\.dismiss) private var dismiss

    @State private var showPreview = false
    @State private var showEdit = false
    @State private var showEditor = false
    @State private var confirmDelete = false

    init(clothingId: String) {
        self.clothingId = clothingId
        _model = StateObject(wrappedValue: ClothingDetailModel(clothingId: clothingId))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                if let item = model.item {
                    infoCard(item)
                    statsCard(item)
                    purchaseCard(item)
                    if !item.note.isEmpty {
                        noteCard(item.note)
                    }
                    Text("添加于 \(model.createTimeText)")
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textLight)
                        .padding(.top, 16)
                }
            }
            .padding(Theme.pagePadding)
        }
        .background(Theme.bg)
        .navigationTitle(model.item?.name ?? "衣物详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { toolbar }
        .navigationDestination(isPresented: $showEdit) {
            ClothingEditView(clothingId: clothingId)
        }
        .navigationDestination(isPresented: $showEditor) {
            ImageEditorView(source: model.recutSource) { path in
                model.applyRecut(path)
            }
        }
        .fullScreenCover(isPresented: $showPreview) {
            ImagePreviewSheet(paths: [model.image], isPresented: $showPreview)
        }
        .alert("删除衣物", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                let message = model.delete()
                ToastCenter.shared.show(message)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
            }
        } message: {
            Text("删除后不可恢复，并会自动从所有穿搭中移除这件衣物。")
        }
        .onChange(of: model.missing) { _, missing in
            // 可能是在别处被删掉了
            if missing {
                ToastCenter.shared.show("这件衣物已不存在")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() }
            }
        }
    }

    /* ==================== 大图 ==================== */

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.card)
            if model.image.isEmpty {
                Text("暂无图片")
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.textLight)
            } else {
                StoredImage(path: model.image, mode: .fit, maxPixel: 1400)
            }
        }
        .frame(height: 280)
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !model.image.isEmpty { showPreview = true }
        }
    }

    /* ==================== 名称与标签 ==================== */

    private func infoCard(_ item: ClothingItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name)
                .font(.system(size: Theme.fontTitle, weight: .semibold))

            ChipFlow([item.category] + item.seasons, spacing: 6) { value in
                TagChip(title: value, soft: value == item.category)
            }

            if !item.tags.isEmpty {
                ChipFlow(item.tags, spacing: 6) { value in
                    TagChip(title: "# \(value)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardStyle()
        .padding(.top, 12)
    }

    /* ==================== 穿着统计 ==================== */

    private func statsCard(_ item: ClothingItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.wearCount)")
                    .font(.system(size: 22, weight: .semibold))
                Text("穿着次数")
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textSub)
            }
            .frame(minWidth: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.lastWornText.isEmpty ? "—" : model.lastWornText)
                    .font(.system(size: Theme.fontSubtitle, weight: .medium))
                Text("最近穿着")
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textSub)
            }
            .frame(minWidth: 70, alignment: .leading)

            Spacer()

            Button("今天穿了 +1") { model.wearOnce() }
                .buttonStyle(AppButtonStyle(kind: .soft, small: true))
        }
        .padding(12)
        .cardStyle()
        .padding(.top, 12)
    }

    /* ==================== 购买信息 ==================== */

    private func purchaseCard(_ item: ClothingItem) -> some View {
        VStack(spacing: 0) {
            ValueRow(label: "购买日期", value: item.purchaseDate)
            HStack {
                Text("价格")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.textSub)
                Spacer()
                Text(model.priceText.isEmpty ? "未填写" : model.priceText)
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(model.priceText.isEmpty ? Theme.textLight : Theme.text)
            }
            .frame(height: Theme.cellHeight)
            .cellDivider()
            ValueRow(label: "尺码", value: item.size, showDivider: false)
        }
        .padding(.horizontal, 12)
        .cardStyle()
        .padding(.top, 12)
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
        .padding(.top, 12)
    }

    /* ==================== 底部操作 ==================== */

    private var toolbar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
            HStack(spacing: 8) {
                Button("删除") { confirmDelete = true }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                Button("重新抠图") { showEditor = true }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                Button("编辑") { showEdit = true }
                    .buttonStyle(AppButtonStyle(kind: .primary, small: true))
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.card)
    }
}
