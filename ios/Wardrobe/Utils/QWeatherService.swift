//
//  QWeatherService.swift —— 和风天气（备用通道）
//
//  系统自带的 WeatherKit 需要付费开发者账号 + 后台开能力，免费账号用不了；
//  这里补一条「填一个 Key 就能自动获取天气」的备用通道，两条通道在设置里二选一。
//
//  接口（和风天气开发服务，官方文档 https://dev.qweather.com/docs/api/）：
//   - 实况天气  GET https://<host>/v7/weather/now?location=经度,纬度&key=KEY&lang=zh&unit=m
//   - 逐日预报  GET https://<host>/v7/weather/3d?location=经度,纬度&key=KEY&lang=zh&unit=m
//   - 城市搜索  GET https://<host>/geo/v2/city/lookup?location=关键字&key=KEY&lang=zh
//
//  关于 API Host：老账号（免费开发版）用 devapi.qweather.com，城市搜索在 geoapi.qweather.com；
//  2024 年之后的新账号每人一个专属域名（形如 abc123.re.qweatherapi.com），两个接口都在这个域名下。
//  所以这里用「配置的 host 打头、失败再退回 geoapi.qweather.com」的方式兼容两种账号。
//
//  返回结构与小程序的 weather.js 对齐（{ temp, text, icon, kind }），其中 icon 存的是 SF Symbol 名，
//  由和风天气的图标码（100 / 305 / 501 …）映射过来。
//

import Foundation

final class QWeatherService {
    static let shared = QWeatherService()

    /// 老账号（免费开发版）的默认接口域名
    static let defaultHost = "devapi.qweather.com"
    /// 城市搜索的老域名（新账号在专属域名下也有同样的路径）
    private static let legacyGeoHost = "geoapi.qweather.com"
    /// 免费开发版能查到的预报天数（付费版才有 7d / 10d / 15d / 30d）
    static let forecastDays = 3

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    /* ==================== 对外接口 ==================== */

    /// 按日期取天气：今天取实况，未来几天取逐日预报（过去的日子和风天气也要付费才有历史数据）
    func fetch(city: CityRef, date: String, key: String, host: String) async throws -> WeatherSnapshot {
        let apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw WeatherError.fetchFailed("还没填和风天气的 API Key，去「设置 → 天气」里填一个")
        }
        guard city.hasCoordinate else {
            throw WeatherError.noCity
        }

        let today = DateUtil.today()
        guard date >= today else { throw WeatherError.pastDate }

        let location = String(format: "%.4f,%.4f", city.longitude, city.latitude)

        if date == today {
            let now = try await request(NowResponse.self, path: "/v7/weather/now", host: host, key: apiKey, query: ["location": location])
            guard let item = now.now else { throw WeatherError.fetchFailed("和风天气没有返回实况数据") }
            return WeatherSnapshot(temp: item.temp, text: item.text, icon: Self.symbol(forCode: item.icon), kind: "now")
        }

