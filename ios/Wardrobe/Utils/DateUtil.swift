//
//  DateUtil.swift —— 日期工具（对应 utils/date.js）
//
//  约定：业务里日期一律用 'YYYY-MM-DD' 字符串（本地时区）表示，
//       解析、格式化都走这里，避免各处自己拼字符串导致差一天。
//

import Foundation

/// 月历里的一格（对应 date.js 的 buildCell 返回值）
struct CalendarCell: Identifiable, Hashable {
    var date: String
    var day: Int
    var month: Int
    var inMonth: Bool
    var isToday: Bool
    var isFuture: Bool

    var id: String { date }
}

enum DateUtil {
    /// 周日开头的星期标签
    static let weekLabels = ["日", "一", "二", "三", "四", "五", "六"]

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        cal.timeZone = TimeZone.current
        cal.firstWeekday = 1 // 周日
        return cal
    }

    static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Date -> 'YYYY-MM-DD'
    static func formatDate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(pad(parts.month ?? 1))-\(pad(parts.day ?? 1))"
    }

    /// 'YYYY-MM-DD' -> Date（本地时区 0 点），非法输入返回今天
    static func parseDate(_ string: String) -> Date {
        let parts = string.split(separator: "-")
        guard parts.count >= 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return Date()
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? Date()
    }

    static func today() -> String {
        formatDate(Date())
    }

    static func isSameDay(_ a: String, _ b: String) -> Bool {
        formatDate(parseDate(a)) == formatDate(parseDate(b))
    }

    static func addDays(_ dateString: String, _ days: Int) -> String {
        let date = calendar.date(byAdding: .day, value: days, to: parseDate(dateString)) ?? Date()
        return formatDate(date)
    }

    /// 月份加减，返回该月 1 号的 'YYYY-MM-DD'
    static func addMonths(_ monthKey: String, _ delta: Int) -> String {
        let first = parseDate(monthKey + "-01")
        let date = calendar.date(byAdding: .month, value: delta, to: first) ?? first
        return formatDate(date)
    }

    /// 'YYYY-MM-DD' -> 'YYYY-MM'
    static func monthKeyOf(_ dateString: String) -> String {
        String(formatDate(parseDate(dateString)).prefix(7))
    }

    /// 'YYYY-MM' -> '2026年10月'
    static func formatMonthTitle(_ monthKey: String) -> String {
        let parts = monthKey.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return monthKey }
        return "\(year)年\(month)月"
    }

    static func formatMonthDay(_ dateString: String) -> String {
        let parts = calendar.dateComponents([.month, .day], from: parseDate(dateString))
        return "\(parts.month ?? 1)月\(parts.day ?? 1)日"
    }

    /// 今天 / 昨天 / M月D日 / YYYY年M月D日
    static func friendlyDate(_ dateString: String) -> String {
        let date = parseDate(dateString)
        let normalized = formatDate(date)
        let todayKey = today()
        if normalized == todayKey { return "今天" }
        if normalized == addDays(todayKey, -1) { return "昨天" }
        let parts = calendar.dateComponents([.year], from: date)
        let currentYear = calendar.dateComponents([.year], from: Date()).year
        if parts.year == currentYear { return formatMonthDay(dateString) }
        return "\(parts.year ?? 0)年\(formatMonthDay(dateString))"
    }

    /// 'YYYY-MM-DD' -> 'M月D日 HH:mm'（天气卡片的「自动获取 · …」用）
    static func timeText(_ milliseconds: Double) -> String {
        guard milliseconds > 0 else { return "" }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return "\(formatMonthDay(formatDate(date))) \(pad(parts.hour ?? 0)):\(pad(parts.minute ?? 0))"
    }

    /// 两个日期相差多少天（对应 date.js 的 daysBetween）
    static func daysBetween(_ from: String, _ to: String) -> Int {
        let start = calendar.startOfDay(for: parseDate(from))
        let end = calendar.startOfDay(for: parseDate(to))
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return days
    }

    /// 生成月历网格（周日开头，固定 6 行 42 格，切换月份时高度不跳）——对应 date.js 的 monthGrid
    static func monthGrid(_ monthKey: String) -> [CalendarCell] {
        let parts = monthKey.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return [] }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        let firstDay = calendar.date(from: components) ?? Date()

        let startWeekday = calendar.component(.weekday, from: firstDay) - 1 // 0 = 周日
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstDay)?.count ?? 30
        let todayKey = today()

        var cells: [CalendarCell] = []
        // 前置补位（上个月的末尾几天）
        for offset in 0..<startWeekday {
            let date = calendar.date(byAdding: .day, value: offset - startWeekday, to: firstDay) ?? firstDay
            cells.append(buildCell(date, month: month, todayKey: todayKey, inMonth: false))
        }
        for day in 1...daysInMonth {
            var dayComponents = components
            dayComponents.day = day
            let date = calendar.date(from: dayComponents) ?? firstDay
            cells.append(buildCell(date, month: month, todayKey: todayKey, inMonth: true))
        }
        // 补满 42 格
        while cells.count < 42 {
            guard let last = cells.last else { break }
            let date = calendar.date(byAdding: .day, value: 1, to: parseDate(last.date)) ?? Date()
            cells.append(buildCell(date, month: month, todayKey: todayKey, inMonth: false))
        }
        return cells
    }

    private static func buildCell(_ date: Date, month: Int, todayKey: String, inMonth: Bool) -> CalendarCell {
        let dateString = formatDate(date)
        let parts = calendar.dateComponents([.day, .month], from: date)
        let cellMonth = parts.month ?? month
        return CalendarCell(
            date: dateString,
            day: parts.day ?? 1,
            month: cellMonth,
            inMonth: cellMonth == month ? inMonth : false,
            isToday: dateString == todayKey,
            isFuture: dateString > todayKey
        )
    }
}
