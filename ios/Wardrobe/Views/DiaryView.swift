//
//  DiaryView.swift —— 穿搭日记（对应 pages/diary）
//
//  结构：上面是月历（有记录的日期打点），下面是选中那天的穿搭列表。
//  一天可以有多套穿搭，每套都能单独设封面（用关联衣物的图，或从相册选一张）。
//
//  天气卡片：记下那天的城市 / 温度 / 天气。
//   - 手填永远可用（不依赖任何接口，也能离线用）
//   - 点「获取天气」按城市自动抓：今天取实况、未来几天取预报，过去的日子系统不提供、
//     会明确提示手填（对应小程序里「历史天气不在免费额度」的处理）
//

import SwiftUI

/// 月历里的一格 + 角标 / 选中态
struct DiaryCell: Identifiable, Hashable {
    var cell: CalendarCell
    var count: Int
    var selected: Bool

    var id: String { cell.date }
}

struct OutfitThumb: Identifiable, Hashable {
    var id: String
    var image: String
}

/// 当天穿搭列表里的一项（展示用字段，对应 diary.js 的 buildOutfits 结果）
struct DiaryOutfitRow: Identifiable, Hashable {
    var id: String
    var cover: String
    var hasCover: Bool
    var note: String
    var thumbs: [OutfitThumb]
    var more: Int
    var countText: String
}

final class DiaryModel: ObservableObject {
    /// 手动选天气时的常用选项（接口返回的其它说法会自动补进胶囊里）
    static let weatherOptions = ["晴", "多云", "阴", "小雨", "中雨", "大雨", "雷阵雨", "雪", "雾", "霾"]
    private static let maxThumbs = 6

    @Published var monthKey = DateUtil.monthKeyOf(DateUtil.today())
    @Published var selectedDate = DateUtil.today()
    @Published var cells: [DiaryCell] = []
    @Published var outfits: [DiaryOutfitRow] = []
    @Published var totalOutfits = 0
    @Published var totalDays = 0

    @Published var weatherCity = ""
    @Published var weatherTemp = ""
    @Published var weatherText = ""
    @Published var weatherChips: [String] = []
    @Published var weatherSourceText = ""
    @Published var fetching = false
    /// 只在「没有别的城市可用」时弹城市选择
    @Published var weatherMessage: String?

    private var weatherRecord: WeatherRecord?
    private let today = DateUtil.today()
    /// 已经自动抓过的「日期 | 城市」：同一个不再重复请求（配好天气来源后自动获取用）
    private var autoFetched: Set<String> = []
    private var autoFetching = false

