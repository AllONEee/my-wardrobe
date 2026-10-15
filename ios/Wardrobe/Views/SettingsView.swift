//
//  SettingsView.swift —— 设置（对应 pages/settings）
//
//  五块内容：
//   - 显示设置：衣橱卡片是否显示最近穿着日期（写进本地存储，衣橱页订阅事件后即时生效）
//   - 分类：衣物分类改成可自定义之后，这里进「分类管理」改名 / 增删
//   - 数据：导出 JSON、清空数据、查看存储与图片占用
//   - 抠图 / 天气：抠图走系统能力；天气两条通道二选一（系统 WeatherKit / 和风天气备用通道）
//   - 关于：版本、系统信息
//
//  导出的是「数据 + 图片文件名清单」：图片本身在本地沙箱里，导出文件里只记文件名。
//  清空数据会连本地图片文件一起删掉，所以这里做了两次确认。
//

import SwiftUI

final class SettingsModel: ObservableObject {
    static let version = "1.0.0"

    @Published var settings = AppSettings()
    @Published var clothingCount = 0
    @Published var outfitCount = 0
    @Published var inspirationCount = 0
    @Published var storageText = ""
    @Published var imageText = ""
    @Published var lastCityName = ""
    @Published var weatherAvailable = WeatherAPI.shared.isAvailable
    /// 天气来源（系统 WeatherKit / 和风天气），以及和风天气那条通道的配置
    @Published var provider: WeatherProvider = WeatherAPI.shared.provider
    @Published var qweatherKey = ""
    @Published var qweatherHost = QWeatherService.defaultHost
    @Published var qweatherStatus = ""
    @Published var testing = false
    /// 衣物分类（可自定义）
    @Published var categoryText = ""
    @Published var cutoutSupported = CutoutService.shared.isSupported
    @Published var exportURL: URL?

    private var configuredQWeatherKey = ""
    private var configuredQWeatherHost = QWeatherService.defaultHost

    init() {
        refresh()
        AppState.shared.bus.on(.settingsChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async {
                self?.settings = Database.shared.getSettings()
            }
        }
        for event in [AppEvent.clothingChange, .outfitChange, .inspirationChange] {
            AppState.shared.bus.on(event, ctx: self) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshStats() }
            }
        }
        AppState.shared.bus.on(.weatherChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshWeather() }
        }
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
    }

    func refresh() {
        settings = Database.shared.getSettings()
        refreshStats()
        refreshStorage()
        refreshCategories()
        refreshWeather()
    }

    func refreshCategories() {
        let list = Database.shared.listCategories()
        categoryText = list.isEmpty ? "" : "\(list.count) 个 · " + list.joined(separator: " / ")
    }

    func refreshStats() {
        clothingCount = Database.shared.listClothing().count
        outfitCount = Database.shared.listOutfits().count
        inspirationCount = Database.shared.listInspirations().count
    }

    func refreshStorage() {
        let used = Storage.shared.usedSizeKB()
        let images = ImageStore.shared.imagesStat()
        storageText = "\(used) KB"
        imageText = "\(images.count) 张 · 约 \(Self.formatSize(images.sizeKB))"
    }

    func refreshWeather() {
        let config = WeatherAPI.shared.getConfig()
        lastCityName = config.lastCity?.name ?? ""
        provider = config.currentProvider
        configuredQWeatherKey = config.qweatherKey
        configuredQWeatherHost = config.qweatherHost
        // 正在输入的框里还有字的话别覆盖掉（比如刚打开键盘）
        if qweatherKey.isEmpty { qweatherKey = config.qweatherKey }
        qweatherHost = config.qweatherHost
        weatherAvailable = WeatherAPI.shared.isAvailable
    }

    /* ==================== 天气来源 ==================== */

    /// 切换天气来源（系统 / 和风天气），立刻写进本地配置
    func setProvider(_ value: WeatherProvider) {
        provider = value
        Database.shared.saveWeatherConfig { config in
            config.provider = value.rawValue
            config.enabled = true
        }
        refreshWeather()
        if value == .qweather, !qweatherKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 换到和风天气、Key 也填好了：顺手测一次，用户不用自己找按钮
            testQWeather()
        }
    }

    /// 把 Key / Host 存进配置；`test` 为 true 时再跑一次连通性自检
    func commitQWeather(test: Bool) {
        let key = qweatherKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = QWeatherService.normalize(host: qweatherHost)
        qweatherKey = key
        qweatherHost = host
        guard key != configuredQWeatherKey || host != configuredQWeatherHost else {
            if test { testQWeather() }
            return
        }
        Database.shared.saveWeatherConfig { config in
            config.qweatherKey = key
            config.qweatherHost = host
            config.enabled = true
        }
        configuredQWeatherKey = key
        configuredQWeatherHost = host
        ToastCenter.shared.show(key.isEmpty ? "已清空和风天气的 Key" : "已保存，正在测试连通性…")
        if test || !key.isEmpty { testQWeather() }
    }

    /// 和风天气连通性自检：用上次用过的城市（没有就用当前位置）取一次实况
    func testQWeather() {
        guard !testing else { return }
        testing = true
        qweatherStatus = "正在测试…"
        Task {
            do {
                let snapshot = try await WeatherAPI.shared.testQWeather()
                let summary = [snapshot.text, snapshot.temp.isEmpty ? "" : snapshot.temp + "℃"]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                await MainActor.run {
                    testing = false
                    qweatherStatus = "已连通 · \(summary)"
                    ToastCenter.shared.show("和风天气已连通：\(summary)")
                    Haptic.success()
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "测试失败"
                await MainActor.run {
                    testing = false
                    qweatherStatus = message
                    ToastCenter.shared.show("和风天气测试失败")
                }
            }
        }
    }

    /* ==================== 显示设置 ==================== */

    func setShowLastWorn(_ value: Bool) {
        Database.shared.saveSettings { $0.showLastWorn = value }
        settings = Database.shared.getSettings()
    }

    /* ==================== 导出 ==================== */

    func exportToFile() {
        let name = "我的衣橱-\(DateUtil.today()).json"
        guard let url = ImageStore.shared.writeTextFile(
            directory: ImageStore.shared.exportsDirectory,
            name: name,
            content: Database.shared.exportJSONString()
        ) else {
            ToastCenter.shared.show("导出失败，请重试")
            return
        }
        exportURL = url
    }

    func copyJSON() {
        UIPasteboard.general.string = Database.shared.exportJSONString()
        ToastCenter.shared.show("已复制到剪贴板")
    }

    /* ==================== 清空数据 ==================== */

    func clearAll() {
        Database.shared.clearAll()
        ImageStore.shared.clearImages()
        refresh()
        Haptic.success()
        ToastCenter.shared.show("已清空")
    }

    static func formatSize(_ kb: Int) -> String {
        if kb <= 0 { return "0 KB" }
        if kb < 1024 { return "\(kb) KB" }
        return String(format: "%.1f MB", Double(kb) / 1024.0)
    }
}

