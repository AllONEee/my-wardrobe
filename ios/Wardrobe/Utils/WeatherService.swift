//
//  WeatherService.swift —— 天气（替代小程序的 utils/weather.js）
//
//  两条通道，在设置里二选一（见 WeatherProvider）：
//   1. system  —— iOS 自带的 WeatherKit，不用 Key，但要付费开发者账号 + 后台开 WeatherKit 能力
//   2. qweather —— 和风天气（备用通道，见 Utils/QWeatherService.swift），免费账号填个 Key 就能用
//  页面只调这里的 fetchByDate / searchCity，不关心当前用的是哪条通道。
//
//  对外接口与小程序保持一致（fetchByDate(city, date) -> { temp, text, icon, kind }）：
//   - 今天：取实况
//   - 未来几天：取逐日预报（WeatherKit 大约覆盖未来 10 天）
//   - 过去的日子：系统不提供历史天气，明确抛错提示手填，绝不阻塞记录
//   - 城市：用系统地理编码（CLGeocoder）按关键字搜索，或直接用当前位置
//
//  工程约定：
//   1. 需要 Apple Developer 后台为 App ID 打开 WeatherKit 能力（entitlement 见 Config/Wardrobe.entitlements）
//   2. 定位权限只在用户点「获取天气」时申请，拒绝也不影响手填
//   3. 取到的数据由日记页写进本地存储（Database.saveWeather），断网也能翻看
//

import CoreLocation
import Foundation
import WeatherKit

/// 天气相关的错误（都带一句给用户看的话）
enum WeatherError: LocalizedError {
    case unsupportedSystem
    case notAuthorized
    case notEntitled
    case locationFailed(String)
    case noCity
    case pastDate
    case outOfForecastRange(Int)
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            return "当前系统版本不支持 WeatherKit。可以到「设置 → 天气」把来源换成「和风天气」，或者手填城市、温度和天气"
        case .notAuthorized:
            return "没有定位权限，可以在「设置 → 隐私与安全性 → 定位服务」里打开，或者手填城市"
        case .notEntitled:
            return "系统天气（WeatherKit）用不了：当前签名没有这个权限。免费个人开发者账号不支持 WeatherKit；付费账号也要先在开发者后台给这个 App ID 勾上 WeatherKit 能力。\n\n两条路：到「设置 → 天气」把来源换成「和风天气」（免费账号填一个 API Key 就能自动获取），或者直接在天气卡片上手动填写。"
        case .locationFailed(let reason):
            return "拿不到当前位置：\(reason)"
        case .noCity:
            return "先选一个城市"
        case .pastDate:
            return "系统天气只提供实况和未来几天的预报，过去的日子需要手填"
        case .outOfForecastRange(let days):
            return "预报只能查到未来 \(days) 天，这天还太远，先手填吧"
        case .fetchFailed(let reason):
            return reason
        }
    }
}

final class WeatherAPI {
    static let shared = WeatherAPI()

    /// WeatherKit 逐日预报大概覆盖的天数，用来说明「太远了查不到」
    static let forecastDays = 10

    private let db = Database.shared
    private let locationProvider = LocationProvider.shared

    /// 这台设备/这次安装能不能用 WeatherKit：第一次失败后记下来，之后直接给提示，不用每次都等网络超时
    private(set) var weatherKitUnavailable = false

    private init() {}

    /* ==================== 配置 ==================== */

    func getConfig() -> WeatherConfig {
        db.getWeatherConfig()
    }

    @discardableResult
    func setConfig(_ patch: (inout WeatherConfig) -> Void) -> WeatherConfig {
        db.saveWeatherConfig(patch: patch)
    }

    /// 当前选中的来源
    var provider: WeatherProvider { getConfig().currentProvider }

