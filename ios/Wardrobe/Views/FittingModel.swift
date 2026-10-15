//
//  FittingModel.swift —— 试衣间的逻辑（对应 pages/fitting 的 fitting.js）
//
//  顶部是文件夹 tab：「搭配」（虚拟，对应全部穿搭）+ 各个灵感文件夹。
//
//  【搭配】把衣橱里的衣物拖到画布上拼一套：
//   - 每件衣物是一个图层：单指拖动、双指捏合缩放 / 旋转，摆位存进穿搭的 canvasData
//   - 保存时把画布合成一张透明背景的封面图（见 FittingComposer）
//   - 「我的搭配」按四季分类：点胶囊只看这个季节，长按可以设置季节 / 删除
//
//  【灵感】网格展示灵感图：点击看大图，长按进入多选 → 关联衣物 / 加备注 / 移动 / 删除。
//
//  入口约定：别的页面要「在试衣间继续编辑某套搭配」时，先把 id 放进 AppState.pendingFitting，
//  再切到试衣间；这里在 onShow（页面重新可见）时取走并清空。
//

import SwiftUI

final class FittingModel: ObservableObject {
    // 缩放 / 旋转的取值范围（与小程序的 MIN_SCALE / MAX_SCALE / SNAP_ANGLE 一致）
    static let minScale: CGFloat = 0.3
    static let maxScale: CGFloat = 4
    static let snapAngleValue: CGFloat = 4
    static let maxImport = 9

    /* ==================== 顶部文件夹 ==================== */

    @Published var folders: [FittingFolder] = []
    @Published var activeFolderId = Wardrobe.outfitFolderID
    @Published var activeFolderName = "搭配"
    @Published var isOutfitTab = true

    /* ==================== 画布 ==================== */

    @Published var stageSize: CGSize = .zero
    @Published var layers: [FittingLayer] = []
    @Published var selectedId = ""
    @Published var selectedName = ""
    @Published var outfitSeason = Wardrobe.all
    @Published var outfits: [SavedOutfit] = []
    @Published var outfitCountText = ""
    @Published var loadedOutfitId = ""
    @Published var saving = false

    /* ==================== 弹层 ==================== */

    @Published var seasonSheet = SeasonSheetState()
    @Published var showSelector = false
    @Published var selectorMode = FittingSelectorMode.stage
    @Published var selectorSelected: [String] = []
    @Published var selectorTitle = "添加衣物"

    /* ==================== 灵感 ==================== */

    @Published var inspirations: [InspirationRow] = []
    @Published var selectMode = false
    @Published var selectedCount = 0
    @Published var previewPaths: [String] = []

    /* ==================== 内部状态 ==================== */

    private var poses: [String: FittingPose] = [:]
    private var layerSize: CGFloat = 140
    private var imageDims: [String: CGSize] = [:]
    private var gestureState: (id: String, scale: CGFloat, rotation: CGFloat, x: CGFloat, y: CGFloat)?
    private var magnifying = false
    private var selectIds: [String] = []
    private var didLoad = false
    private var pendingFittingHandled = false

