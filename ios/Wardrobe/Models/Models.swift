//
//  Models.swift —— 数据模型
//
//  对应小程序的 utils/db.js 里的 normalizeXxx：字段名、默认值、取值规则全部保持一致，
//  这样导出的 JSON 和小程序互通，迁移数据时不需要额外转换。
//

import Foundation

// MARK: - 固定枚举值（对应 db.js 顶部的 CATEGORIES / SEASONS / SIZES / ALL）

enum Wardrobe {
    /// 默认分类（第一次启动时的取值；用户可以在「分类管理」里改名 / 增删，见 Data/Database.swift）
    static let categories = ["上衣", "裤子", "裙子", "鞋", "配饰", "套装"]
    /// 兜底分类：分类字段为空（老数据 / 被清空）时用它
    static var defaultCategory: String { categories.first ?? "上衣" }
    /// 固定季节
    static let seasons = ["春", "夏", "秋", "冬"]
    /// 固定尺码（留空表示不填）
    static let sizes = ["XS", "S", "M", "L", "XL"]
    /// 筛选项里的「全部」
    static let all = "全部"
    /// 默认灵感文件夹（不可删除）
    static let defaultFolderID = "f1"
    /// 试衣间里的虚拟「搭配」文件夹
    static let outfitFolderID = "outfit"
}

/// 断舍离：一件衣物离开衣橱时的去向。
/// 存进数据的只有 rawValue（空字符串表示还在穿），这样老数据不用迁移也能读。
enum ReleaseMethod: String, CaseIterable, Identifiable {
    case sold
    case gifted
    case discarded
    case retired

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sold: return "卖掉了"
        case .gifted: return "送人了"
        case .discarded: return "扔掉了"
        case .retired: return "淘汰了"
        }
    }

    /// 列表 / 标签里的短标签
    var shortTitle: String {
        switch self {
        case .sold: return "已卖"
        case .gifted: return "已送人"
        case .discarded: return "已丢弃"
        case .retired: return "已淘汰"
        }
    }

    var symbol: String {
        switch self {
        case .sold: return "yensign.circle"
        case .gifted: return "gift"
        case .discarded: return "trash"
        case .retired: return "archivebox"
        }
    }

    /// 卖掉时才有「回血」金额
    var needsPrice: Bool { self == .sold }
}

/// 一些共用的上限（表单校验和批量操作都看这里，别各写各的）
enum ClothingLimits {
    /// 一件衣物最多几个标签
    static let maxTags = 10
}

/// 标签管理页里的一项：标签名 + 用它的衣物件数
struct TagSummary: Identifiable, Hashable {
    var name: String
    var count: Int

    var id: String { name }
}

/// 衣橱列表的排序方式（存在 WardrobeFilter 里，下次进来还是它）
enum WardrobeSort: String, CaseIterable, Identifiable {
    case latest
    case lastWorn
    case mostWorn
    case costHigh
    case priceHigh
    case purchaseNew

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return "最新添加"
        case .lastWorn: return "最近穿过"
        case .mostWorn: return "穿得最多"
        case .costHigh: return "单次成本高"
        case .priceHigh: return "价格最高"
        case .purchaseNew: return "买得最晚"
        }
    }

    /// 排序菜单里的一句话说明
    var note: String {
        switch self {
        case .latest: return "刚加进来的排前面"
        case .lastWorn: return "最近穿过的排前面"
        case .mostWorn: return "穿得多的排前面"
        case .costHigh: return "每次穿越贵越靠前，找「假便宜」"
        case .priceHigh: return "单价最高的排前面"
        case .purchaseNew: return "按购买日期从新到旧"
        }
    }
}

/// 实体类型：决定 id 前缀与落库的 key（对应 db.js 的 TYPE_PREFIX / TYPE_LIST_KEY）
enum EntityKind: String, Codable {
    case clothing
    case outfit
    case inspiration
    case folder

