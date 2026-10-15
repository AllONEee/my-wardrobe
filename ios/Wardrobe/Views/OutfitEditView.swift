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

    struct PickedClothing: Identifiable, Hashable {
        var id: String
        var name: String
        var image: String
    }

    private var old: Outfit?

    init(outfitId: String, date: String) {
        let target = date.isEmpty ? DateUtil.today() : date
        self.date = target
        guard !outfitId.isEmpty, let outfit = Database.shared.getOutfit(outfitId) else {
            refreshItems()
            return
        }
        self.outfitId = outfit.id
        old = outfit
        self.date = outfit.date.isEmpty ? target : outfit.date
        note = outfit.note
        seasons = outfit.seasons
        picked = outfit.clothingIds
        refreshItems()
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
        Database.shared.saveOutfit(draft)

        Haptic.success()
        ToastCenter.shared.show(isEditing ? "已保存" : "已记录")
        return true
    }
}

struct OutfitEditView: View {
    let outfitId: String
    let date: String

    @StateObject private var model: OutfitEditModel
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.floatingBarInset) private var floatingBarInset
    @Environment(\.dismiss) private var dismiss
    @State private var showDatePicker = false

    init(outfitId: String, date: String = "") {
        self.outfitId = outfitId
        self.date = date
        _model = StateObject(wrappedValue: OutfitEditModel(outfitId: outfitId, date: date))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                dateCard
                clothingCard
                noteCard
                Text("保存后可以去试衣间把这几件拖到一起，生成一张搭配封面。")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
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
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
            Button("保存穿搭") {
                if model.save() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
                }
            }
            .buttonStyle(AppButtonStyle(kind: .primary, fullWidth: true))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.card)
        // 悬浮底栏浮在页面之上，这条保存栏往上让开
        .padding(.bottom, floatingBarInset)
    }
}