    init() {
        refreshFolders()
        refreshOutfits()

        AppState.shared.bus.on(.outfitChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshOutfits() }
        }
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.onClothingChange() }
        }
        AppState.shared.bus.on(.inspirationChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshInspirations() }
        }
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
    }

    /* ==================== 生命周期（对应 onLoad / onReady / onShow） ==================== */

    func onLoad() {
        guard !didLoad else { return }
        didLoad = true
        refreshFolders()
        refreshOutfits()
        refreshInspirations()
    }

    /// tabBar 页从别处切回来时不会重新 onLoad，刷新与新数据都在这里处理
    func onShow() {
        refreshFolders()
        refreshOutfits()
        refreshInspirations()

        if let pending = AppState.shared.pendingFitting, !pending.outfitId.isEmpty {
            AppState.shared.pendingFitting = nil
            activeFolderId = Wardrobe.outfitFolderID
            activeFolderName = "搭配"
            isOutfitTab = true
            loadOutfit(pending.outfitId)
        }
    }

    /// 画布区尺寸：宽度铺满，高度按可用高度收（顶部 tab、底部操作栏、「我的搭配」都要留位置）
    /// 合成封面与画布保持同样的宽高比，导出的图才和屏幕上看到的一致
    func setLayout(pageWidth: CGFloat, pageHeight: CGFloat) {
        guard pageWidth > 0, pageHeight > 0 else { return }
        let areaW = max(280, (pageWidth - 12).rounded())
        let areaH = max(240, min((areaW * 1.08).rounded(), (pageHeight - 125).rounded()))
        let size = CGSize(width: areaW, height: areaH)
        let box = (min(areaW, areaH) * 0.44).rounded()
        guard size != stageSize || box != layerSize else { return }
        stageSize = size
        layerSize = box
        if !layers.isEmpty { renderLayers() }
    }

    /* ==================== 顶部文件夹 tab ==================== */

    func refreshFolders() {
        folders = Database.shared.listFittingFolders()
        if let folder = folders.first(where: { $0.id == activeFolderId }) {
            activeFolderName = folder.name
        } else if let first = folders.first {
            activeFolderId = first.id
            activeFolderName = first.name
            isOutfitTab = first.id == Wardrobe.outfitFolderID
        }
    }

    func selectFolder(_ id: String) {
        guard id != activeFolderId else { return }
        exitSelect()
        activeFolderId = id
        activeFolderName = folders.first(where: { $0.id == id })?.name ?? ""
        isOutfitTab = id == Wardrobe.outfitFolderID
        if !isOutfitTab { refreshInspirations() }
    }

    func addFolder(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ToastCenter.shared.show("名字不能为空")
            return
        }
        let folder = Database.shared.addFolder(name)
        refreshFolders()
        selectFolder(folder.id)
    }

    func renameFolder(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Database.shared.renameFolder(id, name: trimmed)
        refreshFolders()
    }

    func deleteFolder(_ id: String) {
        guard id != Wardrobe.outfitFolderID else {
            ToastCenter.shared.show("「搭配」是固定分类，不能删除")
            return
        }
        guard Database.shared.deleteFolder(id) else {
            ToastCenter.shared.show("默认文件夹不能删除")
            return
        }
        let list = Database.shared.listFittingFolders()
        folders = list
        if activeFolderId == id, let fallback = list.last {
            activeFolderId = fallback.id
            activeFolderName = fallback.name
            isOutfitTab = fallback.id == Wardrobe.outfitFolderID
        }
        refreshInspirations()
    }

    /* ==================== 画布：图层 ==================== */

    /// 衣物数据变了（新增 / 编辑 / 删除）：把画布上已经不存在的衣物拿掉
    func onClothingChange() {
        guard !layers.isEmpty else { return }
        renderLayers()
    }

    /// 按 poses 里记着的衣物重建图层
    func renderLayers() {
        let ids = Array(poses.keys)
        let items = Database.shared.listClothingByIds(ids)
        var alive: [String: ClothingItem] = [:]
        items.forEach { alive[$0.id] = $0 }
        poses.keys.filter { alive[$0] == nil }.forEach { poses.removeValue(forKey: $0) }

        var list: [FittingLayer] = items.map { item in
            let image = item.coverImage.isEmpty ? item.originalImage : item.coverImage
            let size = sizeOf(image)
            var pose = poses[item.id] ?? cascadePose(poses.count)
            let maxX = max(0, stageSize.width - size.width)
            let maxY = max(0, stageSize.height - size.height)
            pose.x = min(max(0, pose.x), maxX)
            pose.y = min(max(0, pose.y), maxY)
            poses[item.id] = pose
            return FittingLayer(
                clothingId: item.id,
                name: item.name,
                image: image,
                w: size.width,
                h: size.height,
                x: pose.x,
                y: pose.y,
                scale: pose.scale,
                rotation: pose.rotation,
                z: pose.zIndex,
                selected: item.id == selectedId
            )
        }

        list.sort { $0.z < $1.z }
        // 归一化层级：DOM 顺序与 z 值保持一致，重绘 / 导出都不会错
        for (index, layer) in list.enumerated() {
            list[index].z = index + 1
            if var pose = poses[layer.clothingId] {
                pose.x = layer.x
                pose.y = layer.y
                pose.zIndex = layer.z
                poses[layer.clothingId] = pose
            }
        }
        layers = list
        if let selected = list.first(where: { $0.clothingId == selectedId }) {
            selectedName = selected.name
        } else {
            selectedId = ""
            selectedName = ""
        }
    }

    /// 图层显示尺寸：按图片比例塞进一个正方形盒子里
    private func sizeOf(_ image: String) -> CGSize {
        let box = layerSize > 0 ? layerSize : 140
        let dims = dimsOf(image)
        let width = dims.width > 0 ? dims.width : box
        let height = dims.height > 0 ? dims.height : box
        let ratio = width / height
        if ratio >= 1 {
            return CGSize(width: box, height: max(24, (box / ratio).rounded()))
        }
        return CGSize(width: max(24, (box * ratio).rounded()), height: box)
    }

    /// 图片尺寸（按文件名缓存）
    /// 抠完的图四周常常是整片透明：按「有内容的那块」量，定位框才不会比衣服大一圈。
    private func dimsOf(_ image: String) -> CGSize {
        if let cached = imageDims[image] { return cached }
        if let size = ImageStore.shared.contentImage(for: image, maxPixelSize: 400)?.size, size.width > 0 {
            imageDims[image] = size
            return size
        }
        guard !image.isEmpty,
              let url = ImageStore.shared.url(for: image),
              let loaded = ImageCache.shared.image(at: url, maxPixelSize: 400) else {
            let fallback = CGSize(width: 0, height: 0)
            imageDims[image] = fallback
            return fallback
        }
        imageDims[image] = loaded.size
        return loaded.size
    }

    /// 新加的衣物按阶梯错开摆，不会完全叠在一起
    private func cascadePose(_ index: Int) -> FittingPose {
        let step: CGFloat = 16
        return FittingPose(
            x: 14 + CGFloat(index % 5) * step,
            y: 14 + CGFloat(index % 5) * step,
            scale: 1,
            rotation: 0,
            zIndex: index + 1
        )
    }

    /* ==================== 画布：选中与手势 ==================== */

    func select(_ id: String) {
        let next = id == selectedId ? "" : id
        selectedId = next
        renderLayers()
    }

    func clearSelection() {
        guard !selectedId.isEmpty else { return }
        selectedId = ""
        renderLayers()
    }

    func beginGesture(_ id: String) {
        if gestureState?.id != id {
            guard let layer = layers.first(where: { $0.clothingId == id }) else { return }
            gestureState = (id, layer.scale, layer.rotation, layer.x, layer.y)
            magnifying = false
            if selectedId != id {
                selectedId = id
                renderLayers()
            }
        }
    }

    func drag(_ id: String, translation: CGSize) {
        guard let state = gestureState, state.id == id, !magnifying,
              let layer = layers.first(where: { $0.clothingId == id }) else { return }
        let maxX = max(0, stageSize.width - layer.w)
        let maxY = max(0, stageSize.height - layer.h)
        updatePose(id) { pose in
            pose.x = min(max(0, state.x + translation.width), maxX)
            pose.y = min(max(0, state.y + translation.height), maxY)
        }
    }

    func magnify(_ id: String, magnification: CGFloat) {
        guard let state = gestureState, state.id == id else { return }
        magnifying = true
        let scale = min(Self.maxScale, max(Self.minScale, state.scale * magnification))
        updatePose(id) { $0.scale = scale }
    }

    func rotate(_ id: String, degrees: CGFloat) {
        guard let state = gestureState, state.id == id else { return }
        magnifying = true
        let rotation = Self.snapAngle(state.rotation + degrees)
        updatePose(id) { $0.rotation = rotation }
    }

    func endGesture(_ id: String) {
        guard gestureState?.id == id else { return }
        gestureState = nil
        magnifying = false
        renderLayers()
    }

    private func updatePose(_ id: String, _ update: (inout FittingPose) -> Void) {
        guard var pose = poses[id] else { return }
        update(&pose)
        poses[id] = pose
        guard let index = layers.firstIndex(where: { $0.clothingId == id }) else { return }
        layers[index].x = pose.x
        layers[index].y = pose.y
        layers[index].scale = pose.scale
        layers[index].rotation = pose.rotation
    }

    func layerToFront() {
        reorderLayer(toFront: true)
    }

    func layerToBack() {
        reorderLayer(toFront: false)
    }

    private func reorderLayer(toFront: Bool) {
        guard !selectedId.isEmpty, var pose = poses[selectedId] else { return }
        pose.zIndex = toFront ? layers.count + 1 : -1
        poses[selectedId] = pose
        renderLayers()
    }

    /// 复位：缩放与旋转回默认，位置放到画布中间
    func layerReset() {
        guard !selectedId.isEmpty,
              let layer = layers.first(where: { $0.clothingId == selectedId }),
              var pose = poses[selectedId] else { return }
        pose.scale = 1
        pose.rotation = 0
        pose.x = ((stageSize.width - layer.w) / 2).rounded()
        pose.y = ((stageSize.height - layer.h) / 2).rounded()
        poses[selectedId] = pose
        renderLayers()
    }

    func removeLayer(_ id: String) {
        poses.removeValue(forKey: id)
        renderLayers()
        ToastCenter.shared.show("已从画布移除")
    }

    /* ==================== 画布：增删与保存 ==================== */

    func addClothing() {
        selectorMode = .stage
        selectorTitle = "添加衣物"
        selectorSelected = layers.map { $0.clothingId }
        showSelector = true
    }

    /// 弹层回传的是画布上应该有的衣物清单：没摆位的补上，被取消的拿掉
    func syncStageClothing(_ ids: [String]) {
        var keep: Set<String> = []
        ids.forEach { id in
            keep.insert(id)
            if poses[id] == nil { poses[id] = cascadePose(poses.count) }
        }
        poses.keys.filter { !keep.contains($0) }.forEach { poses.removeValue(forKey: $0) }
        renderLayers()
    }

    func clearStage() {
        poses = [:]
        layers = []
        selectedId = ""
        selectedName = ""
        loadedOutfitId = ""
        ToastCenter.shared.show("画布已清空")
    }

    func saveOutfit() {
        guard !saving else { return }
        guard !layers.isEmpty else {
            ToastCenter.shared.show("画布上还没有衣物")
            return
        }
        saving = true
        defer { saving = false }

        guard let image = FittingComposer.compose(layers: layers, stageSize: stageSize),
              let cover = ImageStore.shared.saveImage(image, prefix: "outfit-cover", keepAlpha: true) else {
            ToastCenter.shared.show("保存失败")
            return
        }

        let old = loadedOutfitId.isEmpty ? nil : Database.shared.getOutfit(loadedOutfitId)
        var draft = OutfitDraft()
        draft.id = old?.id ?? ""
        draft.clothingIds = layers.map { $0.clothingId }
        draft.canvasData = layers.map { layer in
            let pose = poses[layer.clothingId]
            return CanvasItem(
                clothingId: layer.clothingId,
                x: Double(pose?.x ?? layer.x),
                y: Double(pose?.y ?? layer.y),
                scale: Double(layer.scale),
                rotation: Double(layer.rotation),
                zIndex: layer.z
            )
        }
        draft.cover = cover
        draft.note = old?.note ?? ""
        draft.date = old?.date ?? DateUtil.today()
        draft.createTime = old?.createTime ?? 0
        // 季节和当天的照片是在别的页面维护的（日记 / 穿搭编辑），这里保存画布时要原样带过去，
        // 不然在试衣间按一次保存就把它们清空了
        draft.seasons = old?.seasons ?? []
        draft.photo = old?.photo ?? ""
        let outfit = Database.shared.saveOutfit(draft)

        // 旧封面如果只被这套搭配用着，替换后就没用了
        if let oldCover = old?.cover, !oldCover.isEmpty, oldCover != cover,
           !Database.shared.isImageInUse(oldCover) {
            ImageStore.shared.removeFile(oldCover)
        }

        loadedOutfitId = outfit.id
        Haptic.light()
        ToastCenter.shared.show(old != nil ? "已更新搭配" : "已保存搭配")
        refreshOutfits()
    }

    func duplicateOutfit() {
        guard !loadedOutfitId.isEmpty else {
            ToastCenter.shared.show("先保存或从下面选中一套搭配")
            return
        }
        guard let copy = Database.shared.duplicateOutfit(loadedOutfitId, date: DateUtil.today()) else { return }
        loadedOutfitId = copy.id
        refreshOutfits()
        ToastCenter.shared.show("已复制成一套新搭配")
    }

    /* ==================== 「我的搭配」列表 ==================== */

    func refreshOutfits() {
        let total = Database.shared.listOutfits().count
        let filtering = outfitSeason != Wardrobe.all
        let list = Database.shared.listOutfits(season: outfitSeason).map { outfit -> SavedOutfit in
            let items = Database.shared.listClothingByIds(outfit.clothingIds)
            let first = items.first.map { $0.coverImage.isEmpty ? $0.originalImage : $0.coverImage } ?? ""
            return SavedOutfit(
                id: outfit.id,
                cover: outfit.cover.isEmpty ? first : outfit.cover,
                count: items.count,
                seasonText: outfit.seasons.joined(separator: "/"),
                dateLabel: DateUtil.friendlyDate(outfit.date)
            )
        }
        outfits = list
        outfitCountText = filtering ? "\(list.count) 套 · 全部 \(total) 套" : "\(list.count) 套 · 长按可以删除"
    }

    /// 「我的搭配」的四季分类：点胶囊只看那个季节，点「全部」看全部
    func selectOutfitSeason(_ value: String) {
        guard value != outfitSeason else { return }
        outfitSeason = value
        refreshOutfits()
    }

    func loadOutfit(_ id: String) {
        guard let outfit = Database.shared.getOutfit(id) else {
            ToastCenter.shared.show("这套搭配已不存在")
            return
        }
        poses = [:]
        outfit.canvasData.forEach { item in
            poses[item.clothingId] = FittingPose(
                x: CGFloat(item.x),
                y: CGFloat(item.y),
                scale: item.scale == 0 ? 1 : CGFloat(item.scale),
                rotation: CGFloat(item.rotation),
                zIndex: item.zIndex == 0 ? 1 : item.zIndex
            )
        }
        // 只在穿搭编辑里选进来、还没在试衣间摆过的衣物，按级联补个位置
        var index = poses.count
        outfit.clothingIds.forEach { id in
            if poses[id] == nil {
                poses[id] = cascadePose(index)
                index += 1
            }
        }
        loadedOutfitId = outfit.id
        selectedId = ""
        selectedName = ""
        renderLayers()
    }

    func deleteOutfit(_ id: String) {
        guard let outfit = Database.shared.getOutfit(id) else { return }
        let cover = outfit.cover
        Database.shared.deleteOutfit(id)
        if !cover.isEmpty, !Database.shared.isImageInUse(cover) {
            ImageStore.shared.removeFile(cover)
        }
        // 正在编辑的就是这套的话，画布留着，但之后再保存会新建一套
        if loadedOutfitId == id { loadedOutfitId = "" }
        ToastCenter.shared.show("已删除")
        refreshOutfits()
    }

    /* ==================== 搭配：四季分类弹层 ==================== */

    func openSeasonSheet(_ id: String) {
        guard let outfit = Database.shared.getOutfit(id) else { return }
        seasonSheet = SeasonSheetState(show: true, outfitId: id, selected: outfit.seasons)
    }

    func toggleSeasonChip(_ value: String) {
        if let index = seasonSheet.selected.firstIndex(of: value) {
            seasonSheet.selected.remove(at: index)
        } else {
            seasonSheet.selected.append(value)
        }
    }

    func saveSeasonSheet() {
        let sheet = seasonSheet
        guard !sheet.outfitId.isEmpty else { return }
        let seasons = sheet.selected.sorted {
            (Wardrobe.seasons.firstIndex(of: $0) ?? 0) < (Wardrobe.seasons.firstIndex(of: $1) ?? 0)
        }
        Database.shared.updateOutfit(sheet.outfitId) { $0.seasons = seasons }
        seasonSheet = SeasonSheetState()
        refreshOutfits()
        ToastCenter.shared.show(seasons.isEmpty ? "已清空季节标记" : "已标记 " + seasons.joined(separator: "/"))
    }

    /* ==================== 灵感 ==================== */

    func refreshInspirations() {
        guard !isOutfitTab else { return }
        let list = Database.shared.listInspirations(folderId: activeFolderId)
        inspirations = list.map { item in
            InspirationRow(
                id: item.id,
                folderId: item.folderId,
                images: item.images,
                clothingIds: item.clothingIds,
                thumb: item.images.first ?? "",
                note: item.note.isEmpty ? item.title : item.note,
                imageCount: item.images.count,
                clothingText: item.clothingIds.isEmpty
                    ? "未关联衣物"
                    : "关联 \(item.clothingIds.count) 件衣物",
                selected: selectIds.contains(item.id)
            )
        }
        selectedCount = selectIds.count
    }

    func importImages(_ datas: [Data]) {
        guard activeFolderId != Wardrobe.outfitFolderID else { return }
        var created: [String] = []
        for data in datas {
            guard let saved = ImageStore.shared.saveData(data, prefix: "insp") else { continue }
            created.append(saved)
        }
        guard !created.isEmpty else {
            ToastCenter.shared.show("导入失败，请重试")
            return
        }
        Database.shared.addInspiration(folderId: activeFolderId, images: created)
        ToastCenter.shared.show("已导入 \(created.count) 张")
        refreshInspirations()
    }

    func tapInspiration(_ id: String) {
        guard let row = inspirations.first(where: { $0.id == id }) else { return }
        if selectMode {
            toggleSelect(id)
            return
        }
        guard !row.images.isEmpty else { return }
        previewPaths = row.images
    }

    func longPressInspiration(_ id: String) {
        Haptic.medium()
        if !selectIds.contains(id) { selectIds.append(id) }
        selectMode = true
        refreshInspirations()
    }

    func toggleSelect(_ id: String) {
        if let index = selectIds.firstIndex(of: id) {
            selectIds.remove(at: index)
        } else {
            selectIds.append(id)
        }
        if selectIds.isEmpty {
            exitSelect()
            return
        }
        refreshInspirations()
    }

    func exitSelect() {
        selectIds = []
        selectMode = false
        selectedCount = 0
        if !isOutfitTab { refreshInspirations() }
    }

    /// 多选时的目标灵感（去掉已经被删掉的）
    private func selectTargets() -> [Inspiration] {
        selectIds.compactMap { Database.shared.getInspiration($0) }
    }

    func linkClothing() {
        let targets = selectTargets()
        guard !targets.isEmpty else { return }
        var selected: [String] = []
        targets.forEach { item in
            item.clothingIds.forEach { id in
                if !selected.contains(id) { selected.append(id) }
            }
        }
        selectorMode = .inspiration
        selectorTitle = "关联衣物"
        selectorSelected = selected
        showSelector = true
    }

    func applyInspirationClothing(_ ids: [String]) {
        let targets = selectTargets()
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            Database.shared.updateInspiration(targets[0].id) { $0.clothingIds = ids }
        } else {
            // 多张一起关联：保留各自原有的关联，再并上这次选的
            targets.forEach { item in
                var merged = item.clothingIds
                ids.forEach { id in
                    if !merged.contains(id) { merged.append(id) }
                }
                Database.shared.updateInspiration(item.id) { $0.clothingIds = merged }
            }
        }
        ToastCenter.shared.show("已关联衣物")
        exitSelect()
    }

    /// 灵感备注：一次只能改一张
    func noteTarget() -> Inspiration? {
        let targets = selectTargets()
        guard targets.count == 1 else {
            if !targets.isEmpty { ToastCenter.shared.show("一次只能改一张的备注") }
            return nil
        }
        return targets[0]
    }

    func saveNote(_ value: String) {
        guard let target = noteTarget() else { return }
        Database.shared.updateInspiration(target.id) {
            $0.note = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        exitSelect()
        ToastCenter.shared.show("备注已保存")
    }

    /// 可以移动到的其它文件夹
    func moveCandidates() -> [InspirationFolder] {
        Database.shared.listFolders().filter { $0.id != activeFolderId }
    }

    func moveInspirations(to folder: InspirationFolder) {
        let targets = selectTargets()
        guard !targets.isEmpty else { return }
        targets.forEach { item in
            Database.shared.updateInspiration(item.id) { $0.folderId = folder.id }
        }
        ToastCenter.shared.show("已移动到「\(folder.name)」")
        exitSelect()
    }

    func deleteInspirations() {
        let targets = selectTargets()
        guard !targets.isEmpty else { return }
        targets.forEach { item in
            ImageStore.shared.removeFiles(item.images)
            Database.shared.deleteInspiration(item.id)
        }
        exitSelect()
        ToastCenter.shared.show("已删除")
    }

    /* ==================== 选衣弹层 ==================== */

    func handleSelectorConfirm(_ ids: [String]) {
        showSelector = false
        if selectorMode == .inspiration {
            applyInspirationClothing(ids)
        } else {
            syncStageClothing(ids)
        }
    }

    /* ==================== 小工具 ==================== */

    /// 把角度收敛到 [-180, 180)，避免连续旋转累积出很大的数值
    static func wrapAngle(_ angle: CGFloat) -> CGFloat {
        var value = angle.truncatingRemainder(dividingBy: 360)
        if value >= 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// 接近水平 / 垂直时轻微吸附，摆正不用靠手感
    static func snapAngle(_ angle: CGFloat) -> CGFloat {
        let wrapped = wrapAngle(angle)
        let target = (wrapped / 90).rounded() * 90
        if abs(wrapped - target) <= snapAngleValue { return wrapAngle(target) }
        return wrapped
    }
}