    var prefix: String {
        switch self {
        case .clothing: return "c"
        case .outfit: return "o"
        case .inspiration: return "i"
        case .folder: return "f"
        }
    }

    init?(prefix: Character) {
        switch prefix {
        case "c": self = .clothing
        case "o": self = .outfit
        case "i": self = .inspiration
        case "f": self = .folder
        default: return nil
        }
    }
}

// MARK: - 衣物

struct ClothingItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// 展示用图（通常为抠图后的图）
    var coverImage: String
    /// 原图，保留用于「重新抠图」与画笔恢复
    var originalImage: String
    var category: String
    var tags: [String]
    var seasons: [String]
    var purchaseDate: String
    var price: Double
    var size: String
    var note: String
    var wearCount: Int
    var lastWornDate: String
    /// 毫秒时间戳，与小程序保持一致
    var createTime: Double
    /// 断舍离状态：空 = 还在穿；sold / gifted / discarded / retired = 已处置（见 ReleaseMethod）
    var status: String
    /// 处置日期（YYYY-MM-DD）
    var statusDate: String
    /// 卖掉时的回血金额（其它处置方式为 0）
    var soldPrice: Double

    init(
        id: String,
        name: String,
        coverImage: String = "",
        originalImage: String = "",
        category: String = Wardrobe.categories[0],
        tags: [String] = [],
        seasons: [String] = [],
        purchaseDate: String = "",
        price: Double = 0,
        size: String = "",
        note: String = "",
        wearCount: Int = 0,
        lastWornDate: String = "",
        createTime: Double = Date().milliseconds,
        status: String = "",
        statusDate: String = "",
        soldPrice: Double = 0
    ) {
        self.id = id
        self.name = name
        self.coverImage = coverImage
        self.originalImage = originalImage
        self.category = category
        self.tags = tags
        self.seasons = seasons
        self.purchaseDate = purchaseDate
        self.price = price
        self.size = size
        self.note = note
        self.wearCount = wearCount
        self.lastWornDate = lastWornDate
        self.createTime = createTime
        self.status = status
        self.statusDate = statusDate
        self.soldPrice = soldPrice
    }

    /// 对应 db.js 的 normalizeClothing
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id)
        let rawName = c.flexString(.name).trimmingCharacters(in: .whitespacesAndNewlines)
        name = rawName.isEmpty ? "未命名衣物" : rawName
        coverImage = c.flexString(.coverImage)
        originalImage = c.flexString(.originalImage)
        // 分类是可自定义的：这里只保证非空，具体有哪些分类由数据层（Database.listCategories）管
        let rawCategory = c.flexString(.category)
        category = rawCategory.isEmpty ? Wardrobe.defaultCategory : rawCategory
        tags = c.flexStrings(.tags).filter { !$0.isEmpty }
        seasons = c.flexStrings(.seasons).filter { Wardrobe.seasons.contains($0) }
        purchaseDate = c.flexString(.purchaseDate)
        price = c.flexDouble(.price) ?? 0
        let rawSize = c.flexString(.size)
        size = Wardrobe.sizes.contains(rawSize) ? rawSize : ""
        note = c.flexString(.note)
        wearCount = Int(c.flexDouble(.wearCount) ?? 0)
        lastWornDate = c.flexString(.lastWornDate)
        createTime = c.flexDouble(.createTime) ?? Date().milliseconds
        let rawStatus = c.flexString(.status)
        status = ReleaseMethod(rawValue: rawStatus)?.rawValue ?? ""
        statusDate = c.flexString(.statusDate)
        soldPrice = c.flexDouble(.soldPrice) ?? 0
    }

    /* ==================== 派生数据（单次成本 / 断舍离） ==================== */

    /// 还在穿（没被断舍离）
    var isActive: Bool { status.isEmpty }

    /// 已经断舍离（处置掉了）
    var isReleased: Bool { !status.isEmpty }

    /// 处置方式；还在穿时为 nil
    var releaseMethod: ReleaseMethod? { ReleaseMethod(rawValue: status) }

    /// 单次成本 = 价格 ÷ 穿着次数。
    /// 没填价格（0）或还没穿过（0 次）时没有意义，返回 nil —— 界面据此显示「—」或「还没穿过」。
    var costPerWear: Double? {
        guard price > 0, wearCount > 0 else { return nil }
        return price / Double(wearCount)
    }

    /// 买了多少天（没填购买日期时为 nil）
    var ownedDays: Int? {
        guard !purchaseDate.isEmpty else { return nil }
        return max(0, DateUtil.daysBetween(purchaseDate, DateUtil.today()))
    }

    /// 距离上次穿了多少天；从没穿过时返回 nil
    var idleDays: Int? {
        guard !lastWornDate.isEmpty else { return nil }
        return max(0, DateUtil.daysBetween(lastWornDate, DateUtil.today()))
    }

    /// 卖掉后的净成本（买价 - 回血）
    var netPrice: Double {
        guard releaseMethod == .sold, soldPrice > 0 else { return price }
        return max(0, price - soldPrice)
    }
}

