//
//  Database.swift —— 数据层（衣物 / 穿搭 / 灵感 / 文件夹 / 设置 / 天气记录）
//  对应小程序的 utils/db.js，函数名与行为一一对应。
//
//  设计：
//   - 数据以 JSON 形式存在本地（见 Data/Storage.swift），图片只存文件名（见 Utils/ImageStore.swift）
//   - id 全局唯一：前缀区分类型（c=衣物 o=穿搭 i=灵感 f=文件夹），并维护 id -> type 索引，便于统一按 id 反查
//   - 任何写操作都会 emit 对应事件（App/AppState.swift），页面订阅后自动刷新
//   - 所有写操作都是「读全量 -> 改 -> 整体写回」，数据量级（几百件衣物）下完全够用
//

import Foundation

/// 按 id 反查任意实体的结果（对应 db.js 的 { type, item }）
enum EntityRef {
    case clothing(ClothingItem)
    case outfit(Outfit)
    case inspiration(Inspiration)
    case folder(InspirationFolder)

    var kind: EntityKind {
        switch self {
        case .clothing: return .clothing
        case .outfit: return .outfit
        case .inspiration: return .inspiration
        case .folder: return .folder
        }
    }
}

/// 衣物表单（对应 clothing-edit 页里的 form）
struct ClothingDraft {
    var id: String = ""
    var name: String = ""
    var category: String = Wardrobe.categories[0]
    var tags: [String] = []
    var seasons: [String] = []
    var purchaseDate: String = ""
    var price: String = ""
    var size: String = ""
    var note: String = ""
    var originalImage: String = ""
    var coverImage: String = ""
    /// 断舍离：空 = 还在穿
    var status: String = ""
    var statusDate: String = ""
    var soldPrice: String = ""
}

/// 穿搭表单（对应 outfit-edit 页）
struct OutfitDraft {
    var id: String = ""
    var clothingIds: [String] = []
    var canvasData: [CanvasItem] = []
    var cover: String = ""
    var seasons: [String] = []
    var note: String = ""
    var date: String = DateUtil.today()
    /// 0 表示新建
    var createTime: Double = 0
    /// 当天的穿搭照片（抠好的贴图）
    var photo: String = ""
    /// 保存时是否把这几件计入穿着次数：
    /// nil = 沿用原来的状态（新建时为 false），true = 计入，false = 不计入（原来计入过的会回滚）
    var countWear: Bool?
}

final class Database {
    static let shared = Database()

    // 固定分类 / 季节 / 尺码 / 「全部」（对应 db.js 顶部的常量）
    static let categories = Wardrobe.categories
    static let seasons = Wardrobe.seasons
    static let sizes = Wardrobe.sizes
    static let all = Wardrobe.all
    static let defaultFolderID = Wardrobe.defaultFolderID
    static let outfitFolderID = Wardrobe.outfitFolderID

    private let storage = Storage.shared
    private let store = AppState.shared

    private init() {}

    /* ==================== 通用工具 ==================== */

    private func readClothingList() -> [ClothingItem] {
        storage.value(.clothing, as: [ClothingItem].self, default: [])
    }

    private func writeClothingList(_ list: [ClothingItem]) {
        storage.set(.clothing, list)
    }

    private func readOutfitList() -> [Outfit] {
        storage.value(.outfit, as: [Outfit].self, default: [])
    }

    private func writeOutfitList(_ list: [Outfit]) {
        storage.set(.outfit, list)
    }

    private func readInspirationList() -> [Inspiration] {
        storage.value(.inspiration, as: [Inspiration].self, default: [])
    }

    private func writeInspirationList(_ list: [Inspiration]) {
        storage.set(.inspiration, list)
    }

    private func readFolderList() -> [InspirationFolder] {
        storage.value(.folder, as: [InspirationFolder].self, default: [])
    }

    private func writeFolderList(_ list: [InspirationFolder]) {
        storage.set(.folder, list)
    }

    private func nextID(_ kind: EntityKind) -> String {
        let seq = storage.value(.idSeq, as: Int.self, default: 0) + 1
        storage.set(.idSeq, seq)
        return kind.prefix + String(seq, radix: 36)
    }

    private func readIndex() -> [String: String] {
        storage.value(.idIndex, as: [String: String].self, default: [:])
    }

    private func indexAdd(_ id: String, _ kind: EntityKind) {
        var index = readIndex()
        index[id] = kind.rawValue
        storage.set(.idIndex, index)
    }

    private func indexRemove(_ id: String) {
        var index = readIndex()
        guard index[id] != nil else { return }
        index.removeValue(forKey: id)
        storage.set(.idIndex, index)
    }

    private func emitChange(_ event: AppEvent, action: String, id: String = "", reason: String = "") {
        store.bus.emit(event, AppEventPayload(action: action, id: id, reason: reason))
    }

    /// 统一按 id 反查任意实体；索引缺失时按 id 前缀兜底
    func getById(_ id: String) -> EntityRef? {
        guard !id.isEmpty else { return nil }
        let kind: EntityKind?
        if let raw = readIndex()[id], let indexed = EntityKind(rawValue: raw) {
            kind = indexed
        } else if let first = id.first {
            kind = EntityKind(prefix: first)
        } else {
            kind = nil
        }
        guard let kind else { return nil }
        switch kind {
        case .clothing:
            return getClothing(id).map { .clothing($0) }
        case .outfit:
            return getOutfit(id).map { .outfit($0) }
        case .inspiration:
            return getInspiration(id).map { .inspiration($0) }
        case .folder:
            return getFolder(id).map { .folder($0) }
        }
    }

    /* ==================== 衣物 ==================== */

