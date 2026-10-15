//
//  ClothingEditView.swift —— 添加 / 编辑衣物（对应 pages/clothing-edit）
//
//  流程：选图（相册 / 拍照）→ 落盘 → 自动进抠图编辑器 → 编辑器回传处理结果 → 填表 → 保存
//
//  文件清理策略（图片是占空间的大头，必须管好）：
//   - 本页产生的新文件都记在 createdFiles 里
//   - 保存成功：只保留最终引用的两张图，本次产生的其它中间文件删掉；被替换掉的旧图也删掉
//   - 用户返回 / 取消（模型释放）：createdFiles 全部删掉，不留垃圾
//

import SwiftUI

final class ClothingEditModel: ObservableObject {
    static let maxTags = 10

    let isEditing: Bool
    @Published var draft = ClothingDraft()
    @Published var tagInput = ""
    @Published var saving = false
    /// 分类列表（可自定义，见 CategoryEditorSheet）
    @Published var categories: [String] = Database.shared.listCategories()

    private var createdFiles: [String] = []
    private var saved = false

    init(clothingId: String) {
        isEditing = !clothingId.isEmpty
        if !isEditing {
            // 新增时默认选中当前列表里的第一个分类（用户在分类管理里改过第一个也照样对）
            draft.category = categories.first ?? Wardrobe.defaultCategory
        }
        AppState.shared.bus.on(.categoryChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.categories = Database.shared.listCategories()
                // 正在编辑的这件衣物用的分类被删掉了：换成列表里的第一个，别保存出一个不存在的分类
                if !self.categories.contains(self.draft.category) {
                    self.draft.category = self.categories.first ?? Wardrobe.defaultCategory
                }
            }
        }
        guard !clothingId.isEmpty, let item = Database.shared.getClothing(clothingId) else { return }
        draft = ClothingDraft(
            id: item.id,
            name: item.name,
            category: item.category,
            tags: item.tags,
            seasons: item.seasons,
            purchaseDate: item.purchaseDate,
            price: item.price == 0 ? "" : String(item.price),
            size: item.size,
            note: item.note,
            originalImage: item.originalImage,
            coverImage: item.coverImage.isEmpty ? item.originalImage : item.coverImage
        )
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
        // 没能保存成功的，把本次产生的图片文件清掉
        if !saved {
            createdFiles.forEach { ImageStore.shared.removeFile($0) }
        }
    }

    var coverImage: String { draft.coverImage }
    var hasOriginalImage: Bool { !draft.originalImage.isEmpty }
    var seasonOptions: [String] { Wardrobe.seasons }
    var sizes: [String] { Wardrobe.sizes }
    var seasonCount: Int { draft.seasons.count }
    var tagCount: Int { draft.tags.count }

    /* ==================== 图片 ==================== */

    /// 保存选中的图片（相册 / 拍照回来的数据），并返回落盘后的文件名
    @discardableResult
    func trackPickedImage(_ data: Data) -> String? {
        guard let saved = ImageStore.shared.saveData(data, prefix: "cloth-src") else {
            ToastCenter.shared.show("选图失败，请重试")
            return nil
        }
        trackFile(saved)
        // 抠图之前先用原图兜底，万一用户在编辑器里直接返回，衣物也有图
        draft.originalImage = saved
        draft.coverImage = saved
        return saved
    }

    func applyEdited(_ path: String) {
        trackFile(path)
        draft.coverImage = path
        ToastCenter.shared.show("已应用抠图")
    }

    private func trackFile(_ path: String) {
        guard !path.isEmpty, !createdFiles.contains(path) else { return }
        createdFiles.append(path)
    }

    /* ==================== 表单 ==================== */

    func toggleSeason(_ value: String) {
        var seasons = draft.seasons
        if let index = seasons.firstIndex(of: value) {
            seasons.remove(at: index)
        } else {
            seasons.append(value)
        }
        // 按固定顺序排列，保存后各处展示都稳定
        draft.seasons = seasons.sorted {
            (Wardrobe.seasons.firstIndex(of: $0) ?? 0) < (Wardrobe.seasons.firstIndex(of: $1) ?? 0)
        }
    }

    /// 尺码单选，再点一次取消（留空 = 不填）
    func toggleSize(_ value: String) {
        draft.size = draft.size == value ? "" : value
    }

    func addTag(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if draft.tags.contains(value) {
            tagInput = ""
            return
        }
        guard draft.tags.count < Self.maxTags else {
            ToastCenter.shared.show("标签最多 \(Self.maxTags) 个")
            return
        }
        draft.tags.append(value)
        tagInput = ""
    }

    func removeTag(_ value: String) {
        draft.tags.removeAll { $0 == value }
    }

    /* ==================== 保存 ==================== */

    /// - Returns: 保存成功返回 true，页面据此返回上一页
    func save() -> Bool {
        guard !saving else { return false }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ToastCenter.shared.show("给这件衣物起个名字吧")
            return false
        }

        saving = true
        let oldItem = draft.id.isEmpty ? nil : Database.shared.getClothing(draft.id)
        var payload = draft
        payload.name = name
        payload.coverImage = draft.coverImage.isEmpty ? draft.originalImage : draft.coverImage
        let result = Database.shared.saveClothing(payload)

        saved = true
        cleanupFiles(result, oldItem: oldItem)
        Haptic.success()
        ToastCenter.shared.show(isEditing ? "已保存" : "已添加")
        return true
    }

    /// 保存成功后的文件清理
    private func cleanupFiles(_ item: ClothingItem, oldItem: ClothingItem?) {
        let keep = [item.originalImage, item.coverImage]
        createdFiles.forEach { path in
            if !keep.contains(path) { ImageStore.shared.removeFile(path) }
        }
        createdFiles = []

        guard let oldItem else { return }
        if !oldItem.originalImage.isEmpty, !keep.contains(oldItem.originalImage) {
            ImageStore.shared.removeFile(oldItem.originalImage)
        }
        if !oldItem.coverImage.isEmpty, !keep.contains(oldItem.coverImage) {
            ImageStore.shared.removeFile(oldItem.coverImage)
        }
    }
}