// MARK: - 穿搭

/// 画布上的一件衣物（对应 canvasData 的一项）
struct CanvasItem: Codable, Hashable {
    var clothingId: String
    var x: Double
    var y: Double
    var scale: Double
    var rotation: Double
    var zIndex: Int

    init(clothingId: String, x: Double = 0, y: Double = 0, scale: Double = 1, rotation: Double = 0, zIndex: Int = 1) {
        self.clothingId = clothingId
        self.x = x
        self.y = y
        self.scale = scale
        self.rotation = rotation
        self.zIndex = zIndex
    }

    /// 对应 db.js 的 normalizeCanvasData
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clothingId = c.flexString(.clothingId)
        x = c.flexDouble(.x) ?? 0
        y = c.flexDouble(.y) ?? 0
        let rawScale = c.flexDouble(.scale) ?? 1
        scale = rawScale == 0 ? 1 : rawScale
        rotation = c.flexDouble(.rotation) ?? 0
        zIndex = Int(c.flexDouble(.zIndex) ?? 0)
    }
}

struct Outfit: Codable, Identifiable, Hashable {
    var id: String
    var clothingIds: [String]
    var canvasData: [CanvasItem]
    /// 保存搭配时用 canvas 合成的封面图
    var cover: String
    var seasons: [String]
    var note: String
    var date: String
    var createTime: Double
    /// 当天的穿搭照片（抠好背景的贴图，透明 PNG），显示在日历里
    var photo: String
    /// 这套记录是否已经计入过关联衣物的穿着次数（记录穿搭时默认计入，删除 / 取消时会回滚）
    var wearCounted: Bool

    init(
        id: String,
        clothingIds: [String] = [],
        canvasData: [CanvasItem] = [],
        cover: String = "",
        seasons: [String] = [],
        note: String = "",
        date: String = DateUtil.today(),
        createTime: Double = Date().milliseconds,
        photo: String = "",
        wearCounted: Bool = false
    ) {
        self.id = id
        self.clothingIds = clothingIds
        self.canvasData = canvasData
        self.cover = cover
        self.seasons = seasons
        self.note = note
        self.date = date
        self.createTime = createTime
        self.photo = photo
        self.wearCounted = wearCounted
    }

    /// 对应 db.js 的 normalizeOutfit
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id)
        clothingIds = c.flexStrings(.clothingIds).filter { !$0.isEmpty }
        if let list = try? c.decodeIfPresent([CanvasItem].self, forKey: .canvasData) {
            canvasData = list.filter { !$0.clothingId.isEmpty }
        } else {
            canvasData = []
        }
        cover = c.flexString(.cover)
        seasons = c.flexStrings(.seasons).filter { Wardrobe.seasons.contains($0) }
        note = c.flexString(.note)
        let rawDate = c.flexString(.date)
        date = rawDate.isEmpty ? DateUtil.today() : rawDate
        createTime = c.flexDouble(.createTime) ?? Date().milliseconds
        photo = c.flexString(.photo)
        wearCounted = c.flexBool(.wearCounted) ?? false
    }
}

