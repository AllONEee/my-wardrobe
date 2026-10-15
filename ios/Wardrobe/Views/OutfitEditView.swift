//
//  OutfitEditView.swift —— 新增 / 编辑一套穿搭（对应 pages/outfit-edit）
//
//  入口：
//   - date 传日期：从日记页新增（不传则是今天）
//   - outfitId 传 id：从穿搭详情 / 试衣间进入编辑
//
//  选衣走 ClothingSelectorSheet 弹层（多选，弹层回传的是「勾选后的完整列表」，直接替换即可）。
//  季节是可选的（春/夏/秋/冬，可多选；都不选表示四季都能穿），用来给试衣间的「我的搭配」分类。
//  保存时：
//   - 新增：canvasData 为空，等用户去试衣间摆位置、生成封面
//   - 编辑：保留原有的 canvasData（只过滤掉本次被移除的衣物）与封面
//

import SwiftUI

final class OutfitEditModel: ObservableObject {
    @Published var outfitId = ""
    @Published var date = DateUtil.today()
    @Published var note = ""
    @Published var seasons: [String] = []
    @Published var picked: [String] = []
    @Published var items: [PickedClothing] = []
    @Published var showSelector = false
    /// 当天的穿搭照片（抠好背景的贴图，会显示在日历里）
    @Published var photo = ""
    /// 保存时是否给关联衣物 +1 次穿着
    @Published var countWear = true

    struct PickedClothing: Identifiable, Hashable {
        var id: String
        var name: String
        var image: String
    }

    private var old: Outfit?
    /// 本次新产生的图片文件；没保存成功就清掉，别留垃圾
    private var createdFiles: [String] = []
    private var saved = false

    init(outfitId: String, date: String) {
        let target = date.isEmpty ? DateUtil.today() : date
        self.date = target
        guard !outfitId.isEmpty, let outfit = Database.shared.getOutfit(outfitId) else {
            // 新建：默认计入穿着次数（记一套穿搭 = 今天穿了这几件）
            countWear = true
            refreshItems()
            return
        }
        self.outfitId = outfit.id
        old = outfit
        self.date = outfit.date.isEmpty ? target : outfit.date
        note = outfit.note
        seasons = outfit.seasons
        picked = outfit.clothingIds
        photo = outfit.photo
        countWear = outfit.wearCounted
        refreshItems()
    }

    deinit {
        if !saved {
            createdFiles.forEach { ImageStore.shared.removeFile($0) }
        }
    }

    var isEditing: Bool { !outfitId.isEmpty }
    var countText: String { items.isEmpty ? "" : "\(items.count) 件" }
    var seasonOptions: [String] { Wardrobe.seasons }
    var seasonCount: Int { seasons.count }

    /* ==================== 季节 ==================== */

    /// 季节多选（不选表示四季都能穿），顺序固定，保存后各处展示都稳定
    func toggleSeason(_ value: String) {
        if let index = seasons.firstIndex(of: value) {
            seasons.remove(at: index)
        } else {
            seasons.append(value)
        }
        seasons.sort {
            (Wardrobe.seasons.firstIndex(of: $0) ?? 0) < (Wardrobe.seasons.firstIndex(of: $1) ?? 0)
        }
    }

    /* ==================== 关联衣物 ==================== */

    func refreshItems() {
        items = Database.shared.listClothingByIds(picked).map {
            PickedClothing(
                id: $0.id,
                name: $0.name,
                image: $0.coverImage.isEmpty ? $0.originalImage : $0.coverImage
            )
        }
    }

    func applySelection(_ ids: [String]) {
        picked = ids
        refreshItems()
    }

    func remove(_ id: String) {
        picked.removeAll { $0 == id }
        refreshItems()
    }

    /* ==================== 当天的照片 ==================== */

