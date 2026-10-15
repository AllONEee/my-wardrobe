//
//  FittingView.swift —— 试衣间（对应 pages/fitting）
//
//  页面结构：顶部文件夹 tab（搭配 + 各灵感文件夹）→ 画布 / 灵感网格 → 底部操作栏。
//  具体逻辑都在 FittingModel 里（见 FittingModel.swift），这里只负责摆位置和弹层。
//

import SwiftUI

struct FittingView: View {
    var isActive: Bool = true

    @StateObject private var model = FittingModel()
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.floatingBarInset) private var floatingBarInset

    @State private var showImportPicker = false
    @State private var showCreateFolder = false
    @State private var renameTarget: FittingFolder?
    @State private var actionFolder: FittingFolder?
    @State private var confirmClearStage = false
    @State private var confirmDeleteOutfit = false
    @State private var confirmDeleteInspirations = false
    @State private var deleteOutfitId = ""
    @State private var showNoteInput = false
    @State private var noteInput = ""
    @State private var showMoveOptions = false
    @State private var suppressNextTap = false

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        folderTabs
                        if model.isOutfitTab {
                            outfitSection
                        } else {
                            inspirationSection
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
                bottomBar
            }
            .onAppear {
                model.setLayout(pageWidth: geo.size.width, pageHeight: geo.size.height)
                model.onLoad()
                model.onShow()
            }
            .onChange(of: geo.size) { _, size in
                model.setLayout(pageWidth: size.width, pageHeight: size.height)
            }
        }
        .background(Theme.bg)
        .navigationTitle("试衣间")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isActive) { _, active in
            if active { model.onShow() }
        }
        .textInputDialog(
            isPresented: $showCreateFolder,
            title: "新建文件夹",
            placeholder: "例如：秋冬灵感",
            initialText: ""
        ) { value in
            model.addFolder(value)
        }
        .textInputDialog(
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            ),
            title: "重命名",
            initialText: renameTarget?.name ?? ""
        ) { value in
            if let target = renameTarget { model.renameFolder(target.id, name: value) }
            renameTarget = nil
        }
        .textInputDialog(
            isPresented: $showNoteInput,
            title: "灵感备注",
            placeholder: "这套想怎么穿？",
            initialText: noteInput
        ) { value in
            model.saveNote(value)
        }
        .alert("清空画布", isPresented: $confirmClearStage) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { model.clearStage() }
        } message: {
            Text("画布上的衣物会全部拿掉，已经保存过的搭配不受影响。")
        }
        .alert("删除搭配", isPresented: $confirmDeleteOutfit) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { model.deleteOutfit(deleteOutfitId) }
        } message: {
            Text("删除后不可恢复（关联的衣物不会被删除）。")
        }
        .alert("删除灵感", isPresented: $confirmDeleteInspirations) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { model.deleteInspirations() }
        } message: {
            Text("会同时删掉选中的灵感及其图片，不可恢复。")
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { !model.previewPaths.isEmpty },
                set: { if !$0 { model.previewPaths = [] } }
            )
        ) {
            ImagePreviewSheet(
                paths: model.previewPaths,
                isPresented: Binding(
                    get: { !model.previewPaths.isEmpty },
                    set: { if !$0 { model.previewPaths = [] } }
                )
            )
        }
        .sheet(isPresented: $model.showSelector) {
            ClothingSelectorSheet(
                title: model.selectorTitle,
                selected: model.selectorSelected,
                onConfirm: { ids in model.handleSelectorConfirm(ids) },
                onClose: { model.showSelector = false }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $model.seasonSheet.show) {
            seasonSheet
                .presentationDetents([.height(260)])
        }
    }

    /* ==================== 顶部文件夹 tab ==================== */

    private var folderTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.folders) { folder in
                    Text(folder.name)
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(folder.id == model.activeFolderId ? .white : Theme.textSub)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(folder.id == model.activeFolderId ? Theme.primary : Theme.card)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                        .onTapGesture { model.selectFolder(folder.id) }
                        .contextMenu {
                            if folder.isVirtual {
                                Text("「搭配」是固定分类，不能改名")
                            } else {
                                Button("重命名") {
                                    if let target = model.folders.first(where: { $0.id == folder.id }) {
                                        renameTarget = target
                                    }
                                }
                                Button("删除文件夹", role: .destructive) {
                                    if let target = model.folders.first(where: { $0.id == folder.id }) {
                                        actionFolder = target
                                    }
                                }
                            }
                        }
                }
                Button {
                    showCreateFolder = true
                } label: {
                    Text("+")
                        .font(.system(size: Theme.fontTitle))
                        .foregroundStyle(Theme.textSub)
                        .frame(width: 32, height: 32)
                        .background(Theme.card)
                        .clipShape(Circle())
                }
            }
            .padding(.vertical, 6)
        }
        // 文件夹的「重命名 / 删除」是长按文件夹胶囊弹出来的：挂在胶囊这一行上，弹层就贴着它弹
        .confirmationDialog(
            actionFolder?.name ?? "",
            isPresented: Binding(
                get: { actionFolder != nil },
                set: { if !$0 { actionFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let folder = actionFolder {
                Button("重命名") { renameTarget = folder }
                Button("删除文件夹", role: .destructive) { model.deleteFolder(folder.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除文件夹后，里面的灵感会移到默认文件夹，灵感图本身不会被删掉。")
        }
    }

    /* ==================== 搭配 ==================== */

    private var outfitSection: some View {
        VStack(spacing: 0) {
            FittingStageView(
                layers: model.layers,
                stageSize: model.stageSize,
                onTapLayer: { id in model.select(id) },
                onTapStage: { model.clearSelection() },
                onRemove: { id in model.removeLayer(id) },
                onGestureBegin: { id in model.beginGesture(id) },
                onDrag: { id, translation in model.drag(id, translation: translation) },
                onMagnify: { id, value in model.magnify(id, magnification: value) },
                onRotate: { id, value in model.rotate(id, degrees: value) },
                onGestureEnd: { id in model.endGesture(id) }
            )
            .padding(.top, 6)

            layerBar
            savedSection
        }
    }

    private var layerBar: some View {
        HStack(spacing: 8) {
            if !model.selectedId.isEmpty {
                Text(model.selectedName)
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Button("置顶") { model.layerToFront() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                Button("置底") { model.layerToBack() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                Button("复位") { model.layerReset() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
            } else {
                Text(model.layers.isEmpty
                     ? "先把衣物放到画布上"
                     : "点一下衣物可以选中它，双指捏合缩放、旋转")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textLight)
                Spacer()
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("我的搭配")
                    .font(.system(size: Theme.fontBody, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(model.outfitCountText)
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
            }
            .padding(.horizontal, 6)

            ChipRow([Wardrobe.all] + Wardrobe.seasons) { value in
                TagChip(title: value, active: value == model.outfitSeason) {
                    model.selectOutfitSeason(value)
                }
            }
            .padding(.horizontal, 6)

            if model.outfits.isEmpty {
                Text(model.outfitSeason == Wardrobe.all
                     ? "还没有保存过搭配，摆好之后点「保存搭配」"
                     : "这个季节还没有搭配，换个季节或者点「全部」看看")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textLight)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.outfits) { outfit in
                            savedThumb(outfit)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.top, 4)
    }

    private func savedThumb(_ outfit: SavedOutfit) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if outfit.cover.isEmpty {
                    Theme.imageWell
                        .overlay(
                            Text("\(outfit.count) 件")
                                .font(.system(size: Theme.fontTiny))
                                .foregroundStyle(Theme.textSub)
                        )
                } else {
                    StoredImage(path: outfit.cover, mode: .fit, maxPixel: 500)
                        .background(Theme.imageWell)
                }
            }
            .frame(width: 84, height: 84)

            if !outfit.seasonText.isEmpty {
                Text(outfit.seasonText)
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(height: 14)
                    .background(Color(hex: 0x2E2A28).opacity(0.55))
                    .clipShape(Capsule())
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                .stroke(outfit.id == model.loadedOutfitId ? Theme.primary : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.loadOutfit(outfit.id) }
        .contextMenu {
            Button("在画布中打开") { model.loadOutfit(outfit.id) }
            Button("设置季节") { model.openSeasonSheet(outfit.id) }
            Button("删除这套搭配", role: .destructive) {
                deleteOutfitId = outfit.id
                confirmDeleteOutfit = true
            }
        }
    }

    /* ==================== 灵感 ==================== */

    private var inspirationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(model.activeFolderName.isEmpty ? "灵感" : model.activeFolderName) · \(model.inspirations.count) 组")
                    .font(.system(size: Theme.fontSubtitle, weight: .semibold))
                Spacer()
                Button("+ 导入图片") { showImportPicker = true }
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.primary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)

            if model.inspirations.isEmpty {
                EmptyStateView(
                    text: "这个文件夹还是空的",
                    desc: "从相册导入几张图片当作灵感，之后可以关联衣橱里的衣物、写备注",
                    actionText: "导入图片",
                    action: { showImportPicker = true }
                )
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 10
                ) {
                    ForEach(model.inspirations) { row in
                        inspirationCell(row)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        // 导入图片的两个入口（标题右侧的「+ 导入图片」和空态里的按钮）都长在这一块上：
        // 弹层挂在这一块，系统就会贴着它弹，而不是被摆到页面最下边
        .imagePicker(isPresented: $showImportPicker, maxSelection: FittingModel.maxImport) { datas in
            model.importImages(datas)
        }
    }

    private func inspirationCell(_ row: InspirationRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if row.thumb.isEmpty {
                        Theme.imageWell
                            .overlay(
                                Text("无图")
                                    .font(.system(size: Theme.fontTiny))
                                    .foregroundStyle(Theme.textLight)
                            )
                    } else {
                        StoredImage(path: row.thumb, mode: .fill, maxPixel: 400)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                        .stroke(row.selected ? Theme.primary : Color.clear, lineWidth: 2)
                )

                if row.imageCount > 1 {
                    Text("\(row.imageCount)")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(height: 14)
                        .background(Color(hex: 0x2E2A28).opacity(0.55))
                        .clipShape(Capsule())
                        .padding(4)
                }

                if model.selectMode {
                    Text(row.selected ? "✓" : "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(row.selected ? Theme.primary : Color(hex: 0x2E2A28).opacity(0.32))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if suppressNextTap {
                    suppressNextTap = false
                    return
                }
                model.tapInspiration(row.id)
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                suppressNextTap = true
                model.longPressInspiration(row.id)
            }

            if !row.note.isEmpty {
                Text(row.note)
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Text(row.clothingText)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textLight)
                .lineLimit(1)
        }
    }

    /* ==================== 底部操作栏 ==================== */

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
            HStack(spacing: 8) {
                if model.isOutfitTab {
                    Button("添加衣物") { model.addClothing() }
                        .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button("复制") { model.duplicateOutfit() }
                        .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button("清空") { confirmClearStage = true }
                        .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button(model.saving ? "保存中…" : "保存搭配") { model.saveOutfit() }
                        .buttonStyle(AppButtonStyle(kind: .primary, small: true))
                        .frame(maxWidth: .infinity)
                        .disabled(model.saving)
                } else if model.selectMode {
                    Text("已选 \(model.selectedCount)")
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.textSub)
                    Spacer()
                    Button("关联衣物") { model.linkClothing() }
                        .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button("加备注") {
                        if let target = model.noteTarget() {
                            noteInput = target.note
                            showNoteInput = true
                        }
                    }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button("移动") { showMoveOptions = true }
                        .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                    Button("删除") { confirmDeleteInspirations = true }
                        .buttonStyle(AppButtonStyle(kind: .danger, small: true))
                    Button("取消") { model.exitSelect() }
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.textSub)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.card)
        // 悬浮底栏浮在页面之上，这一条操作栏往上让开
        .padding(.bottom, floatingBarInset)
        // 「移动到哪里」由这一栏的「移动」按钮触发：挂在操作栏上，弹层就贴着它弹
        .confirmationDialog("移动到哪里", isPresented: $showMoveOptions, titleVisibility: .visible) {
            ForEach(model.moveCandidates()) { folder in
                Button(folder.name) { model.moveInspirations(to: folder) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    /* ==================== 设置季节弹层 ==================== */

    private var seasonSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这套搭配适合哪些季节？")
                .font(.system(size: Theme.fontSubtitle, weight: .semibold))
                .padding(.top, 20)

            ChipFlow(Wardrobe.seasons, spacing: 6) { value in
                TagChip(title: value, active: model.seasonSheet.selected.contains(value)) {
                    model.toggleSeasonChip(value)
                }
            }

            Text("可以多选；都不选表示四季都能穿")
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textLight)

            HStack(spacing: 10) {
                Button("取消") { model.seasonSheet = SeasonSheetState() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, fullWidth: true))
                Button("保存") { model.saveSeasonSheet() }
                    .buttonStyle(AppButtonStyle(kind: .primary, fullWidth: true))
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
    }
}