// MARK: - 灵感

struct Inspiration: Codable, Identifiable, Hashable {
    var id: String
    var folderId: String
    var images: [String]
    var clothingIds: [String]
    var title: String
    var note: String
    var createTime: Double

    init(
        id: String,
        folderId: String = Wardrobe.defaultFolderID,
        images: [String] = [],
        clothingIds: [String] = [],
        title: String = "",
        note: String = "",
        createTime: Double = Date().milliseconds
    ) {
        self.id = id
        self.folderId = folderId
        self.images = images
        self.clothingIds = clothingIds
        self.title = title
        self.note = note
        self.createTime = createTime
    }

    /// 对应 db.js 的 normalizeInspiration
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id)
        let rawFolder = c.flexString(.folderId)
        folderId = rawFolder.isEmpty ? Wardrobe.defaultFolderID : rawFolder
        images = c.flexStrings(.images).filter { !$0.isEmpty }
        clothingIds = c.flexStrings(.clothingIds).filter { !$0.isEmpty }
        title = c.flexString(.title)
        note = c.flexString(.note)
        createTime = c.flexDouble(.createTime) ?? Date().milliseconds
    }
}

struct InspirationFolder: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String
    var createTime: Double

    init(id: String, name: String, type: String = "inspiration", createTime: Double = Date().milliseconds) {
        self.id = id
        self.name = name
        self.type = type
        self.createTime = createTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id)
        let rawName = c.flexString(.name).trimmingCharacters(in: .whitespacesAndNewlines)
        name = rawName.isEmpty ? "新文件夹" : rawName
        let rawType = c.flexString(.type)
        type = rawType.isEmpty ? "inspiration" : rawType
        createTime = c.flexDouble(.createTime) ?? Date().milliseconds
    }
}

/// 试衣间顶部 tab 用的文件夹（虚拟「搭配」+ 灵感文件夹），对应 db.js 的 OUTFIT_FOLDER / listFittingFolders
struct FittingFolder: Identifiable, Hashable {
    let id: String
    let name: String
    /// 「搭配」是固定分类，不能改名 / 删除
    let isVirtual: Bool
}

// MARK: - 天气

/// 天气记录（日记页「当天天气」卡片，按日期存）
struct WeatherRecord: Codable, Hashable {
    var date: String
    var city: String
    var cityId: String
    var temp: String
    var text: String
    var icon: String
    /// 'api' = 自动获取，'manual' = 手填
    var source: String
    var updateTime: Double

    init(
        date: String,
        city: String = "",
        cityId: String = "",
        temp: String = "",
        text: String = "",
        icon: String = "",
        source: String = "",
        updateTime: Double = Date().milliseconds
    ) {
        self.date = date
        self.city = city
        self.cityId = cityId
        self.temp = temp
        self.text = text
        self.icon = icon
        self.source = source
        self.updateTime = updateTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.flexString(.date)
        city = c.flexString(.city)
        cityId = c.flexString(.cityId)
        temp = c.flexString(.temp)
        text = c.flexString(.text)
        icon = c.flexString(.icon)
        source = c.flexString(.source)
        updateTime = c.flexDouble(.updateTime) ?? Date().milliseconds
    }

    /// 城市 / 温度 / 天气全空视作没有内容（对应 db.js 的 saveWeather）
    var hasContent: Bool {
        !city.isEmpty || !temp.isEmpty || !text.isEmpty
    }
}

/// 最近用的城市：iOS 版存经纬度，供 WeatherKit 按坐标取天气
struct CityRef: Codable, Hashable {
    var name: String
    var adm: String
    var latitude: Double
    var longitude: Double