        let daily = try await request(DailyResponse.self, path: "/v7/weather/3d", host: host, key: apiKey, query: ["location": location])
        guard let day = daily.daily?.first(where: { $0.fxDate == date }) else {
            // 三天以外的日子免费版查不到，让用户知道大概是这个原因
            let days = (daily.daily?.count ?? 0) > 0 ? (daily.daily?.count ?? Self.forecastDays) : Self.forecastDays
            throw WeatherError.outOfForecastRange(days)
        }
        let low = Int(day.tempMin) ?? 0
        let high = Int(day.tempMax) ?? 0
        return WeatherSnapshot(
            temp: "\(low)~\(high)",
            text: day.textDay,
            icon: Self.symbol(forCode: day.iconDay),
            kind: "forecast"
        )
    }

    /// 城市搜索（返回带经纬度的结果，可以直接用来取天气）
    func searchCity(_ keyword: String, key: String, host: String) async throws -> [CityRef] {
        let apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw WeatherError.fetchFailed("先填和风天气的 API Key") }

        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }

        let response: GeoResponse
        do {
            response = try await request(GeoResponse.self, path: "/geo/v2/city/lookup", host: host, key: apiKey, query: ["location": word])
        } catch let error as WeatherError {
            // 老账号的城市搜索在另一个域名下，这里再试一次
            guard case .fetchFailed = error else { throw error }
            response = try await request(
                GeoResponse.self,
                path: "/geo/v2/city/lookup",
                host: Self.legacyGeoHost,
                key: apiKey,
                query: ["location": word]
            )
        }

        return (response.location ?? []).prefix(8).compactMap { item -> CityRef? in
            guard let latitude = Double(item.lat), let longitude = Double(item.lon) else { return nil }
            let adm = item.adm1 ?? ""
            let name = item.name
            return CityRef(name: name, adm: adm == name ? "" : adm, latitude: latitude, longitude: longitude)
        }
    }

    /* ==================== 请求 ==================== */

    /// 组装 https://<host><path>?... 并把和风天气的状态码翻成人话
    private func request<T: Decodable & QWeatherCoded>(
        _ type: T.Type,
        path: String,
        host: String,
        key: String,
        query: [String: String]
    ) async throws -> T {
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "key", value: key))
        items.append(URLQueryItem(name: "lang", value: "zh"))
        items.append(URLQueryItem(name: "unit", value: "m"))

        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.normalize(host: host)
        components.path = path
        components.queryItems = items

        guard let url = components.url else {
            throw WeatherError.fetchFailed("接口地址不对，检查一下「设置 → 天气」里的 API Host")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorNotConnectedToInternet || nsError.code == NSURLErrorTimedOut {
                throw WeatherError.fetchFailed("网络不可用，稍后再试，或者先手填")
            }
            throw WeatherError.fetchFailed("连不上和风天气：\(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw WeatherError.fetchFailed("和风天气返回 HTTP \(status)，检查 Key 和 API Host 是否与账号匹配")
        }

        let payload: T
        do {
            payload = try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WeatherError.fetchFailed("和风天气返回的内容看不懂：\(error.localizedDescription)")
        }

        if payload.code != "200" {
            throw Self.error(forCode: payload.code)
        }
        return payload
    }

    /// 和风天气的状态码（https://dev.qweather.com/docs/resource/status-code/）
    private static func error(forCode code: String) -> WeatherError {
        switch code {
        case "204":
            return .fetchFailed("和风天气没有这天的数据（免费版只提供未来 3 天预报，过去的日子要手填）")
        case "400":
            return .fetchFailed("请求参数有问题（城市坐标为空？）")
        case "401":
            return .fetchFailed("和风天气的 API Key 无效：去「设置 → 天气」里核对一下 Key 和 API Host")
        case "402":
            return .fetchFailed("和风天气的访问次数用完了，明天再试或者换系统天气")
        case "403":
            return .fetchFailed("这个 Key 没有权限访问该数据（免费版只能查实况和 3 天预报）")
        case "404":
            return .fetchFailed("和风天气查不到这个城市，换一个城市试试")
        case "500":
            return .fetchFailed("和风天气服务出错了，稍后再试")
        default:
            return .fetchFailed("和风天气返回状态码 \(code)")
        }
    }

    /// host 允许写成 devapi.qweather.com / https://devapi.qweather.com/ / 带路径的专属域名
    static func normalize(host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return defaultHost }
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[value.startIndex..<slash])
        }
        return value.isEmpty ? defaultHost : value
    }

    /* ==================== 图标码 -> SF Symbol ==================== */

    /// 和风天气的图标码（100 晴 / 305 小雨 / 501 雾 …）映射成系统图标名
    static func symbol(forCode code: String) -> String {
        guard let value = Int(code) else { return "cloud.fill" }
        switch value {
        case 100, 150: return "sun.max.fill"
        case 101, 102, 103, 151, 152, 153: return "cloud.sun.fill"
        case 104: return "cloud.fill"
        case 200...213: return "wind"
        case 300...304: return "cloud.bolt.rain.fill"
        case 305...309: return "cloud.rain.fill"
        case 310...318, 399: return "cloud.heavyrain.fill"
        case 400...403: return "cloud.snow.fill"
        case 404...406: return "cloud.sleet.fill"
        case 407...410: return "cloud.snow.fill"
        case 456, 457: return "cloud.sleet.fill"
        case 499: return "cloud.snow.fill"
        case 501, 509, 510, 514, 515: return "cloud.fog.fill"
        case 502, 511, 512, 513: return "cloud.fog.fill"
        case 503, 504, 507, 508: return "sun.dust.fill"
        case 900: return "thermometer.sun.fill"
        case 901: return "thermometer.snowflake"
        default: return "cloud.fill"
        }
    }
}

/* ==================== 返回结构 ==================== */

/// 和风天气的返回都带一个 status code（"200" / "401" …）
protocol QWeatherCoded {
    var code: String { get }
}

struct NowResponse: Decodable, QWeatherCoded {
    let code: String
    let now: Item?

    struct Item: Decodable {
        let temp: String
        let text: String
        let icon: String
    }
}

struct DailyResponse: Decodable, QWeatherCoded {
    let code: String
    let daily: [Item]?

    struct Item: Decodable {
        let fxDate: String
        let tempMax: String
        let tempMin: String
        let textDay: String
        let iconDay: String
    }
}

struct GeoResponse: Decodable, QWeatherCoded {
    let code: String
    let location: [Item]?

    struct Item: Decodable {
        let name: String
        let adm1: String?
        let lat: String
        let lon: String
    }
}
