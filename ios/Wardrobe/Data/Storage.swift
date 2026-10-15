//
//  Storage.swift —— 本地存储底座（对应 utils/storage.js）
//
//  职责：
//   - 统一 key 前缀，业务层不写裸字符串
//   - 同步读写（和 wx.setStorageSync 一样的语义：写完立刻落盘），配合 AppState + 事件总线做状态管理
//   - 只存 JSON 可序列化的数据；图片本身存文件系统，这里只存文件名（见 utils/image.js → ImageStore）
//
//  与小程序的差异（只这一处，其余一致）：
//   小程序把数据放在 wx.setStorageSync 里，iOS 版把每个 key 存成 Application Support 下的一个 json 文件。
//   好处是数据量不受 plist 体积限制，且 iOS 沙箱路径会变，文件方式更稳。
//

import Foundation

final class Storage {
    static let shared = Storage()

    /// 所有 storage key 的集中定义（与 utils/storage.js 的 KEYS 一一对应）
    enum Key: String, CaseIterable {
        case schemaVersion = "schema_version"
        case idSeq = "id_seq"
        case idIndex = "id_index"
        case clothing = "clothing_list"
        case outfit = "outfit_list"
        case inspiration = "inspiration_list"
        case folder = "folder_list"
        case settings = "settings"
        case wardrobeFilter = "wardrobe_filter"
        case categories = "category_list"
        case weatherConfig = "weather_config"
        case weatherLog = "weather_log"
    }

    /// 数据结构版本号，后续字段变更时在这里做迁移
    ///  - v1：初始版本
    ///  - v2：衣物加「断舍离状态 / 处置日期 / 回血金额」，穿搭加「当天照片 / 是否计入穿着次数」，
    ///        设置加「网格列数 / 单次成本开关」，筛选加「排序 / 显示已处置」
    static let schemaVersion = 2

    /// key 前缀，对应小程序里的 'wardrobe_'
    private let prefix = "wardrobe_"
    private let directory: URL
    private var cache: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Wardrobe/store", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadAll()
    }

    /* ==================== 读写 ==================== */

    /// 读取，失败或不存在时返回 defaultValue（对应 storage.get）
    func value<T: Decodable>(_ key: Key, as type: T.Type, default defaultValue: T) -> T {
        guard let data = cache[fileName(key)] else { return defaultValue }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            print("[storage] 解码失败：\(key.rawValue) \(error)")
            return defaultValue
        }
    }

    /// 可选读取：不存在时返回 nil，用来区分「没写过」和「写成了空值」
    func optionalValue<T: Decodable>(_ key: Key, as type: T.Type) -> T? {
        guard let data = cache[fileName(key)] else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// 写入，返回是否成功（对应 storage.set）
    @discardableResult
    func set<T: Encodable>(_ key: Key, _ value: T) -> Bool {
        do {
            let data = try encoder.encode(value)
            cache[fileName(key)] = data
            try data.write(to: url(key), options: .atomic)
            return true
        } catch {
            print("[storage] 写入失败：\(key.rawValue) \(error)")
            return false
        }
    }

    func has(_ key: Key) -> Bool {
        cache[fileName(key)] != nil
    }

    @discardableResult
    func remove(_ key: Key) -> Bool {
        cache.removeValue(forKey: fileName(key))
        do {
            if FileManager.default.fileExists(atPath: url(key).path) {
                try FileManager.default.removeItem(at: url(key))
            }
            return true
        } catch {
            print("[storage] 删除失败：\(key.rawValue) \(error)")
            return false
        }
    }

    /// 只清理本 App 自己写入的 key（都带前缀），不影响其它文件
    @discardableResult
    func clearAll() -> Bool {
        var ok = true
        for key in Key.allCases where has(key) {
            ok = remove(key) && ok
        }
        cache.removeAll()
        return ok
    }

    /* ==================== 版本迁移 ==================== */

    /// 版本迁移入口：App 启动时调用一次，返回 true 表示本次做了一次迁移（首次安装也算）
    ///
    /// 迁移原则：新字段全部「缺失即默认」，所以老数据永远读得进来；
    /// 这里额外把列表重新写一遍，是为了让落盘文件（以及导出的备份）里就带着新字段。
    @discardableResult
    func initSchema() -> Bool {
        let current = value(.schemaVersion, as: Int.self, default: 0)
        if current >= Storage.schemaVersion { return false }
        if current >= 1 { migrateV1toV2() }
        // current == 0：首次安装，没有老数据要迁
        set(.schemaVersion, Storage.schemaVersion)
        return true
    }

    /// v1 -> v2：新增字段都有默认值，这里只做一次「重写落盘」让文件里带上它们
    private func migrateV1toV2() {
        if let list = optionalValue(.clothing, as: [ClothingItem].self) { set(.clothing, list) }
        if let list = optionalValue(.outfit, as: [Outfit].self) { set(.outfit, list) }
        if let settings = optionalValue(.settings, as: AppSettings.self) { set(.settings, settings) }
        if let filter = optionalValue(.wardrobeFilter, as: WardrobeFilter.self) { set(.wardrobeFilter, filter) }
    }

    /* ==================== 容量信息（设置页展示用） ==================== */

    /// 已用存储空间（KB），对应 storage.getInfo().currentSize
    func usedSizeKB() -> Int {
        var bytes = 0
        cache.values.forEach { bytes += $0.count }
        return Int((Double(bytes) / 1024.0).rounded())
    }

    /// 已写入的 key 数量
    func storedKeyCount() -> Int {
        cache.count
    }

    /* ==================== 内部 ==================== */

    private func fileName(_ key: Key) -> String {
        prefix + key.rawValue + ".json"
    }

    private func url(_ key: Key) -> URL {
        directory.appendingPathComponent(fileName(key))
    }

    private func loadAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let raw = file.deletingPathExtension().lastPathComponent
            guard raw.hasPrefix(prefix) else { continue }
            cache[file.lastPathComponent] = try? Data(contentsOf: file)
        }
    }
}
