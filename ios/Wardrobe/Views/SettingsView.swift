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
    /// 版本号直接读 App 包里的（跟着 Xcode 的 MARKETING_VERSION 走，这里不用手动同步）
    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

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
    /// 完整备份（数据 + 图片）的文件夹 URL，生成成功后交给系统分享面板
    @Published var backupURL: URL?
    @Published var backupText = ""
    @Published var backingUp = false
    @Published var restoring = false
    @Published var restoreMessage: String?

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

    /// 衣橱卡片上是否显示单次成本角标
    func setShowCost(_ value: Bool) {
        Database.shared.saveSettings { $0.showCostPerWear = value }
        settings = Database.shared.getSettings()
    }

    /// 衣橱网格每行几件
    func setGridColumns(_ value: Int) {
        Database.shared.saveSettings { $0.gridColumns = value == 4 ? 4 : 3 }
        settings = Database.shared.getSettings()
    }

    /// 外观：system / light / dark（写入设置后由 App 入口统一应用）
    func setAppearance(_ value: String) {
        Database.shared.saveSettings { $0.appearance = value }
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

    /* ==================== 完整备份 / 恢复 ==================== */

    /// 生成「数据 + 图片」的完整备份文件夹，之后交给系统分享面板（存到「文件」/ AirDrop 都行）
    func makeBackup() {
        guard !backingUp else { return }
        backingUp = true
        defer { backingUp = false }
        do {
            let result = try BackupService.makeBackup()
            backupURL = result.url
            backupText = result.summary.folderName + " · 含 \(result.summary.imageCount) 张图片"
            Haptic.success()
        } catch {
            ToastCenter.shared.show((error as? LocalizedError)?.errorDescription ?? "备份失败")
        }
    }

    /// 从备份文件夹恢复（覆盖当前数据）
    func restore(from folder: URL) {
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            let result = try BackupService.restore(from: folder)
            refresh()
            Haptic.success()
            restoreMessage = """
            已恢复 \(result.clothing) 件衣物、\(result.outfits) 套穿搭、\(result.inspirations) 条灵感（\(result.imageCount) 张图片）。
            """
        } catch {
            restoreMessage = (error as? LocalizedError)?.errorDescription ?? "恢复失败"
        }
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
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.floatingBarInset) private var floatingBarInset
    @State private var showExportOptions = false
    @State private var showShareSheet = false
    @State private var showBackupSheet = false
    @State private var showRestorePicker = false
    @State private var confirmClear = false
    @State private var confirmClearAgain = false
    @State private var showCategoryEditor = false
    @State private var showStats = false
    @State private var showTags = false
    @State private var showDeclutter = false
    @State private var confirmRestore = false
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
                wardrobeToolsCard

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
            .padding(.bottom, Theme.floatingBarSpace)
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
        .sheet(isPresented: $showBackupSheet, onDismiss: { model.backupURL = nil }) {
            if let url = model.backupURL {
                ActivityView(items: [url])
            }
        }
        .sheet(isPresented: $showRestorePicker) {
            FolderPicker { url in
                showRestorePicker = false
                model.restore(from: url)
            } onCancel: {
                showRestorePicker = false
            }
        }
        .sheet(isPresented: $showCategoryEditor) {
            CategoryEditorSheet {
                model.refreshCategories()
            }
        }
        .navigationDestination(isPresented: $showStats) { StatsView() }
        .navigationDestination(isPresented: $showTags) { TagManagerView() }
        .navigationDestination(isPresented: $showDeclutter) { DeclutterView() }
        .alert("恢复备份", isPresented: $confirmRestore) {
            Button("取消", role: .cancel) {}
            Button("选择备份文件夹", role: .destructive) { showRestorePicker = true }
        } message: {
            Text("会覆盖当前的全部数据（衣物、穿搭、灵感、图片）。建议先点「完整备份」把现在的数据存一份。")
        }
        .messageDialog(
            isPresented: Binding(
                get: { model.restoreMessage != nil },
                set: { if !$0 { model.restoreMessage = nil } }
            ),
            title: "恢复备份",
            message: model.restoreMessage ?? ""
        )
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
            .cellDivider()

            HStack {
                Text("卡片上显示单次成本")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.settings.showCostPerWear },
                    set: { model.setShowCost($0) }
                ))
                .labelsHidden()
                .tint(Theme.primary)
            }
            .frame(height: Theme.cellHeight)
            .cellDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text("衣橱每行显示")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.text)
                Picker("每行件数", selection: Binding(
                    get: { model.settings.gridColumns },
                    set: { model.setGridColumns($0) }
                )) {
                    Text("3 件").tag(3)
                    Text("4 件").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.top, 12)
            .padding(.bottom, 14)
            .cellDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text("外观")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.text)
                Picker("外观", selection: Binding(
                    get: { model.settings.appearance },
                    set: { model.setAppearance($0) }
                )) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.top, 12)
            .padding(.bottom, 14)
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

            TapRow(
                label: "完整备份",
                value: model.backingUp ? "打包中…" : "备份",
                placeholder: "备份"
            ) {
                model.makeBackup()
                if model.backupURL != nil { showBackupSheet = true }
            }
            if !model.backupText.isEmpty {
                Text("上次打包：" + model.backupText)
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }

            TapRow(label: "恢复备份", value: "恢复", placeholder: "恢复") {
                confirmRestore = true
            }

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

    /// 衣橱相关的几个工具页入口（统计 / 断舍离 / 标签）
    private var wardrobeToolsCard: some View {
        VStack(spacing: 0) {
            TapRow(label: "衣橱统计", value: "单次成本 · 常青树 · 闲置", placeholder: "查看") {
                showStats = true
            }
            TapRow(label: "标签管理", value: "改名 · 合并 · 删除", placeholder: "管理") {
                showTags = true
            }
            TapRow(label: "断舍离", value: "建议处理 · 已处置", placeholder: "查看", showDivider: false) {
                showDeclutter = true
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
