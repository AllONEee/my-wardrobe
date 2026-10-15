//
//  Format.swift —— 金额 / 百分比 / 天数这些到处都要用的格式化
//
//  金额规则（全 App 统一，别在各页面自己拼字符串）：
//   - 整数不带小数点：¥1280
//   - 有小数时最多两位：¥38.5 / ¥38.52
//   - 超过一万加千分位：¥12,800
//

import Foundation

enum Money {
    /// ¥1280 / ¥38.5
    static func text(_ value: Double) -> String {
        "¥" + number(value)
    }

    /// 单次成本：¥38.5/次
    static func costPerWear(_ value: Double) -> String {
        "¥" + number(value) + "/次"
    }

    /// 不带符号的数字
    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return grouped(String(Int(rounded.rounded())))
        }
        var text = String(format: "%.2f", rounded)
        // 38.50 -> 38.5，38.00 -> 38
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        let parts = text.split(separator: ".", maxSplits: 1)
        if parts.count == 2 {
            return grouped(String(parts[0])) + "." + parts[1]
        }
        return grouped(String(parts[0]))
    }

    /// 千分位
    private static func grouped(_ raw: String) -> String {
        var value = raw
        var negative = false
        if value.hasPrefix("-") {
            negative = true
            value.removeFirst()
        }
        guard value.count > 3 else { return negative ? "-" + value : value }
        var result = ""
        var counter = 0
        for character in value.reversed() {
            if counter > 0, counter % 3 == 0 { result.append(",") }
            result.append(character)
            counter += 1
        }
        let output = String(result.reversed())
        return negative ? "-" + output : output
    }
}

enum Percent {
    /// 0.234 -> 23%
    static func text(_ value: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", value * 100)
    }
}