    init() {
        refresh()
        // 任何地方的穿搭 / 衣物变化都会派发事件，这里跟着刷新
        AppState.shared.bus.on(.outfitChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
    }

    var monthTitle: String { DateUtil.formatMonthTitle(monthKey) }
    var weekLabels: [String] { DateUtil.weekLabels }
    var selectedLabel: String {
        let weekday = "周" + DateUtil.weekLabels[weekdayIndex(of: selectedDate)]
        return DateUtil.friendlyDate(selectedDate) + " · " + weekday
    }
    var isTodaySelected: Bool { selectedDate == today }
    /// 城市里有没有可用坐标（没有的话取天气时会用当前位置）
    var hasCityCoordinate: Bool { parsedCoordinate != nil }

    /* ==================== 数据 ==================== */

    func refresh() {
        let counts = Database.shared.countOutfitsByDate()
        let dates = Database.shared.listOutfitDates()

        cells = DateUtil.monthGrid(monthKey).map { cell in
            DiaryCell(cell: cell, count: counts[cell.date] ?? 0, selected: cell.date == selectedDate)
        }
        outfits = buildOutfits(selectedDate)
        totalOutfits = Database.shared.listOutfits().count
        totalDays = dates.count
        loadWeather(selectedDate)
    }

    /// 当天穿搭 + 展示用字段（封面、衣物缩略图）
    private func buildOutfits(_ date: String) -> [DiaryOutfitRow] {
        let list = Database.shared.listOutfits(date: date)
        guard !list.isEmpty else { return [] }

        // 衣物一次性读出来做成 map，别在循环里反复读
        var map: [String: ClothingItem] = [:]
        Database.shared.listClothing().forEach { map[$0.id] = $0 }

        return list.map { outfit in
            let items = outfit.clothingIds.compactMap { map[$0] }
            let thumbs = items.prefix(Self.maxThumbs).map {
                OutfitThumb(id: $0.id, image: $0.coverImage.isEmpty ? $0.originalImage : $0.coverImage)
            }
            let firstImage = thumbs.first?.image ?? ""
            let seasons = outfit.seasons
            return DiaryOutfitRow(
                id: outfit.id,
                cover: outfit.cover.isEmpty ? firstImage : outfit.cover,
                hasCover: !outfit.cover.isEmpty,
                note: outfit.note,
                thumbs: Array(thumbs),
                more: max(0, items.count - thumbs.count),
                // 顺带把「我的搭配」里标的季节显示出来，回看时一眼知道这套属于哪一季
                countText: "\(items.count) 件衣物" + (seasons.isEmpty ? "" : " · " + seasons.joined(separator: "/"))
            )
        }
    }

    private func weekdayIndex(of date: String) -> Int {
        let weekday = Calendar.current.component(.weekday, from: DateUtil.parseDate(date))
        return max(0, min(6, weekday - 1))
    }

    /* ==================== 天气 ==================== */

    /// 把这一天的天气记录搬进界面（选中的日期变了要重新读）
    func loadWeather(_ date: String) {
        var record = Database.shared.getWeather(date) ?? WeatherRecord(date: date)
        if record.city.isEmpty, let last = WeatherAPI.shared.getConfig().lastCity, !last.name.isEmpty {
            // 没记过城市的一天：拿上次用过的城市打个底，切到新日期点「获取天气」就能直接用
            record.city = last.name
            record.cityId = Self.cityIdString(for: last)
        }
        weatherRecord = record
        weatherCity = record.city
        weatherTemp = record.temp
        weatherText = record.text
        weatherChips = buildWeatherChips(record.text)
        weatherSourceText = sourceText(record)
        autoFetchIfNeeded()
    }

    private func buildWeatherChips(_ text: String) -> [String] {
        // 接口给的说法如果不在常用列表里（比如「浮尘」），补一个胶囊，免得不显示
        var options = Self.weatherOptions
        if !text.isEmpty, !options.contains(text) { options.append(text) }
        return options
    }

    private func sourceText(_ record: WeatherRecord) -> String {
        if record.temp.isEmpty && record.text.isEmpty { return "" }
        if record.source == "api" {
            return "自动获取（\(WeatherAPI.shared.provider.title)）· " + DateUtil.timeText(record.updateTime)
        }
        return "手动填写"
    }

    /// 配好天气来源之后：打开日记页、看到空白的一天，就自动把当天的天气抓回来
    /// （只在「已经有城市坐标」时自动跑，免得一进页面就弹定位权限）
    private func autoFetchIfNeeded() {
        guard !fetching, !autoFetching else { return }
        guard WeatherAPI.shared.isConfigured() else { return }
        guard selectedDate >= today else { return }

        let record = weatherRecord ?? WeatherRecord(date: selectedDate)
        guard record.temp.isEmpty, record.text.isEmpty else { return }
        let key = selectedDate + "|" + record.cityId
        guard !autoFetched.contains(key), !record.cityId.isEmpty else { return }

        autoFetched.insert(key)
        autoFetching = true
        Task {
            await fetchWeather(silent: true)
            autoFetching = false
        }
    }

    func updateTemp(_ value: String) {
        weatherTemp = value
        saveWeather(manual: true) { record in
            record.temp = value.trimmingCharacters(in: .whitespacesAndNewlines)
            record.icon = ""
        }
    }

    func tapWeatherText(_ value: String) {
        let next = value == weatherText ? "" : value
        weatherText = next
        weatherChips = buildWeatherChips(next)
        saveWeather(manual: true) { record in
            record.text = next
            record.icon = ""
        }
    }

    /// 任何一次手填都算「手动填写」，并且顺手清掉上一次自动获取的信息
    private func saveWeather(manual: Bool, patch: (inout WeatherRecord) -> Void) {
        let saved = Database.shared.saveWeather(selectedDate) { record in
            record.source = manual ? "manual" : "api"
            patch(&record)
        }
        // 记录被清空（城市、温度、天气都没了）时留着内存里那份，接着取天气还能用上城市
        weatherRecord = saved ?? weatherRecord ?? WeatherRecord(date: selectedDate)
        if !manual {
            loadWeather(selectedDate)
        } else {
            weatherSourceText = sourceText(weatherRecord ?? WeatherRecord(date: selectedDate))
        }
    }

    /// 选城市（带坐标，能直接取天气）
    func pickCity(_ city: CityRef) {
        weatherCity = city.name
        Database.shared.saveWeather(selectedDate) { record in
            record.city = city.name
            record.cityId = Self.cityIdString(for: city)
        }
        Database.shared.saveWeatherConfig { config in
            config.enabled = true
            config.lastCity = city
        }
        loadWeather(selectedDate)
        Task { await fetchWeather() } // 选完城市顺手把那天的天气抓回来
    }

    /// 手填城市名（没有坐标，取天气时用当前位置）
    func setCityManually(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        weatherCity = trimmed
        Database.shared.saveWeather(selectedDate) { record in
            record.city = trimmed
            record.cityId = ""
        }
        loadWeather(selectedDate)
    }

    /// 自动获取（对应 diary.js 的 fetchWeather）
    /// - Parameter silent: 自动抓取时用：失败不弹框（用户没主动点，别打断他）
    func fetchWeather(silent: Bool = false) async {
        guard !fetching else { return }
        let record = weatherRecord ?? WeatherRecord(date: selectedDate)

        // 城市带坐标就直接用；没有坐标时用当前位置（并顺手把城市名记下来）
        var city: CityRef
        if let coordinate = parsedCoordinate {
            city = CityRef(name: record.city.isEmpty ? "当前位置" : record.city, latitude: coordinate.latitude, longitude: coordinate.longitude)
        } else {
            do {
                city = try await WeatherAPI.shared.currentCity()
            } catch {
                if !silent {
                    weatherMessage = (error as? LocalizedError)?.errorDescription ?? "拿不到当前位置"
                }
                return
            }
        }

        fetching = true
        defer { fetching = false }
        do {
            let snapshot = try await WeatherAPI.shared.fetchByDate(city: city, date: selectedDate)
            Database.shared.saveWeather(selectedDate) { item in
                item.city = city.name
                item.cityId = Self.cityIdString(for: city)
                item.temp = snapshot.temp
                item.text = snapshot.text
                item.icon = snapshot.icon
                item.source = "api"
            }
            Database.shared.saveWeatherConfig { config in
                config.enabled = true
                config.lastCity = city
            }
            loadWeather(selectedDate)
            let summary = [snapshot.text, snapshot.temp.isEmpty ? "" : snapshot.temp + "℃"]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            ToastCenter.shared.show("已获取 \(summary)")
        } catch {
            if !silent {
                weatherMessage = (error as? LocalizedError)?.errorDescription ?? "获取失败"
            }
        }
    }

    /// cityId 里存的是「纬度,经度」，这样数据结构和小程序完全一致
    static func cityIdString(for city: CityRef) -> String {
        guard city.hasCoordinate else { return "" }
        return String(format: "%.4f,%.4f", city.latitude, city.longitude)
    }

    private var parsedCoordinate: (latitude: Double, longitude: Double)? {
        let raw = weatherRecord?.cityId ?? ""
        let parts = raw.split(separator: ",")
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]) else { return nil }
        return (latitude, longitude)
    }

    /* ==================== 日历 ==================== */

    func select(_ date: String) {
        selectedDate = date
        // 点到上/下个月的补位格子时，顺手把月历也切过去
        let key = DateUtil.monthKeyOf(date)
        if key != monthKey { monthKey = key }
        refresh()
    }

    func switchMonth(_ delta: Int) {
        // addMonths 收的是 'YYYY-MM-DD'，所以补上 1 号再算
        let key = DateUtil.monthKeyOf(DateUtil.addMonths(monthKey + "-01", delta))
        monthKey = key
        selectedDate = key == DateUtil.monthKeyOf(today) ? today : key + "-01"
        refresh()
    }

    func backToToday() {
        monthKey = DateUtil.monthKeyOf(today)
        selectedDate = today
        refresh()
    }

    /* ==================== 封面 ==================== */

    /// 关联衣物里能当封面的那些
    func coverCandidates(_ outfitId: String) -> [ClothingItem] {
        guard let outfit = Database.shared.getOutfit(outfitId) else { return [] }
        return Database.shared.listClothingByIds(outfit.clothingIds)
            .filter { !$0.coverImage.isEmpty || !$0.originalImage.isEmpty }
    }

    func applyCover(_ outfitId: String, cover: String) {
        guard let outfit = Database.shared.getOutfit(outfitId) else { return }
        Database.shared.updateOutfit(outfitId) { item in
            item.cover = cover
        }
        // 换掉的旧封面如果只属于这套穿搭，顺手删掉，别让图片目录越攒越大
        if !outfit.cover.isEmpty, outfit.cover != cover, !Database.shared.isImageInUse(outfit.cover) {
            ImageStore.shared.removeFile(outfit.cover)
        }
        ToastCenter.shared.show(cover.isEmpty ? "已恢复默认封面" : "封面已更新")
        refresh()
    }
}