struct SettingsView: View {
    var isActive: Bool = true

    @StateObject private var model = SettingsModel()
    @State private var showExportOptions = false
    @State private var showShareSheet = false
    @State private var confirmClear = false
    @State private var confirmClearAgain = false
    @State private var showCategoryEditor = false
    @FocusState private var weatherFieldFocused: Bool

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SectionTitle(text: "显示")
                displayCard

                SectionTitle(text: "衣橱")
                categoryCard

                SectionTitle(text: "数据")
                dataCard

                SectionTitle(text: "抠图")
                cutoutCard

                SectionTitle(text: "天气")
                weatherCard

                SectionTitle(text: "关于")
                aboutCard
            }
            .padding(Theme.pagePadding)
            .padding(.bottom, 40)
        }
        .background(Theme.bg)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isActive) { _, active in
            // 图片占用这类信息只有回到本页时才需要重新算
            if active { model.refresh() }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = model.exportURL {
                ActivityView(items: [url])
            }
        }
        .sheet(isPresented: $showCategoryEditor) {
            CategoryEditorSheet {
                model.refreshCategories()
            }
        }
        .alert("清空数据", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) { confirmClearAgain = true }
        } message: {
            Text("会删除全部衣物、穿搭、灵感，以及本地保存的图片文件（设置保留）。此操作不可恢复。")
        }
        .alert("再确认一次", isPresented: $confirmClearAgain) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { model.clearAll() }
        } message: {
            Text("确定要清空全部数据吗？")
        }
    }

    /* ==================== 显示 ==================== */

    private var displayCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("显示最近穿着日期")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.settings.showLastWorn },
                    set: { model.setShowLastWorn($0) }
                ))
                .labelsHidden()
                .tint(Theme.primary)
            }
            .frame(height: Theme.cellHeight)
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    /* ==================== 数据 ==================== */

    /// 衣物分类（可自定义：改名 / 增删都在 CategoryEditorSheet 里）
    private var categoryCard: some View {
        VStack(spacing: 0) {
            TapRow(
                label: "衣物分类",
                value: "管理",
                placeholder: "管理",
                showDivider: false
            ) {
                showCategoryEditor = true
            }
            Text(model.categoryText.isEmpty ? "默认分类：\(Wardrobe.categories.joined(separator: " / "))" : model.categoryText)
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textLight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    private var dataCard: some View {
        VStack(spacing: 0) {
            ValueRow(
                label: "衣物 / 穿搭 / 灵感",
                value: "\(model.clothingCount) / \(model.outfitCount) / \(model.inspirationCount)"
            )
            ValueRow(label: "本地存储占用", value: model.storageText)
            ValueRow(label: "图片文件", value: model.imageText)
            TapRow(label: "导出 JSON", value: "导出", placeholder: "导出") {
                showExportOptions = true
            }
            // 挂在被点的那一行上：系统弹层会贴着这一行弹出，而不是被摆到页面底部
            .confirmationDialog("导出 JSON", isPresented: $showExportOptions, titleVisibility: .visible) {
                Button("导出为 JSON 文件") {
                    model.exportToFile()
                    if model.exportURL != nil { showShareSheet = true }
                }
                Button("复制到剪贴板") { model.copyJSON() }
                Button("取消", role: .cancel) {}
            }
            TapRow(label: "清空数据", value: "清空", placeholder: "清空", danger: true, showDivider: false) {
                confirmClear = true
            }
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    /* ==================== 抠图 ==================== */

    private var cutoutCard: some View {
        VStack(spacing: 0) {
            ValueRow(
                label: "抠图方式",
                value: model.cutoutSupported ? "系统视觉框架（本机）" : "仅手动涂抹"
            )
            ValueRow(
                label: "需要联网吗",
                value: "不需要",
                showDivider: false
            )
            Text(model.cutoutSupported
                 ? "抠图直接用 iOS 的 Vision 框架在本机完成，图片不会离开这台设备，也不再需要云端接口地址和 Key。抠不干净时可以用橡皮擦擦掉多余部分，用画笔把抠多的部分涂回来。"
                 : "当前系统版本不支持自动抠图（需要 iOS 17 及以上），可以用橡皮擦和画笔手动处理。")
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textLight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    /* ==================== 天气 ==================== */

    private var weatherCard: some View {
        VStack(spacing: 0) {
            // 天气来源二选一：系统 WeatherKit / 和风天气（备用通道）
            HStack(spacing: 8) {
                Text("天气来源")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.textSub)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { model.provider },
                    set: { model.setProvider($0) }
                )) {
                    ForEach(WeatherProvider.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            .frame(height: Theme.cellHeight)
            .cellDivider()

            if model.provider == .qweather {
                qweatherFields
            } else {
                ValueRow(
                    label: "系统天气",
                    value: model.weatherAvailable ? "可用" : "当前签名没有权限"
                )
            }

            ValueRow(
                label: "最近用的城市",
                value: model.lastCityName,
                placeholder: "未选择",
                showDivider: false
            )

            Text(model.provider.note + "\n今天取实况、未来几天取预报，两条通道都不提供历史天气（过去的日子手填）。定位只在需要时用一次。")
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textLight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    /// 和风天气那条通道的配置：Key + API Host + 连通性自检
    private var qweatherFields: some View {
        VStack(spacing: 0) {
            FormRow(label: "API Key") {
                TextField("粘贴和风天气的 Key", text: $model.qweatherKey)
                    .font(.system(size: Theme.fontBody))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($weatherFieldFocused)
                    .onSubmit { model.commitQWeather(test: true) }
            }

            FormRow(label: "API Host") {
                TextField(QWeatherService.defaultHost, text: $model.qweatherHost)
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textSub)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($weatherFieldFocused)
                    .onSubmit { model.commitQWeather(test: false) }
            }

            TapRow(
                label: "测试连通性",
                value: model.testing ? "测试中…" : "测试",
                placeholder: "测试"
            ) {
                weatherFieldFocused = false
                model.commitQWeather(test: true)
            }

            if !model.qweatherStatus.isEmpty {
                Text(model.qweatherStatus)
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(model.qweatherStatus.hasPrefix("已连通") ? Theme.primaryDark : Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
    }

    /* ==================== 关于 ==================== */

    private var aboutCard: some View {
        VStack(spacing: 0) {
            ValueRow(label: "版本", value: SettingsModel.version)
            ValueRow(label: "系统", value: "\(SystemInfo.current.systemName) \(SystemInfo.current.systemVersion)")
            ValueRow(label: "数据存储", value: "仅本机", showDivider: false)
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }
}
