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
    /// 这件衣物参与过的穿搭
    @Published var history: [HistoryRow] = []

    struct HistoryRow: Identifiable, Hashable {
        var id: String
        var cover: String
        var dateLabel: String
        var note: String
        var countText: String
    }

    private var deleting = false

    init(clothingId: String) {
        self.clothingId = clothingId
        load()
        // 编辑页保存、衣橱页加次数等都会派发这个事件
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.load() }
        }
        AppState.shared.bus.on(.outfitChange, ctx: self) { [weak self] _ in
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
            history = buildHistory()
            return
        }
        // 删除流程自己会提示并返回；这里再走一遍会多弹一个「已不存在」
        if !deleting { missing = true }
    }

    /// 历史穿搭：一次把衣物读成 map，别在循环里反复读
    private func buildHistory() -> [HistoryRow] {
        var map: [String: ClothingItem] = [:]
        Database.shared.listClothing().forEach { map[$0.id] = $0 }

        return Database.shared.listOutfits(clothingId: clothingId).map { outfit in
            let items = outfit.clothingIds.compactMap { map[$0] }
            let first = items.first.map { $0.coverImage.isEmpty ? $0.originalImage : $0.coverImage } ?? ""
            return HistoryRow(
                id: outfit.id,
                cover: outfit.cover.isEmpty ? first : outfit.cover,
                dateLabel: DateUtil.friendlyDate(outfit.date),
                note: outfit.note,
                countText: "\(items.count) 件衣物"
                    + (outfit.seasons.isEmpty ? "" : " · " + outfit.seasons.joined(separator: "/"))
            )
        }
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

    /// 单次成本 = 价格 ÷ 次数；没填价格显示「—」，还没穿过给一句人话
    var costText: String {
        guard let item, item.price > 0 else { return "—" }
        guard let cost = item.costPerWear else { return "还没穿过" }
        return Money.costPerWear(cost)
    }

    var createTimeText: String {
        guard let item else { return "" }
        return DateUtil.formatDate(Date(timeIntervalSince1970: item.createTime / 1000))
    }

    static func priceString(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    func wearOnce() {
        guard let before = item,
              let next = Database.shared.increaseWearCount(clothingId, step: 1) else { return }
        load()
        Haptic.light()
        ToastCenter.shared.show("已记录，共 \(next.wearCount) 次", actionTitle: "撤销") {
            Database.shared.restoreWear(self.clothingId, wearCount: before.wearCount, lastWornDate: before.lastWornDate)
        }
    }

    /// 点错了 / 记重了：减一次
    func wearMinus() {
        guard let next = Database.shared.increaseWearCount(clothingId, step: -1) else { return }
        load()
        Haptic.light()
        ToastCenter.shared.show("已减 1 · 共 \(next.wearCount) 次")
    }

    /// 直接改成某个次数（搬旧记录、补录历史用）
    func setWearCount(_ value: Int) {
        guard let next = Database.shared.setWearCount(clothingId, count: value) else { return }
        load()
        Haptic.success()
        ToastCenter.shared.show("穿着次数已改成 \(next.wearCount)")
    }

    /* ==================== 断舍离 ==================== */

    func release(_ method: ReleaseMethod) {
        Database.shared.releaseClothing(clothingId, method: method)
        load()
        Haptic.success()
        ToastCenter.shared.show("已\(method.title)，可在「断舍离」里找回")
    }

    func restore() {
        Database.shared.restoreClothing(clothingId)
        load()
        Haptic.light()
        ToastCenter.shared.show("已放回衣橱")
    }

    /// 分享用的卡片图
    func shareImage() -> UIImage? {
        guard let item else { return nil }
        return SharePoster.clothing(item)
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
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.dismiss) private var dismiss

    @State private var showPreview = false
    @State private var showEdit = false
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var releaseDialog = false
    @State private var showCountInput = false
    @State private var showShare = false
    @State private var historyOutfitId: String?

    init(clothingId: String) {
        self.clothingId = clothingId
        _model = StateObject(wrappedValue: ClothingDetailModel(clothingId: clothingId))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                if let item = model.item {
                    if item.isReleased { releasedBanner(item) }
                    infoCard(item)
                    statsCard(item)
                    purchaseCard(item)
                    if !item.note.isEmpty {
                        noteCard(item.note)
                    }
                    historySection
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
        .toolbar { toolbarMenu }
        .safeAreaInset(edge: .bottom) { toolbar }
        .navigationDestination(isPresented: $showEdit) {
            ClothingEditView(clothingId: clothingId)
        }
        .navigationDestination(isPresented: $showEditor) {
            ImageEditorView(source: model.recutSource) { path in
                model.applyRecut(path)
            }
        }
        .navigationDestination(item: $historyOutfitId) { id in
            OutfitDetailView(outfitId: id)
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
        .confirmationDialog("让它离开衣橱", isPresented: $releaseDialog, titleVisibility: .visible) {
            ForEach(ReleaseMethod.allCases) { method in
                Button(method.title) { model.release(method) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("衣物不会删除，历史穿搭里仍然看得到；之后可以在「断舍离」页恢复。")
        }
        .textInputDialog(
            isPresented: $showCountInput,
            title: "穿着次数",
            message: "把次数改成实际的数字（补录以前的记录时用得上）",
            placeholder: "例如：8",
            initialText: "\(model.item?.wearCount ?? 0)",
            confirmText: "保存"
        ) { value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            model.setWearCount(Int(cleaned) ?? 0)
        }
        .sheet(isPresented: $showShare) {
            if let image = model.shareImage() {
                ActivityView(items: [image])
            }
        }
        .onChange(of: model.missing) { _, missing in
            // 可能是在别处被删掉了
            if missing {
                ToastCenter.shared.show("这件衣物已不存在")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() }
            }
        }
    }

    /* ==================== 顶部菜单：分享 / 断舍离 ==================== */

    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showShare = true
                } label: {
                    Label("分享这张卡片", systemImage: "square.and.arrow.up")
                }
                Button {
                    if let image = model.shareImage() { PhotoSaver.save(image) }
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                }
                Divider()
                if model.item?.isReleased == true {
                    Button {
                        model.restore()
                    } label: {
                        Label("放回衣橱", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        releaseDialog = true
                    } label: {
                        Label("断舍离", systemImage: "leaf")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
            }
        }
    }

    /* ==================== 已处置横幅 ==================== */

    private func releasedBanner(_ item: ClothingItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.releaseMethod?.symbol ?? "archivebox")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSub)
            VStack(alignment: .leading, spacing: 2) {
                Text("已\(item.releaseMethod?.title ?? "处置")")
                    .font(.system(size: Theme.fontSmall, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(
                    item.statusDate.isEmpty
                    ? "这件衣物已经不在「在穿」列表里"
                    : "\(DateUtil.friendlyDate(item.statusDate))处置 · 不在「在穿」列表里"
                )
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textSub)
            }
            Spacer(minLength: 4)
            Button("放回衣橱") { model.restore() }
                .buttonStyle(AppButtonStyle(kind: .soft, small: true))
        }
        .padding(12)
        .cardStyle()
        .padding(.top, 12)
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
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.wearCount)")
                        .font(.system(size: 22, weight: .semibold))
                    Text("穿着次数")
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textSub)
                }
                .frame(minWidth: 62, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.lastWornText.isEmpty ? "—" : model.lastWornText)
                        .font(.system(size: Theme.fontSubtitle, weight: .medium))
                    Text("最近穿着")
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textSub)
                }
                .frame(minWidth: 62, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.costText)
                        .font(.system(size: Theme.fontSubtitle, weight: .medium))
                        .foregroundStyle(item.costPerWear == nil ? Theme.textSub : Theme.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("单次成本")
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textSub)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if item.price <= 0 {
                Text("填上价格，就能算出每次穿它花了多少钱")
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if item.wearCount == 0 {
                Text("价格 \(Money.text(item.price)) · 记录一次穿着就能看到单次成本")
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button("今天没穿 −1") { model.wearMinus() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                Button("改次数") { showCountInput = true }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                Spacer(minLength: 4)
                Button("今天穿了 +1") { model.wearOnce() }
                    .buttonStyle(AppButtonStyle(kind: .soft, small: true))
            }
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

    /* ==================== 历史穿搭 ==================== */

    /// 这件衣物参与过的穿搭：点一行进那套穿搭的详情
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("历史穿搭")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textSub)
                Text(model.history.isEmpty ? "· 还没有记录" : "· \(model.history.count) 套")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textLight)
                Spacer()
            }
            .padding(.top, 12)
            .padding(.bottom, model.history.isEmpty ? 12 : 4)

            if model.history.isEmpty {
                Text("记一套穿它的搭配，之后这里会按时间列出（去「日记 → 添加穿搭」或者试衣间保存搭配）")
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            } else {
                ForEach(model.history) { row in
                    Button {
                        historyOutfitId = row.id
                    } label: {
                        historyRow(row)
                    }
                    .buttonStyle(.plain)
                    if row.id != model.history.last?.id {
                        Rectangle().fill(Theme.border).frame(height: 0.5)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .cardStyle()
        .padding(.top, 12)
    }

    private func historyRow(_ row: ClothingDetailModel.HistoryRow) -> some View {
        HStack(spacing: 10) {
            Group {
                if row.cover.isEmpty {
                    Theme.imageWell
                        .overlay(
                            Text("无图")
                                .font(.system(size: Theme.fontTiny))
                                .foregroundStyle(Theme.textLight)
                        )
                } else {
                    StoredImage(path: row.cover, mode: .fit, maxPixel: 300)
                        .background(Theme.imageWell)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(row.dateLabel)
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.text)
                if !row.note.isEmpty {
                    Text(row.note)
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.textSub)
                        .lineLimit(1)
                }
                Text(row.countText)
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
            }

            Spacer(minLength: 4)
            Text("›")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textLight)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /* ==================== 底部操作 ==================== */

    private var toolbar: some View {
        FloatingActionBar {
            Button("删除") { confirmDelete = true }
                .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
            Button("重新抠图") { showEditor = true }
                .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
            Button("编辑") { showEdit = true }
                .buttonStyle(AppButtonStyle(kind: .primary, small: true))
                .frame(maxWidth: .infinity)
        }
    }
}