struct DiaryView: View {
    var isActive: Bool = true

    @StateObject private var model = DiaryModel()
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.floatingBarInset) private var floatingBarInset
    @State private var detailId: String?
    @State private var showAddOutfit = false
    @State private var coverTarget: String?
    @State private var coverDialog = false
    @State private var showClothingCoverPicker = false
    @State private var showImagePicker = false
    @State private var showCityPicker = false
    @State private var showManualCityInput = false

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                calendar
                dayBar
                weatherCard
                outfitList
            }
            .padding(Theme.pagePadding)
            .padding(.bottom, 90)
        }
        .background(Theme.bg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("穿搭日记")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) { fab }
        .navigationDestination(item: $detailId) { id in
            OutfitDetailView(outfitId: id)
        }
        .navigationDestination(isPresented: $showAddOutfit) {
            OutfitEditView(outfitId: "", date: model.selectedDate)
        }
        .onChange(of: isActive) { _, active in
            if active { model.refresh() } // 从编辑页 / 详情页回来时兜底刷新一次
        }
        .sheet(isPresented: $showCityPicker) {
            CityPickerSheet(
                onPick: { city in
                    showCityPicker = false
                    model.pickCity(city)
                },
                onManual: {
                    showCityPicker = false
                    showManualCityInput = true
                }
            )
            .presentationDetents([.medium, .large])
        }
        .textInputDialog(
            isPresented: $showManualCityInput,
            title: "城市",
            placeholder: "例如：杭州",
            initialText: model.weatherCity
        ) { value in
            model.setCityManually(value)
        }
        .messageDialog(
            isPresented: Binding(
                get: { model.weatherMessage != nil },
                set: { if !$0 { model.weatherMessage = nil } }
            ),
            title: "没能拿到天气",
            message: (model.weatherMessage ?? "")
        )
    }

    /* ==================== 月历 ==================== */

    private var calendar: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.switchMonth(-1) } label: {
                    Text("‹").font(.system(size: 22)).foregroundStyle(Theme.textSub)
                        .frame(width: 32, height: 32)
                }
                Spacer()
                Text(model.monthTitle)
                    .font(.system(size: Theme.fontTitle, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button { model.switchMonth(1) } label: {
                    Text("›").font(.system(size: 22)).foregroundStyle(Theme.textSub)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            HStack(spacing: 0) {
                ForEach(model.weekLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textLight)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(model.cells) { item in
                    dayCell(item)
                }
            }

            HStack {
                Text("共 \(model.totalOutfits) 套 · 记录 \(model.totalDays) 天")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textSub)
                Spacer()
                Button("回到今天") { model.backToToday() }
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.primary)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.border).frame(height: 0.5)
            }
        }
        .cardStyle(padding: 12)
    }

    private func dayCell(_ item: DiaryCell) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(item.selected ? Theme.primary : Color.clear)
                    .frame(width: 30, height: 30)
                if item.cell.isToday && !item.selected {
                    Circle().stroke(Theme.primary, lineWidth: 1).frame(width: 30, height: 30)
                }
                Text("\(item.cell.day)")
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(dayColor(item))
            }
            .frame(height: 32)

            Circle()
                .fill(item.selected ? Theme.primaryDark : Theme.primary)
                .frame(width: 4, height: 4)
                .opacity(item.count > 0 ? 1 : 0)
                .padding(.bottom, 4)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture { model.select(item.cell.date) }
    }

    private func dayColor(_ item: DiaryCell) -> Color {
        if item.selected { return .white }
        if !item.cell.inMonth { return Theme.textLight }
        if item.cell.isToday { return Theme.primary }
        return Theme.text
    }

    /* ==================== 选中那天 ==================== */

    private var dayBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedLabel)
                    .font(.system(size: Theme.fontTitle, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(model.outfits.count) 套穿搭")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textSub)
            }
            Spacer()
            Button("添加穿搭") { showAddOutfit = true }
                .buttonStyle(AppButtonStyle(kind: .soft, small: true))
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /* ==================== 天气卡片 ==================== */

    private var weatherCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("当天天气")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textSub)
                Spacer()
                if model.fetching {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button("获取天气") {
                        Task { await model.fetchWeather() }
                    }
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.primary)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 2)

            Button {
                showCityPicker = true
            } label: {
                HStack {
                    Text("城市")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.textSub)
                    Spacer()
                    Text(model.weatherCity.isEmpty ? "选择城市" : model.weatherCity)
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(model.weatherCity.isEmpty ? Theme.textLight : Theme.text)
                    Text("›").font(.system(size: 15)).foregroundStyle(Theme.textLight)
                }
                .frame(height: Theme.cellHeight)
            }
            .buttonStyle(.plain)
            .cellDivider()

            HStack {
                Text("温度")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.textSub)
                Spacer()
                TextField(
                    "未填写",
                    text: Binding(
                        get: { model.weatherTemp },
                        set: { model.updateTemp($0) }
                    )
                )
                .font(.system(size: Theme.fontBody))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                Text("℃")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.textSub)
            }
            .frame(height: Theme.cellHeight)
            .cellDivider()

            VStack(alignment: .leading, spacing: 4) {
                Text("天气")
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.textSub)
                    .padding(.top, 12)
                ChipFlow(model.weatherChips, spacing: 6) { value in
                    TagChip(title: value, active: value == model.weatherText) {
                        model.tapWeatherText(value)
                    }
                }
                .padding(.bottom, 6)
            }

            if !model.weatherSourceText.isEmpty {
                Text(model.weatherSourceText)
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } else {
                Text(
                    WeatherAPI.shared.isConfigured()
                    ? "手填即可；也可以点「获取天气」按城市自动获取（来源：\(WeatherAPI.shared.provider.title)）"
                    : "手填即可；想自动获取天气，去「设置 → 天气」选一个来源（系统 WeatherKit 或和风天气）"
                )
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .cardStyle(padding: 12)
    }

    /* ==================== 当天穿搭 ==================== */

    private var outfitList: some View {
        VStack(spacing: 10) {
            if model.outfits.isEmpty {
                EmptyStateView(
                    text: "这天还没有穿搭记录",
                    desc: "点下面的按钮记一套今天的穿搭，之后会出现在这里",
                    actionText: "添加穿搭",
                    action: { showAddOutfit = true }
                )
            } else {
                ForEach(model.outfits) { row in
                    outfitCard(row)
                }
            }
        }
        .padding(.top, 12)
        // 封面相关的两个弹层都由「卡片上的设置封面按钮」触发：挂到卡片列表这一块上，
        // 系统弹层就会贴着它弹，而不是被摆到页面最下边（iOS 26 的气泡按挂载点定位）
        .confirmationDialog("设置封面", isPresented: $coverDialog, titleVisibility: .hidden) {
            if let id = coverTarget, !model.coverCandidates(id).isEmpty {
                Button("用关联衣物的图片") { showClothingCoverPicker = true }
            }
            Button("从相册选一张") { showImagePicker = true }
            Button("恢复默认封面") {
                if let id = coverTarget { model.applyCover(id, cover: "") }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "选一件衣物的图片当封面",
            isPresented: $showClothingCoverPicker,
            titleVisibility: .visible
        ) {
            if let id = coverTarget {
                ForEach(model.coverCandidates(id).prefix(6)) { item in
                    Button(item.name) {
                        let image = item.coverImage.isEmpty ? item.originalImage : item.coverImage
                        model.applyCover(id, cover: image)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .imagePicker(isPresented: $showImagePicker) { datas in
            guard let id = coverTarget, let data = datas.first,
                  let saved = ImageStore.shared.saveData(data, prefix: "outfit-cover") else {
                ToastCenter.shared.show("选图失败，请重试")
                return
            }
            model.applyCover(id, cover: saved)
        }
    }

    private func outfitCard(_ row: DiaryOutfitRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if row.cover.isEmpty {
                        RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous)
                            .fill(Theme.imageWell)
                            .overlay(
                                Text("暂无封面")
                                    .font(.system(size: Theme.fontTiny))
                                    .foregroundStyle(Theme.textLight)
                            )
                    } else {
                        StoredImage(path: row.cover, mode: .fit, maxPixel: 700)
                            .background(Theme.imageWell)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
                    }
                }
                .frame(width: 110, height: 130)

                Button {
                    coverTarget = row.id
                    coverDialog = true
                } label: {
                    Text(row.hasCover ? "换封面" : "设封面")
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Color(hex: 0x2E2A28).opacity(0.55))
                        .clipShape(Capsule())
                        .padding(5)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if !row.thumbs.isEmpty {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(38), spacing: 5), count: 4),
                        spacing: 5
                    ) {
                        ForEach(row.thumbs) { thumb in
                            StoredImage(path: thumb.image, mode: .fill, maxPixel: 300)
                                .frame(width: 38, height: 38)
                                .background(Theme.imageWell)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
                        }
                        if row.more > 0 {
                            Text("+\(row.more)")
                                .font(.system(size: Theme.fontTiny))
                                .foregroundStyle(Theme.textSub)
                                .frame(width: 38, height: 38)
                                .background(Theme.bg)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
                        }
                    }
                }
                Spacer(minLength: 0)
                if !row.note.isEmpty {
                    Text(row.note)
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                }
                Text(row.countText)
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { detailId = row.id }
    }

    private var fab: some View {
        Button {
            showAddOutfit = true
        } label: {
            Text("+")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Theme.primary)
                .clipShape(Circle())
                .shadow(color: Theme.primary.opacity(0.38), radius: 16, x: 0, y: 6)
        }
        .padding(.trailing, 20)
        // 悬浮底栏浮在页面之上，按钮要抬到它上方
        .padding(.bottom, floatingBarInset + 16)
    }
}