    /// 列表查询：`category` / `season` 传「全部」或空表示不过滤，`keyword` 按名称和备注搜索。
    /// 默认只返回还在穿的衣物；`includeReleased` 打开后连已断舍离的也一起返回（统计 / 断舍离页用）。
    func listClothing(
        category: String = Wardrobe.all,
        season: String = Wardrobe.all,
        keyword: String = "",
        includeReleased: Bool = false,
        sort: WardrobeSort = .latest
    ) -> [ClothingItem] {
        var list = readClothingList()
        if !includeReleased {
            list = list.filter { $0.isActive }
        }
        if !category.isEmpty, category != Wardrobe.all {
            list = list.filter { $0.category == category }
        }
        if !season.isEmpty, season != Wardrobe.all {
            list = list.filter { $0.seasons.contains(season) }
        }
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !word.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(word) || $0.note.lowercased().contains(word)
            }
        }
        return Self.sortClothing(list, by: sort)
    }

    func listClothing(filter: WardrobeFilter) -> [ClothingItem] {
        listClothing(
            category: filter.category,
            season: filter.season,
            keyword: filter.keyword,
            includeReleased: filter.showReleased,
            sort: filter.currentSort
        )
    }

    /// 全部衣物（连已断舍离的一起，统计页 / 断舍离页用）
    func listAllClothing() -> [ClothingItem] {
        readClothingList()
    }

    /// 排序规则集中放这里，衣橱页和统计页共用同一套（「没有值」的一律排最后，不参与比大小）
    static func sortClothing(_ list: [ClothingItem], by sort: WardrobeSort) -> [ClothingItem] {
        switch sort {
        case .latest:
            return list.sorted { $0.createTime > $1.createTime }
        case .lastWorn:
            return list.sorted { a, b in
                if a.lastWornDate.isEmpty != b.lastWornDate.isEmpty { return !a.lastWornDate.isEmpty }
                if a.lastWornDate != b.lastWornDate { return a.lastWornDate > b.lastWornDate }
                return a.createTime > b.createTime
            }
        case .mostWorn:
            return list.sorted { a, b in
                if a.wearCount != b.wearCount { return a.wearCount > b.wearCount }
                return a.createTime > b.createTime
            }
        case .costHigh:
            return list.sorted { a, b in
                switch (a.costPerWear, b.costPerWear) {
                case let (left?, right?):
                    if left != right { return left > right }
                    return a.createTime > b.createTime
                case (nil, nil):
                    return a.createTime > b.createTime
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                }
            }
        case .priceHigh:
            return list.sorted { a, b in
                if a.price != b.price { return a.price > b.price }
                return a.createTime > b.createTime
            }
        case .purchaseNew:
            return list.sorted { a, b in
                if a.purchaseDate.isEmpty != b.purchaseDate.isEmpty { return !a.purchaseDate.isEmpty }
                if a.purchaseDate != b.purchaseDate { return a.purchaseDate > b.purchaseDate }
                return a.createTime > b.createTime
            }
        }
    }

    func getClothing(_ id: String) -> ClothingItem? {
        readClothingList().first { $0.id == id }
    }

    /// 按 id 数组取衣物（保持传入顺序，自动跳过已删除的）
    func listClothingByIds(_ ids: [String]) -> [ClothingItem] {
        let map = Dictionary(uniqueKeysWithValues: readClothingList().map { ($0.id, $0) })
        return ids.compactMap { map[$0] }
    }

    @discardableResult
    func addClothing(_ draft: ClothingDraft) -> ClothingItem {
        let item = normalize(draft, id: nextID(.clothing), createTime: Date().milliseconds)
        var list = readClothingList()
        list.append(item)
        writeClothingList(list)
        indexAdd(item.id, .clothing)
        emitChange(.clothingChange, action: "add", id: item.id)
        return item
    }

    /// 批量导入衣物（相册多选一次进来好几件）：一次写盘 + 一次事件
    @discardableResult
    func addClothingBatch(_ drafts: [ClothingDraft]) -> [ClothingItem] {
        guard !drafts.isEmpty else { return [] }
        var list = readClothingList()
        var index = readIndex()
        var created: [ClothingItem] = []
        for draft in drafts {
            let item = normalize(draft, id: nextID(.clothing), createTime: Date().milliseconds)
            list.append(item)
            index[item.id] = EntityKind.clothing.rawValue
            created.append(item)
        }
        writeClothingList(list)
        storage.set(.idIndex, index)
        emitChange(.clothingChange, action: "add", reason: "batch")
        return created
    }

    @discardableResult
    func updateClothing(_ id: String, patch: (inout ClothingItem) -> Void) -> ClothingItem? {
        var list = readClothingList()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        var item = list[index]
        patch(&item)
        item.id = id
        item = normalize(item)
        list[index] = item
        writeClothingList(list)
        emitChange(.clothingChange, action: "update", id: id)
        return item
    }

    /// 新增或更新统一入口：带 id 且已存在则更新，否则新增（对应 db.saveClothing）
    @discardableResult
    func saveClothing(_ draft: ClothingDraft) -> ClothingItem {
        if !draft.id.isEmpty, let old = getClothing(draft.id) {
            // 编辑时保留原有统计
            guard let saved = updateClothing(draft.id, patch: { item in
                var next = self.normalize(draft, id: draft.id, createTime: old.createTime)
                next.wearCount = old.wearCount
                next.lastWornDate = old.lastWornDate
                item = next
            }) else { return old }
            return saved
        }
        return addClothing(draft)
    }

    /// 删除衣物，并同步清理所有穿搭的 clothingIds / canvasData 与灵感的 clothingIds
    @discardableResult
    func deleteClothing(_ id: String) -> (affectedOutfits: Int, affectedInspirations: Int) {
        writeClothingList(readClothingList().filter { $0.id != id })
        indexRemove(id)

        var affectedOutfits = 0
        let outfits = readOutfitList().map { outfit -> Outfit in
            guard outfit.clothingIds.contains(id) else { return outfit }
            affectedOutfits += 1
            var next = outfit
            next.clothingIds = outfit.clothingIds.filter { $0 != id }
            next.canvasData = outfit.canvasData.filter { $0.clothingId != id }
            return next
        }
        if affectedOutfits > 0 {
            writeOutfitList(outfits)
            emitChange(.outfitChange, action: "update", id: id, reason: "clothing-deleted")
        }

        var affectedInspirations = 0
        let inspirations = readInspirationList().map { item -> Inspiration in
            guard item.clothingIds.contains(id) else { return item }
            affectedInspirations += 1
            var next = item
            next.clothingIds = item.clothingIds.filter { $0 != id }
            return next
        }
        if affectedInspirations > 0 {
            writeInspirationList(inspirations)
            emitChange(.inspirationChange, action: "update", id: id, reason: "clothing-deleted")
        }

        emitChange(.clothingChange, action: "delete", id: id)
        return (affectedOutfits, affectedInspirations)
    }

    /// 加/减穿着次数，加次数时顺带更新最近穿着日期
    @discardableResult
    func increaseWearCount(_ id: String, step: Int = 1) -> ClothingItem? {
        guard let item = getClothing(id) else { return nil }
        let count = max(0, item.wearCount + step)
        var lastWorn = step > 0 ? max(item.lastWornDate, DateUtil.today()) : item.lastWornDate
        // 减到 0 次时「最近穿着」已经没有意义了，清掉，免得卡片上还挂着个旧日期
        if count == 0 { lastWorn = "" }
        return updateClothing(id) { next in
            next.wearCount = count
            next.lastWornDate = lastWorn
        }
    }

    /// 直接把次数改成想要的值（衣物详情页的「改次数」/ 撤销用），一次写盘
    @discardableResult
    func setWearCount(_ id: String, count: Int, lastWornDate: String? = nil) -> ClothingItem? {
        guard let item = getClothing(id) else { return nil }
        let value = max(0, count)
        let lastWorn = lastWornDate ?? (value == 0 ? "" : item.lastWornDate)
        return updateClothing(id) { next in
            next.wearCount = value
            next.lastWornDate = lastWorn
        }
    }

    /// 撤销 / 恢复用：把一件衣物整体还原成之前的样子（次数 + 最近穿着日期）
    @discardableResult
    func restoreWear(_ id: String, wearCount: Int, lastWornDate: String) -> ClothingItem? {
        setWearCount(id, count: wearCount, lastWornDate: max(0, wearCount) == 0 ? "" : lastWornDate)
    }

    /* ==================== 断舍离（处置 / 恢复） ==================== */

    /// 处置一件衣物：记下方式和日期，卖掉时还能记一笔回血金额。
    /// 衣物本身不删除（历史穿搭里还要看得到），只是从「在用」列表里退出去。
    @discardableResult
    func releaseClothing(
        _ id: String,
        method: ReleaseMethod,
        date: String = DateUtil.today(),
        soldPrice: Double = 0
    ) -> ClothingItem? {
        updateClothing(id) { item in
            item.status = method.rawValue
            item.statusDate = date
            item.soldPrice = method.needsPrice ? max(0, soldPrice) : 0
        }
    }

    /// 重新回到衣橱（断舍离点错了 / 又留下了）
    @discardableResult
    func restoreClothing(_ id: String) -> ClothingItem? {
        updateClothing(id) { item in
            item.status = ""
            item.statusDate = ""
            item.soldPrice = 0
        }
    }

    /// 批量处置（衣橱多选里用），一次写盘
    @discardableResult
    func releaseClothingBatch(
        _ ids: [String],
        method: ReleaseMethod,
        date: String = DateUtil.today()
    ) -> Int {
        guard !ids.isEmpty else { return 0 }
        let target = Set(ids)
        var list = readClothingList()
        var changed = 0
        for index in list.indices where target.contains(list[index].id) {
            list[index].status = method.rawValue
            list[index].statusDate = date
            list[index].soldPrice = 0
            changed += 1
        }
        guard changed > 0 else { return 0 }
        writeClothingList(list)
        emitChange(.clothingChange, action: "release", reason: "batch")
        return changed
    }

    /// 批量恢复到衣橱
    @discardableResult
    func restoreClothingBatch(_ ids: [String]) -> Int {
        guard !ids.isEmpty else { return 0 }
        let target = Set(ids)
        var list = readClothingList()
        var changed = 0
        for index in list.indices where target.contains(list[index].id) {
            list[index].status = ""
            list[index].statusDate = ""
            list[index].soldPrice = 0
            changed += 1
        }
        guard changed > 0 else { return 0 }
        writeClothingList(list)
        emitChange(.clothingChange, action: "restore", reason: "batch")
        return changed
    }

    /* ==================== 批量操作（衣橱多选） ====================
     多选改动都是「一批 id 一次写盘」，不要在调用方循环单件接口 ——
     每次单件写入都会把整个列表重新编码落盘，几百件时会明显卡。
     */

    /// 批量改（分类 / 季节 / 标签都用它），只写一次
    @discardableResult
    func updateClothingBatch(_ ids: [String], patch: (inout ClothingItem) -> Void) -> Int {
        guard !ids.isEmpty else { return 0 }
        let target = Set(ids)
        var list = readClothingList()
        var changed = 0
        for index in list.indices where target.contains(list[index].id) {
            patch(&list[index])
            list[index].id = list[index].id
            list[index].wearCount = max(0, list[index].wearCount)
            // 季节统一按固定顺序排，各处展示稳定
            list[index].seasons = list[index].seasons
                .filter { Wardrobe.seasons.contains($0) }
                .sorted { (Wardrobe.seasons.firstIndex(of: $0) ?? 0) < (Wardrobe.seasons.firstIndex(of: $1) ?? 0) }
            changed += 1
        }
        guard changed > 0 else { return 0 }
        writeClothingList(list)
        emitChange(.clothingChange, action: "batch", reason: "update")
        return changed
    }

    /// 批量删除：衣物列表 / 穿搭的关联 / 灵感的关联 / id 索引只写一次，图片最后统一回收
    @discardableResult
    func deleteClothingBatch(_ ids: [String]) -> (clothing: Int, outfits: Int, inspirations: Int) {
        guard !ids.isEmpty else { return (0, 0, 0) }
        let target = Set(ids)

        let all = readClothingList()
        let removed = all.filter { target.contains($0.id) }
        let images = removed.flatMap { [$0.coverImage, $0.originalImage] }.filter { !$0.isEmpty }
        writeClothingList(all.filter { !target.contains($0.id) })

        var index = readIndex()
        ids.forEach { index.removeValue(forKey: $0) }
        storage.set(.idIndex, index)

        var affectedOutfits = 0
        let outfits = readOutfitList().map { outfit -> Outfit in
            guard outfit.clothingIds.contains(where: { target.contains($0) }) else { return outfit }
            affectedOutfits += 1
            var next = outfit
            next.clothingIds = outfit.clothingIds.filter { !target.contains($0) }
            next.canvasData = outfit.canvasData.filter { !target.contains($0.clothingId) }
            return next
        }
        if affectedOutfits > 0 {
            writeOutfitList(outfits)
            emitChange(.outfitChange, action: "update", reason: "clothing-deleted")
        }

        var affectedInspirations = 0
        let inspirations = readInspirationList().map { item -> Inspiration in
            guard item.clothingIds.contains(where: { target.contains($0) }) else { return item }
            affectedInspirations += 1
            var next = item
            next.clothingIds = item.clothingIds.filter { !target.contains($0) }
            return next
        }
        if affectedInspirations > 0 {
            writeInspirationList(inspirations)
            emitChange(.inspirationChange, action: "update", reason: "clothing-deleted")
        }

        // 图片文件在数据层之外，统一回收（没被别处引用才删）
        images.forEach { path in
            if !isImageInUse(path) { ImageStore.shared.removeFile(path) }
        }

        emitChange(.clothingChange, action: "delete", reason: "batch")
        return (removed.count, affectedOutfits, affectedInspirations)
    }

    /* ==================== 标签管理 ==================== */

    /// 所有标签 + 各自被多少件衣物用着（按用得多的排前面，同数量按名字排）
    func listTags() -> [TagSummary] {
        var counter: [String: Int] = [:]
        readClothingList().forEach { item in
            item.tags.forEach { counter[$0, default: 0] += 1 }
        }
        return counter
            .map { TagSummary(name: $0.key, count: $0.value) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
    }

    /// 标签改名：新名字已经存在时按「合并」处理。返回受影响的衣物件数
    @discardableResult
    func renameTag(from old: String, to rawNew: String) -> Int {
        let target = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawNew.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !value.isEmpty, target != value else { return 0 }
        var list = readClothingList()
        var changed = 0
        for index in list.indices where list[index].tags.contains(target) {
            var tags = list[index].tags.filter { $0 != target }
            if !tags.contains(value) { tags.append(value) }
            list[index].tags = tags
            changed += 1
        }
        guard changed > 0 else { return 0 }
        writeClothingList(list)
        emitChange(.clothingChange, action: "tag", reason: "rename")
        return changed
    }

    /// 删除标签（从所有衣物上摘掉）
    @discardableResult
    func deleteTag(_ name: String) -> Int {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return 0 }
        var list = readClothingList()
        var changed = 0
        for index in list.indices where list[index].tags.contains(target) {
            list[index].tags.removeAll { $0 == target }
            changed += 1
        }
        guard changed > 0 else { return 0 }
        writeClothingList(list)
        emitChange(.clothingChange, action: "tag", reason: "delete")
        return changed
    }

    /// 给一批衣物加同一个标签（批量为「这些衣服都适合通勤」打标）
    @discardableResult
    func addTagBatch(_ tag: String, ids: [String], limit: Int = ClothingLimits.maxTags) -> Int {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !ids.isEmpty else { return 0 }
        let target = Set(ids)
        var list = readClothingList()
        var changed = 0
        for index in list.indices where target.contains(list[index].id) {
            guard !list[index].tags.contains(value), list[index].tags.count < limit else { continue }
            list[index].tags.append(value)
            changed += 1
        }
        guard changed > 0 else { return 0 }
        writeClothingList(list)
        emitChange(.clothingChange, action: "tag", reason: "batch")
        return changed
    }

    /* ==================== 穿搭 ==================== */

    /// 传 date 只返回当天；传 season 只返回标了这个季节的
    func listOutfits(date: String? = nil, season: String? = nil) -> [Outfit] {
        var list = readOutfitList()
        if let date, !date.isEmpty {
            list = list.filter { $0.date == date }
        }
        if let season, !season.isEmpty, season != Wardrobe.all {
            list = list.filter { $0.seasons.contains(season) }
        }
        return list.sorted { $0.createTime > $1.createTime }
    }

    func getOutfit(_ id: String) -> Outfit? {
        readOutfitList().first { $0.id == id }
    }

    /// 某件衣物参与过的穿搭（按创建时间倒序），衣物详情页的「历史穿搭」用它
    func listOutfits(clothingId: String) -> [Outfit] {
        guard !clothingId.isEmpty else { return [] }
        return readOutfitList()
            .filter { $0.clothingIds.contains(clothingId) }
            .sorted { $0.createTime > $1.createTime }
    }

    /// 有穿搭记录的日期，用于日记页日历打点
    func listOutfitDates() -> [String] {
        Array(Set(readOutfitList().compactMap { $0.date.isEmpty ? nil : $0.date })).sorted()
    }

    /// date -> 当天穿搭数量，日历角标用
    func countOutfitsByDate() -> [String: Int] {
        var map: [String: Int] = [:]
        readOutfitList().forEach { outfit in
            guard !outfit.date.isEmpty else { return }
            map[outfit.date, default: 0] += 1
        }
        return map
    }

    @discardableResult
    func addOutfit(_ draft: OutfitDraft) -> Outfit {
        let outfit = normalize(draft, id: nextID(.outfit), createTime: Date().milliseconds)
        var list = readOutfitList()
        list.append(outfit)
        writeOutfitList(list)
        indexAdd(outfit.id, .outfit)
        emitChange(.outfitChange, action: "add", id: outfit.id)
        return outfit
    }

    @discardableResult
    func updateOutfit(_ id: String, patch: (inout Outfit) -> Void) -> Outfit? {
        var list = readOutfitList()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        var outfit = list[index]
        patch(&outfit)
        outfit = normalize(outfit)
        list[index] = outfit
        writeOutfitList(list)
        emitChange(.outfitChange, action: "update", id: id)
        return outfit
    }

    /// 新增或更新统一入口
    @discardableResult
    func saveOutfit(_ draft: OutfitDraft) -> Outfit {
        let old = draft.id.isEmpty ? nil : getOutfit(draft.id)
        // 这套记录要不要计入穿着次数：调用方没指定就沿用原来的状态（新建时默认不计入）
        let counted = draft.countWear ?? (old?.wearCounted ?? false)
        var payload = draft
        payload.countWear = counted

        let saved: Outfit
        if let old {
            saved = updateOutfit(old.id) { outfit in
                var next = normalize(payload, id: old.id, createTime: old.createTime)
                next.createTime = old.createTime
                outfit = next
            } ?? old
        } else {
            saved = addOutfit(payload)
        }

        // 记一套穿搭 = 这几件今天穿了：新加进来的 +1，被拿掉的 -1（原来就没计数的整套不动）
        let oldIds = Set(old?.clothingIds ?? [])
        let newIds = Set(saved.clothingIds)
        var add: Set<String> = []
        var remove: Set<String> = []
        if counted {
            add = newIds.subtracting(old?.wearCounted == true ? oldIds : [])
        }
        if old?.wearCounted == true {
            remove = oldIds.subtracting(counted ? newIds : [])
        }
        applyWearChanges(add: add, remove: remove, date: saved.date)
        return saved
    }

    /// 复制一套穿搭（试衣间的「复制」）
    @discardableResult
    func duplicateOutfit(_ id: String, date: String? = nil, note: String? = nil) -> Outfit? {
        guard let outfit = getOutfit(id) else { return nil }
        var draft = OutfitDraft(
            clothingIds: outfit.clothingIds,
            canvasData: outfit.canvasData,
            cover: outfit.cover,
            seasons: outfit.seasons,
            note: note ?? outfit.note,
            date: date ?? outfit.date
        )
        draft.createTime = 0
        // 复制出来的只是一套「摆法」，不代表今天真的穿了，所以不计次数、也不带当天的照片
        draft.countWear = false
        return addOutfit(draft)
    }

    @discardableResult
    func deleteOutfit(_ id: String) -> Bool {
        guard let outfit = getOutfit(id) else { return false }
        writeOutfitList(readOutfitList().filter { $0.id != id })
        indexRemove(id)
        // 这套记录之前给衣物加过次数的话，删掉记录时一起回滚，别留下虚高的次数
        if outfit.wearCounted {
            applyWearChanges(add: [], remove: Set(outfit.clothingIds), date: outfit.date)
        }
        emitChange(.outfitChange, action: "delete", id: id)
        return true
    }

    /* ==================== 穿着次数（穿搭记录带来的增减） ==================== */

    /// 把「这套穿搭带来的次数变化」一次性应用到衣物上：
    /// 读一遍、改一遍、写一遍（不要在循环里调用单件接口，那样每件都要全量落盘一次）
    private func applyWearChanges(add: Set<String>, remove: Set<String>, date: String) {
        guard !add.isEmpty || !remove.isEmpty else { return }
        var list = readClothingList()
        var changed = false
        for index in list.indices {
            let id = list[index].id
            if add.contains(id) {
                list[index].wearCount = max(0, list[index].wearCount + 1)
                // 日期取更晚的那个：补记旧日期的穿搭不该把「最近穿着」往回拨
                if date > list[index].lastWornDate { list[index].lastWornDate = date }
                changed = true
            } else if remove.contains(id) {
                list[index].wearCount = max(0, list[index].wearCount - 1)
                if list[index].wearCount == 0 { list[index].lastWornDate = "" }
                changed = true
            }
        }
        guard changed else { return }
        writeClothingList(list)
        emitChange(.clothingChange, action: "wear", reason: "outfit")
    }

    /* ==================== 灵感 ==================== */

    /// folderId 传空表示全部
    func listInspirations(folderId: String? = nil) -> [Inspiration] {
        var list = readInspirationList()
        if let folderId, !folderId.isEmpty {
            list = list.filter { $0.folderId == folderId }
        }
        return list.sorted { $0.createTime > $1.createTime }
    }

    func getInspiration(_ id: String) -> Inspiration? {
        readInspirationList().first { $0.id == id }
    }

    @discardableResult
    func addInspiration(folderId: String, images: [String], clothingIds: [String] = [], title: String = "", note: String = "") -> Inspiration {
        let item = Inspiration(
            id: nextID(.inspiration),
            folderId: folderId,
            images: images.filter { !$0.isEmpty },
            clothingIds: clothingIds.filter { !$0.isEmpty },
            title: title,
            note: note,
            createTime: Date().milliseconds
        )
        var list = readInspirationList()
        list.append(item)
        writeInspirationList(list)
        indexAdd(item.id, .inspiration)
        emitChange(.inspirationChange, action: "add", id: item.id)
        return item
    }

    @discardableResult
    func updateInspiration(_ id: String, patch: (inout Inspiration) -> Void) -> Inspiration? {
        var list = readInspirationList()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        var item = list[index]
        patch(&item)
        item.id = id
        list[index] = item
        writeInspirationList(list)
        emitChange(.inspirationChange, action: "update", id: id)
        return item
    }

    @discardableResult
    func deleteInspiration(_ id: String) -> Bool {
        writeInspirationList(readInspirationList().filter { $0.id != id })
        indexRemove(id)
        emitChange(.inspirationChange, action: "delete", id: id)
        return true
    }

    /* ==================== 灵感文件夹 ==================== */

    private func buildDefaultFolder() -> InspirationFolder {
        InspirationFolder(id: Wardrobe.defaultFolderID, name: "灵感", type: "inspiration", createTime: Date().milliseconds)
    }

    func listFolders() -> [InspirationFolder] {
        readFolderList()
    }

    func getFolder(_ id: String) -> InspirationFolder? {
        readFolderList().first { $0.id == id }
    }

    /// 试衣间顶部 tab 用的文件夹列表：虚拟「搭配」文件夹 + 灵感文件夹
    func listFittingFolders() -> [FittingFolder] {
        [FittingFolder(id: Wardrobe.outfitFolderID, name: "搭配", isVirtual: true)]
            + listFolders().map { FittingFolder(id: $0.id, name: $0.name, isVirtual: false) }
    }

    @discardableResult
    func addFolder(_ name: String, type: String = "inspiration") -> InspirationFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = InspirationFolder(
            id: nextID(.folder),
            name: trimmed.isEmpty ? "新文件夹" : trimmed,
            type: type,
            createTime: Date().milliseconds
        )
        var list = readFolderList()
        list.append(folder)
        writeFolderList(list)
        indexAdd(folder.id, .folder)
        return folder
    }

    @discardableResult
    func renameFolder(_ id: String, name: String) -> InspirationFolder? {
        var list = readFolderList()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list[index].name = trimmed
        }
        writeFolderList(list)
        return list[index]
    }

    /// 删除文件夹：其中的灵感移到默认文件夹，默认文件夹不可删
    @discardableResult
    func deleteFolder(_ id: String) -> Bool {
        guard id != Wardrobe.defaultFolderID else { return false }
        writeFolderList(readFolderList().filter { $0.id != id })
        indexRemove(id)

        let inspirations = readInspirationList().map { item -> Inspiration in
            guard item.folderId == id else { return item }
            var next = item
            next.folderId = Wardrobe.defaultFolderID
            return next
        }
        writeInspirationList(inspirations)
        emitChange(.inspirationChange, action: "update", id: id, reason: "folder-deleted")
        return true
    }

    /* ==================== 设置 / 衣橱筛选 / 天气 ==================== */

    func getSettings() -> AppSettings {
        storage.value(.settings, as: AppSettings.self, default: AppSettings())
    }

    @discardableResult
    func saveSettings(patch: (inout AppSettings) -> Void) -> AppSettings {
        var next = getSettings()
        patch(&next)
        storage.set(.settings, next)
        store.settings = next
        store.bus.emit(.settingsChange, AppEventPayload(type: "settings"))
        return next
    }

    func getWardrobeFilter() -> WardrobeFilter {
        storage.value(.wardrobeFilter, as: WardrobeFilter.self, default: WardrobeFilter())
    }

    /* ==================== 衣物分类（可自定义） ====================
     内置的六个分类只是「默认值」：用户第一次改动之后就以本地存储里的那份为准。
     改分类名 / 删分类都会同步到已经用了这个分类的衣物上，不会让老数据变成孤儿。
     */

    /// 当前分类列表（没改过就是内置的默认分类）
    func listCategories() -> [String] {
        let cleaned = Self.cleanCategories(storage.value(.categories, as: [String].self, default: []))
        return cleaned.isEmpty ? Wardrobe.categories : cleaned
    }

    /// 当前是不是还没改过的默认分类
    func isDefaultCategories() -> Bool {
        storage.value(.categories, as: [String].self, default: []).isEmpty
    }

    /// 整体替换（至少留一个分类，否则拒绝写入）
    @discardableResult
    func saveCategories(_ list: [String]) -> [String] {
        let cleaned = Self.cleanCategories(list)
        guard !cleaned.isEmpty else { return listCategories() }
        storage.set(.categories, cleaned)
        store.bus.emit(.categoryChange, AppEventPayload(type: "categories"))
        return cleaned
    }

    /// 改名：把用到旧名字的衣物一起改成新名字
    @discardableResult
    func renameCategory(_ from: String, to rawNew: String) -> [String] {
        let old = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = rawNew.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, old != new else { return listCategories() }

        var list = listCategories()
        guard let index = list.firstIndex(of: old) else { return list }
        // 新名字已经存在时按「合并」处理：旧分类里的衣物并入新分类
        if let exist = list.firstIndex(of: new), exist != index {
            list.remove(at: index)
        } else {
            list[index] = new
        }
        saveCategories(list)
        reassignClothing(from: old, to: new)
        return listCategories()
    }

    /// 删除分类：这个分类下的衣物会移到 fallback（一般是列表里的第一个）
    @discardableResult
    func deleteCategory(_ name: String, fallback: String) -> [String] {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = listCategories()
        guard list.count > 1, let index = list.firstIndex(of: target) else { return list }
        list.remove(at: index)
        let nextFallback = list.contains(fallback) ? fallback : (list.first ?? Wardrobe.categories[0])
        saveCategories(list)
        reassignClothing(from: target, to: nextFallback)
        return listCategories()
    }

    /// 恢复成内置的默认分类（已经用了自定义分类的衣物保持原样，不丢数据）
    @discardableResult
    func resetCategories() -> [String] {
        storage.remove(.categories)
        store.bus.emit(.categoryChange, AppEventPayload(type: "categories"))
        return listCategories()
    }

    /// 新增一个分类（重名直接返回原列表）
    @discardableResult
    func addCategory(_ name: String) -> [String] {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return listCategories() }
        var list = listCategories()
        guard !list.contains(value) else { return list }
        list.append(value)
        return saveCategories(list)
    }

    /// 把某个分类下的衣物整体挪到另一个分类
    private func reassignClothing(from old: String, to new: String) {
        guard old != new else { return }
        var list = readClothingList()
        var changed = false
        for index in list.indices where list[index].category == old {
            list[index].category = new
            changed = true
        }
        guard changed else { return }
        writeClothingList(list)
        emitChange(.clothingChange, action: "category", reason: "reassign")
    }

    /// 分类名的清洗：去空白、去重、限长、限个数
    static func cleanCategories(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in list {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count > maxCategoryLength {
                value = String(value.prefix(maxCategoryLength))
            }
            guard !value.isEmpty, !seen.contains(value) else { continue }
            seen.insert(value)
            result.append(value)
            if result.count >= maxCategories { break }
        }
        return result
    }

    /// 分类名的长度 / 数量上限（界面上的输入校验也用它）
    static let maxCategoryLength = 8
    static let maxCategories = 20

    @discardableResult
    func saveWardrobeFilter(_ filter: WardrobeFilter) -> WardrobeFilter {
        storage.set(.wardrobeFilter, filter)
        store.wardrobeFilter = filter
        store.bus.emit(.wardrobeFilterChange, AppEventPayload(type: "filter"))
        return filter
    }

    func getWeatherConfig() -> WeatherConfig {
        storage.value(.weatherConfig, as: WeatherConfig.self, default: WeatherConfig())
    }

    @discardableResult
    func saveWeatherConfig(patch: (inout WeatherConfig) -> Void) -> WeatherConfig {
        var next = getWeatherConfig()
        patch(&next)
        storage.set(.weatherConfig, next)
        store.bus.emit(.weatherChange, AppEventPayload(type: "weatherConfig"))
        return next
    }

    /// 全部天气记录
    func getWeatherLog() -> [String: WeatherRecord] {
        storage.value(.weatherLog, as: [String: WeatherRecord].self, default: [:])
    }

    func getWeather(_ date: String) -> WeatherRecord? {
        getWeatherLog()[date]
    }

    /// 记一天的天气；日期、城市、温度、天气全空就把这条删掉，免得攒一堆空记录
    @discardableResult
    func saveWeather(_ date: String, patch: (inout WeatherRecord) -> Void) -> WeatherRecord? {
        guard !date.isEmpty else { return nil }
        var log = getWeatherLog()
        var record = log[date] ?? WeatherRecord(date: date)
        patch(&record)
        record.date = date
        record.updateTime = Date().milliseconds
        if record.hasContent {
            log[date] = record
            storage.set(.weatherLog, log)
            store.bus.emit(.weatherChange, AppEventPayload(type: "weather", id: date))
            return record
        }
        log.removeValue(forKey: date)
        storage.set(.weatherLog, log)
        store.bus.emit(.weatherChange, AppEventPayload(type: "weather", id: date))
        return nil
    }

    /* ==================== 初始化 / 导出 / 清空 ==================== */

    /// 这张图片是否还被引用（衣物封面 / 原图、穿搭封面、灵感图）。删文件前先问一句
    func isImageInUse(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if readClothingList().contains(where: { $0.coverImage == path || $0.originalImage == path }) {
            return true
        }
        if readOutfitList().contains(where: { $0.cover == path || $0.photo == path }) {
            return true
        }
        return readInspirationList().contains { $0.images.contains(path) }
    }

    /// 全部还在用的图片文件名（备份时按这个清单打包图片，不会漏也不会多带回收掉的图）
    func allImageNames() -> [String] {
        var names: Set<String> = []
        readClothingList().forEach { item in
            if !item.coverImage.isEmpty { names.insert(item.coverImage) }
            if !item.originalImage.isEmpty { names.insert(item.originalImage) }
        }
        readOutfitList().forEach { outfit in
            if !outfit.cover.isEmpty { names.insert(outfit.cover) }
            if !outfit.photo.isEmpty { names.insert(outfit.photo) }
        }
        readInspirationList().forEach { item in
            item.images.forEach { names.insert($0) }
        }
        return Array(names)
    }

    /// 按现有数据重建 id 索引，并从已有 id 里恢复自增序号，避免 id 冲突
    func rebuildIndex() {
        var index: [String: String] = [:]
        var maxSeq = storage.value(.idSeq, as: Int.self, default: 0)

        func scan(_ ids: [String], _ kind: EntityKind) {
            for id in ids where !id.isEmpty {
                index[id] = kind.rawValue
                if let seq = Int(id.dropFirst(), radix: 36), seq > maxSeq {
                    maxSeq = seq
                }
            }
        }
        scan(readClothingList().map { $0.id }, .clothing)
        scan(readOutfitList().map { $0.id }, .outfit)
        scan(readInspirationList().map { $0.id }, .inspiration)
        scan(readFolderList().map { $0.id }, .folder)

        storage.set(.idIndex, index)
        storage.set(.idSeq, maxSeq)
    }

    /// App 启动时调用（对应 db.init）
    func initialize() {
        storage.initSchema()

        if readFolderList().isEmpty {
            writeFolderList([buildDefaultFolder()])
        }
        if !storage.has(.settings) {
            storage.set(.settings, AppSettings())
        }
        if !storage.has(.wardrobeFilter) {
            storage.set(.wardrobeFilter, WardrobeFilter())
        }
        rebuildIndex()
    }

    /// 导出全部数据（设置页「导出 JSON」用；图片只有文件名，文件本身在本地沙箱里）
    func exportData() -> ExportPayload {
        let formatter = ISO8601DateFormatter()
        return ExportPayload(
            app: "wardrobe-ios",
            version: Storage.schemaVersion,
            exportTime: formatter.string(from: Date()),
            settings: getSettings(),
            folders: listFolders(),
            clothing: readClothingList(),
            outfits: readOutfitList(),
            inspirations: readInspirationList(),
            weather: getWeatherLog()
        )
    }

    func exportJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(exportData()) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 解析一份备份 JSON（恢复备份的第一步，先解析成功再动数据）
    func decodePayload(_ data: Data) -> ExportPayload? {
        try? JSONDecoder().decode(ExportPayload.self, from: data)
    }

    /// 用备份里的数据整体替换本地数据（设置页「恢复备份」用）。
    /// 图片文件由调用方负责搬（见 Utils/BackupService.swift）。
    @discardableResult
    func replaceAll(with payload: ExportPayload) -> Bool {
        writeClothingList(payload.clothing)
        writeOutfitList(payload.outfits)
        writeInspirationList(payload.inspirations)
        writeFolderList(payload.folders.isEmpty ? [buildDefaultFolder()] : payload.folders)
        storage.set(.weatherLog, payload.weather)
        storage.set(.settings, payload.settings)
        storage.set(.wardrobeFilter, WardrobeFilter())
        rebuildIndex()

        store.settings = payload.settings
        store.wardrobeFilter = WardrobeFilter()
        emitChange(.clothingChange, action: "restore")
        emitChange(.outfitChange, action: "restore")
        emitChange(.inspirationChange, action: "restore")
        store.bus.emit(.settingsChange, AppEventPayload(type: "settings"))
        store.bus.emit(.wardrobeFilterChange, AppEventPayload(type: "filter"))
        return true
    }

    /// 清空业务数据（图片文件由 ImageStore.clearImages 单独清理），保留自增序号
    func clearAll() {
        writeClothingList([])
        writeOutfitList([])
        writeInspirationList([])
        writeFolderList([buildDefaultFolder()])
        storage.set(.weatherLog, [String: WeatherRecord]())
        storage.set(.idIndex, [String: String]())
        storage.set(.settings, AppSettings())
        storage.set(.wardrobeFilter, WardrobeFilter())

        store.settings = AppSettings()
        store.wardrobeFilter = WardrobeFilter()
        emitChange(.clothingChange, action: "clear")
        emitChange(.outfitChange, action: "clear")
        emitChange(.inspirationChange, action: "clear")
        store.bus.emit(.settingsChange, AppEventPayload(type: "settings"))
        store.bus.emit(.wardrobeFilterChange, AppEventPayload(type: "filter"))
    }

    /* ==================== 归一化（对应 db.js 里的 normalizeXxx） ==================== */

    private func normalize(_ draft: ClothingDraft, id: String, createTime: Double) -> ClothingItem {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 分类是可自定义的：空值兜底成当前分类列表里的第一个，其余原样保留
        let rawCategory = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = rawCategory.isEmpty ? (listCategories().first ?? Wardrobe.defaultCategory) : rawCategory
        let size = Wardrobe.sizes.contains(draft.size) ? draft.size : ""
        let seasons = draft.seasons
            .filter { Wardrobe.seasons.contains($0) }
            .sorted { (Wardrobe.seasons.firstIndex(of: $0) ?? 0) < (Wardrobe.seasons.firstIndex(of: $1) ?? 0) }
        let priceValue = draft.price.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClothingItem(
            id: id,
            name: name.isEmpty ? "未命名衣物" : name,
            coverImage: draft.coverImage,
            originalImage: draft.originalImage,
            category: category,
            tags: draft.tags.filter { !$0.isEmpty },
            seasons: seasons,
            purchaseDate: draft.purchaseDate,
            price: priceValue.isEmpty ? 0 : (Double(priceValue) ?? 0),
            size: size,
            note: draft.note,
            wearCount: 0,
            lastWornDate: "",
            createTime: createTime
        )
    }

    /// 已存数据再过一遍归一化（编辑时用）
    private func normalize(_ item: ClothingItem) -> ClothingItem {
        var draft = ClothingDraft()
        draft.name = item.name
        draft.category = item.category
        draft.tags = item.tags
        draft.seasons = item.seasons
        draft.purchaseDate = item.purchaseDate
        draft.price = item.price == 0 ? "" : String(item.price)
        draft.size = item.size
        draft.note = item.note
        draft.originalImage = item.originalImage
        draft.coverImage = item.coverImage
        draft.status = item.status
        draft.statusDate = item.statusDate
        draft.soldPrice = item.soldPrice == 0 ? "" : String(item.soldPrice)
        var next = normalize(draft, id: item.id, createTime: item.createTime)
        next.price = item.price
        next.wearCount = max(0, item.wearCount)
        next.lastWornDate = item.lastWornDate
        next.status = item.status
        next.statusDate = item.statusDate
        next.soldPrice = item.soldPrice
        return next
    }

    private func normalize(_ draft: OutfitDraft, id: String, createTime: Double) -> Outfit {
        let canvasData = draft.canvasData.enumerated().map { index, item -> CanvasItem in
            CanvasItem(
                clothingId: item.clothingId,
                x: item.x,
                y: item.y,
                scale: item.scale == 0 ? 1 : item.scale,
                rotation: item.rotation,
                zIndex: item.zIndex == 0 ? index + 1 : item.zIndex
            )
        }
        let seasons = draft.seasons
            .filter { Wardrobe.seasons.contains($0) }
            .sorted { (Wardrobe.seasons.firstIndex(of: $0) ?? 0) < (Wardrobe.seasons.firstIndex(of: $1) ?? 0) }
        return Outfit(
            id: id,
            clothingIds: draft.clothingIds.filter { !$0.isEmpty },
            canvasData: canvasData.filter { !$0.clothingId.isEmpty },
            cover: draft.cover,
            seasons: seasons,
            note: draft.note,
            date: draft.date.isEmpty ? DateUtil.today() : draft.date,
            createTime: createTime,
            photo: draft.photo,
            wearCounted: draft.countWear ?? false
        )
    }

    private func normalize(_ outfit: Outfit) -> Outfit {
        var draft = OutfitDraft()
        draft.clothingIds = outfit.clothingIds
        draft.canvasData = outfit.canvasData
        draft.cover = outfit.cover
        draft.seasons = outfit.seasons
        draft.note = outfit.note
        draft.date = outfit.date
        draft.photo = outfit.photo
        draft.countWear = outfit.wearCounted
        return normalize(draft, id: outfit.id, createTime: outfit.createTime)
    }
}