    /// 选中的原图先落盘（编辑器要拿它当底图）
    @discardableResult
    func trackPickedPhoto(_ data: Data) -> String? {
        guard let path = ImageStore.shared.saveData(data, prefix: "outfit-photo") else {
            ToastCenter.shared.show("选图失败，请重试")
            return nil
        }
        createdFiles.append(path)
        return path
    }

    /// 抠图编辑器回传的成品
    func applyEditedPhoto(_ path: String) {
        if !path.isEmpty, !createdFiles.contains(path) { createdFiles.append(path) }
        let previous = photo
        photo = path
        // 换掉的那张如果只是本次产生的中间文件，顺手删掉
        if !previous.isEmpty, previous != path, createdFiles.contains(previous),
           !Database.shared.isImageInUse(previous) {
            ImageStore.shared.removeFile(previous)
            createdFiles.removeAll { $0 == previous }
        }
        ToastCenter.shared.show("照片已就位")
    }

    func removePhoto() {
        let previous = photo
        photo = ""
        if !previous.isEmpty, !Database.shared.isImageInUse(previous) {
            ImageStore.shared.removeFile(previous)
            createdFiles.removeAll { $0 == previous }
        }
    }

    /* ==================== 保存 ==================== */

    /// - Returns: 保存成功返回 true
    func save() -> Bool {
        guard !picked.isEmpty else {
            ToastCenter.shared.show("先选几件衣物吧")
            return false
        }

        var draft = OutfitDraft()
        draft.id = outfitId
        draft.clothingIds = picked
        // 编辑时保留画布摆位；被移除的衣物对应的摆位一并丢掉，避免留下看不见的空位
        draft.canvasData = (old?.canvasData ?? []).filter { picked.contains($0.clothingId) }
        draft.cover = old?.cover ?? ""
        draft.seasons = seasons
        draft.note = note
        draft.date = date
        draft.createTime = old?.createTime ?? 0
        draft.photo = photo
        draft.countWear = countWear
        let result = Database.shared.saveOutfit(draft)

        // 换了照片 / 关联衣物后，旧图没人用了就删掉
        let keep = [result.photo]
        createdFiles.filter { !keep.contains($0) }.forEach { path in
            if !Database.shared.isImageInUse(path) { ImageStore.shared.removeFile(path) }
        }
        createdFiles = []
        self.saved = true

        Haptic.success()
        var message = isEditing ? "已保存" : "已记录"
        if countWear, !picked.isEmpty { message += " · 已计入穿着次数" }
        ToastCenter.shared.show(message)
        return true
    }
}

struct OutfitEditView: View {
    let outfitId: String
    let date: String