    /// 和风天气通道是否配好了（填了 Key 就算配好）
    var hasQWeatherKey: Bool {
        !getConfig().qweatherKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否允许自动获取（对应小程序「配了 Key 没有」的判断）
    func isConfigured() -> Bool {
        switch provider {
        case .qweather: return hasQWeatherKey
        case .system: return isAvailable
        }
    }

    /// 系统是否能提供天气数据（WeatherKit 需要 iOS 16 及以上）
    var isSupported: Bool {
        if #available(iOS 16.0, *) { return true }
        return false
    }

    /// 系统通道当前是否可用（免费个人账号 + 没开权限时是 false）
    var isSystemAvailable: Bool {
        isSupported && !weatherKitUnavailable
    }

    /// 当前来源是否可用
    var isAvailable: Bool {
        switch provider {
        case .qweather: return hasQWeatherKey
        case .system: return isSystemAvailable
        }
    }

    /* ==================== 城市 ==================== */

    /// 按关键字搜城市（对应 weather.js 的 searchCity），返回 [{ name, adm, 经纬度 }]
    func searchCity(_ keyword: String) async throws -> [CityRef] {
        let config = getConfig()
        if config.currentProvider == .qweather, hasQWeatherKey {
            // 和风天气自带城市搜索（返回的结果直接带经纬度）
            return try await QWeatherService.shared.searchCity(
                keyword,
                key: config.qweatherKey,
                host: config.qweatherHost
            )
        }

        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }

        let placemarks = try await CLGeocoder().geocodeAddressString(word)
        return placemarks.prefix(8).compactMap { placemark -> CityRef? in
            guard let coordinate = placemark.location?.coordinate else { return nil }
            let name = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.name
            guard let name, !name.isEmpty else { return nil }
            let adm = placemark.administrativeArea ?? ""
            return CityRef(
                name: name,
                // 省 / 直辖市与城市同名时只留一个，免得出现「北京 · 北京」
                adm: adm == name ? "" : adm,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }

    /// 当前位置所在的城市（日记页「用当前位置」）
    func currentCity() async throws -> CityRef {
        let location = try await locationProvider.requestLocation()
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                let name = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.name ?? "当前位置"
                let adm = placemark.administrativeArea ?? ""
                return CityRef(
                    name: name,
                    adm: adm == name ? "" : adm,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            }
        } catch {
            // 反查城市名失败也不影响取天气，用坐标继续
        }
        return CityRef(
            name: "当前位置",
            adm: "",
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    /* ==================== 天气 ==================== */

    /// 按日期取某城市的天气（对应 weather.js 的 fetchByDate）
    func fetchByDate(city: CityRef, date: String) async throws -> WeatherSnapshot {
        let config = getConfig()
        if config.currentProvider == .qweather {
            return try await QWeatherService.shared.fetch(
                city: city,
                date: date,
                key: config.qweatherKey,
                host: config.qweatherHost
            )
        }
        return try await fetchByDateFromSystem(city: city, date: date)
    }

    /// 和风天气连通性自检：拿一个已知城市（没有就用当前位置）取一次实况
    func testQWeather() async throws -> WeatherSnapshot {
        let config = getConfig()
        let city: CityRef
        if let last = config.lastCity, last.hasCoordinate {
            city = last
        } else {
            city = try await currentCity()
        }
        return try await QWeatherService.shared.fetch(
            city: city,
            date: DateUtil.today(),
            key: config.qweatherKey,
            host: config.qweatherHost
        )
    }

    /// 系统通道：WeatherKit
    private func fetchByDateFromSystem(city: CityRef, date: String) async throws -> WeatherSnapshot {
        guard #available(iOS 16.0, *) else { throw WeatherError.unsupportedSystem }
        guard !weatherKitUnavailable else { throw WeatherError.notEntitled }
        guard !date.isEmpty else { throw WeatherError.noCity }

        let today = DateUtil.today()
        guard date >= today else { throw WeatherError.pastDate }

        let location = try await resolveLocation(city)
        let current: CurrentWeather
        let daily: Forecast<DayWeather>
        do {
            (current, daily) = try await WeatherService.shared.weather(
                for: location,
                including: .current,
                .daily
            )
        } catch {
            if Self.isEntitlementError(error) {
                weatherKitUnavailable = true
                throw WeatherError.notEntitled
            }
            throw WeatherError.fetchFailed(Self.readable(error))
        }
        weatherKitUnavailable = false

        if date == today {
            return WeatherSnapshot(
                temp: Self.temperatureText(current.temperature),
                text: Self.text(for: current.condition),
                icon: Self.symbol(for: current.condition),
                kind: "now"
            )
        }

        let target = DateUtil.parseDate(date)
        if let day = daily.first(where: { Calendar.current.isDate($0.date, inSameDayAs: target) }) {
            let low = Int(day.lowTemperature.converted(to: .celsius).value.rounded())
            let high = Int(day.highTemperature.converted(to: .celsius).value.rounded())
            return WeatherSnapshot(
                temp: "\(low)~\(high)",
                text: Self.text(for: day.condition),
                icon: Self.symbol(for: day.condition),
                kind: "forecast"
            )
        }
        throw WeatherError.outOfForecastRange(WeatherAPI.forecastDays)
    }

    /* ==================== 内部 ==================== */

    /// 城市带了坐标就直接用；没坐标（手填的城市）时退回当前位置
    private func resolveLocation(_ city: CityRef) async throws -> CLLocation {
        if city.hasCoordinate {
            return CLLocation(latitude: city.latitude, longitude: city.longitude)
        }
        return try await locationProvider.requestLocation()
    }

    private static func temperatureText(_ measurement: Measurement<UnitTemperature>) -> String {
        String(Int(measurement.converted(to: .celsius).value.rounded()))
    }

    /// WeatherCondition -> 中文说法（对应小程序里接口返回的 text）
    static func text(for condition: WeatherCondition) -> String {
        switch condition {
        case .clear, .hot: return "晴"
        case .mostlyClear: return "晴间多云"
        case .partlyCloudy: return "多云"
        case .mostlyCloudy, .cloudy: return "阴"
        case .foggy: return "雾"
        case .haze, .smoky, .blowingDust: return "霾"
        case .breezy, .windy: return "大风"
        case .drizzle, .freezingDrizzle: return "小雨"
        case .rain, .sunShowers: return "中雨"
        case .heavyRain: return "大雨"
        case .freezingRain, .sleet, .wintryMix, .hail: return "雨夹雪"
        case .snow, .flurries: return "小雪"
        case .heavySnow: return "大雪"
        case .blizzard, .blowingSnow: return "暴雪"
        case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms: return "雷阵雨"
        case .strongStorms, .tropicalStorm, .hurricane: return "雷雨大风"
        case .frigid: return "严寒"
        default: return "多云"
        }
    }

    /// 存一个 SF Symbol 名字当图标（小程序存的是和风天气的图标码，iOS 版换成系统图标）
    static func symbol(for condition: WeatherCondition) -> String {
        switch condition {
        case .clear, .hot: return "sun.max.fill"
        case .mostlyClear, .partlyCloudy: return "cloud.sun.fill"
        case .mostlyCloudy, .cloudy: return "cloud.fill"
        case .foggy, .haze, .smoky, .blowingDust: return "cloud.fog.fill"
        case .breezy, .windy: return "wind"
        case .drizzle, .rain, .freezingRain, .sleet: return "cloud.rain.fill"
        case .heavyRain, .strongStorms, .tropicalStorm, .hurricane: return "cloud.heavyrain.fill"
        case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms: return "cloud.bolt.rain.fill"
        case .snow, .flurries, .heavySnow, .blizzard, .blowingSnow, .wintryMix, .hail: return "cloud.snow.fill"
        case .frigid: return "thermometer.snowflake"
        default: return "cloud.fill"
        }
    }

    /// WeatherKit 没有权限时的报错长得比较杂（有的来自 WeatherDaemon 的鉴权代理），统一按「没权限」处理
    private static func isEntitlementError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == 401 { return true }
        let text = "\(nsError.domain) \(nsError.localizedDescription)".lowercased()
        let markers = [
            "weatherdaemon", "wdsjwt", "authenticat", "unauthorized", "unauthorised",
            "not entitled", "entitlement", "authorization", "authorisation",
        ]
        return markers.contains { text.contains($0) }
    }

    /// 把系统错误翻成人话，并把最常见的「能力没开」讲清楚（对应小程序里那段常见原因提示）
    private static func readable(_ error: Error) -> String {
        let message = (error as NSError).localizedDescription
        let code = (error as NSError).code
        if message.contains("Network") || code == -1009 {
            return "网络不可用，稍后再试，或者先手填"
        }
        return "获取天气失败：\(message)"
    }
}

/// 定位（只在用户主动点「获取天气」时才会用到）
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutWork: DispatchWorkItem?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// 取一次当前位置；被拒绝 / 超时都会抛错，由页面提示用户手填
    func requestLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let work = DispatchWorkItem { [weak self] in
                self?.finish(with: .failure(WeatherError.locationFailed("定位超时")))
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
            start()
        }
    }

    private func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(with: .failure(WeatherError.notAuthorized))
        default:
            manager.requestLocation()
        }
    }

    private func finish(with result: Result<CLLocation, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    /* ==================== CLLocationManagerDelegate ==================== */

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            return
        case .denied, .restricted:
            finish(with: .failure(WeatherError.notAuthorized))
        default:
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(with: .failure(WeatherError.locationFailed("没有拿到坐标")))
            return
        }
        finish(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: .failure(WeatherError.locationFailed(error.localizedDescription)))
    }
}