struct ClothingEditView: View {
    let clothingId: String

    @StateObject private var model: ClothingEditModel
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var photoDialog = false
    @State private var showEditor = false
    @State private var editorSource = ""
    @State private var showPurchaseDatePicker = false
    @State private var showCategoryEditor = false

    init(clothingId: String) {
        self.clothingId = clothingId
        _model = StateObject(wrappedValue: ClothingEditModel(clothingId: clothingId))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                photoCard
                basicCard
                purchaseCard
                noteCard
            }
            .padding(Theme.pagePadding)
        }
        .background(Theme.bg)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(model.isEditing ? "编辑衣物" : "添加衣物")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { saveBar }
        .confirmationDialog("图片", isPresented: $photoDialog, titleVisibility: .hidden) {
            Button("重新选择图片") { showPicker = true }
            Button("重新抠图") { openEditor(model.draft.originalImage) }
            Button("取消", role: .cancel) {}
        }
        .imagePicker(isPresented: $showPicker) { datas in
            guard let data = datas.first, let path = model.trackPickedImage(data) else { return }
            openEditor(path)
        }
        .navigationDestination(isPresented: $showEditor) {
            ImageEditorView(source: editorSource, onDone: { path in
                model.applyEdited(path)
            })
        }
        .sheet(isPresented: $showPurchaseDatePicker) {
            DatePickerSheet(
                title: "购买日期",
                date: $model.draft.purchaseDate,
                allowClear: true,
                allowsFuture: false
            )
            .presentationDetents([.height(320)])
        }
        .sheet(isPresented: $showCategoryEditor) {
            CategoryEditorSheet()
        }
    }

    /* ==================== 图片 ==================== */

    private var photoCard: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                    .fill(Color(hex: 0xFAF8F7))
                if model.coverImage.isEmpty {
                    VStack(spacing: 6) {
                        Text("+")
                            .font(.system(size: 42, weight: .ultraLight))
                            .foregroundStyle(Theme.textLight)
                        Text("选择照片")
                            .font(.system(size: Theme.fontSmall))
                            .foregroundStyle(Theme.textLight)
                    }
                } else {
                    StoredImage(path: model.coverImage, mode: .fit, maxPixel: 1400)
                }
            }
            .frame(height: 230)
            .contentShape(Rectangle())
            .onTapGesture {
                if model.hasOriginalImage {
                    photoDialog = true
                } else {
                    showPicker = true
                }
            }

            Text(model.coverImage.isEmpty ? "选好照片后会自动进入抠图编辑器" : "点图片可重新选择或重新抠图")
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textSub)
                .padding(.top, 8)
        }
        .cardStyle(padding: 12)
    }

    private func openEditor(_ source: String) {
        guard !source.isEmpty else { return }
        editorSource = source
        showEditor = true
    }

    /* ==================== 基本信息 ==================== */

    private var basicCard: some View {
        VStack(spacing: 0) {
            FormRow(label: "名称") {
                TextField("例如：白色衬衫", text: $model.draft.name)
                    .font(.system(size: Theme.fontBody))
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("分类")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.textSub)
                    Spacer(minLength: 6)
                    Button {
                        showCategoryEditor = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11))
                            Text("管理分类")
                        }
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.primaryDark)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
                ChipFlow(model.categories, spacing: 6) { value in
                    TagChip(title: value, active: value == model.draft.category) {
                        model.draft.category = value
                    }
                }
                .padding(.bottom, 10)
            }
            .cellDivider()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("季节")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.textSub)
                    if model.seasonCount > 0 {
                        Text("· 已选 \(model.seasonCount) 个")
                            .font(.system(size: Theme.fontTiny))
                            .foregroundStyle(Theme.textLight)
                    }
                }
                .padding(.top, 12)
                ChipFlow(model.seasonOptions, spacing: 6) { value in
                    TagChip(title: value, active: model.draft.seasons.contains(value)) {
                        model.toggleSeason(value)
                    }
                }
                .padding(.bottom, 10)
            }
            .cellDivider()

            VStack(alignment: .leading, spacing: 4) {
                Text("标签")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.textSub)
                    .padding(.top, 12)

                if !model.draft.tags.isEmpty {
                    ChipFlow(model.draft.tags, spacing: 6) { value in
                        TagChip(title: "\(value) ✕", soft: true) {
                            model.removeTag(value)
                        }
                    }
                    .padding(.bottom, 6)
                }

                HStack(spacing: 8) {
                    TextField("输入标签后回车添加，如：通勤", text: $model.tagInput)
                        .font(.system(size: Theme.fontSmall))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Theme.bg)
                        .clipShape(Capsule())
                        .onSubmit { model.addTag(model.tagInput) }
                    Button("添加") { model.addTag(model.tagInput) }
                        .buttonStyle(AppButtonStyle(kind: .soft, small: true))
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 12)
        .cardStyle()
        .padding(.top, 12)
    }

    /* ==================== 购买信息 ==================== */

    private var purchaseCard: some View {
        VStack(spacing: 0) {
            TapRow(
                label: "购买日期",
                value: model.draft.purchaseDate,
                placeholder: "未填写"
            ) {
                showPurchaseDatePicker = true
            }

            FormRow(label: "价格") {
                HStack(spacing: 4) {
                    TextField("未填写", text: $model.draft.price)
                        .font(.system(size: Theme.fontBody))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                    Text("元")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.textSub)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("尺码")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.textSub)
                    if !model.draft.size.isEmpty {
                        Text("· 再点一下取消")
                            .font(.system(size: Theme.fontTiny))
                            .foregroundStyle(Theme.textLight)
                    }
                }
                .padding(.top, 12)
                ChipFlow(model.sizes, spacing: 6) { value in
                    TagChip(title: value, active: model.draft.size == value) {
                        model.toggleSize(value)
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 12)
        .cardStyle()
        .padding(.top, 12)
    }

    /* ==================== 备注 ==================== */

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("备注")
                .font(.system(size: Theme.fontBody))
                .foregroundStyle(Theme.textSub)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ZStack(alignment: .topLeading) {
                if model.draft.note.isEmpty {
                    Text("材质、版型、搭配心得…")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.textLight)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 10)
                }
                TextEditor(text: $model.draft.note)
                    .font(.system(size: Theme.fontBody))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                    .padding(.horizontal, 4)
            }
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
        .cardStyle()
        .padding(.top, 12)
    }

    /* ==================== 底部保存栏 ==================== */

    private var saveBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
            Button("保存") {
                if model.save() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
                }
            }
            .buttonStyle(AppButtonStyle(kind: .primary, fullWidth: true))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(Theme.card)
    }
}