    init(name: String, adm: String = "", latitude: Double = 0, longitude: Double = 0) {
        self.name = name
        self.adm = adm
        self.latitude = latitude
        self.longitude = longitude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name)
        adm = c.flexString(.adm)
        latitude = c.flexDouble(.latitude) ?? 0
        longitude = c.flexDouble(.longitude) ?? 0
    }

    var hasCoordinate: Bool {
        latitude != 0 || longitude != 0
    }

    /// 展示用：「杭州 · 浙江」
    var displayText: String {
        adm.isEmpty ? name : name + " · " + adm
    }
}

/// 天气配置：iOS 版没有第三方 Key，`enabled` 表示是否允许按城市自动获取
/// 天气来源：系统 WeatherKit（默认） / 和风天气（备用通道，填个 Key 就能用）
enum WeatherProvider: String, CaseIterable {
    case system
    case qweather

    var title: String {
        switch self {
        case .system: return "系统 WeatherKit"
        case .qweather: return "和风天气"
        }
    }

    /// 设置页里的一句话说明
    var note: String {
        switch self {
        case .system:
            return "用 iOS 自带的 WeatherKit：不用申请 Key，但需要付费开发者账号，并在开发者后台给这个 App ID 勾上 WeatherKit 能力。"
        case .qweather:
            return "用和风天气的接口：免费开发者账号也能用，填一个 API Key 就行（Key 存在本机，不会上传）。免费版提供实况和未来 3 天预报，过去的日子仍需手填。"
        }
    }
}

struct WeatherConfig: Codable, Hashable {
    /// 天气来源（system / qweather），默认系统
    var provider: String
    var enabled: Bool
    var lastCity: CityRef?
    /// 和风天气的 API Key（备用通道用）
    var qweatherKey: String
    /// 和风天气的 API Host：老账号 devapi.qweather.com，新账号是自己专属的域名
    var qweatherHost: String

    init(
        provider: String = WeatherProvider.system.rawValue,
        enabled: Bool = false,
        lastCity: CityRef? = nil,
        qweatherKey: String = "",
        qweatherHost: String = QWeatherService.defaultHost
    ) {
        self.provider = provider
        self.enabled = enabled
        self.lastCity = lastCity
        self.qweatherKey = qweatherKey
        self.qweatherHost = qweatherHost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawProvider = c.flexString(.provider)
        provider = WeatherProvider(rawValue: rawProvider)?.rawValue ?? WeatherProvider.system.rawValue
        enabled = c.flexBool(.enabled) ?? false
        if let raw = try? c.decodeIfPresent(CityRef.self, forKey: .lastCity) {
            lastCity = raw
        } else {
            lastCity = nil
        }
        qweatherKey = c.flexString(.qweatherKey)
        let host = c.flexString(.qweatherHost)
        qweatherHost = host.isEmpty ? QWeatherService.defaultHost : host
    }

    /// 当前选中的来源
    var currentProvider: WeatherProvider {
        WeatherProvider(rawValue: provider) ?? .system
    }
}

/// WeatherKit 取回的一条天气（对应 utils/weather.js 的 { temp, text, icon, kind }）
struct WeatherSnapshot: Hashable {
    var temp: String
    var text: String
    var icon: String
    /// 'now' | 'forecast'
    var kind: String
}

// MARK: - 设置 / 筛选

struct AppSettings: Codable, Hashable {
    /// 衣橱卡片是否显示最近穿着日期
    var showLastWorn: Bool
    /// 外观：system（跟随系统）/ light（浅色）/ dark（深色）
    var appearance: String
    /// 衣橱网格每行几件（3 / 4）
    var gridColumns: Int
    /// 衣橱卡片上是否显示单次成本角标
    var showCostPerWear: Bool