/* ==================== 城市选择（对应 diary.js 的 searchCity / inputCityName） ==================== */

struct CityPickerSheet: View {
    let onPick: (CityRef) -> Void
    let onManual: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var results: [CityRef] = []
    @State private var searching = false
    @State private var locating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("选择城市")
                .font(.system(size: Theme.fontTitle, weight: .semibold))
                .padding(.top, 18)
                .padding(.bottom, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textLight)
                TextField("搜索城市，例如：杭州 / 三亚 / 京都", text: $keyword)
                    .font(.system(size: Theme.fontSmall))
                    .submitLabel(.search)
                    .onSubmit { search() }
                if searching {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.bg)
            .clipShape(Capsule())
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Button {
                    useCurrentLocation()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill").font(.system(size: 11))
                        Text(locating ? "定位中…" : "用当前位置")
                    }
                }
                .buttonStyle(AppButtonStyle(kind: .soft, small: true))
                .disabled(locating)

                Button("手填城市名") { onManual() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, small: true))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if let error {
                Text(error)
                    .font(.system(size: Theme.fontCaption))
                    .foregroundStyle(Theme.textSub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(results, id: \.self) { city in
                        Button {
                            onPick(city)
                        } label: {
                            HStack {
                                Text(city.name)
                                    .font(.system(size: Theme.fontBody))
                                    .foregroundStyle(Theme.text)
                                if !city.adm.isEmpty {
                                    Text(city.adm)
                                        .font(.system(size: Theme.fontCaption))
                                        .foregroundStyle(Theme.textLight)
                                }
                                Spacer()
                                Text("›").foregroundStyle(Theme.textLight)
                            }
                            .frame(height: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .cellDivider()
                    }
                    if results.isEmpty && !keyword.isEmpty && !searching {
                        Text("没找到这个城市")
                            .font(.system(size: Theme.fontSmall))
                            .foregroundStyle(Theme.textLight)
                            .padding(.top, 40)
                    }
                }
            }
            .padding(.top, 8)
        }
        .background(Theme.card)
        .appToast()
    }

    private func search() {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        searching = true
        error = nil
        Task {
            do {
                let list = try await WeatherAPI.shared.searchCity(word)
                await MainActor.run {
                    results = list
                    searching = false
                    if list.isEmpty { error = "没找到这个城市" }
                }
            } catch {
                await MainActor.run {
                    searching = false
                    results = []
                    self.error = (error as? LocalizedError)?.errorDescription ?? "搜索失败，请重试"
                }
            }
        }
    }

    private func useCurrentLocation() {
        locating = true
        error = nil
        Task {
            do {
                let city = try await WeatherAPI.shared.currentCity()
                await MainActor.run {
                    locating = false
                    onPick(city)
                }
            } catch {
                await MainActor.run {
                    locating = false
                    self.error = (error as? LocalizedError)?.errorDescription ?? "拿不到当前位置"
                }
            }
        }
    }
}