    @StateObject private var model: OutfitEditModel
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.dismiss) private var dismiss
    @State private var showDatePicker = false
    @State private var showPhotoPicker = false
    @State private var showPhotoEditor = false
    @State private var photoSource = ""

    init(outfitId: String, date: String = "") {
        self.outfitId = outfitId
        self.date = date
        _model = StateObject(wrappedValue: OutfitEditModel(outfitId: outfitId, date: date))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                photoCard
                dateCard
                clothingCard
                wearCard
                noteCard
                Text("保存后可以去试衣间把这几件拖到一起，生成一张搭配封面。")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
            }
            .padding(Theme.pagePadding)
        }
        .background(Theme.bg)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(model.isEditing ? "编辑穿搭" : "记录穿搭")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { saveBar }
        .sheet(isPresented: $model.showSelector) {
            ClothingSelectorSheet(
                title: "选择衣物",
                selected: model.picked,
                onConfirm: { ids in
                    model.showSelector = false
                    model.applySelection(ids)
                },
                onClose: { model.showSelector = false }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet(title: "日期", date: $model.date, allowClear: false, allowsFuture: true)
                .presentationDetents([.height(320)])
        }
        .navigationDestination(isPresented: $showPhotoEditor) {
            ImageEditorView(source: photoSource, onDone: { path in
                model.applyEditedPhoto(path)
            })
        }
        .imagePicker(isPresented: $showPhotoPicker) { datas in
            guard let data = datas.first, let path = model.trackPickedPhoto(data) else { return }
            photoSource = path
            showPhotoEditor = true
        }
    }

    /* ==================== 当天的照片（贴到日历里的那张） ==================== */

    private var photoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("今天的照片")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textSub)
                Spacer()
                if !model.photo.isEmpty {
                    Button("重选") { showPhotoPicker = true }
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.primary)
                    Button("删掉") { model.removePhoto() }
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.textSub)
                        .padding(.leading, 10)
                }
            }
            .padding(.bottom, 8)

            Button {
                if model.photo.isEmpty {
                    showPhotoPicker = true
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                        .fill(Theme.imageWell)
                    if model.photo.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "camera")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(Theme.textLight)
                            Text("拍一张 / 选一张今天的穿搭")
                                .font(.system(size: Theme.fontSmall))
                                .foregroundStyle(Theme.textLight)
                            Text("会自动抠掉背景，作为贴图显示在日历和日记里")
                                .font(.system(size: Theme.fontTiny))
                                .foregroundStyle(Theme.textLight)
                        }
                    } else {
                        Theme.imageWell
                        StoredImage(path: model.photo, mode: .fit, maxPixel: 1200, contentOnly: true)
                    }
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .cardStyle()
    }

    /* ==================== 是否计入穿着次数 ==================== */

    private var wearCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $model.countWear) {
                Text("计入穿着次数")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.primary)

            Text(model.countWear
                 ? "保存后，这几件各 +1 次（这次被拿掉的会 −1），单次成本跟着更新"
                 : "只记录搭配，不改动这些衣物的穿着次数")
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textLight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .cardStyle()
        .padding(.top, 10)
    }

    /* ==================== 日期 / 季节 ==================== */

    private var dateCard: some View {
        VStack(spacing: 0) {
            TapRow(label: "日期", value: model.date, placeholder: "选择日期") {
                showDatePicker = true
            }

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
                    TagChip(title: value, active: model.seasons.contains(value)) {
                        model.toggleSeason(value)
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    /* ==================== 关联衣物 ==================== */

    private var clothingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("关联衣物")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textSub)
                if !model.countText.isEmpty {
                    Text("· \(model.countText)")
                        .font(.system(size: Theme.fontCaption))
                        .foregroundStyle(Theme.textLight)
                }
                Spacer()
                Button("+ 添加衣物") { model.showSelector = true }
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.primary)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            if model.items.isEmpty {
                Text("还没选衣物，点右上角「添加衣物」从衣橱里挑几件")
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.textLight)
                    .padding(.vertical, 16)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                    spacing: 10
                ) {
                    ForEach(model.items) { item in
                        VStack(spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                StoredImage(path: item.image, mode: .fit, maxPixel: 400)
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .background(Theme.imageWell)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
                                Button {
                                    model.remove(item.id)
                                } label: {
                                    Text("✕")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white)
                                        .frame(width: 20, height: 20)
                                        .background(Color(hex: 0x2E2A28).opacity(0.62))
                                        .clipShape(Circle())
                                }
                                .offset(x: 5, y: -5)
                            }
                            Text(item.name)
                                .font(.system(size: Theme.fontTiny))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 12)
        .cardStyle()
        .padding(.top, 10)
    }

    /* ==================== 备注 ==================== */

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("备注")
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textSub)
            ZStack(alignment: .topLeading) {
                if model.note.isEmpty {
                    Text("今天穿了什么？搭配的灵感从哪来？")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.textLight)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 10)
                }
                TextEditor(text: $model.note)
                    .font(.system(size: Theme.fontBody))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .padding(.horizontal, 4)
            }
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
        }
        .padding(12)
        .cardStyle()
        .padding(.top, 10)
    }

    private var saveBar: some View {
        FloatingActionBar {
            Button("保存穿搭") {
                if model.save() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
                }
            }
            .buttonStyle(AppButtonStyle(kind: .primary, fullWidth: true))
        }
    }
}