    init(
        showLastWorn: Bool = true,
        appearance: String = "system",
        gridColumns: Int = 3,
        showCostPerWear: Bool = true
    ) {
        self.showLastWorn = showLastWorn
        self.appearance = appearance
        self.gridColumns = gridColumns
        self.showCostPerWear = showCostPerWear
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showLastWorn = c.flexBool(.showLastWorn) ?? true
        let raw = c.flexString(.appearance)
        appearance = ["system", "light", "dark"].contains(raw) ? raw : "system"
        let columns = Int(c.flexDouble(.gridColumns) ?? 3)
        gridColumns = (columns == 4) ? 4 : 3
        showCostPerWear = c.flexBool(.showCostPerWear) ?? true
    }
}

struct WardrobeFilter: Codable, Hashable {
    var category: String
    var season: String
    var keyword: String
    /// 排序方式（WardrobeSort 的 rawValue）
    var sort: String
    /// 是否把已断舍离的衣物也列出来
    var showReleased: Bool

    init(
        category: String = Wardrobe.all,
        season: String = Wardrobe.all,
        keyword: String = "",
        sort: String = WardrobeSort.latest.rawValue,
        showReleased: Bool = false
    ) {
        self.category = category
        self.season = season
        self.keyword = keyword
        self.sort = sort
        self.showReleased = showReleased
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = c.flexString(.category).isEmpty ? Wardrobe.all : c.flexString(.category)
        season = c.flexString(.season).isEmpty ? Wardrobe.all : c.flexString(.season)
        keyword = c.flexString(.keyword)
        let rawSort = c.flexString(.sort)
        sort = WardrobeSort(rawValue: rawSort)?.rawValue ?? WardrobeSort.latest.rawValue
        showReleased = c.flexBool(.showReleased) ?? false
    }

    var isFiltering: Bool {
        category != Wardrobe.all || season != Wardrobe.all
            || !keyword.trimmingCharacters(in: .whitespaces).isEmpty || showReleased
    }

    var isEmpty: Bool {
        category == Wardrobe.all && season == Wardrobe.all && keyword.isEmpty && !showReleased
    }

    /// 当前排序方式
    var currentSort: WardrobeSort {
        WardrobeSort(rawValue: sort) ?? .latest
    }
}

// MARK: - 导出

/// 对应 db.js 的 exportData()：数据 + 图片路径清单，图片本身在本地沙箱里
struct ExportPayload: Codable {
    var app: String
    var version: Int
    var exportTime: String
    var settings: AppSettings
    var folders: [InspirationFolder]
    var clothing: [ClothingItem]
    var outfits: [Outfit]
    var inspirations: [Inspiration]
    var weather: [String: WeatherRecord]
}

// MARK: - 容错解码工具（对应 db.js 里那些 `Number(x) || 0` / `String(x || '')` 的兜底）

extension KeyedDecodingContainer {
    /// 取字符串：null / 数字 / 布尔都兜住，缺失返回空串
    func flexString(_ key: Key) -> String {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return text }
        if let flag = try? decodeIfPresent(Bool.self, forKey: key) { return flag ? "true" : "false" }
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return String(number) }
        if let number = try? decodeIfPresent(Int.self, forKey: key) { return String(number) }
        return ""
    }

    func flexDouble(_ key: Key) -> Double? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number }
        if let text = try? decodeIfPresent(String.self, forKey: key), let number = Double(text) {
            return number
        }
        return nil
    }

    func flexBool(_ key: Key) -> Bool? {
        if let flag = try? decodeIfPresent(Bool.self, forKey: key) { return flag }
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return text == "true" || text == "1"
        }
        return nil
    }

    /// 取字符串数组：跳过 null 与非字符串项
    func flexStrings(_ key: Key) -> [String] {
        guard let list = try? decodeIfPresent([String?].self, forKey: key) else { return [] }
        return list.compactMap { $0 }
    }
}

extension Date {
    /// 毫秒时间戳（与小程序 Date.now() 对齐）
    var milliseconds: Double {
        timeIntervalSince1970 * 1000
    }
}
